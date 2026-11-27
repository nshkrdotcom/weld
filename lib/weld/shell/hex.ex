defmodule Weld.Shell.Hex do
  @moduledoc """
  Strict archive observations and an exact-byte Hex Core 0.21.1 transport.
  Publication outcomes are append-only. Uncertain writes require reconciliation.
  """
  alias Weld.Core.{Identity, Inventory}
  alias Weld.Shell.Files
  alias Weld.{Error, Hash, Output}

  @outer ~w(CHECKSUM VERSION contents.tar.gz metadata.config)
  @archive_limit 16 * 1024 * 1024
  @expanded_limit 128 * 1024 * 1024
  @outcome_keys ~w(schema id operation artifact bundle_id package version destination expected_archive_sha256 expected_docs_sha256 previous_id package_state docs_state observed recorded_at)
  @states ~w(not_attempted not_sent submitting staged confirmed rejected unknown conflict not_applicable)

  def freeze_docs!(directory, target) do
    ensure_core!()
    {observed, empty_dirs} = Files.tree!(directory)

    files =
      Enum.map(observed, fn entry ->
        {to_charlist(entry.target), File.read!(Output.source!(directory, entry.target)),
         %{executable: entry.executable}}
      end)

    directories = Enum.map(empty_dirs, &{to_charlist(&1), to_charlist(Path.join(directory, &1))})
    config = Map.put(:hex_core.default_config(), :tarball_files_root, to_charlist(directory))

    with {:ok, bytes} <- :hex_tarball.create_docs(files ++ directories, config),
         true <- byte_size(bytes) <= @archive_limit do
      File.write!(target, bytes, [:exclusive, :sync])
      actual = docs_observation!(target)

      unless actual.entries == records(observed) and actual.empty_dirs == empty_dirs,
        do: raise(Error, "frozen documentation archive differs from the docs payload")

      %{
        path: target,
        entries: actual.entries,
        empty_dirs: empty_dirs,
        sha256: Identity.raw(bytes)
      }
    else
      _ -> raise Error, "cannot build bounded frozen documentation archive"
    end
  end

  def docs_observation!(path) do
    ensure_core!()
    bytes = read_archive!(path)

    with {:ok, contents} <- :hex_tarball.unpack_docs(bytes, :memory),
         {:ok, plain} <- :hex_registry.gunzip(bytes, @expanded_limit) do
      archive_observation!(plain, contents)
    else
      _ -> raise Error, "invalid documentation archive"
    end
  end

  def package_observation!(path) do
    ensure_core!()
    bytes = read_archive!(path)

    with {:ok, outer} <- :erl_tar.extract({:binary, bytes}, [:memory]),
         {:ok, outer_headers} <- :erl_tar.table({:binary, bytes}, [:verbose]),
         true <- Enum.sort(Enum.map(outer, fn {name, _} -> to_string(name) end)) == @outer,
         true <- length(outer_headers) == 4,
         true <- Enum.all?(outer_headers, &outer_header?(&1, outer)),
         {:ok,
          %{
            contents: contents,
            metadata: metadata,
            inner_checksum: inner,
            outer_checksum: outer_sha
          }} <- :hex_tarball.unpack(bytes, :memory),
         {_, raw_metadata} <- List.keyfind(outer, ~c"metadata.config", 0),
         :ok <- validate_raw_metadata!(raw_metadata),
         {_, compressed} <- List.keyfind(outer, ~c"contents.tar.gz", 0),
         {:ok, plain} <- :hex_registry.gunzip(compressed, @expanded_limit) do
      observed = archive_observation!(plain, contents)
      names = Enum.sort(Enum.map(observed.entries, & &1["path"]) ++ observed.directories)
      declared = Map.get(metadata, "files", [])

      unless is_list(declared) and Enum.sort(declared) == names and
               length(Enum.uniq(declared)) == length(declared),
             do: raise(Error, "Hex metadata file membership differs from actual archive members")

      Map.merge(observed, %{
        metadata: normalize_metadata!(metadata),
        outer_checksum: hex(outer_sha),
        inner_checksum: hex(inner)
      })
    else
      _ -> raise Error, "invalid Hex archive envelope, checksum or metadata"
    end
  end

  def check_package!(tarball, root, paths, expected, opts \\ []) do
    observed = package_observation!(tarball)
    files = Files.observe_many!(root, paths) |> records()

    unless files == observed.entries,
      do: raise(Error, "Hex archive paths, modes, sizes or bytes differ from package inventory")

    empty_dirs = Enum.sort(opts[:empty_dirs] || [])

    unless observed.empty_dirs == empty_dirs,
      do: raise(Error, "Hex archive empty directory membership differs")

    for directory <- observed.directories do
      allowed =
        directory in empty_dirs or
          Enum.any?(paths ++ empty_dirs, &String.starts_with?(&1, directory <> "/"))

      unless allowed and File.dir?(Output.source!(root, directory)),
        do: raise(Error, "Hex archive contains an unplanned publication directory: #{directory}")
    end

    expected = expected_metadata(expected) |> Map.delete("files")

    for {key, value} <- expected do
      unless observed.metadata[key] == value,
        do: raise(Error, "Hex package metadata differs at #{key}")
    end

    :ok
  end

  @doc false
  def validate_dependency_metadata!(metadata, dependencies) do
    expected =
      Enum.reduce(dependencies, %{}, fn dep, acc ->
        {app, requirement, options} =
          case dep do
            %{"app" => app, "requirement" => requirement, "opts" => opts} ->
              {app, requirement, opts}

            [app, requirement, opts] ->
              {app, requirement, opts}

            _ ->
              raise Error, "unsupported publication dependency record"
          end

        opts =
          if is_list(options),
            do: Map.new(options, fn [key, value] -> {key, value} end),
            else: options

        if is_nil(opts["only"]) or "prod" in List.wrap(opts["only"]) do
          unless is_binary(requirement) and is_nil(opts["path"]) and is_nil(opts["git"]) and
                   is_nil(opts["github"]),
                 do: raise(Error, "non-Hex dependency in publishable package")

          name = opts["hex"] || app
          if Map.has_key?(acc, name), do: raise(Error, "duplicate publication dependency alias")

          repository =
            (opts["repo"] ||
               if(opts["organization"], do: "hexpm:" <> opts["organization"], else: "hexpm"))
            |> String.split(":", parts: 2)
            |> List.last()

          Map.put(acc, name, %{
            "app" => app,
            "requirement" => requirement,
            "optional" => opts["optional"] || false,
            "repository" => repository
          })
        else
          acc
        end
      end)

    unless normalize_requirements!(metadata["requirements"] || %{}) == expected,
      do: raise(Error, "archive dependencies differ from compiler inventory")

    :ok
  end

  defp expected_metadata(%{otp_app: app, name: name, version: version}),
    do: %{"app" => to_string(app), "name" => name, "version" => version}

  defp expected_metadata(metadata) when is_map(metadata), do: normalize_metadata!(metadata)

  @doc false
  def normalize_metadata!(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), metadata_value!(value)} end)
    |> Map.update("requirements", %{}, &normalize_requirements!/1)
    |> Map.update("files", [], &Enum.sort/1)
  end

  defp metadata_value!(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), metadata_value!(item)} end)

  defp metadata_value!(value) when is_list(value) do
    pairs? =
      value != [] and
        Enum.all?(value, fn
          {key, _} when is_binary(key) or is_atom(key) -> true
          _ -> false
        end)

    if pairs? do
      keys = Enum.map(value, fn {key, _} -> to_string(key) end)

      unless length(keys) == length(Enum.uniq(keys)),
        do: raise(Error, "duplicate Hex metadata keys")

      Map.new(value, fn {key, item} -> {to_string(key), metadata_value!(item)} end)
    else
      Enum.map(value, &metadata_value!/1)
    end
  end

  defp metadata_value!(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_nil(value), do: value

  defp metadata_value!(_), do: raise(Error, "unsupported Hex metadata value")

  defp normalize_requirements!(requirements) when is_map(requirements) do
    Map.new(requirements, fn {name, requirement} ->
      unless is_binary(name) and is_map(requirement) and is_binary(requirement["requirement"]),
        do: raise(Error, "invalid Hex dependency metadata")

      unless Map.keys(requirement) -- ~w(app requirement optional repository) == [],
        do: raise(Error, "unsupported Hex dependency metadata")

      {name,
       requirement
       |> Map.put_new("app", name)
       |> Map.put_new("optional", false)
       |> Map.put_new("repository", "hexpm")}
    end)
  end

  defp normalize_requirements!(requirements) when is_list(requirements) do
    requirements = metadata_value!(requirements)

    if is_map(requirements),
      do: normalize_requirements!(requirements),
      else: named_requirements!(requirements)
  end

  defp normalize_requirements!(_), do: raise(Error, "unsupported Hex dependency representation")

  defp named_requirements!(requirements) do
    pairs =
      Enum.map(requirements, fn
        %{"name" => name} = requirement when is_binary(name) ->
          {name, Map.delete(requirement, "name")}

        _ ->
          raise Error, "unsupported Hex dependency representation"
      end)

    unless length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs),
      do: raise(Error, "duplicate Hex dependency metadata")

    normalize_requirements!(Map.new(pairs))
  end

  # Use the pinned decoder's non-atom-creating lexer before it collapses a
  # proplist into a map. Ambiguous duplicate keys must never become evidence.
  defp validate_raw_metadata!(bytes) when byte_size(bytes) <= 1024 * 1024 do
    unless String.valid?(bytes), do: raise(Error, "Hex metadata must be UTF-8")
    raw_terms!(String.to_charlist(bytes), MapSet.new())
  end

  defp validate_raw_metadata!(_), do: raise(Error, "Hex metadata exceeds its bound")

  defp raw_terms!(chars, seen) do
    case :safe_erl_term.tokens([], chars) do
      {:done, {:ok, tokens, _}, rest} ->
        case :erl_parse.parse_term(tokens) do
          {:ok, {key, value}} when is_binary(key) ->
            if MapSet.member?(seen, key), do: raise(Error, "duplicate Hex metadata key")
            validate_raw_value!(value)
            raw_terms!(rest, MapSet.put(seen, key))

          _ ->
            raise Error, "invalid Hex metadata term"
        end

      {:more, continuation} ->
        unless match?({:done, {:eof, _}, _}, :safe_erl_term.tokens(continuation, :eof)),
          do: raise(Error, "truncated Hex metadata term")

        :ok

      {:done, {:eof, _}, _} ->
        :ok

      _ ->
        raise Error, "invalid safe Hex metadata tokens"
    end
  end

  defp validate_raw_value!(value) when is_list(value) do
    if value != [] and Enum.all?(value, &match?({key, _} when is_binary(key), &1)) do
      keys = Enum.map(value, &elem(&1, 0))

      unless length(keys) == length(Enum.uniq(keys)),
        do: raise(Error, "duplicate nested Hex metadata key")
    end

    Enum.each(value, &validate_raw_value!/1)
  end

  defp validate_raw_value!({key, value}) when is_binary(key), do: validate_raw_value!(value)

  defp validate_raw_value!(value)
       when is_binary(value) or is_integer(value) or value in [nil, true, false], do: :ok

  defp validate_raw_value!(_), do: raise(Error, "unsupported raw Hex metadata value")

  defp archive_observation!(plain, contents) do
    with {:ok, headers} <- :erl_tar.table({:binary, plain}, [:verbose]) do
      names = Enum.map(headers, &header_name!/1)

      unless length(Enum.uniq(names)) == length(names),
        do: raise(Error, "duplicate archive member")

      content_names = Enum.map(contents, fn {name, _} -> to_string(name) end)

      unless length(Enum.uniq(content_names)) == length(content_names),
        do: raise(Error, "duplicate archive content")

      content = Map.new(contents, fn {name, bytes} -> {to_string(name), bytes} end)

      {entries, directories} =
        Enum.reduce(headers, {[], []}, fn header, {files, dirs} ->
          {name, type, size, _time, mode, _uid, _gid} = header
          path = header_name!(header)

          case type do
            :regular ->
              bytes = Map.get(content, to_string(name))

              unless is_binary(bytes) and byte_size(bytes) == size and
                       Bitwise.band(mode, 0o7777) in [0o644, 0o755],
                     do:
                       raise(Error, "archive member has invalid size or normalized mode: #{path}")

              entry = %{
                "path" => path,
                "sha256" => Identity.raw(bytes),
                "size" => size,
                "executable" => Bitwise.band(mode, 0o111) != 0
              }

              {[entry | files], dirs}

            :directory ->
              unless size == 0 and Bitwise.band(mode, 0o7777) == 0o755,
                do: raise(Error, "archive directory has invalid mode or size: #{path}")

              {files, [path | dirs]}

            _ ->
              raise Error, "archive contains a link or unsupported entry: #{path}"
          end
        end)

      unless Enum.sort(content_names) == Enum.sort(Enum.map(entries, & &1["path"])),
        do: raise(Error, "archive table and extracted content disagree")

      _ =
        Inventory.validate!(
          Enum.map(entries, fn entry -> Map.put(entry, :target, entry["path"]) end)
        )

      files = MapSet.new(Enum.map(entries, & &1["path"]))

      for directory <- directories do
        if MapSet.member?(files, directory) or
             Enum.any?(files, &String.starts_with?(directory, &1 <> "/")),
           do: raise(Error, "archive file/directory collision")
      end

      empty =
        Enum.reject(directories, fn directory ->
          Enum.any?(names, &String.starts_with?(&1, directory <> "/"))
        end)

      %{
        entries: Enum.sort_by(entries, & &1["path"]),
        empty_dirs: Enum.sort(empty),
        directories: Enum.sort(directories)
      }
    else
      _ -> raise Error, "malformed archive headers or checksum"
    end
  rescue
    error in ArgumentError -> raise Error, Exception.message(error)
  end

  defp header_name!({name, type, _size, _time, _mode, _uid, _gid}) do
    raw = to_string(name)
    path = if type == :directory, do: String.trim_trailing(raw, "/"), else: raw
    if String.ends_with?(raw, "//"), do: raise(Error, "ambiguous archive directory path")
    Inventory.validate_path!(path)
  end

  defp header_name!(_), do: raise(Error, "unsupported archive header")

  defp outer_header?({name, :regular, size, _time, mode, _uid, _gid}, contents) do
    case List.keyfind(contents, name, 0) do
      {_, bytes} ->
        to_string(name) in @outer and size == byte_size(bytes) and
          Bitwise.band(mode, 0o7777) == 0o644

      _ ->
        false
    end
  end

  defp outer_header?(_, _), do: false

  defp read_archive!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @archive_limit -> File.read!(path)
      _ -> raise Error, "archive missing, unsafe or larger than #{@archive_limit} bytes"
    end
  end

  defp records(entries),
    do:
      Enum.map(entries, fn entry ->
        %{
          "path" => entry.target,
          "sha256" => entry.sha256,
          "size" => entry.size,
          "executable" => entry.executable
        }
      end)

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "Public destination used to serialize writes for a package/version."
  def destination(opts) do
    case opts[:transport] do
      %{trust: %{destination: destination}} -> safe_endpoint!(destination, true)
      _ -> safe_endpoint!(configured_core()[:api_url], false)
    end
  end

  def publish!(selector, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)
    result = result(metadata, candidate)

    if opts[:dry_run] == true do
      Map.merge(result, %{
        dry_run: true,
        completed?: false,
        exit_status: 0,
        action: :validated_local_bytes
      })
    else
      unless opts[:yes] == true,
        do: raise(Error, "publication requires --yes after inspecting the pinned bundle")

      transport = transport!(opts, :write)
      history = history!(selector, candidate, transport.trust.destination)
      prior = List.last(history)
      remote = observe(transport, candidate, prior)
      ensure_retry!(prior, remote, metadata)

      {history, remote} =
        submit_part!(selector, history, metadata, candidate, transport, remote, :package)

      {history, remote} =
        if remote.package.state == "confirmed" do
          submit_part!(selector, history, metadata, candidate, transport, remote, :docs)
        else
          {history, remote}
        end

      _ = history

      Map.merge(result, %{
        state: overall(remote),
        remote: wire_remote(remote),
        completed?: overall(remote) == "confirmed",
        exit_status: if(overall(remote) == "confirmed", do: 0, else: 1)
      })
    end
  end

  @doc "Read the latest durable outcome without credentials or network observations."
  def local_status(selector, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)
    List.last(history!(selector, candidate, destination(opts)))
  end

  def status(selector, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)
    transport = transport!(opts, :read)
    prior = List.last(history!(selector, candidate, transport.trust.destination))
    %{remote: wire_remote(observe(transport, candidate, prior)), local_outcome: prior}
  end

  def reconcile!(selector, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)
    transport = transport!(opts, :read)
    history = history!(selector, candidate, transport.trust.destination)
    remote = observe(transport, candidate, List.last(history))
    _ = append_outcome!(selector, history, metadata, candidate, transport, remote, "reconcile")

    Map.merge(result(metadata, candidate), %{
      state: overall(remote),
      remote: wire_remote(remote),
      completed?: overall(remote) == "confirmed"
    })
  end

  defp candidate!(bundle, metadata) do
    package_record = metadata["files"]["package"]
    docs_record = metadata["files"]["docs_archive"]

    unless is_map(package_record) and is_map(docs_record),
      do: raise(Error, "bundle is not Hex publishable")

    package = read_archive!(Output.source!(bundle, package_record["path"]))
    docs = read_archive!(Output.source!(bundle, docs_record["path"]))
    package_sha = Identity.raw(package)
    docs_sha = Identity.raw(docs)

    unless package_sha == metadata["archive_sha256"] and package_sha == package_record["sha256"] and
             docs_sha == metadata["docs_archive_sha256"] and docs_sha == docs_record["sha256"],
           do: raise(Error, "frozen publication bytes changed")

    %{
      name: metadata["package"],
      version: metadata["version"],
      package: package,
      docs: docs,
      package_sha: package_sha,
      docs_sha: docs_sha
    }
  end

  defp result(metadata, candidate),
    do: %{
      artifact: metadata["artifact"],
      identity: metadata["bundle_id"],
      bundle_id: metadata["bundle_id"],
      package: candidate.name,
      version: candidate.version,
      archive_sha256: candidate.package_sha,
      docs_sha256: candidate.docs_sha
    }

  defp transport!(opts, operation) do
    transport = opts[:transport] || http_transport(configured_core())

    unless is_function(transport[:read], 3) and is_function(transport[:write], 4),
      do: raise(Error, "invalid exact-byte Hex transport")

    trust = transport[:trust]

    unless is_map(trust) and trust[:authenticated] == true and trust[:authoritative] == true and
             trust[:adapter] == "hex_core/0.21.1",
           do:
             raise(Error, "remote evidence requires authenticated, authoritative Hex trust facts")

    _ = safe_endpoint!(trust.destination, trust[:conformance] == :loopback)

    if operation == :write and not qualified_transport?(trust),
      do:
        raise(
          Error,
          "public Hex writes disabled until authenticated adapter conformance is recorded"
        )

    transport
  end

  defp qualified_transport?(%{conformance: :loopback, destination: destination}) do
    URI.parse(destination).host in ["127.0.0.1", "::1", "localhost"]
  end

  defp qualified_transport?(trust) do
    case Application.get_env(:weld, :hex_conformance) do
      %{
        "schema" => "weld.hex-conformance/2",
        "adapter" => "hex_core/0.21.1",
        "destination" => destination,
        "authenticated" => true,
        "tls_verified" => true,
        "staged_readback" => true,
        "package_body_sha256" => package,
        "docs_body_sha256" => docs,
        "adapter_sha256" => adapter
      } ->
        destination == trust.destination and Identity.valid?(package) and Identity.valid?(docs) and
          adapter == adapter_fingerprint()

      _ ->
        false
    end
  end

  @doc "Construct the pinned HTTP boundary; explicit config also supports loopback contract tests."
  def http_transport(config) do
    ensure_core!()
    destination = safe_endpoint!(config[:api_url], config[:weld_loopback] == true)
    _ = safe_endpoint!(config[:repo_url], config[:weld_loopback] == true)

    unless config[:repo_verify] != false and config[:repo_verify_origin] != false and
             is_binary(config[:repo_public_key]),
           do: raise(Error, "unsafe Hex signature/origin trust configuration")

    authenticated = is_binary(config[:api_key]) and config[:api_key] != ""

    trust = %{
      destination: destination,
      authenticated: authenticated,
      authoritative: authenticated,
      adapter: "hex_core/0.21.1",
      conformance: if(config[:weld_loopback], do: :loopback, else: :unqualified)
    }

    config =
      config
      |> Map.put(:send_100_continue, false)
      |> Map.put(
        :http_adapter,
        {:hex_http_httpc,
         %{http_options: [timeout: 120_000, connect_timeout: 15_000, autoredirect: false]}}
      )

    %{
      trust: trust,
      read: fn part, name, version -> read_remote(config, part, name, version) end,
      read_staged: fn location -> read_staged(config, location) end,
      write: fn
        :package, _name, _version, bytes ->
          :hex_api_release.publish(config, bytes, replace: false)

        :docs, name, version, bytes ->
          path =
            :hex_api.build_repository_path(config, ["packages", name, "releases", version, "docs"])

          :hex_api.post(config, path, {~c"application/octet-stream", bytes})
      end
    }
  end

  defp ensure_core! do
    _ = Application.load(:hex_core)

    unless to_string(Application.spec(:hex_core, :vsn)) == "0.21.1",
      do:
        raise(
          Error,
          "Hex archive/HTTP contracts require the locked hex_core 0.21.1 implementation"
        )
  end

  defp configured_core do
    config = :hex_core.default_config() |> Map.merge(Application.get_env(:weld, :hex_config, %{}))
    key = Application.get_env(:weld, :hex_api_key)
    if key, do: Map.put(config, :api_key, key), else: config
  end

  defp read_remote(config, :package, name, version) do
    with {:ok, {200, _headers, %{"checksum" => api_sha}}} <-
           :hex_api_release.get(config, name, version),
         {:ok, {200, _headers, %{releases: releases}}} <- :hex_repo.get_package(config, name),
         release when is_map(release) <- Enum.find(releases, &(&1.version == version)),
         {:ok, {200, _headers, bytes}} <- :hex_repo.get_tarball(config, name, version),
         sha = Identity.raw(bytes),
         true <- api_sha == sha and hex(release.outer_checksum) == sha do
      {:ok,
       %{
         state: "confirmed",
         sha256: sha,
         source: "authenticated-api+signed-registry+tarball",
         authoritative: true
       }}
    else
      # A public-version 404 cannot exclude a pending staged upload. There is
      # deliberately no CDN/unauthenticated 404 => permission-to-write shortcut.
      {:ok, {404, _, _}} ->
        {:ok, %{state: "unknown", code: "no_public_release", authoritative: false}}

      _ ->
        {:ok,
         %{
           state: "unknown",
           code: "untrusted_or_unsupported_package_readback",
           authoritative: false
         }}
    end
  end

  defp read_remote(config, :docs, name, version) do
    case :hex_api_release.get(config, name, version) do
      {:ok, {200, _, %{"has_docs" => false}}} ->
        {:ok,
         %{
           state: "unknown",
           code: "no_public_docs_does_not_exclude_staging",
           authoritative: false
         }}

      _ ->
        # Hex does not advertise a signed docs checksum. A fetched or
        # recompressed CDN tar alone is not authoritative documentation proof.
        {:ok,
         %{
           state: "unknown",
           code: "unsupported_authenticated_docs_readback",
           authoritative: false
         }}
    end
  end

  defp read_staged(config, location) do
    base = String.trim_trailing(config.api_url, "/") <> "/"

    if String.starts_with?(location, base) and is_nil(URI.parse(location).query) do
      path = String.replace_prefix(location, base, "")
      :hex_api.get(config, path)
    else
      {:error, :untrusted_staged_location}
    end
  end

  defp observe(transport, candidate, prior) do
    Map.new([:package, :docs], fn part ->
      observation = safe_read(transport, candidate, part)
      prior_part = if prior, do: get_in(prior, ["observed", to_string(part)]), else: nil

      observation =
        if (observation.state == "unknown" and prior_part) && prior_part["location"] &&
             transport[:read_staged] do
          staged_observation(
            transport.read_staged.(prior_part["location"]),
            prior_part["location"]
          )
        else
          observation
        end

      {part, observation}
    end)
  end

  defp safe_read(transport, candidate, part) do
    expected = Map.fetch!(candidate, if(part == :package, do: :package_sha, else: :docs_sha))

    case transport.read.(part, candidate.name, candidate.version) do
      {:ok, %{state: state, authoritative: true} = value}
      when state in ["confirmed", "absent", "rejected", "staged"] ->
        cond do
          state == "confirmed" and not Identity.valid?(value[:sha256]) ->
            observation("unknown", "missing_trusted_digest")

          state == "confirmed" and value.sha256 != expected ->
            observation("conflict", "remote_checksum_conflict", value)

          state == "staged" and is_binary(value[:sha256]) and value.sha256 != expected ->
            observation("conflict", "staged_checksum_conflict", value)

          true ->
            observation(state, value[:code] || "authoritative_readback", value)
            |> safe_location(transport.trust.destination)
        end

      _ ->
        observation("unknown", "untrusted_or_unsupported_readback")
    end
  rescue
    _ -> observation("unknown", "remote_read_failed")
  catch
    _, _ -> observation("unknown", "remote_read_interrupted")
  end

  defp ensure_retry!(prior, remote, metadata) do
    if Enum.any?(remote, fn {_part, value} -> value.state == "conflict" end),
      do: raise(Error, "conflicting remote bytes; replacement is forbidden")

    if prior &&
         Enum.any?(
           ["package_state", "docs_state"],
           &(prior[&1] in ["submitting", "unknown", "staged"])
         ) do
      unless prior["operation"] == "reconcile" and prior["bundle_id"] == metadata["bundle_id"] and
               Enum.all?(remote, fn {_part, value} ->
                 value.state in ["confirmed", "absent", "rejected"]
               end),
             do:
               raise(
                 Error,
                 "publication outcome unresolved; reconcile the same pinned bundle before another write"
               )
    end
  end

  defp submit_part!(selector, history, metadata, candidate, transport, remote, part) do
    value = remote[part]

    cond do
      value.state == "confirmed" ->
        {history, remote}

      value.state in ["absent", "rejected", "not_sent"] ->
        intent = Map.put(remote, part, observation("submitting", "durable_intent"))

        history =
          append_outcome!(selector, history, metadata, candidate, transport, intent, "publish")

        response = write_once(transport, candidate, part)
        written = write_observation(response) |> safe_location(transport.trust.destination)

        written =
          if written.state == "unknown" and written.code == "response_received" do
            safe_read(transport, candidate, part)
          else
            written
          end

        written =
          if written.state == "absent",
            do: observation("unknown", "absence_after_possible_send"),
            else: written

        remote = Map.put(remote, part, written)

        {append_outcome!(selector, history, metadata, candidate, transport, remote, "publish"),
         remote}

      value.state == "staged" ->
        {append_outcome!(selector, history, metadata, candidate, transport, remote, "publish"),
         remote}

      true ->
        remote = Map.put(remote, part, observation("not_sent", "preflight_" <> value.code))

        {append_outcome!(selector, history, metadata, candidate, transport, remote, "publish"),
         remote}
    end
  end

  defp write_once(transport, candidate, part) do
    transport.write.(part, candidate.name, candidate.version, Map.fetch!(candidate, part))
  rescue
    _ -> {:error, :possible_send}
  catch
    _, _ -> {:error, :possible_send}
  end

  defp write_observation({:error, :not_sent}),
    do: observation("not_sent", "transport_failed_before_send")

  defp write_observation({:ok, {status, headers, %{"status" => "staged"}}})
       when status in 200..299,
       do: observation("staged", "awaiting_approval", %{location: header(headers, "location")})

  defp write_observation({:ok, {409, _, _}}),
    do: observation("conflict", "remote_version_conflict")

  defp write_observation({:ok, {status, _, _}})
       when status in [400, 401, 403, 404, 413, 415, 422, 429],
       do: observation("rejected", "authenticated_rejection_#{status}")

  defp write_observation({:ok, {status, _, _}}) when status in 200..299,
    do: observation("unknown", "response_received")

  defp write_observation(_),
    do: observation("unknown", "possible_send_without_trustworthy_result")

  defp staged_observation({:ok, {200, _, %{"status" => "staged"}}}, location),
    do: observation("staged", "awaiting_approval", %{location: location})

  defp staged_observation({:ok, {200, _, %{"status" => status}}}, _location)
       when status in ["rejected", "expired"], do: observation("rejected", "staged_#{status}")

  defp staged_observation(_, _),
    do: observation("unknown", "staged_readback_requires_published_digest")

  defp observation(state, code, values \\ %{}),
    do: %{
      state: state,
      code: public_label(code),
      sha256: values[:sha256],
      source: public_label(values[:source]),
      location: values[:location]
    }

  defp public_label(nil), do: nil

  defp public_label(value) do
    value = to_string(value)

    if byte_size(value) <= 200 and Regex.match?(~r/\A[a-zA-Z0-9_.:+ -]+\z/, value),
      do: value,
      else: "unclassified_remote_result"
  end

  defp safe_location(observation, destination) do
    location = observation.location

    valid =
      is_binary(location) and
        String.starts_with?(location, String.trim_trailing(destination, "/") <> "/") and
        is_nil(URI.parse(location).userinfo) and is_nil(URI.parse(location).query) and
        is_nil(URI.parse(location).fragment)

    %{observation | location: if(valid, do: location)}
  end

  defp overall(remote) do
    states = Enum.map(remote, fn {_part, value} -> value.state end)

    cond do
      Enum.all?(states, &(&1 == "confirmed")) -> "confirmed"
      "conflict" in states -> "conflict"
      "staged" in states -> "staged"
      "unknown" in states or "submitting" in states -> "unknown"
      "rejected" in states -> "rejected"
      true -> "not_sent"
    end
  end

  defp wire_remote(remote),
    do:
      Map.new(remote, fn {part, value} ->
        {to_string(part), Map.new(value, fn {key, item} -> {to_string(key), item} end)}
      end)

  defp history!(selector, candidate, destination) do
    root = Output.path(repo_root(selector), ["outcomes"])

    records =
      if File.dir?(root) do
        Output.reject_tree_links!(root)

        Path.wildcard(Path.join(root, "*/*/*.json"))
        |> Enum.map(fn path ->
          bytes = File.read!(path)
          if byte_size(bytes) > 1024 * 1024, do: raise(Error, "oversized publication outcome")
          record = Jason.decode!(bytes)
          validate_outcome!(record, path, bytes)
          record
        end)
        |> Enum.filter(fn record ->
          record["destination"] == destination and record["package"] == candidate.name and
            record["version"] == candidate.version
        end)
      else
        []
      end

    order_outcomes!(records, nil, [])
  end

  defp validate_outcome!(record, path, bytes) do
    unless is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@outcome_keys) and
             record["schema"] == "weld.outcome/2" and
             record["operation"] in ["publish", "reconcile"] and
             is_binary(record["id"]) and Regex.match?(~r/\A[0-9a-f]{24}\z/, record["id"]) and
             Path.basename(path) == record["id"] <> ".json" and
             Path.basename(Path.dirname(path)) == record["bundle_id"] and
             Path.basename(Path.dirname(Path.dirname(path))) == record["artifact"] and
             Identity.valid?(record["bundle_id"]) and
             Identity.valid?(record["expected_archive_sha256"]) and
             Identity.valid?(record["expected_docs_sha256"]) and
             is_binary(record["artifact"]) and is_binary(record["package"]) and
             is_binary(record["version"]) and
             record["package_state"] in @states and record["docs_state"] in @states and
             is_map(record["observed"]) and
             (is_nil(record["previous_id"]) or
                (is_binary(record["previous_id"]) and
                   Regex.match?(~r/\A[0-9a-f]{24}\z/, record["previous_id"]))) and
             is_binary(record["recorded_at"]) and
             match?({:ok, _, _}, DateTime.from_iso8601(record["recorded_at"])) and
             Identity.canonical(record) == bytes,
           do: raise(Error, "invalid canonical publication outcome")

    destination = safe_endpoint!(record["destination"], true)

    unless Enum.sort(Map.keys(record["observed"])) == ["docs", "package"],
      do: raise(Error, "invalid outcome observations")

    for part <- ["docs", "package"] do
      value = record["observed"][part]

      unless is_map(value) and Enum.sort(Map.keys(value)) == ~w(code location sha256 source state) and
               value["state"] in (@states ++ ["absent"]) and
               state_for_record(value["state"]) == record[part <> "_state"] and
               (is_nil(value["sha256"]) or Identity.valid?(value["sha256"])) and
               value["code"] == public_label(value["code"]) and
               value["source"] == public_label(value["source"]),
             do: raise(Error, "invalid typed outcome observation")

      location = value["location"]

      if location && safe_location(%{location: location}, destination).location != location,
        do: raise(Error, "untrusted staged outcome location")
    end

    :ok
  end

  defp order_outcomes!([], _previous, ordered), do: ordered

  defp order_outcomes!(records, previous, ordered) do
    case Enum.filter(records, &(&1["previous_id"] == previous)) do
      [next] -> order_outcomes!(List.delete(records, next), next["id"], ordered ++ [next])
      _ -> raise Error, "broken, branched or cyclic publication outcome chain"
    end
  end

  defp append_outcome!(selector, history, metadata, candidate, transport, remote, operation) do
    previous = List.last(history)
    id = Output.nonce()

    record = %{
      "schema" => "weld.outcome/2",
      "id" => id,
      "operation" => operation,
      "artifact" => metadata["artifact"],
      "bundle_id" => metadata["bundle_id"],
      "package" => candidate.name,
      "version" => candidate.version,
      "destination" => transport.trust.destination,
      "expected_archive_sha256" => candidate.package_sha,
      "expected_docs_sha256" => candidate.docs_sha,
      "previous_id" => previous && previous["id"],
      "package_state" => state_for_record(remote.package.state),
      "docs_state" => state_for_record(remote.docs.state),
      "observed" => wire_remote(remote),
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    path =
      Output.path(repo_root(selector), [
        "outcomes",
        metadata["artifact"],
        metadata["bundle_id"],
        id <> ".json"
      ])

    Output.with_lock(repo_root(selector), fn ->
      if File.exists?(path), do: raise(Error, "publication outcome already exists")
      Output.atomic_write!(path, Identity.canonical(record))
    end)

    history ++ [record]
  end

  defp state_for_record("absent"), do: "not_sent"
  defp state_for_record(state), do: state
  defp repo_root(%{repo_root: root}), do: root
  defp repo_root(%{manifest: %{repo_root: root}}), do: root
  defp adapter_fingerprint, do: :code.which(:hex_api_release) |> to_string() |> Hash.sha256_file()
  defp header(headers, name) when is_map(headers), do: headers[name]

  defp header(headers, name) when is_list(headers),
    do:
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == name, do: to_string(value)
      end)

  defp safe_endpoint!(url, loopback?) when is_binary(url) do
    uri = URI.parse(url)

    unless is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             is_binary(uri.host) and
             (uri.scheme == "https" or
                (loopback? and uri.scheme == "http" and
                   uri.host in ["127.0.0.1", "localhost", "::1"])),
           do: raise(Error, "untrusted Hex endpoint; credentials and URL overrides are forbidden")

    String.trim_trailing(url, "/")
  end

  defp safe_endpoint!(_, _), do: raise(Error, "missing trusted Hex endpoint")
end
