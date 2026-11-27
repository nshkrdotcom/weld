defmodule Weld.Plan do
  @moduledoc """
  Resolves one artifact view from the manifest and workspace graph.
  """

  alias Weld.Core.Compiler
  alias Weld.{Graph, Manifest}
  alias Weld.Shell.Snapshot
  alias Weld.{Violation, Workspace}
  alias Weld.Workspace.Project

  @enforce_keys [
    :manifest,
    :artifact,
    :workspace,
    :graph,
    :selected_ids,
    :excluded_ids,
    :selected_projects,
    :external_deps,
    :violations
  ]
  defstruct @enforce_keys ++
              [
                facts: nil,
                artifact_graph: nil,
                dependency_ids: [],
                source_member_ids: [],
                inventory_member_ids: [],
                verification_ids: [],
                externalized_edges: [],
                source_root: nil,
                source_roots: [],
                source_inventory: [],
                structural_inputs: [],
                layout: nil,
                output_inventory: [],
                input_watches: []
              ]

  @type external_dep :: Graph.external_dep()

  @typedoc """
  A source-to-target inventory relationship within an artifact plan.

  Monolith entries also describe the materialization operation and
  whether the destination belongs to the publication inventory.
  """
  @type inventory_entry :: %{
          optional(:operation) => :link_or_copy | :copy | :transform | :generate,
          optional(:publish) => boolean(),
          source: String.t(),
          target: String.t(),
          owner: String.t() | nil,
          kind: :compiled | :runtime | :test | :docs | :metadata | :artifact_test,
          directory: boolean()
        }

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          artifact: Manifest.Artifact.t(),
          workspace: Workspace.t(),
          graph: Graph.t(),
          artifact_graph: Graph.t() | nil,
          dependency_ids: [String.t()],
          source_member_ids: [String.t()],
          inventory_member_ids: [String.t()],
          verification_ids: [String.t()],
          externalized_edges: [Weld.Graph.Edge.t()],
          source_root: Path.t() | nil,
          source_roots: [inventory_entry()],
          source_inventory: [inventory_entry()],
          structural_inputs: [Path.t()],
          layout: map() | nil,
          output_inventory: [map()],
          input_watches: [map()],
          selected_ids: [String.t()],
          excluded_ids: [String.t()],
          selected_projects: [Project.t()],
          external_deps: [external_dep()],
          violations: [Violation.t()]
        }

  @spec build!(Path.t() | Manifest.t(), keyword()) :: t()
  def build!(source, opts \\ [])
  def build!(path, opts) when is_binary(path), do: path |> Manifest.load!() |> build!(opts)

  def build!(%Manifest{} = manifest, opts) do
    build_from_workspace!(manifest, Workspace.load!(manifest, opts), opts)
  end

  def build_from_workspace!(manifest, workspace, opts) do
    artifact =
      manifest |> Manifest.artifact!(opts[:artifact]) |> Manifest.bind_native(workspace.projects)

    facts = workspace.facts || Snapshot.collect!(manifest, opts)

    projects =
      Map.new(workspace.projects, fn {id, project} -> {id, Map.put(project, :facts, facts)} end)

    workspace = %{workspace | facts: facts, projects: projects}
    compiled = Compiler.compile!(manifest, workspace, artifact, opts)
    struct!(__MODULE__, compiled)
  end

  defdelegate selected?(plan, id), to: Weld.Core.Selection
  defdelegate projects_for_view(plan, view), to: Weld.Core.Selection
  defdelegate external_deps_for_view(plan, view), to: Weld.Core.Selection
  defdelegate ensure_valid!(plan), to: Weld.Core.Selection
end
