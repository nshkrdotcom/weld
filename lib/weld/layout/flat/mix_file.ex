defmodule Weld.Layout.Flat.MixFile do
  @moduledoc false

  alias Weld.Layout.FilePlan
  alias Weld.Layout.Support
  alias Weld.Layout.Render
  alias Weld.Core.Inputs
  alias Weld.SourceFormatter

  def plan!(%{} = plan, operations, opts) do
    application = Render.application(plan, opts)
    inputs = Keyword.get(opts, :inputs, [])

    app_operations =
      if application.module do
        relative = Path.join(["lib", to_string(plan.artifact.package.otp_app), "application.ex"])

        [
          FilePlan.generated(
            relative,
            Render.application_source(application, plan.artifact.package.otp_app)
            |> SourceFormatter.format!(),
            :compiled,
            inputs
          )
        ]
      else
        []
      end

    paths = Enum.map(operations ++ app_operations, & &1.target)

    files =
      Inputs.publication_files(plan, ["mix.exs" | paths], package_files(plan, paths))

    opts = Keyword.put(opts, :package_files, files)

    mix =
      FilePlan.generated(
        "mix.exs",
        mixfile_contents(plan, paths, application, opts) |> SourceFormatter.format!(),
        :metadata,
        inputs
      )

    %{operations: [mix | app_operations], package_files: files}
  end

  def package_files(%{} = plan, paths, opts \\ []) do
    package_dir_files(paths, Keyword.get(opts, :include_tests?, false))
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Kernel.++(["mix.exs"])
    |> Enum.uniq()
    |> List.delete("projection.lock.json")
    |> collapse_descendant_paths()
    |> Enum.sort()
  end

  defp mixfile_contents(plan, paths, application, opts) do
    erlc = build_erlc_paths(paths, Keyword.get(opts, :test_support_projects, []))

    spec = %{
      elixirc_paths: ["lib"],
      test_elixirc_paths:
        if(has_path?(paths, "test/support"), do: ["lib", "test/support"], else: ["lib"]),
      erlc_paths: Enum.filter(erlc, &(&1 == "src")),
      test_erlc_paths: erlc,
      include_paths: if(has_path?(paths, "include"), do: ["include"], else: []),
      test_include_paths: if(has_path?(paths, "include"), do: ["include"], else: []),
      test_paths: ["test"],
      test_ignore_filters:
        Enum.filter(
          paths,
          &(String.starts_with?(&1, "test/") and
              (String.ends_with?(&1, "_helper.exs") or String.starts_with?(&1, "test/support/")))
        ),
      deps:
        Render.dependencies(
          Keyword.get(opts, :runtime_external_deps, plan.external_deps),
          Keyword.get(opts, :test_external_deps, []) ++
            Keyword.get(opts, :forced_test_external_deps, []),
          plan.artifact.package.development_dependencies
        )
    }

    Render.mix(plan, application, spec, opts)
  end

  defp build_erlc_paths(paths, test_support_projects) do
    runtime_paths = if has_path?(paths, "src"), do: ["src"], else: []

    test_paths =
      test_support_projects
      |> Enum.map(fn project ->
        Path.join(["test", "support", "weld_projects", project_slug(project.id), "src"])
      end)
      |> Enum.filter(&has_path?(paths, &1))

    runtime_paths ++ test_paths
  end

  defp package_dir_files(paths, include_tests?) do
    candidates =
      ["README.md", "LICENSE", "lib", "config", "priv", "src", "c_src", "include"]
      |> maybe_add_tests(include_tests?)
      |> Kernel.++(root_docs_dirs(paths))
      |> Kernel.++(root_tooling_files(paths))

    candidates
    |> Enum.filter(fn relative ->
      has_path?(paths, relative)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_add_tests(candidates, true), do: candidates ++ ["test"]
  defp maybe_add_tests(candidates, false), do: candidates

  defp root_docs_dirs(paths) do
    ["guides", "docs", "examples"]
    |> Enum.filter(&has_path?(paths, &1))
  end

  defp root_tooling_files(paths) do
    Support.root_tooling_candidates()
    |> Enum.filter(&(&1 in paths))
  end

  defp has_path?(paths, relative),
    do: Enum.any?(paths, &(&1 == relative or String.starts_with?(&1, relative <> "/")))

  defp collapse_descendant_paths(paths) do
    Enum.reject(paths, fn path ->
      Enum.any?(paths, fn candidate ->
        candidate != path and String.starts_with?(path, candidate <> "/")
      end)
    end)
  end

  defp project_slug(project_id), do: FilePlan.slug(project_id)
end
