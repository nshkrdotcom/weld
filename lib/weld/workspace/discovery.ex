defmodule Weld.Workspace.Discovery do
  @moduledoc "Discovers only projects explicitly declared by the v2 manifest."

  alias Weld.{Error, Manifest, Output}
  @ignored ~w(.git .weld _build deps dist tmp doc)
  @type result :: %{
          source: :manifest,
          root_project?: boolean(),
          globs: [String.t()],
          project_ids: [String.t()],
          adapter: nil
        }

  @spec discover(Manifest.t()) :: result()
  def discover(%Manifest{} = manifest) do
    root = manifest.repo_root
    globs = manifest.workspace.project_globs

    projects =
      globs
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1), match_dot: false))
      |> Enum.map(&Path.relative_to(Path.expand(&1), root))
      |> Enum.reject(fn id -> Enum.any?(Path.split(id), &(&1 in @ignored)) end)
      |> Enum.filter(fn id ->
        project = if id == ".", do: root, else: Output.source!(root, id)
        File.regular?(Output.source!(project, "mix.exs"))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if projects == [], do: raise(Error, "workspace.projects matched no Mix projects")

    %{
      source: :manifest,
      root_project?: "." in projects,
      globs: globs,
      project_ids: projects,
      adapter: nil
    }
  end
end
