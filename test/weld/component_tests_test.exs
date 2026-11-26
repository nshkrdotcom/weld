defmodule Weld.ComponentTestsTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  setup do
    root = FixtureCase.copy_fixture("source_project")

    for {component, module} <- [{"pure", "Sprout.Pure"}, {"runtime", "Sprout.Runtime"}] do
      test = Path.join([root, "components", component, "test"])
      File.mkdir_p!(Path.join(test, "fixtures"))
      File.write!(Path.join(test, "test_helper.exs"), "ExUnit.start()\n")
      File.write!(Path.join(test, "fixtures/expected.txt"), "seed\n")

      File.write!(Path.join(test, "value_test.exs"), """
      defmodule #{module}ValueTest do
        use ExUnit.Case
        test "value and relative fixture survive composition" do
          assert #{module}.value() == :seed
          assert File.read!(Path.join(__DIR__, "fixtures/expected.txt")) == "seed\\n"
        end
      end
      """)
    end

    manifest = Path.join(root, "build_support/components.exs")

    File.write!(manifest, """
    [schema: 2, workspace: [root: "..", projects: ["components/*", "extensions/*"]],
     artifacts: [sprout: [layout: :components, roots: ["components/runtime"],
       package: [name: "sprout", otp_app: :sprout, version: "0.1.0"],
       files: [docs: ["README.md"], assets: ["priv"]],
       verify: [component_tests: true, hex_publish_check: false]]]]
    """)

    %{root: root, manifest: manifest}
  end

  test "component paths and helpers remain independent and are excluded from Hex", ctx do
    for kind <- [[], [live: true]] do
      result = Weld.Commands.project!(ctx.manifest, kind)
      source = File.read!(Path.join(result.build_path, "mix.exs"))

      for component <- ~w(pure runtime) do
        prefix = "components/components/#{component}"
        assert source =~ "#{prefix}/test"
        assert Enum.any?(result.package_files, &String.starts_with?(&1, "#{prefix}/lib/"))
        refute prefix in result.package_files
        refute "#{prefix}/test" in result.package_files
        assert "#{prefix}/test/value_test.exs" in result.verification_files

        assert File.read!(Path.join(result.build_path, "#{prefix}/test/fixtures/expected.txt")) ==
                 "seed\n"
      end

      {output, status} =
        System.cmd("mix", ["test"],
          cd: result.build_path,
          env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}],
          stderr_to_stdout: true
        )

      assert status == 0, "projection #{inspect(kind)} at #{result.build_path}:\n#{output}"
      assert output =~ "2 tests, 0 failures" or output =~ "Result: 2 passed"
    end
  end

  @tag integration: true, ci_build: "component_prepare", timeout: 600_000
  test "selected suites use a configured test dependency without adopting its private suite",
       ctx do
    owner = Path.join(ctx.root, "components/runtime")
    probe = Path.join(ctx.root, "components/probe")
    File.cp_r!(FixtureCase.fixture_path("component_test_dependency"), probe)

    mixfile = Path.join(owner, "mix.exs")
    original = File.read!(mixfile)
    runtime_deps = ~s([{:sprout_pure, path: "../pure"}])

    test_deps =
      ~s([{:sprout_pure, path: "../pure"}, {:sprout_probe, path: "../probe", only: :test}])

    assert original =~ runtime_deps
    File.write!(mixfile, String.replace(original, runtime_deps, test_deps))

    File.write!(Path.join(owner, "test/probe_test.exs"), """
    defmodule Sprout.SelectedProbeTest do
      use ExUnit.Case

      test "the dependency's ordinary compiler inputs and assets serve the selected suite" do
        assert Sprout.Probe.value() == {"seed", :seed}
        assert Application.fetch_env(:sprout_probe, :private_suite_config) == :error
      end
    end
    """)

    verified = Weld.Commands.verify!(ctx.manifest)
    baseline = Enum.find(verified.verification_results, &(&1.task == "selected_tests_baseline"))

    projected =
      Enum.find(verified.verification_results, &(&1.task == "test --warnings-as-errors"))

    assert baseline.test_count == 3
    assert projected.test_count == baseline.test_count

    assert Enum.sort(Enum.map(baseline.project_test_counts, & &1.project_id)) ==
             ["components/pure", "components/runtime"]

    prefix = "components/components/probe/"

    for path <-
          ~w(lib/probe.ex src/sprout_probe_native.erl include/sprout_probe.hrl priv/probe.txt) do
      assert (prefix <> path) in verified.verification_files
    end

    refute File.exists?(Path.join(verified.build_path, prefix <> "test"))
    refute File.exists?(Path.join(verified.build_path, prefix <> "config"))
    refute File.read!(Path.join(verified.build_path, "mix.exs")) =~ ":jason"

    {:ok, outer} = :erl_tar.extract(String.to_charlist(verified.tarball_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])

    refute Enum.any?(files, fn {path, bytes} ->
             String.starts_with?(to_string(path), prefix) or
               (String.starts_with?(to_string(path), "config/") and
                  bytes =~ "private_suite_config")
           end)

    live = Weld.Commands.project!(ctx.manifest, live: true)

    {output, status} =
      System.cmd("mix", ["test"],
        cd: live.build_path,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_BUILD_ROOT", nil},
          {"MIX_DEPS_PATH", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "3 tests, 0 failures" or output =~ "Result: 3 passed"
  end

  test "component verification rejects tests inside a published compiler root", ctx do
    project = Path.join(ctx.root, "components/pure")
    File.rename!(Path.join(project, "test"), Path.join(project, "lib/verification"))
    mixfile = Path.join(project, "mix.exs")

    File.write!(
      mixfile,
      String.replace(
        File.read!(mixfile),
        "deps: []",
        "test_paths: [\"lib/verification\"], deps: []"
      )
    )

    assert_raise Weld.Error, ~r/test input overlaps a published runtime root/, fn ->
      Weld.Commands.project!(ctx.manifest)
    end
  end

  @tag integration: true, ci_build: "component_prepare", timeout: 600_000
  test "component baseline dependency resolution never writes source locks", ctx do
    mixfile = Path.join(ctx.root, "components/pure/mix.exs")
    original = File.read!(mixfile)

    File.write!(
      mixfile,
      String.replace(original, "deps: []", "deps: [{:jason, \"~> 1.4\", only: :test}]")
    )

    source_lock = Path.join(ctx.root, "components/pure/mix.lock")
    refute File.exists?(source_lock)

    result = Weld.Commands.verify!(ctx.manifest)

    assert Enum.any?(result.verification_results, &(&1.task == "selected_tests_baseline"))
    refute File.exists?(source_lock)
  end

  @tag integration: true, ci_build: "component_prepare", timeout: 600_000
  test "prepared candidates retain component tests and finalized lock identity", ctx do
    FixtureCase.init_git!(ctx.root)
    prepared = Weld.Commands.release_prepare!(ctx.manifest)

    for component <- ~w(pure runtime) do
      assert File.regular?(
               Path.join(
                 prepared.project_path,
                 "components/components/#{component}/test/value_test.exs"
               )
             )
    end

    marker =
      prepared.project_path
      |> Path.join("weld.provenance.json")
      |> File.read!()
      |> Jason.decode!()

    assert marker["artifact_id"] == Weld.Hash.project_identity(prepared.project_path)

    verified_marker =
      prepared.build_path |> Path.join("weld.provenance.json") |> File.read!() |> Jason.decode!()

    assert verified_marker["artifact_id"] == marker["artifact_id"]
    assert Weld.Commands.release_prepare!(ctx.manifest).identity == prepared.identity
  end
end
