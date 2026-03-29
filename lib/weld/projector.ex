defmodule Weld.Projector do
  @moduledoc """
  Generates the welded Mix project and its initial lockfile.
  """

  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Lockfile
  alias Weld.Plan

  @spec project!(Plan.t()) :: map()
  def project!(%Plan{} = plan) do
    plan = Plan.ensure_valid!(plan)
    build_path = build_path(plan)

    File.rm_rf!(build_path)
    File.mkdir_p!(build_path)

    copied_components = Enum.flat_map(plan.selected_projects, &copy_project!(build_path, &1))
    copied_docs = Enum.flat_map(plan.artifact.output.docs, &copy_relative!(plan, build_path, &1))

    copied_assets =
      Enum.flat_map(plan.artifact.output.assets, &copy_relative!(plan, build_path, &1))

    copied_tests =
      Enum.flat_map(
        plan.artifact.verify.artifact_tests,
        &copy_artifact_tests!(plan, build_path, &1)
      )

    ensure_readme!(plan, build_path)
    render_mixfile!(plan, build_path)

    projection =
      %{
        build_path: build_path,
        copied_files:
          (copied_components ++ copied_docs ++ copied_assets ++ copied_tests)
          |> Enum.uniq()
          |> Enum.sort(),
        package_files: package_files(plan),
        git_revision: Git.revision(plan.manifest.repo_root),
        tree_digest: Hash.sha256_tree(build_path)
      }

    lockfile = Lockfile.build(plan, projection, [])
    lockfile_path = Path.join(build_path, "projection.lock.json")
    File.write!(lockfile_path, Lockfile.encode!(lockfile))

    Map.put(projection, :lockfile_path, lockfile_path)
  end

  @spec build_path(Plan.t()) :: Path.t()
  def build_path(%Plan{} = plan) do
    dist_root = Path.expand(plan.artifact.output.dist_root, plan.manifest.repo_root)
    Path.join([dist_root, "hex", plan.artifact.package.name])
  end

  @spec package_files(Plan.t()) :: [String.t()]
  def package_files(%Plan{} = plan) do
    component_roots =
      plan.selected_projects
      |> Enum.map(&component_dir/1)
      |> Enum.map(&Path.join("components", &1))

    ["mix.exs", "projection.lock.json"]
    |> Kernel.++(component_roots)
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp copy_project!(build_path, project) do
    base = Path.join([build_path, "components", component_dir(project)])

    project.copy_dirs
    |> Enum.flat_map(fn dir ->
      source = Path.join(project.abs_path, dir)
      target = Path.join(base, dir)

      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)

      target
      |> list_copied_paths()
    end)
  end

  defp copy_relative!(plan, build_path, relative_path) do
    source = Path.join(plan.manifest.repo_root, relative_path)
    target = Path.join(build_path, relative_path)

    cond do
      File.regular?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        [relative_path]

      File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp_r!(source, target)

        target
        |> list_copied_paths()
        |> Enum.map(&Path.relative_to(&1, build_path))

      true ->
        raise Error, "copy target not found: #{relative_path}"
    end
  end

  defp copy_artifact_tests!(plan, build_path, relative_path) do
    source = Path.join(plan.manifest.repo_root, relative_path)

    unless File.dir?(source) do
      raise Error, "artifact test path not found: #{relative_path}"
    end

    target = Path.join(build_path, "test")
    File.mkdir_p!(target)

    source
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn child ->
      child_source = Path.join(source, child)
      child_target = Path.join(target, child)

      if File.dir?(child_source) do
        File.cp_r!(child_source, child_target)
      else
        File.cp!(child_source, child_target)
      end

      child_target
      |> list_copied_paths()
      |> Enum.map(&Path.relative_to(&1, build_path))
    end)
  end

  defp render_mixfile!(plan, build_path) do
    File.write!(Path.join(build_path, "mix.exs"), mixfile_contents(plan))
  end

  defp ensure_readme!(plan, build_path) do
    readme = Path.join(build_path, "README.md")

    unless File.exists?(readme) do
      File.write!(readme, "# #{plan.artifact.package.name}\n")
    end
  end

  defp mixfile_contents(plan) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    elixirc_paths = component_paths(plan.selected_projects, & &1.elixirc_paths)
    erlc_paths = component_paths(plan.selected_projects, & &1.erlc_paths)
    deps = render_deps(plan.external_deps)
    files = package_files(plan) |> Enum.map_join(",\n        ", &inspect/1)
    extras = plan.artifact.output.docs |> Enum.map_join(",\n        ", &inspect/1)
    links = package.links |> fallback_links(plan.manifest.repo_root) |> inspect(pretty: true)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        [
          app: #{inspect(package.otp_app)},
          version: #{inspect(package.version)},
          elixir: #{inspect(package.elixir)},
          start_permanent: Mix.env() == :prod,
          elixirc_paths: elixirc_paths(Mix.env()),
          erlc_paths: #{inspect(erlc_paths)},
          deps: deps(),
          description: #{inspect(package.description)},
          package: package(),
          docs: docs()
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end

      def elixirc_paths(:test) do
        base = #{inspect(elixirc_paths)}

        if File.dir?("test/support") do
          base ++ ["test/support"]
        else
          base
        end
      end

      def elixirc_paths(_env), do: #{inspect(elixirc_paths)}

      defp deps do
        [
    #{deps}
        ]
      end

      defp package do
        [
          licenses: #{inspect(package.licenses)},
          maintainers: #{inspect(package.maintainers)},
          links: #{links},
          files: [
            #{files}
          ]
        ]
      end

      defp docs do
        [
          main: #{inspect(package.docs_main)},
          extras: [
            #{extras}
          ]
        ]
      end
    end
    """
  end

  defp component_paths(projects, path_fun) do
    projects
    |> Enum.flat_map(fn project ->
      project
      |> path_fun.()
      |> Enum.map(fn relative ->
        Path.join(["components", component_dir(project), relative])
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp render_deps(external_deps) do
    external_deps
    |> Enum.map(fn dep -> dep.original end)
    |> Kernel.++([{:ex_doc, "~> 0.40", only: :dev, runtime: false}])
    |> Enum.map_join(",\n      ", &inspect/1)
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case Git.remote_url(repo_root) do
      nil -> %{"Source" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp component_dir(%{id: "."}), do: "root"
  defp component_dir(%{id: id}), do: id

  defp list_copied_paths(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Weld.Hash.list_files(path)
      true -> []
    end
  end
end
