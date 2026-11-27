defmodule Weld.Layout.Support do
  @moduledoc false

  alias Weld.Core.{Facts, Selection}
  alias Weld.{Error, Manifest}

  @root_tooling_files ~w(.formatter.exs .credo.exs .dialyzer_ignore.exs)

  @doc false
  def validate_inputs!(plan) do
    root = plan.manifest.repo_root
    artifact = plan.artifact
    graph? = artifact.mode != :source_project

    if graph?, do: validate_output_paths!(artifact)

    for path <-
          artifact.output.docs ++
            artifact.output.assets ++
            artifact.verify.artifact_tests ++
            List.wrap(artifact.verify.smoke.entry_file) do
      Facts.source!(plan.facts, root, path) |> then(&Facts.reject_tree_links!(plan.facts, &1))
    end

    if graph?, do: validate_graph_projects!(plan, root)
  end

  defp validate_output_paths!(artifact) do
    for path <- artifact.output.docs ++ artifact.output.assets do
      if hd(Path.split(path)) in ~w(mix.exs mix.lock doc config components test lib src c_src include weld.provenance.json projection.lock.json) do
        raise Error, "output path overlaps generated project files: #{path}"
      end
    end
  end

  defp validate_graph_projects!(plan, root) do
    for project <- Selection.projects_for_view(plan, :test) do
      include_suite? = plan.artifact.mode == :monolith or Selection.selected?(plan, project.id)
      validate_project_inputs!(root, project, include_suite?)
    end
  end

  defp validate_project_inputs!(root, project, include_suite?) do
    if project.id != ".", do: Facts.source!(project.facts, root, project.id)

    suite_paths =
      if include_suite? do
        project.test_elixirc_paths ++
          project.test_erlc_paths ++ project.test_paths ++ ["config", "test"]
      else
        []
      end

    for dir <-
          Enum.uniq(
            project.copy_dirs ++
              project.elixirc_paths ++
              project.erlc_paths ++
              [project.erlc_include_path] ++ suite_paths
          ) do
      relative = Path.relative_to(Path.expand(dir, project.abs_path), project.abs_path)

      Facts.source!(project.facts, project.abs_path, relative)
      |> then(&Facts.reject_tree_links!(project.facts, &1))
    end
  end

  @spec root_tooling_candidates() :: [String.t()]
  def root_tooling_candidates, do: @root_tooling_files

  @spec root_tooling_files(map()) :: [String.t()]
  def root_tooling_files(%{artifact: _} = plan) do
    @root_tooling_files
    |> Enum.filter(&Facts.regular?(plan.facts, Path.join(plan.manifest.repo_root, &1)))
  end

  @type docs_artifact :: %Manifest.Artifact{package: Manifest.Package.t()}

  @doc false
  @spec docs_options(
          %{required(:artifact) => docs_artifact(), optional(any()) => any()}
          | docs_artifact()
        ) :: nonempty_list({atom(), term()})
  def docs_options(%Manifest.Artifact{} = artifact), do: artifact_docs_options(artifact)

  def docs_options(%{artifact: %Manifest.Artifact{} = artifact}),
    do: artifact_docs_options(artifact)

  defp artifact_docs_options(artifact) do
    docs = artifact.package.docs

    extras =
      Enum.map(Manifest.docs_paths(artifact), fn path ->
        case docs.extra_titles do
          %{^path => title} -> {path, [title: title]}
          _titles -> path
        end
      end)

    [main: docs.main, extras: extras]
    |> maybe_put_docs_option(:logo, docs.logo)
    |> maybe_put_docs_option(:homepage_url, docs.homepage_url)
    |> maybe_put_docs_option(:source_url, docs.source_url)
    |> maybe_put_docs_option(:source_ref, docs.source_ref)
    |> maybe_put_docs_option(:assets, docs.assets)
    |> maybe_put_docs_option(:groups_for_extras, docs.groups_for_extras)
  end

  # ExDoc swaps page content on in-site navigation and fires "exdoc:loaded"
  # (also on first load), so DOMContentLoaded alone misses navigated pages.
  # The hook text for `before_closing_body_tag`. When `package.docs.hook_file` is
  # set, that checkout file is the single owner (the root Mix project can read
  # the same file); otherwise the built-in Mermaid hook is used.
  @doc false
  def mermaid_hook(%{artifact: _} = plan) do
    case plan.artifact.package.docs.hook_file do
      nil ->
        mermaid_hook()

      relative ->
        Facts.read!(plan.facts, Facts.source!(plan.facts, plan.manifest.repo_root, relative))
    end
  end

  @doc false
  def mermaid_hook do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"></script>
    <script>
    window.addEventListener("exdoc:loaded", () => {
    const codeBlocks = document.querySelectorAll("pre code.mermaid");
    if (!codeBlocks.length || !window.mermaid) return;
    mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: document.body.classList.contains("dark") ? "dark" : "default"
    });
    const nodes = Array.from(codeBlocks, code => {
    const diagram = document.createElement("div");
    diagram.className = "mermaid";
    diagram.textContent = code.textContent;
    code.parentElement.replaceWith(diagram);
    return diagram;
    });
    mermaid.run({nodes});
    });
    </script>
    """
  end

  @doc false
  def render_docs_options(%{artifact: _} = plan) do
    options =
      inspect(docs_options(plan), pretty: true, limit: :infinity, printable_limit: :infinity)

    if plan.artifact.package.docs.mermaid do
      hook = plan |> mermaid_hook() |> inspect(limit: :infinity, printable_limit: :infinity)

      "Keyword.put(#{options}, :before_closing_body_tag, fn :html -> #{hook}; _ -> \"\" end)"
    else
      options
    end
  end

  defp maybe_put_docs_option(options, _key, nil), do: options
  defp maybe_put_docs_option(options, _key, empty) when empty in [%{}, []], do: options
  defp maybe_put_docs_option(options, key, value), do: Keyword.put(options, key, value)

  def detect_repo_infos(projects) do
    projects
    |> Enum.flat_map(fn project ->
      lib_root = Path.join(project.abs_path, "lib")

      if Facts.dir?(project.facts, lib_root) do
        project.facts
        |> Facts.list_files(lib_root)
        |> Enum.filter(&(Path.extname(&1) == ".ex"))
        |> Enum.flat_map(&repo_info_from_file(&1, project))
      else
        []
      end
    end)
  end

  defp repo_info_from_file(path, project) do
    contents = Facts.read!(project.facts, path)

    if String.contains?(contents, "use Ecto.Repo") do
      module =
        case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, contents, capture: :all_but_first) do
          [module] -> Module.concat([module])
          _ -> raise Error, "unable to parse Ecto repo module from #{path}"
        end

      otp_app =
        case Regex.run(~r/otp_app:\s*:(\w+)/, contents, capture: :all_but_first) do
          [otp_app] -> String.to_atom(otp_app)
          _ -> raise Error, "unable to parse Ecto repo otp_app from #{path}"
        end

      [
        %{
          project_id: project.id,
          source: path,
          module: module,
          otp_app: otp_app
        }
      ]
    else
      []
    end
  end
end
