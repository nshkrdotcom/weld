defmodule Weld.SourceConsumptionTest do
  use ExUnit.Case, async: false

  alias Mix.Dep.Lock
  alias Weld.FixtureCase

  @moduletag integration: true, ci_build: "source_consumption", timeout: 600_000

  setup do
    root = FixtureCase.copy_fixture("source_project")
    scratch = FixtureCase.unique_tmp_dir("sprout_consumers")
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)
    on_exit(fn -> File.rm_rf!(scratch) end)
    %{root: root, scratch: scratch, manifest: Path.join(root, "build_support/weld.exs")}
  end

  test "direct and live path consumers compile edits, added/deleted modules and authoritative assets",
       ctx do
    %{root: root, manifest: manifest} = ctx

    for component <- ["components/pure", "components/runtime"] do
      mix!(Path.join(root, component), ["deps.get"])
      mix!(Path.join(root, component), ["compile", "--warnings-as-errors"])
    end

    direct = consumer!(ctx, "direct", [{:sprout, path: root}])
    check!(direct)
    refute File.exists?(Path.join(root, ".weld"))

    %{build_path: live} = Weld.Commands.project!(manifest, live: true)
    consumer = consumer!(ctx, "live", [{:sprout, path: live}])
    check!(consumer)
    File.write!(Path.join(root, "priv/theme.txt"), "olive")
    extra = Path.join(root, "components/pure/lib/addition.ex")
    File.write!(extra, "defmodule Sprout.Addition do\n  def value, do: :one\nend\n")
    expr!(consumer, ":one = Sprout.Addition.value(); \"olive\" = Sprout.Runtime.asset()")

    # Mix's incremental compiler can use second-resolution source mtimes.
    Process.sleep(1100)
    File.write!(extra, "defmodule Sprout.Addition do\n  def value, do: :two\nend\n")
    expr!(consumer, ":two = Sprout.Addition.value()")

    expr!(
      consumer,
      "true = to_string(Sprout.Addition.module_info(:compile)[:source]) == #{inspect(extra)}"
    )

    File.rm!(extra)
    expr!(consumer, "false = Code.ensure_loaded?(Sprout.Addition)")

    File.write!(manifest, File.read!(manifest) <> "\n# structural edit\n")
    {message, status} = mix(consumer, ["run", "check.exs"])
    assert status != 0
    assert message =~ "mix weld project --artifact sprout --kind live"
    Weld.Commands.project!(manifest, live: true)
    expr!(consumer, "\"olive\" = Sprout.Runtime.asset()")
    {message, status} = mix(live, ["hex.build"])
    assert status != 0
    assert message =~ "live projections cannot be packaged"
  end

  test "full, prepared, unpacked Hex and a fresh projection clone run without the source checkout",
       ctx do
    %{root: root, manifest: manifest, scratch: scratch} = ctx
    FixtureCase.init_git!(root)
    prepared = Weld.Commands.release_prepare!(manifest)
    full = Path.join(scratch, "detached-full")
    frozen = Path.join(scratch, "detached-prepared")
    File.cp_r!(prepared.build_path, full)
    File.cp_r!(prepared.project_path, frozen)

    tracked = Weld.Commands.release_track!(manifest)
    refute Weld.Commands.release_track!(manifest).committed?
    clone = Path.join(scratch, "projection")

    FixtureCase.git_output!(root, ["clone", "--no-local", "--branch", tracked.branch, root, clone])

    assert FixtureCase.git_output!(clone, ["rev-parse", "HEAD"]) == tracked.commit_sha

    extracted = Path.join(scratch, "unpacked")
    unpack!(prepared.tarball_path, extracted)
    assert File.regular?(Path.join(extracted, "VERSION"))
    refute File.exists?(Path.join(extracted, "extensions"))

    extensions =
      for variant <- ~w(color layout) do
        staging = Path.join(scratch, "package-" <> variant)
        File.cp_r!(Path.join([root, "extensions", variant]), staging)
        File.cp!(Path.join(root, "VERSION"), Path.join(staging, "VERSION"))
        mix!(staging, ["hex.build"])
        independent = Path.join(scratch, "detached-" <> variant)
        archive = Path.join(staging, "sprout_#{variant}-0.1.0.tar")
        unpack!(archive, independent)
        {String.to_atom("sprout_" <> variant), path: independent}
      end

    consumers =
      for {source, index} <- Enum.with_index([full, frozen, extracted, clone]) do
        consumer!(ctx, "independent-#{index}", [
          {:sprout, path: source, override: true} | extensions
        ])
      end

    File.rename!(root, root <> "-offline")

    for consumer <- consumers do
      check!(consumer)

      expr!(
        consumer,
        "{:layout, :seed} = Sprout.Layout.value(); {:color, :seed} = Sprout.Color.value()"
      )
    end
  end

  test "a local Hex archive with a matching version and a legacy API fails the consumer contract",
       ctx do
    %{root: root, scratch: scratch} = ctx
    runtime = Path.join(root, "components/runtime/lib/runtime.ex")
    File.write!(runtime, String.replace(File.read!(runtime), "def asset,", "def legacy_asset,"))
    mix!(root, ["hex.build"])
    extracted = Path.join(scratch, "legacy-archive")
    unpack!(Path.join(root, "sprout-0.1.0.tar"), extracted)
    consumer = consumer!(ctx, "new-api", [{:sprout, "~> 0.1.0", path: extracted}])
    mix!(consumer, ["deps.get"])
    {output, status} = mix(consumer, ["run", "check.exs"])
    assert status != 0
    assert output =~ "Sprout.Runtime.asset"
  end

  test "Git root and two extension subdirectories resolve per-app commits and deliberate convergence",
       ctx do
    %{root: root, scratch: scratch} = ctx
    FixtureCase.init_git!(root)
    first = FixtureCase.git_output!(root, ["rev-parse", "HEAD"])
    pure = Path.join(root, "components/pure/lib/pure.ex")
    File.write!(pure, String.replace(File.read!(pure), ":seed", ":second"))
    FixtureCase.commit_all!(root, "Second API revision")
    second = FixtureCase.git_output!(root, ["rev-parse", "HEAD"])
    bare = Path.join(scratch, "sprout.git")
    FixtureCase.git_output!(root, ["clone", "--bare", root, bare])

    for {ref, value} <- [{first, :seed}, {second, :second}] do
      deps = [
        {:sprout, "~> 0.1.0", git: bare, ref: ref, override: true},
        {:sprout_color, git: bare, ref: ref, subdir: "extensions/color"},
        {:sprout_layout, git: bare, ref: ref, subdir: "extensions/layout"}
      ]

      consumer = consumer!(ctx, "git-#{value}", deps)
      mix!(consumer, ["deps.get"])

      expr!(consumer, """
      #{inspect(value)} = Sprout.Runtime.value()
      {:color, #{inspect(value)}} = Sprout.Color.value()
      {:layout, #{inspect(value)}} = Sprout.Layout.value()
      [one] = Enum.filter(Application.loaded_applications(), &(elem(&1, 0) == :sprout))
      true = elem(one, 0) == :sprout
      """)

      lock = Lock.read(Path.join(consumer, "mix.lock"))

      for app <- ~w(sprout sprout_color sprout_layout)a do
        assert {:git, ^bare, ^ref, _opts} = Map.fetch!(lock, app)
      end
    end

    cases = [
      conflict: [
        {:sprout, git: bare, ref: second},
        {:sprout_color, git: bare, ref: first, subdir: "extensions/color"}
      ],
      missing_subdir: [{:sprout_color, git: bare, ref: first, subdir: "extensions/missing"}],
      wrong_app: [{:sprout_color, git: bare, ref: first, subdir: "extensions/layout"}],
      incompatible: [{:sprout, "~> 9.0", git: bare, ref: first}]
    ]

    for {name, deps} <- cases do
      consumer = consumer!(ctx, Atom.to_string(name), deps)
      {_message, fetch} = mix(consumer, ["deps.get"])

      if fetch == 0 do
        {_message, run} = mix(consumer, ["run", "--no-start", "-e", ":ok"])
        assert run != 0, "accepted invalid source selection #{name}"
      end
    end
  end

  defp unpack!(archive, destination) do
    File.mkdir!(destination)
    {:ok, outer} = :erl_tar.extract(String.to_charlist(archive), [:memory])
    {~c"contents.tar.gz", inner} = List.keyfind(outer, ~c"contents.tar.gz", 0)

    :ok =
      :erl_tar.extract({:binary, inner}, [:compressed, {:cwd, String.to_charlist(destination)}])
  end

  defp consumer!(%{root: root, scratch: scratch}, name, deps) do
    target = Path.join(scratch, name)
    File.cp_r!(Path.join(root, "consumer"), target)
    File.write!(Path.join(target, "dependencies.exs"), inspect(deps, limit: :infinity) <> "\n")
    target
  end

  defp check!(root) do
    mix!(root, ["deps.get"])
    mix!(root, ["run", "check.exs"])
  end

  defp expr!(root, expr), do: mix!(root, ["run", "-e", expr])

  defp mix!(root, args) do
    {output, status} = mix(root, args)
    assert status == 0, "mix #{Enum.join(args, " ")} in #{root}:\n#{output}"
  end

  defp mix(root, args) do
    System.cmd("mix", args,
      cd: root,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_DEPS_PATH", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_BUILD_ROOT", nil}
      ]
    )
  end
end
