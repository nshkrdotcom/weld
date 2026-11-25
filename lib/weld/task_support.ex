defmodule Weld.TaskSupport do
  @doc false
  def reject_invalid!([]), do: :ok

  def reject_invalid!(invalid) do
    Mix.raise("Invalid options: #{inspect(invalid)}")
  end

  @moduledoc false

  @default_manifest_paths [
    "build_support/weld.exs",
    "build_support/weld_contract.exs"
  ]

  def shell_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  def release_command(task, manifest_path, artifact, identity) do
    "mix release.#{task} #{shell_arg(Path.expand(manifest_path))} " <>
      "--artifact #{shell_arg(artifact)} --identity #{shell_arg(identity)}"
  end

  def each_release_artifact!(manifest_path, operation) do
    failures =
      Enum.flat_map(Weld.artifact_ids!(manifest_path), fn artifact ->
        try do
          operation.(artifact)
          []
        rescue
          error in Weld.Error ->
            message = "#{artifact}: #{Exception.message(error)}"
            Mix.shell().error(message)
            [artifact]
        end
      end)

    if failures != [] do
      Mix.raise("Release operation failed for #{Enum.join(failures, ", ")}")
    end
  end

  @spec resolve_manifest_path!([String.t()], String.t()) :: String.t()
  def resolve_manifest_path!(positional, usage) do
    case positional do
      [] -> discover_manifest!(usage)
      [path] -> path
      _ -> Mix.raise(usage)
    end
  end

  @spec discover_manifest!(String.t()) :: String.t()
  def discover_manifest!(usage) do
    root = Weld.Git.root(File.cwd!()) || File.cwd!()

    default_candidates =
      Enum.map(@default_manifest_paths, &Path.join(root, &1)) |> Enum.filter(&File.regular?/1)

    packaging_candidates = Path.wildcard(Path.join(root, "packaging/weld/*.exs"))

    candidates =
      case default_candidates do
        [] -> packaging_candidates
        defaults -> defaults
      end

    case Enum.uniq(candidates) do
      [path] ->
        path

      [] ->
        Mix.raise("""
        #{usage}

        No weld manifest was found in the current repo. Expected one of:
          #{Enum.join(@default_manifest_paths, "\n  ")}
          packaging/weld/*.exs
        """)

      many ->
        Mix.raise("""
        #{usage}

        Multiple weld manifests were found. Pass the manifest path explicitly:
          #{Enum.join(Enum.sort(many), "\n  ")}
        """)
    end
  end
end
