defmodule Weld.Shell.Hex do
  @moduledoc """
  Exact-byte Hex transport. A persisted submitting record is an unresolved
  outcome, not permission to repeat an upload. Remote reads never authorize
  replacement of conflicting bytes.
  """
  alias Weld.Core.Identity
  alias Weld.Core.Inventory
  alias Weld.{Error, Output}

  def freeze_docs!(directory, target) do
    Output.reject_tree_links!(directory)

    files =
      directory
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(fn path ->
        {path |> Path.relative_to(directory) |> String.to_charlist(), File.read!(path)}
      end)

    expected = Enum.sort(files)

    with {:ok, bytes} <- :hex_tarball.create_docs(files),
         {:ok, contents} <- :hex_tarball.unpack_docs(bytes, :memory),
         true <- Enum.sort(contents) == expected do
      File.write!(target, bytes)
    else
      _ -> raise Error, "frozen documentation archive differs from the docs tree"
    end

    target
  end

  def check_package!(tarball, root, paths, package) do
    expected =
      Map.new(paths, fn relative ->
        path = Output.source!(root, relative)
        mode = if Bitwise.band(File.stat!(path).mode, 0o100) != 0, do: 0o755, else: 0o644
        {relative, {File.read!(path), mode}}
      end)

    bytes = File.read!(tarball)

    with {:ok, %{contents: contents, metadata: metadata}} <- :hex_tarball.unpack(bytes, :memory),
         {:ok, outer} <- :erl_tar.extract({:binary, bytes}, [:memory]),
         {_, compressed} <- List.keyfind(outer, ~c"contents.tar.gz", 0),
         {:ok, headers} <- :erl_tar.table({:binary, compressed}, [:compressed, :verbose]),
         true <- valid_package_metadata?(metadata, package),
         true <- exact_package_contents?(headers, contents, expected) do
      :ok
    else
      _ ->
        raise Error,
              "Hex archive metadata, paths, modes or bytes differ from the package inventory"
    end
  end

  defp valid_package_metadata?(metadata, package) do
    metadata["name"] == package.name and metadata["version"] == package.version and
      metadata["app"] == to_string(package.otp_app)
  end

  defp exact_package_contents?(headers, contents, expected) do
    names =
      Enum.map(headers, fn header ->
        header |> elem(0) |> to_string() |> String.trim_trailing("/")
      end)

    actual = Map.new(contents, fn {name, bytes} -> {to_string(name), bytes} end)

    Enum.uniq(names) == names and map_size(actual) == length(contents) and
      actual == Map.new(expected, fn {name, {bytes, _mode}} -> {name, bytes} end) and
      Enum.all?(headers, &valid_header?(&1, expected))
  end

  defp valid_header?({name, type, _size, _time, mode, _uid, _gid}, expected) do
    name = name |> to_string() |> String.trim_trailing("/")
    Inventory.validate_path!(name)

    case type do
      :regular ->
        permissions = Bitwise.band(mode, 0o7777)
        match?({_, ^permissions}, expected[name])

      :directory ->
        Enum.any?(expected, fn {path, _} -> String.starts_with?(path, name <> "/") end)

      _ ->
        false
    end
  end

  def publish!(plan, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)

    result = %{
      artifact: plan.artifact.id,
      identity: metadata["identity"],
      package: candidate.name,
      version: candidate.version,
      archive_sha256: candidate.package_sha,
      docs_sha256: candidate.docs_sha
    }

    if opts[:dry_run] == true do
      Map.merge(result, %{
        dry_run: true,
        completed?: false,
        exit_status: 0,
        action: :validated_local_bytes
      })
    else
      submit!(plan, metadata, candidate, result, opts)
    end
  end

  defp submit!(plan, metadata, candidate, result, opts) do
    unless opts[:yes] == true,
      do: raise(Error, "publication requires --yes after inspecting the pinned bundle")

    path = outcome_path(plan, metadata)
    prior = read_outcome(path)

    if prior && prior["state"] in ["submitting", "unknown", "conflict"],
      do:
        raise(
          Error,
          "publication is unresolved; use mix weld reconcile before attempting another write"
        )

    unless opts[:transport],
      do: raise(Error, "production Hex writes require a qualified transport")

    transport = transport!(opts)
    remote = observe(transport, candidate)

    if remote.package in [:conflict, :unknown] or remote.docs in [:conflict, :unknown],
      do: raise(Error, "remote identity is conflicting or unavailable; no upload attempted")

    package = upload_part!(path, result, transport, candidate, remote, :package)
    observed = %{remote | package: package}

    observed =
      if package == :match do
        docs = upload_part!(path, result, transport, candidate, observed, :docs)
        %{observed | docs: docs}
      else
        observed
      end

    state = state(observed)
    write_outcome!(path, result, state, observed)

    Map.merge(result, %{
      completed?: state == "confirmed",
      exit_status: if(state == "confirmed", do: 0, else: 1),
      state: state,
      remote: observed
    })
  end

  def status(plan, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)

    %{
      remote: observe(transport!(opts), candidate),
      local_outcome: read_outcome(outcome_path(plan, metadata))
    }
  end

  def reconcile!(plan, bundle, metadata, opts) do
    candidate = candidate!(bundle, metadata)

    result = %{
      artifact: plan.artifact.id,
      identity: metadata["identity"],
      package: candidate.name,
      version: candidate.version,
      archive_sha256: candidate.package_sha,
      docs_sha256: candidate.docs_sha
    }

    remote = observe(transport!(opts), candidate)
    # An absent observation after a possible write is not proof of noncommit.
    state = state(remote)
    write_outcome!(outcome_path(plan, metadata), result, state, remote)
    Map.merge(result, %{state: state, remote: remote, completed?: state == "confirmed"})
  end

  defp candidate!(bundle, metadata) do
    package = File.read!(Output.source!(bundle, metadata["tarball_path"]))
    docs = File.read!(Output.source!(bundle, "docs.tar.gz"))
    package_sha = Identity.raw(package)
    docs_sha = Identity.raw(docs)
    integrity = metadata["integrity"]

    unless package_sha == integrity["archive_sha256"] and
             docs_sha == integrity["docs_archive_sha256"],
           do: raise(Error, "frozen publication bytes changed")

    %{
      name: metadata["package"]["name"],
      version: metadata["package"]["version"],
      package: package,
      docs: docs,
      package_sha: package_sha,
      docs_sha: docs_sha
    }
  end

  defp config! do
    key = Application.get_env(:weld, :hex_api_key)

    unless is_binary(key) and key != "",
      do:
        raise(
          Error,
          "configure :weld, :hex_api_key in runtime config for authenticated remote evidence"
        )

    :hex_core.default_config() |> Map.put(:api_key, key)
  end

  defp transport!(opts) do
    case opts[:transport] do
      %{read: read, write: write} = transport
      when is_function(read, 3) and is_function(write, 4) ->
        transport

      nil ->
        config = config!()

        %{
          read: fn
            :package, name, version -> :hex_repo.get_tarball(config, name, version)
            :docs, name, version -> :hex_repo.get_docs(config, name, version)
          end,
          write: fn
            :package, _name, _version, bytes ->
              :hex_api_release.publish(config, bytes, replace: false)

            :docs, name, version, bytes ->
              submit_docs(config, name, version, bytes)
          end
        }
    end
  end

  defp observe(transport, candidate) do
    %{
      package: observe_part(transport, candidate, :package),
      docs: observe_part(transport, candidate, :docs)
    }
  end

  defp observe_part(transport, candidate, part) do
    sha = if part == :package, do: candidate.package_sha, else: candidate.docs_sha
    classify(transport.read.(part, candidate.name, candidate.version), sha)
  end

  defp upload_part!(path, result, transport, candidate, remote, part) do
    if remote[part] == :match do
      :match
    else
      write_outcome!(path, result, "submitting", Map.put(remote, part, :submitting))

      _response =
        transport.write.(part, candidate.name, candidate.version, Map.fetch!(candidate, part))

      observed = observe_part(transport, candidate, part)
      if observed == :absent, do: :unknown, else: observed
    end
  end

  defp classify({:ok, {200, _, bytes}}, sha) when is_binary(bytes),
    do: if(Identity.raw(bytes) == sha, do: :match, else: :conflict)

  defp classify({:ok, {404, _, _}}, _sha), do: :absent
  defp classify(_, _sha), do: :unknown

  defp submit_docs(config, name, version, bytes) do
    url =
      "https://hex.pm/api/packages/#{URI.encode(name)}/releases/#{URI.encode(version)}/docs"

    headers = [{~c"authorization", String.to_charlist(config.api_key)}]

    tls = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    :httpc.request(
      :post,
      {String.to_charlist(url), headers, ~c"application/octet-stream", bytes},
      [ssl: tls, timeout: 120_000, autoredirect: false],
      body_format: :binary
    )
  end

  defp state(%{package: :match, docs: :match}), do: "confirmed"
  defp state(%{package: :conflict}), do: "conflict"
  defp state(%{docs: :conflict}), do: "conflict"
  defp state(_), do: "unknown"

  defp outcome_path(plan, metadata),
    do:
      Output.path(
        plan.manifest.repo_root,
        ["publication", plan.artifact.id, metadata["identity"], "outcome.json"]
      )

  defp read_outcome(path) do
    case File.read(path) do
      {:ok, bytes} -> Jason.decode!(bytes)
      {:error, :enoent} -> nil
      _ -> raise Error, "cannot read publication outcome"
    end
  end

  defp write_outcome!(path, result, state, remote) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> "-" <> Output.nonce()
    value = Map.merge(result, %{schema: "weld.publication/2", state: state, remote: remote})
    File.write!(tmp, Jason.encode!(value, pretty: true), [:exclusive, :sync])
    File.rename!(tmp, path)
  end
end
