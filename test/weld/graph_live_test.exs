defmodule Weld.GraphLiveTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase}

  test "graph views expose cycle witnesses and stable dependency paths" do
    graph = Weld.Graph.new()
    graph = %{graph | projects: %{"a" => nil, "b" => nil, "c" => nil}}

    graph =
      Enum.reduce(
        [{"a", "b", :runtime}, {"b", "c", :runtime}, {"c", "a", :test}],
        graph,
        fn {from, to, kind}, graph ->
          Weld.Graph.add_edge(graph, %Weld.Graph.Edge{
            from: from,
            to: to,
            app: :example,
            kind: kind,
            opts: [],
            requirement: nil
          })
        end
      )

    assert {:ok, ["c", "b", "a"]} = Weld.Graph.topology(graph, :package)
    assert {:cycle, ["a", "b", "c", "a"]} = Weld.Graph.topology(graph, :test)
    assert {:ok, ["a", "b", "c"]} = Weld.Graph.path(graph, "a", "c", :package)
    assert :no_path = Weld.Graph.path(graph, "c", "a", :package)
  end

  test "package live links component directories and keeps generated files regular" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    full = Weld.Commands.project!(manifest)
    live = Weld.Commands.project!(manifest, live: true)
    source = Path.join(root, "core/contracts/lib")
    target = Path.join(live.build_path, "components/core/contracts/lib")

    assert File.read_link!(target) == source
    assert File.lstat!(Path.join(live.build_path, "mix.exs")).type == :regular
    assert live.package_files == full.package_files
    assert live.linked_files != []
    assert live.verification_files != []

    addition = Path.join(source, "addition.ex")
    File.write!(addition, "defmodule Fixture.Addition, do: def(value, do: :live)\n")
    assert File.read!(Path.join(target, "addition.ex")) == File.read!(addition)
    refute File.exists?(Path.join(full.build_path, "components/core/contracts/lib/addition.ex"))
    File.rm!(addition)
    refute File.exists?(Path.join(target, "addition.ex"))

    assert {_, 0} = evaluate(live.build_path)
    File.write!(manifest, File.read!(manifest) <> "\n# layout changed\n")
    assert {message, status} = evaluate(live.build_path)
    assert status != 0
    assert message =~ "mix weld project --artifact 'fixture_bundle' --kind live"
    assert message =~ manifest
    refreshed = Weld.Commands.project!(manifest, live: true)
    assert {_, 0} = evaluate(refreshed.build_path)
  end

  test "live guard observes creation of a source lock and discovered project" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    live = Weld.Commands.project!(manifest, live: true)
    lock = Path.join(root, "core/contracts/mix.lock")
    File.write!(lock, "%{}\n")
    assert {_message, status} = evaluate(live.build_path)
    assert status != 0
    File.rm!(lock)
    assert {_, 0} = evaluate(live.build_path)

    new_project = Path.join(root, "core/extra")
    File.mkdir!(new_project)
    File.write!(Path.join(new_project, "mix.exs"), "# new discovery input\n")
    assert {_message, status} = evaluate(live.build_path)
    assert status != 0
  end

  test "all live modes reject packaging, including dry runs" do
    for {fixture, artifact} <- [
          {"library_bundle", "fixture_bundle"},
          {"monolith_bundle", "monolith_bundle"}
        ] do
      root = FixtureCase.copy_fixture(fixture)
      manifest = Path.join(root, "packaging/weld/#{artifact}.exs")
      live = Weld.Commands.project!(manifest, live: true)

      for task <- ["hex.build", "hex.publish"] do
        script = """
        Mix.start()
        Mix.Project.in_project(:live_probe, ".", [], fn _ ->
          alias_fun = Keyword.fetch!(Mix.Project.config()[:aliases], #{inspect(String.to_atom(task))})
          alias_fun.(["--dry-run", "--yes"])
        end)
        """

        {message, status} = elixir(live.build_path, script)
        assert status != 0
        action = if task == "hex.build", do: "packaged", else: "published"
        assert message =~ "live projections cannot be #{action}"
      end
    end
  end

  test "monolith content is live but topology and transformed config require refresh" do
    root = FixtureCase.copy_fixture("monolith_bundle")
    manifest = Path.join(root, "packaging/weld/monolith_bundle.exs")
    live = Weld.Commands.project!(manifest, live: true)
    source = Path.join(root, "core/store/lib/fixture/store.ex")
    target = Path.join(live.build_path, "lib/fixture/store.ex")
    assert File.read_link!(target) == source
    File.write!(source, File.read!(source) <> "\n# live content edit\n")
    assert File.read!(target) =~ "live content edit"
    assert {_, 0} = evaluate(live.build_path)

    addition = Path.join(root, "core/store/lib/extra.ex")
    File.write!(addition, "defmodule Extra, do: def(value, do: :ok)\n")
    assert {message, status} = evaluate(live.build_path)
    assert status != 0
    assert message =~ "--kind live"
    File.rm!(addition)
    config = Path.join(root, "core/store/config/config.exs")
    File.write!(config, File.read!(config) <> "\n# transformed input\n")
    assert {_message, status} = evaluate(live.build_path)
    assert status != 0
  end

  test "duplicate graph modules cannot displace a valid candidate" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    full = Weld.Commands.project!(manifest)
    marker = Weld.Hash.observation(full.build_path)
    source = Path.join(root, "core/contracts/lib/weld_fixture/contracts.ex")
    File.cp!(source, Path.join(root, "runtime/local/lib/duplicate.ex"))
    assert_raise Error, ~r/duplicate module/, fn -> Weld.Commands.project!(manifest) end
    assert Weld.Hash.observation(full.build_path) == marker
  end

  test "a generated application cannot write through a monolith source link" do
    root = FixtureCase.copy_fixture("monolith_bundle")
    manifest = Path.join(root, "packaging/weld/monolith_bundle.exs")
    source = Path.join(root, "core/store/lib/monolith_bundle/application.ex")
    File.mkdir_p!(Path.dirname(source))
    bytes = "defmodule Fixture.ReservedPath, do: def(value, do: :source)\n"
    File.write!(source, bytes)

    assert_raise Weld.Error, ~r/projection path collision/, fn ->
      Weld.Commands.project!(manifest, live: true)
    end

    assert File.read!(source) == bytes
  end

  test "a linked document replaced by a source symlink invalidates the view" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    live = Weld.Commands.project!(manifest, live: true)
    readme = Path.join(root, "README.md")
    File.rm!(readme)
    File.ln_s!(manifest, readme)
    assert {_message, status} = evaluate(live.build_path)
    assert status != 0
  end

  @tag integration: true, ci_build: "graph_consumption", timeout: 600_000
  test "ordinary consumers compile graph live edits and detached full projects without Weld" do
    root = FixtureCase.copy_fixture("source_project")
    manifest = Path.join(root, "build_support/graph.exs")

    File.write!(manifest, """
    [schema: 2, workspace: [root: "..", projects: ["components/*", "extensions/*"]],
     artifacts: [sprout: [layout: :components, roots: ["components/runtime"],
       package: [name: "sprout", otp_app: :sprout, version: "0.1.0"],
       files: [docs: ["README.md"], assets: ["priv"]],
       verify: [hex_publish_check: false]]]]
    """)

    scratch = FixtureCase.unique_tmp_dir("graph_consumers")
    live = Weld.Commands.project!(manifest, live: true)
    full = Weld.Commands.project!(manifest)
    detached = Path.join(scratch, "full")
    File.cp_r!(full.build_path, detached)

    consumers =
      for {name, source} <- [{"live", live.build_path}, {"full", detached}] do
        consumer = Path.join(scratch, name <> "_consumer")
        File.mkdir!(consumer)

        File.write!(Path.join(consumer, "mix.exs"), """
        defmodule GraphConsumer.MixProject do
          use Mix.Project
          def project, do: [app: :graph_consumer, version: "0.1.0",
            deps: [{:sprout, path: #{inspect(source)}}]]
        end
        """)

        mix!(consumer, ["deps.get"])

        mix!(consumer, [
          "run",
          "-e",
          ":seed = Sprout.Runtime.value(); \"sage\\n\" = Sprout.Runtime.asset(); false = Code.ensure_loaded?(Weld)"
        ])

        {name, consumer}
      end

    live_consumer =
      Keyword.fetch!(
        Enum.map(consumers, fn {name, path} -> {String.to_atom(name), path} end),
        :live
      )

    addition = Path.join(root, "components/pure/lib/extra.ex")
    File.write!(addition, "defmodule Sprout.Extra, do: def(value, do: :visible)\n")
    mix!(live_consumer, ["run", "-e", ":visible = Sprout.Extra.value()"])
    File.rm!(addition)
    mix!(live_consumer, ["run", "-e", "false = Code.ensure_loaded?(Sprout.Extra)"])

    File.rename!(root, root <> "-offline")
    on_exit(fn -> File.rm_rf!(root <> "-offline") end)
    {"full", full_consumer} = List.keyfind(consumers, "full", 0)
    File.rm_rf!(Path.join(full_consumer, "_build"))

    mix!(full_consumer, [
      "run",
      "-e",
      ":seed = Sprout.Runtime.value(); \"sage\\n\" = Sprout.Runtime.asset()"
    ])
  end

  defp mix!(root, args) do
    {output, status} =
      System.cmd("mix", args,
        cd: root,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_BUILD_ROOT", nil},
          {"MIX_DEPS_PATH", nil}
        ]
      )

    assert status == 0, output
  end

  defp evaluate(root) do
    elixir(root, """
    Mix.start()
    Mix.Project.in_project(:live_probe, ".", [], fn _ -> Mix.Project.config() end)
    """)
  end

  defp elixir(root, script) do
    System.cmd("elixir", ["-e", script],
      cd: root,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
    )
  end
end
