jobs = [
  {"fast", nil},
  {"source_consumption", "source_consumption_test"},
  {"release", "release_test"},
  {"formatter", "release_test"},
  {"internal", "release_test"},
  {"package", "verifier_test"},
  {"runtime", "verifier_test"},
  {"monolith", "verifier_test"},
  {"prepare_cli", "mix_tasks_test"},
  {"monolith_tests", "projector_monolith_test"},
  {"package_config", "projector_package_mode_test"},
  {"source_docs_output", "verifier_test"},
  {"component_prepare", "component_tests_test"},
  {"graph_consumption", "graph_live_test"},
  {"bootstrap_relocation", "bootstrap_relocation_test"},
  {"qualification_faults", "qualification_contract_test"},
  {"hex_consumption", "hex_consumption_contract_test"}
]

build = Mix.Project.build_path()
suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
scratch = Path.join(System.tmp_dir!(), "weld-ci-#{suffix}")
File.mkdir!(scratch)

try do
  commands =
    Enum.map(jobs, fn {name, test_file} ->
      build_root = Path.join(scratch, name)
      File.mkdir!(build_root)
      File.cp_r!(build, Path.join(build_root, "test"))

      args =
        if test_file do
          ["--only", "ci_build:#{name}", "test/weld/#{test_file}.exs"]
        else
          []
        end

      Blitz.command(
        id: name,
        command: "mix",
        args: ["test", "--no-compile", "--warnings-as-errors" | args],
        env: %{
          "WELD_CI_BUILD_ROOT" => build_root,
          "ERL_CRASH_DUMP" => Path.join(build_root, "erl_crash.dump"),
          "ERL_FLAGS" => System.get_env("ERL_FLAGS", "+S 4:4")
        }
      )
    end)

  # Each lane launches additional Mix VMs to compile fixture projects.
  Blitz.run!(commands, max_concurrency: 2)
after
  File.rm_rf!(scratch)
end
