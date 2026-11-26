defmodule Weld.BootstrapRelocationTest do
  use ExUnit.Case, async: false

  alias Weld.{FixtureCase, Manifest}

  @moduletag integration: true, ci_build: "bootstrap_relocation", timeout: 120_000

  test "compiled package and monolith applications bootstrap config after source removal" do
    for mode <- [:package_projection, :monolith] do
      manifest =
        FixtureCase.copied_manifest_path("package_bootstrap_bundle", "package_bootstrap_bundle")

      root = Manifest.load!(manifest).repo_root
      {raw, _binding} = Code.eval_file(manifest)
      raw = put_in(raw, [:artifacts, :package_bootstrap_bundle, :mode], mode)

      raw =
        if mode == :monolith,
          do: put_in(raw, [:artifacts, :package_bootstrap_bundle, :verify, :artifact_tests], []),
          else: raw

      File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
      config = Path.join(root, "core/bootstrap/config")

      File.write!(
        Path.join(config, "config.exs"),
        "import Config\nimport_config \"\#{config_env()}.exs\"\n"
      )

      File.write!(
        Path.join(config, "dev.exs"),
        "import Config\nconfig :fixture_bootstrap, required_value: :configured\n"
      )

      File.write!(
        Path.join(config, "runtime.exs"),
        """
        import Config
        config :fixture_bootstrap, runtime_value: File.read!(Path.join(__DIR__, "value.txt"))
        """
      )

      File.write!(Path.join(config, "value.txt"), "relocated")
      projected = Weld.project!(manifest)
      compiled =
        Path.join(FixtureCase.unique_tmp_dir("weld_compiled"), "package_bootstrap_bundle-0.1.0")
      ebin = Path.join(compiled, "ebin")
      File.mkdir_p!(ebin)

      sources =
        projected.build_path
        |> Weld.Hash.list_files()
        |> Enum.filter(&(Path.extname(&1) == ".ex"))

      compile = """
      Mix.start()
      {:ok, _, %{compile_warnings: [], runtime_warnings: []}} =
        Kernel.ParallelCompiler.compile_to_path(
          #{inspect(sources)}, #{inspect(ebin)}, return_diagnostics: true
        )
      """

      run_elixir!(["-e", compile])

      if File.dir?(Path.join(projected.build_path, "priv")) do
        File.cp_r!(Path.join(projected.build_path, "priv"), Path.join(compiled, "priv"))
      end

      application =
        {:application, :package_bootstrap_bundle,
         [
           description: ~c"Relocatable bootstrap fixture",
           vsn: ~c"0.1.0",
           modules: [
             PackageBootstrapBundle.Application,
             Fixture.Bootstrap,
             Fixture.Bootstrap.Application
           ],
           applications: [:kernel, :stdlib, :elixir, :logger],
           mod: {PackageBootstrapBundle.Application, []}
         ]}

      File.write!(
        Path.join(ebin, "package_bootstrap_bundle.app"),
        :io_lib.format(~c"~tp.~n", [application])
      )

      offline = root <> "-offline"
      File.rename!(root, offline)
      on_exit(fn -> File.rm_rf!(offline) end)

      run_elixir!([
        "-pa",
        ebin,
        "-e",
        """
        {:ok, _} = Application.ensure_all_started(:package_bootstrap_bundle)
        :configured = Application.fetch_env!(:fixture_bootstrap, :required_value)
        "relocated" = Application.fetch_env!(:fixture_bootstrap, :runtime_value)
        """
      ])
    end
  end

  defp run_elixir!(args) do
    {output, status} =
      System.cmd("elixir", args,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "dev"},
          {"MIX_EXS", nil},
          {"MIX_LOCKFILE", nil},
          {"MIX_TARGET", nil}
        ]
      )

    assert status == 0, output
  end
end
