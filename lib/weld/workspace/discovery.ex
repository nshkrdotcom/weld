defmodule Weld.Workspace.Discovery do
  @moduledoc "Discovers only projects explicitly declared by the v2 manifest."

  alias Weld.{Error, Manifest}
  alias Weld.Core.Facts
  alias Weld.Shell.Snapshot
  @ignored ~w(.git .weld _build deps dist tmp doc)
  @type result :: %{
          source: :manifest,
          root_project?: boolean(),
          globs: [String.t()],
          project_ids: [String.t()],
          adapter: nil
        }

  @spec discover(Manifest.t(), map() | nil) :: result()
  def discover(%Manifest{} = manifest, facts \\ nil) do
    root = manifest.repo_root
    facts = facts || Snapshot.observe!(root)
    globs = Enum.map(manifest.workspace.project_globs, fn pattern ->
      pattern |> Path.expand(manifest.workspace.root) |> Path.relative_to(root)
    end)

    projects =
      globs
      |> Enum.flat_map(&Facts.wildcard(facts, Path.join(root, &1)))
      |> Enum.map(&Path.relative_to(Path.expand(&1), root))
      |> Enum.reject(fn id -> Enum.any?(Path.split(id), &(&1 in @ignored)) end)
      |> Enum.filter(fn id ->
        project = if id == ".", do: root, else: Facts.source!(facts, root, id)
        Facts.dir?(facts, project) and Facts.regular?(facts, Facts.source!(facts, project, "mix.exs"))
      end)
      |> Enum.sort()

    case Enum.frequencies(projects)
         |> Enum.filter(fn {_id, count} -> count > 1 end)
         |> Enum.sort() do
      [{duplicate, _} | _] ->
        raise Error, code: :overlapping_globs, phase: :manifest,
          message: "workspace.projects globs overlap at #{duplicate}",
          details: %{path: "workspace.projects", project: duplicate}

      [] ->
        :ok
    end

    if projects == [], do: raise(Error, code: :missing_project, phase: :manifest,
      message: "workspace.projects matched no Mix projects", details: %{path: "workspace.projects"})

    %{
      source: :manifest,
      root_project?: "." in projects,
      globs: globs,
      project_ids: projects,
      adapter: nil
    }
  end
end
