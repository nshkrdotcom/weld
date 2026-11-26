defmodule Weld.Shell.Hex do
  @moduledoc """
  Exact-byte Hex transport. A persisted submitting record is an unresolved
  outcome, not permission to repeat an upload. Remote reads never authorize
  replacement of conflicting bytes.
  """
  alias Weld.{Error, Output}
  alias Weld.Core.Identity

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

    case :hex_tarball.create_docs(files) do
      {:ok, bytes} when is_binary(bytes) -> File.write!(target, bytes)
      bytes when is_binary(bytes) -> File.write!(target, bytes)
      _ -> raise Error, "could not create frozen documentation archive"
    end

    target
  end

  def check_package!(tarball, root, files) do
    expected = Map.new(files, fn file -> {file, File.read!(Output.source!(root, file))} end)

    case :hex_tarball.unpack(File.read!(tarball), :memory) do
      {:ok, %{contents: contents}} ->
        actual = Map.new(contents, fn {name, bytes} -> {to_string(name), bytes} end)

        unless map_size(actual) == length(contents) and actual == expected,
          do: raise(Error, "Hex archive contents do not match the planned package inventory")

        :ok

      _ ->
        raise Error, "could not verify the Hex archive"
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

      config = config!()
      remote = observe(config, candidate)

      if remote.package in [:conflict, :unknown] or remote.docs in [:conflict, :unknown],
        do: raise(Error, "remote identity is conflicting or unavailable; no upload attempted")

      write_outcome!(path, result, "submitting", remote)
      package = if remote.package == :match, do: :match, else: submit_package(config, candidate)

      docs =
        if package == :match do
          if remote.docs == :match, do: :match, else: submit_docs(config, candidate)
        else
          remote.docs
        end

      observed = %{package: package, docs: docs}
      state = state(observed)
      write_outcome!(path, result, state, observed)

      Map.merge(result, %{
        completed?: state == "confirmed",
        exit_status: if(state == "confirmed", do: 0, else: 1),
        state: state,
        remote: observed
      })
    end
  end

  def reconcile!(plan, bundle, metadata) do
    candidate = candidate!(bundle, metadata)

    result = %{
      artifact: plan.artifact.id,
      identity: metadata["identity"],
      package: candidate.name,
      version: candidate.version,
      archive_sha256: candidate.package_sha,
      docs_sha256: candidate.docs_sha
    }

    remote = observe(config!(), candidate)
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
    key = System.get_env("HEX_API_KEY")

    unless is_binary(key) and key != "",
      do: raise(Error, "set HEX_API_KEY for remote publication or reconciliation")

    :hex_core.default_config() |> Map.put(:api_key, key)
  end

  defp observe(config, c) do
    %{
      package: classify(:hex_repo.get_tarball(config, c.name, c.version), c.package_sha),
      docs: classify(:hex_repo.get_docs(config, c.name, c.version), c.docs_sha)
    }
  end

  defp classify({:ok, {200, _, bytes}}, sha) when is_binary(bytes),
    do: if(Identity.raw(bytes) == sha, do: :match, else: :conflict)

  defp classify({:ok, {404, _, _}}, _sha), do: :absent
  defp classify(_, _sha), do: :unknown

  defp submit_package(config, c) do
    # Only the frozen tarball is supplied, not a writable Mix project.
    _ = :hex_api_release.publish(config, c.package, replace: false)
    classify(:hex_repo.get_tarball(config, c.name, c.version), c.package_sha)
  end

  defp submit_docs(config, c) do
    # Pin the public endpoint; do not forward a credential across redirects.
    url =
      "https://hex.pm/api/packages/#{URI.encode(c.name)}/releases/#{URI.encode(c.version)}/docs"

    headers = [{~c"authorization", String.to_charlist(config.api_key)}]

    tls = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    _ =
      :httpc.request(
        :post,
        {String.to_charlist(url), headers, ~c"application/octet-stream", c.docs},
        [ssl: tls, timeout: 120_000, autoredirect: false], body_format: :binary)

    classify(:hex_repo.get_docs(config, c.name, c.version), c.docs_sha)
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
