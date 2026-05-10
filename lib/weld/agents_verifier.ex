defmodule Weld.AgentsVerifier do
  @moduledoc """
  Verifies AGENTS.md files carry dependency-source and runtime-env guidance.
  """

  @required_groups [
    dependency_sources_guidance: [
      "build_support/dependency_sources.exs",
      "build_support/dependency_sources.config.exs"
    ],
    local_override_guidance: [".dependency_sources.local.exs"],
    no_env_dependency_selection_guidance: [
      "dependency source selection",
      "environment variables"
    ],
    runtime_env_guidance: ["lib/**", "os env", "config/runtime.exs"],
    weld_guidance: ["weld", "helper drift", "publish order"]
  ]

  def verify(repo_root) do
    report = report(repo_root)

    if report.violations == [] do
      {:ok, report}
    else
      {:error, report}
    end
  end

  def report(repo_root) do
    repo_root = Path.expand(repo_root)
    agents_files = agents_files(repo_root)

    root_violation =
      if File.regular?(Path.join(repo_root, "AGENTS.md")) do
        []
      else
        [
          violation(
            :missing_root_agents,
            "root AGENTS.md is required",
            Path.join(repo_root, "AGENTS.md")
          )
        ]
      end

    {files, violations} =
      Enum.reduce(agents_files, {[], root_violation}, fn path, {files_acc, violations_acc} ->
        content = File.read!(path)
        file_violations = file_violations(path, content)

        {[%{path: path, status: if(file_violations == [], do: :ok, else: :invalid)} | files_acc],
         violations_acc ++ file_violations}
      end)

    %{
      ok: violations == [],
      repo_root: repo_root,
      files: Enum.sort_by(files, & &1.path),
      violations: violations
    }
  end

  defp agents_files(repo_root) do
    repo_root
    |> Path.join("**/AGENTS.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.relative_to(&1, repo_root) |> ignored_path?()))
    |> Enum.sort()
  end

  defp ignored_path?(path) do
    String.starts_with?(path, "deps/") or String.starts_with?(path, "_build/") or
      String.starts_with?(path, ".git/")
  end

  defp file_violations(path, content) do
    normalized = String.downcase(content)

    Enum.flat_map(@required_groups, fn {group, needles} ->
      if Enum.all?(needles, &String.contains?(normalized, String.downcase(&1))) do
        []
      else
        [violation(missing_code(group), "AGENTS.md is missing #{group}", path)]
      end
    end)
  end

  defp missing_code(:dependency_sources_guidance), do: :missing_dependency_sources_guidance
  defp missing_code(:local_override_guidance), do: :missing_local_override_guidance

  defp missing_code(:no_env_dependency_selection_guidance),
    do: :missing_no_env_dependency_selection_guidance

  defp missing_code(:weld_guidance), do: :missing_weld_guidance
  defp missing_code(:runtime_env_guidance), do: :missing_runtime_env_guidance

  defp violation(code, message, path), do: %{code: code, message: message, path: path}
end
