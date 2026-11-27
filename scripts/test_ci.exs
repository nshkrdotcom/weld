jobs = [
  {"fast", nil},
  {"hex_consumption", "hex_consumption_contract_test"},
  {"qualification_faults", "qualification_contract_test"},
  {"slow", nil},
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
  {"probe_timeout", "workspace_snapshot_v2_test"}
]

# Each lane has its own build root. Keep the two broad source lanes bounded
# because a single test module can also launch four metadata VMs in parallel.
cores = System.schedulers_online()
default_jobs = cores |> div(6) |> max(1) |> min(4)

max_jobs =
  case Integer.parse(System.get_env("WELD_CI_JOBS", Integer.to_string(default_jobs))) do
    {count, ""} when count > 0 and count <= length(jobs) -> count
    _ -> raise "WELD_CI_JOBS must be a positive integer no larger than the lane count"
  end

source_cases = cores |> div(8) |> max(1) |> min(4)

IO.puts(
  "Weld CI: #{length(jobs)} isolated lanes, #{max_jobs} at a time, " <>
    "#{source_cases} source cases per lane"
)

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
        cond do
          name == "fast" ->
            ["--max-cases", Integer.to_string(source_cases)]

          name == "slow" ->
            ["--max-cases", Integer.to_string(source_cases), "--only", "slow"]

          true ->
            ["--max-cases", "1", "--only", "ci_build:#{name}", "test/weld/#{test_file}.exs"]
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

  # Blitz streams labeled child output and reports failures with their lane.
  Blitz.run!(commands, max_concurrency: max_jobs)
after
  File.rm_rf!(scratch)
end
