defmodule Weld.Workspace.Discovery do
  @moduledoc """
  Workspace discovery using manifest globs, root Mix adapters, or filesystem
  fallback.
  """

  alias Weld.Error
  alias Weld.Manifest

  @ignored_prefixes ~w(.git _build deps dist tmp doc)

  @type result :: %{
          source: :manifest | :blitz_workspace | :filesystem,
          root_project?: boolean(),
          globs: [String.t()],
          project_ids: [String.t()],
          adapter: String.t() | nil
        }

  @spec discover(Manifest.t()) :: result()
  def discover(%Manifest{} = manifest) do
    repo_root = manifest.repo_root
    root_project? = File.regular?(Path.join(repo_root, "mix.exs"))
    adapter_globs = if root_project?, do: blitz_workspace_globs(repo_root), else: []

    cond do
      manifest.workspace.project_globs != [] ->
        %{
          source: :manifest,
          root_project?: root_project?,
          globs: manifest.workspace.project_globs,
          project_ids: expand_globs(repo_root, manifest.workspace.project_globs, root_project?),
          adapter: nil
        }

      adapter_globs != [] ->
        %{
          source: :blitz_workspace,
          root_project?: true,
          globs: adapter_globs,
          project_ids: expand_globs(repo_root, adapter_globs, true),
          adapter: "blitz_workspace"
        }

      true ->
        %{
          source: :filesystem,
          root_project?: root_project?,
          globs: [],
          project_ids: scan_filesystem(repo_root, root_project?),
          adapter: nil
        }
    end
  end

  defp blitz_workspace_globs(repo_root) do
    config =
      if current_project_root() == Path.expand(repo_root) do
        Mix.Project.config()
      else
        without_module_conflicts(fn ->
          Mix.Project.in_project(unique_probe(), repo_root, [], fn _module ->
            Mix.Project.config()
          end)
        end)
      end

    workspace = Keyword.get(config, :blitz_workspace)

    projects =
      case workspace do
        list when is_list(list) -> Keyword.get(list, :projects, [])
        map when is_map(map) -> Map.get(map, :projects, Map.get(map, "projects", []))
        _ -> []
      end

    unless is_list(projects) and Enum.all?(projects, &is_binary/1) do
      raise Error, ":blitz_workspace projects must be a list of glob strings"
    end

    Enum.sort(projects)
  end

  defp expand_globs(repo_root, globs, root_project?) do
    discovered =
      globs
      |> Enum.flat_map(fn glob ->
        repo_root
        |> Path.join(glob)
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?(Path.join(&1, "mix.exs")))
        |> Enum.map(&Path.relative_to(&1, repo_root))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if root_project?, do: ["." | discovered] |> Enum.uniq(), else: discovered
  end

  defp scan_filesystem(repo_root, root_project?) do
    discovered =
      repo_root
      |> Path.join("**/mix.exs")
      |> Path.wildcard(match_dot: false)
      |> Enum.reject(&ignored_file?(&1, repo_root))
      |> Enum.map(&Path.dirname/1)
      |> Enum.map(&Path.relative_to(&1, repo_root))
      |> Enum.reject(&(&1 == "."))
      |> Enum.uniq()
      |> Enum.sort()

    if root_project?, do: ["." | discovered] |> Enum.uniq(), else: discovered
  end

  defp ignored_file?(path, repo_root) do
    path
    |> Path.relative_to(repo_root)
    |> Path.split()
    |> Enum.any?(&(&1 in @ignored_prefixes))
  end

  defp unique_probe do
    String.to_atom("weld_discovery_#{System.unique_integer([:positive])}")
  end

  defp current_project_root do
    if Mix.Project.get() do
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.expand()
    end
  end

  defp without_module_conflicts(fun) do
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous[:ignore_module_conflict])
    end
  end
end
