defmodule Weld.LiteralPlan do
  @moduledoc false
  alias Weld.{Graph, Manifest, Plan, Workspace}
  alias Weld.Core.{Compiler, Identity}
  alias Weld.Workspace.Project

  # No file is opened: even Mix source bytes are supplied literal observations.
  def build(root \\ "/nonexistent/weld-literal", additions \\ %{}) do
    files =
      %{
        "build_support/weld.exs" => "# literal trusted declaration\n",
        "apps/a/mix.exs" => "# literal Mix observation, never evaluated\n",
        "apps/a/lib/a.ex" => "defmodule Literal.A do\n  def value, do: :ok\nend\n"
      }
      |> Map.merge(additions)

    nodes =
      Enum.reduce(files, %{}, fn {relative, content}, nodes ->
        path = Path.join(root, relative)

        node = %{
          type: :regular,
          mode: 0o644,
          size: byte_size(content),
          sha256: Identity.raw(content),
          content: content
        }

        add_parents(Map.put(nodes, path, node), Path.dirname(path), root)
      end)

    facts = %{
      root: root,
      nodes: nodes,
      compiler_id: Identity.raw("literal compiler"),
      toolchain: %{"test" => "literal"},
      context: [],
      remote_url: nil
    }

    docs = %Manifest.Docs{
      main: "readme",
      logo: nil,
      homepage_url: nil,
      source_url: nil,
      source_ref: "v0.1.0",
      assets: %{},
      extra_titles: %{},
      groups_for_extras: [],
      mermaid: false,
      hook_file: nil
    }

    package = %Manifest.Package{
      name: "literal",
      otp_app: :literal,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Pure compiler fixture",
      licenses: ["MIT"],
      maintainers: [],
      links: %{"Source" => "https://example.test/literal"},
      docs_main: "readme",
      docs: docs,
      development_dependencies: []
    }

    artifact = %Manifest.Artifact{
      id: "literal",
      mode: :package_projection,
      monolith_opts: [],
      roots: ["apps/a"],
      include: [],
      optional_features: [],
      package: package,
      output: %Manifest.Output{dist_root: ".weld", layout: :components, docs: [], assets: []},
      verify: %Manifest.Verify{
        artifact_tests: [],
        component_tests: false,
        smoke: %{enabled: false, entry_file: nil},
        hex_build: true,
        hex_publish: false,
        context: []
      }
    }

    manifest = %Manifest{
      manifest_path: Path.join(root, "build_support/weld.exs"),
      repo_root: root,
      workspace: %{root: root, project_globs: ["apps/*"]},
      classify: %{tooling: MapSet.new(), proofs: MapSet.new(), ignored: MapSet.new()},
      publication: %{internal_only: MapSet.new(), separate: MapSet.new(), optional: %{}},
      dependencies: %{},
      project_inputs: %{},
      artifacts: %{"literal" => artifact}
    }

    project = %Project{
      id: "apps/a",
      abs_path: Path.join(root, "apps/a"),
      app: :literal_a,
      version: "0.1.0",
      package_name: "literal_a",
      elixir: "~> 1.18",
      deps: [],
      deps_by_env: %{dev: [], test: [], prod: []},
      application: %{mod: nil, extra_applications: [], included_applications: [], registered: []},
      elixirc_paths: ["lib"],
      erlc_paths: ["src"],
      test_elixirc_paths: ["lib"],
      test_erlc_paths: ["src"],
      test_paths: ["test"],
      copy_dirs: ["lib"],
      classification: :runtime,
      publication_role: :default,
      facts: facts
    }

    projects = %{project.id => project}
    graph = Graph.build(manifest, projects)

    workspace = %Workspace{
      manifest: manifest,
      projects: projects,
      graph: graph,
      facts: facts,
      discovery: %{
        source: :manifest,
        root_project?: false,
        globs: ["apps/*"],
        project_ids: [project.id],
        adapter: nil
      }
    }

    struct!(Plan, Compiler.compile!(manifest, workspace, artifact, []))
  end

  defp add_parents(nodes, root, root), do: Map.put(nodes, root, %{type: :directory, mode: 0o755})

  defp add_parents(nodes, directory, root),
    do:
      nodes
      |> Map.put(directory, %{type: :directory, mode: 0o755})
      |> add_parents(Path.dirname(directory), root)
end
