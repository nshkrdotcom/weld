defmodule Weld.WorkspaceSnapshotV2Test do
  use ExUnit.Case, async: false
  alias Weld.CLI
  alias Weld.Core.Selection
  alias Weld.{Error, FixtureCase, Manifest, Workspace}

  setup do
    %{tmp_dir: Weld.FixtureCase.unique_tmp_dir("weld_workspace_snapshot")}
  end

  test "multi-artifact planning probes each project/environment once with competing nested helpers",
       %{tmp_dir: dir} do
    {path, counter} = workspace(dir)
    parent = {Mix.Project.get(), Mix.env(), Code.required_files()}

    assert {:ok, %{results: results, partial_failure: false}} =
             Weld.run(CLI.parse!("plan", ["--manifest", path, "--all"]))

    assert Enum.map(results, & &1.artifact) == ["alpha", "beta"]

    assert probes(counter) == [
             "left:dev",
             "left:prod",
             "left:test",
             "right:dev",
             "right:prod",
             "right:test"
           ]

    assert {Mix.Project.get(), Mix.env(), Code.required_files()} == parent
    refute Code.ensure_loaded?(WeldSnapshot.RepeatedProject)
    refute Code.ensure_loaded?(WeldSnapshot.RepeatedHelper)
  end

  test "compile-time environment and nested required files are explicit snapshot facts", %{
    tmp_dir: dir
  } do
    {path, _counter} = workspace(dir)
    loaded = path |> Manifest.load!() |> Workspace.load!()

    for {id, project} <- loaded.projects do
      assert project.test_paths == ["test/env-specific"]
      assert project.version == "1.2.3"
      assert "#{id}/nested/helper.exs" in project.probe_inputs
      assert project.facts == loaded.facts
      assert Enum.sort(Map.keys(project.deps_by_env)) == [:dev, :prod, :test]
      assert project.probe_context.prod.environment == :prod
      assert project.config_by_env.prod[:version] == "1.2.3"
      assert Enum.sort(Map.keys(project.application_by_env)) == [:dev, :prod, :test]
    end
  end

  test "hidden production dependencies enter publication while dev/test branches remain scoped",
       %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    mix = Path.join(root, "left/mix.exs")

    File.write!(
      mix,
      File.read!(mix)
      |> String.replace(
        "version: WeldSnapshot.RepeatedHelper.version(),",
        "version: WeldSnapshot.RepeatedHelper.version(), deps: if(@environment == :prod, do: [{:production_dep, \"~> 1.0\"}], else: [{:development_dep, \"~> 2.0\"}]),"
      )
    )

    loaded = path |> Manifest.load!() |> Workspace.load!()
    project = loaded.projects["left"]
    assert [%{app: :production_dep}] = project.deps_by_env.prod
    assert [%{app: :development_dep}] = project.deps_by_env.dev
    assert [%{app: :development_dep}] = project.deps_by_env.test

    assert [%{app: :production_dep, opts: opts}] =
             Selection.merge_external_deps(loaded.graph, ["left"], :package).external_deps

    assert opts[:only] == [:prod]
    assert Enum.find(project.deps, &(&1.app == :development_dep)).opts[:only] == [:dev, :test]

    assert Enum.map(
             Selection.merge_external_deps(loaded.graph, ["left"], :test).external_deps,
             & &1.app
           ) == [:development_dep, :production_dep]
  end

  test "equivalent Hex defaults across environments do not introduce scopes", %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    mix = Path.join(root, "left/mix.exs")

    File.write!(
      mix,
      String.replace(
        File.read!(mix),
        "version: WeldSnapshot.RepeatedHelper.version(),",
        ~s|version: WeldSnapshot.RepeatedHelper.version(), deps: if(@environment == :prod, do: [{:fixture_dep, "~> 1.0", hex: "fixture_dep", repo: "hexpm"}], else: [{:fixture_dep, "~> 1.0"}]),|
      )
    )

    loaded = path |> Manifest.load!() |> Workspace.load!()
    project = loaded.projects["left"]

    assert [%{original: {:fixture_dep, "~> 1.0", [hex: "fixture_dep", repo: "hexpm"]}}] =
             project.deps_by_env.prod

    assert [%{original: {:fixture_dep, "~> 1.0"}, opts: []}] = project.deps
  end

  @tag :slow
  test "production-only identity package compiler and application drift fail explicitly", %{
    tmp_dir: dir
  } do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    {raw, _} = Code.eval_file(path)

    raw =
      raw
      |> put_in([:workspace, :projects], ["left"])
      |> put_in([:artifacts], alpha: raw[:artifacts][:alpha])
      |> put_in([:project_inputs], [
        {"left", raw[:project_inputs] |> List.keyfind("left", 0) |> elem(1)}
      ])

    File.write!(path, inspect(raw, pretty: true, limit: :infinity))
    mix = Path.join(root, "left/mix.exs")
    original = File.read!(mix)

    cases = [
      {:app,
       String.replace(
         original,
         "app: :snapshot_left",
         "app: if(@environment == :prod, do: :other_app, else: :snapshot_left)"
       )},
      {:package,
       String.replace(
         original,
         "version: WeldSnapshot.RepeatedHelper.version(),",
         "version: WeldSnapshot.RepeatedHelper.version(), package: [name: if(@environment == :prod, do: \"production_name\", else: \"snapshot_left\")],"
       )},
      {:compilers,
       String.replace(
         original,
         "version: WeldSnapshot.RepeatedHelper.version(),",
         "version: WeldSnapshot.RepeatedHelper.version(), compilers: if(@environment == :prod, do: [:custom], else: []),"
       )},
      {:elixirc_paths,
       String.replace(
         original,
         "version: WeldSnapshot.RepeatedHelper.version(),",
         "version: WeldSnapshot.RepeatedHelper.version(), elixirc_paths: if(@environment == :prod, do: [\"production\"], else: [\"lib\"]),"
       )},
      {:application,
       String.replace(
         original,
         "  def project,",
         "  def application, do: [extra_applications: if(@environment == :prod, do: [:crypto], else: [])]\n  def project,"
       )}
    ]

    for {field, source} <- cases do
      File.write!(mix, source)
      error = assert_raise Error, fn -> path |> Manifest.load!() |> Workspace.load!() end
      assert error.code in [:conflicting_project_identity, :unsupported_environment_semantics]
      assert error.details.environment == :prod
      assert error.details.field == field
      refute File.exists?(Path.join(root, ".weld"))
    end
  end

  @tag :slow
  test "declared dynamic helper input changes invalidate only its artifact", %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    request = CLI.parse!("plan", ["--manifest", path, "--all"])
    assert {:ok, before} = Weld.run(request)
    File.write!(Path.join([Path.dirname(Path.dirname(path)), "left", "VERSION"]), "1.2.4")
    assert {:ok, after_} = Weld.run(request)
    old = Map.new(before.results, &{&1.artifact, &1.data.input_id})
    new = Map.new(after_.results, &{&1.artifact, &1.data.input_id})
    refute old["alpha"] == new["alpha"]
    assert old["beta"] == new["beta"]
  end

  test "probe-side mutation of a declared dynamic input invalidates the snapshot", %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    helper = Path.join(root, "left/nested/helper.exs")

    File.write!(
      helper,
      ~s|File.write!(Path.join(__DIR__, "../VERSION"), "1.2.4")\n| <> File.read!(helper)
    )

    assert_raise Error, ~r/inputs_changed/, fn ->
      path |> Manifest.load!() |> Workspace.load!()
    end

    refute File.exists?(Path.join(root, ".weld"))
  end

  test "a missing required helper fails without activating output", %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    File.rm!(Path.join(root, "left/nested/helper.exs"))
    assert_raise Error, fn -> path |> Manifest.load!() |> Workspace.load!() end
    refute File.exists?(Path.join(root, ".weld"))
  end

  @tag integration: true, ci_build: "probe_timeout"
  test "a stuck metadata VM is bounded and leaves no active child", %{tmp_dir: dir} do
    source = Path.join(dir, "stuck")
    File.mkdir_p!(source)
    marker = Path.join(dir, "pid")

    File.write!(
      Path.join(source, "mix.exs"),
      "File.write!(#{inspect(marker)}, System.pid())\nProcess.sleep(:infinity)\n"
    )

    assert_raise Error, fn -> Workspace.Probe.project!(source, :dev, seconds: 1) end
    pid = marker |> File.read!() |> String.trim()
    assert {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  @tag :slow
  test "affected batches each historical tree once and includes removed artifacts", %{
    tmp_dir: dir
  } do
    {path, counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    FixtureCase.init_git!(root)
    base = Weld.Git.revision(root)

    File.write!(
      Path.join(root, "left/lib/left.ex"),
      "defmodule SnapshotLeft, do: def(value, do: :changed)\n"
    )

    {raw, _} = Code.eval_file(path)

    File.write!(
      path,
      raw
      |> Keyword.update!(:artifacts, &Keyword.delete(&1, :beta))
      |> inspect(pretty: true, limit: :infinity)
    )

    FixtureCase.commit_all!(root, "remove beta and change alpha")
    File.write!(counter, "")
    report = Weld.Affected.compare!(path, base: base, head: "HEAD", task: "package")
    assert report.affected_artifacts == ["alpha", "beta"]
    assert Enum.map(report.results, & &1.artifact) == ["alpha", "beta"]
    assert Enum.find(report.results, &(&1.artifact == "beta")).data.reasons == [:artifact_removed]
    assert length(probes(counter)) == 12
  end

  @tag :slow
  test "an unavailable manifest is conservative while an invalid revision is an argument error",
       %{tmp_dir: dir} do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    FixtureCase.init_git!(root)

    assert_raise Error, ~r/invalid Git revision/, fn ->
      Weld.Affected.compare!(path,
        artifact: "alpha",
        base: "missing-ref",
        head: "HEAD",
        task: "verify"
      )
    end

    File.rm!(path)
    FixtureCase.commit_all!(root, "remove manifest")

    report =
      Weld.Affected.compare!(path,
        artifact: "alpha",
        base: "HEAD~1",
        head: "HEAD",
        task: "verify"
      )

    assert report.affected?
    assert report.unknown?
    assert report.reasons != []
  end

  @tag :slow
  test "release affected binds source provenance even when package content is unchanged", %{
    tmp_dir: dir
  } do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    FixtureCase.init_git!(root)
    File.write!(Path.join(root, "unrelated.txt"), "not an artifact input")
    FixtureCase.commit_all!(root, "unrelated source commit")

    package =
      Weld.Affected.compare!(path,
        artifact: "alpha",
        base: "HEAD~1",
        head: "HEAD",
        task: "package"
      )

    release =
      Weld.Affected.compare!(path,
        artifact: "alpha",
        base: "HEAD~1",
        head: "HEAD",
        task: "release"
      )

    refute package.affected?
    assert release.affected?
    refute release.content_changed
    assert release.source_revision_changed
  end

  @tag :slow
  test "opaque canonical external source locators keep affected analysis conservative", %{
    tmp_dir: dir
  } do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    mix = Path.join(root, "left/mix.exs")

    File.write!(
      mix,
      File.read!(mix)
      |> String.replace(
        "version: WeldSnapshot.RepeatedHelper.version(),",
        "version: WeldSnapshot.RepeatedHelper.version(), deps: [{:external_library, path: \"/unobserved-provider/source\"}],"
      )
    )

    {raw, _} = Code.eval_file(path)
    raw = Keyword.put(raw, :dependencies, external_library: [requirement: "~> 1.0", opts: []])
    File.write!(path, inspect(raw, pretty: true, limit: :infinity))
    FixtureCase.init_git!(root)

    report =
      Weld.Affected.compare!(path, artifact: "alpha", base: "HEAD", head: "HEAD", task: "package")

    assert report.affected?
    assert report.unknown?
    assert report.reasons == [:opaque_inputs]
    assert report.affected_projects == ["left"]
    refute report.content_changed
    refute report.source_revision_changed
  end

  @tag :slow
  test "runtime Git requirements are preserved only for explicit non-Hex artifacts", %{
    tmp_dir: dir
  } do
    {path, _counter} = workspace(dir)
    root = Path.dirname(Path.dirname(path))
    mix = Path.join(root, "left/mix.exs")

    File.write!(
      mix,
      File.read!(mix)
      |> String.replace(
        "version: WeldSnapshot.RepeatedHelper.version(),",
        "version: WeldSnapshot.RepeatedHelper.version(), deps: [{:external_git, git: \"https://example.test/provider.git\", ref: \"pinned\"}],"
      )
    )

    plan = Weld.Plan.build!(path, artifact: "alpha")
    assert Enum.any?(plan.violations, &(&1.code == :unsupported_publication_dependency))
    {raw, _} = Code.eval_file(path)
    raw = put_in(raw, [:artifacts, :alpha, :verify], hex_build: false, hex_publish_check: false)
    File.write!(path, inspect(raw, pretty: true, limit: :infinity))
    plan = Weld.Plan.build!(path, artifact: "alpha")
    assert plan.violations == []
    assert [%{app: :external_git, opts: opts}] = Weld.Plan.external_deps_for_view(plan, :package)
    assert opts[:git] == "https://example.test/provider.git"
    assert opts[:ref] == "pinned"
  end

  defp workspace(dir) do
    root = Path.join(dir, "source")
    counter = Path.join(dir, "probes.log")
    File.mkdir_p!(Path.join(root, "build_support"))
    File.write!(Path.join(root, "README.md"), "# Snapshot fixture\n")

    for id <- ["left", "right"] do
      File.mkdir_p!(Path.join(root, "#{id}/nested"))
      File.mkdir_p!(Path.join(root, "#{id}/lib"))
      File.write!(Path.join(root, "#{id}/VERSION"), "1.2.3")

      File.write!(Path.join(root, "#{id}/nested/helper.exs"), """
      defmodule WeldSnapshot.RepeatedHelper do
        def version, do: File.read!(Path.join(__DIR__, "../VERSION")) |> String.trim()
      end
      """)

      File.write!(Path.join(root, "#{id}/mix.exs"), """
      Code.require_file("nested/helper.exs", __DIR__)
      File.write!(#{inspect(counter)}, #{inspect(id)} <> ":" <> Atom.to_string(Mix.env()) <> "\\n", [:append])
      defmodule WeldSnapshot.RepeatedProject do
        use Mix.Project
        @environment Mix.env()
        def project, do: [app: #{inspect(String.to_atom("snapshot_" <> id))}, version: WeldSnapshot.RepeatedHelper.version(),
          test_paths: if(@environment == :test, do: ["test/env-specific"], else: ["wrong-env"])]
      end
      """)

      File.write!(
        Path.join(root, "#{id}/lib/#{id}.ex"),
        "defmodule Snapshot#{String.capitalize(id)}, do: def(value, do: :ok)\n"
      )
    end

    artifacts =
      for {name, id} <- [alpha: "left", beta: "right"],
          do:
            {name,
             [
               layout: :components,
               roots: [id],
               package: [
                 name: "snapshot_#{name}",
                 otp_app: String.to_atom("snapshot_#{name}"),
                 version: "1.0.0"
               ],
               files: [docs: ["README.md"]],
               verify: [hex_publish_check: false]
             ]}

    inputs =
      for id <- ["left", "right"],
          do: {id, [[path: "VERSION", type: :file, roles: [:generation], target: :none]]}

    spec = [
      schema: 2,
      workspace: [root: "..", projects: ["left", "right"]],
      project_inputs: inputs,
      artifacts: artifacts
    ]

    path = Path.join(root, "build_support/weld.exs")
    File.write!(path, inspect(spec, pretty: true, limit: :infinity))
    {path, counter}
  end

  defp probes(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.sort()
end
