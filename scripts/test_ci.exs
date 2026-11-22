jobs = [
  {"fast", nil},
  {"release", "release_test"},
  {"formatter", "release_test"},
  {"internal", "release_test"},
  {"package", "verifier_test"},
  {"runtime", "verifier_test"},
  {"monolith", "verifier_test"},
  {"prepare_cli", "mix_tasks_test"},
  {"monolith_tests", "projector_monolith_test"},
  {"package_config", "projector_package_mode_test"}
]

build = Mix.Project.build_path()
scratch = Path.join(Path.dirname(build), "ci-#{System.pid()}")
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
        args: ["test", "--no-compile" | args],
        env: %{
          "WELD_CI_BUILD_ROOT" => build_root,
          "ERL_FLAGS" => System.get_env("ERL_FLAGS", "+S 4:4")
        }
      )
    end)

  Blitz.run!(commands)
after
  File.rm_rf!(scratch)
end
