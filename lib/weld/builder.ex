defmodule Weld.Builder do
  @moduledoc """
  Assembles a standalone projection directory and renders the generated Mix
  project.
  """

  alias Weld.Manifest
  alias Weld.ProjectGraph

  @spec build!(Manifest.t(), keyword()) :: Path.t()
  def build!(%Manifest{} = manifest, opts \\ []) do
    graph = ProjectGraph.load!(manifest)

    dist_root =
      opts
      |> Keyword.get(:dist_root, Path.join(manifest.repo_root, "dist"))
      |> Path.expand()

    build_path = Path.join([dist_root, "hex", manifest.package_name])

    File.rm_rf!(build_path)
    File.mkdir_p!(build_path)

    graph.projects
    |> Map.values()
    |> Enum.sort_by(& &1.path)
    |> Enum.each(&copy_project!(build_path, &1))

    copy_docs!(build_path, manifest)
    copy_assets!(build_path, manifest)
    render_mixfile!(build_path, manifest, graph)

    build_path
  end

  @spec verify_build!(Path.t()) :: :ok
  def verify_build!(build_path) do
    run_mix!(build_path, ["deps.get"])
    run_mix!(build_path, ["compile"])
    run_mix!(build_path, ["docs"])
    run_mix!(build_path, ["hex.build"])
    :ok
  end

  defp run_mix!(build_path, args) do
    {output, status} = System.cmd("mix", args, cd: build_path, stderr_to_stdout: true)

    if status != 0 do
      raise Weld.Error,
            "generated project command failed: mix #{Enum.join(args, " ")}\n\n#{output}"
    end
  end

  defp copy_project!(build_path, project) do
    slug = vendor_slug(project.path)

    Enum.each(project.copy_dirs, fn dir ->
      source = Path.join(project.abs_path, dir)
      target = Path.join([build_path, "vendor", slug, dir])

      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)
    end)
  end

  defp copy_docs!(build_path, manifest) do
    Enum.each(manifest.copy.docs, fn relative_path ->
      copy_relative!(manifest.repo_root, build_path, relative_path)
    end)

    unless File.exists?(Path.join(build_path, "README.md")) do
      File.write!(Path.join(build_path, "README.md"), "# #{manifest.package_name}\n")
    end
  end

  defp copy_assets!(build_path, manifest) do
    Enum.each(manifest.copy.assets, fn relative_path ->
      copy_relative!(manifest.repo_root, build_path, relative_path)
    end)
  end

  defp copy_relative!(root, build_path, relative_path) do
    source = Path.join(root, relative_path)
    target = Path.join(build_path, relative_path)

    cond do
      File.regular?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)

      File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp_r!(source, target)

      true ->
        raise Weld.Error, "copy target not found: #{relative_path}"
    end
  end

  defp render_mixfile!(build_path, manifest, graph) do
    File.write!(Path.join(build_path, "mix.exs"), mixfile_contents(manifest, graph))
  end

  defp mixfile_contents(manifest, graph) do
    module_name = "#{Macro.camelize(to_string(manifest.otp_app))}.MixProject"
    package_links = manifest.links |> fallback_links(manifest.repo_root) |> inspect(pretty: true)

    elixirc_paths =
      graph.projects
      |> Map.values()
      |> Enum.flat_map(fn project ->
        slug = vendor_slug(project.path)

        project.elixirc_paths
        |> Enum.map(&Path.join(["vendor", slug, &1]))
        |> Enum.filter(&(Path.extname(&1) == "" and String.ends_with?(&1, "lib")))
      end)
      |> Enum.uniq()

    erlc_paths =
      graph.projects
      |> Map.values()
      |> Enum.flat_map(fn project ->
        slug = vendor_slug(project.path)

        project.erlc_paths
        |> Enum.map(&Path.join(["vendor", slug, &1]))
        |> Enum.filter(&(Path.extname(&1) == "" and String.ends_with?(&1, "src")))
      end)
      |> Enum.uniq()

    package_files =
      build_path_file_list(manifest, graph)
      |> Enum.map_join(",\n        ", &inspect/1)

    deps =
      graph.external_deps
      |> Kernel.++([{:ex_doc, "~> 0.40", only: :dev, runtime: false}])
      |> Enum.map_join(",\n      ", &dep_to_string/1)

    extras =
      manifest.copy.docs
      |> Enum.map_join(",\n        ", &inspect/1)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        [
          app: #{inspect(manifest.otp_app)},
          version: #{inspect(manifest.version)},
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          elixirc_paths: #{inspect(elixirc_paths)},
          erlc_paths: #{inspect(erlc_paths)},
          deps: deps(),
          description: #{inspect(manifest.description)},
          package: package(),
          docs: docs()
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end

      defp deps do
        [
      #{deps}
        ]
      end

      defp package do
        [
          licenses: #{inspect(manifest.licenses)},
          maintainers: #{inspect(manifest.maintainers)},
          links: #{package_links},
          files: [
            #{package_files}
          ]
        ]
      end

      defp docs do
        [
          main: #{inspect(manifest.docs.main)},
          extras: [
            #{extras}
          ]
        ]
      end
    end
    """
  end

  defp build_path_file_list(manifest, graph) do
    vendor_paths =
      graph.projects
      |> Map.values()
      |> Enum.map(fn project -> "vendor/#{vendor_slug(project.path)}" end)

    docs = manifest.copy.docs
    assets = manifest.copy.assets

    ["mix.exs" | vendor_paths ++ docs ++ assets]
    |> Enum.uniq()
  end

  defp dep_to_string(dep) do
    inspect(dep, pretty: true, width: 80, limit: :infinity)
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case repo_remote_url(repo_root) do
      nil -> %{"Weld" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp repo_remote_url(repo_root) do
    case System.cmd("git", ["config", "--get", "remote.origin.url"],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {url, 0} ->
        url
        |> String.trim()
        |> normalize_remote_url()

      _ ->
        nil
    end
  end

  defp normalize_remote_url(""), do: nil

  defp normalize_remote_url("git@github.com:" <> rest) do
    "https://github.com/" <> String.trim_trailing(rest, ".git")
  end

  defp normalize_remote_url(url) when is_binary(url) do
    String.trim_trailing(url, ".git")
  end

  defp vendor_slug(path) do
    path
    |> String.replace("/", "_")
    |> String.replace("-", "_")
  end
end
