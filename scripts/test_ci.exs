Code.require_file("qc/support.exs", __DIR__)

# Blitz schedules every worker. File shards isolate even synchronous ExUnit
# modules without changing any test tags or assertions.
all_jobs = [
  {"component_prepare", "component_tests_test"},
  {"release", "release_test"},
  {"release_faults_prepare", "release_test"},
  {"qualification_faults", "qualification_contract_test"},
  {"release_faults_pointer", "release_test"},
  {"slow", nil},
  {"hex_consumption", "hex_consumption_contract_test"},
  {"hex_native", "hex_consumption_contract_test"},
  {"formatter", "release_test"},
  {"source_consumption", "source_consumption_test"},
  {"hex_flat", "hex_consumption_contract_test"},
  {"hex_preserve", "hex_consumption_contract_test"},
  {"release_faults_seal", "release_test"},
  {"fast", nil},
  {"internal", "release_test"},
  {"package", "verifier_test"},
  {"runtime", "verifier_test"},
  {"monolith", "verifier_test"},
  {"prepare_cli", "mix_tasks_test"},
  {"package_config", "projector_package_mode_test"},
  {"source_docs_output", "verifier_test"},
  {"candidate_registry", "candidate_registry_test"},
  {"monolith_tests", "projector_monolith_test"},
  {"graph_consumption", "graph_live_test"},
  {"bootstrap_relocation", "bootstrap_relocation_test"},
  {"probe_timeout", "workspace_snapshot_v2_test"}
]

layout_jobs = %{
  "hex_consumption" => "components",
  "hex_flat" => "flat",
  "hex_preserve" => "preserve",
  "hex_native" => "native"
}

# Independent tests sharing an integration selector need not share a worker.
# The original ci_build tags remain usable for direct whole-group runs.
case_jobs = %{
  "component_prepare" =>
    ~w(component_prepare-dependency component_prepare-lock component_prepare-bundle),
  "qualification_faults" =>
    ~w(qualification_faults-g02 qualification_faults-gc qualification_faults-include),
  "release_faults_prepare" =>
    ~w(release_faults_prepare-snapshot release_faults_prepare-qualified release_faults_prepare-copied release_faults_prepare-g02),
  "source_consumption" =>
    ~w(source_consumption-live source_consumption-detached source_consumption-legacy source_consumption-git)
}

# Work partitioning is independent of hardware. Blitz owns admission, CPU
# affinity and memory budgets; these stable shard IDs also support retries.
files = Path.wildcard("test/weld/**/*_test.exs") |> Enum.sort()
if files == [], do: raise("no source test files found")

# Every source file belongs to exactly one shard in each tier, even if it has
# no tagged slow tests. Lexical counts affect scheduling only, never selection.
shard = fn tier, count ->
  ranked =
    files
    |> Enum.map(fn file ->
      text = File.read!(file)

      weight =
        if tier == "slow",
          do: max(1, 8 * length(Regex.scan(~r/@(?:module)?tag\s+:slow\b/, text))),
          else: max(1, length(Regex.scan(~r/^\s*test\s+"/m, text)))

      {file, weight}
    end)
    |> Enum.sort_by(fn {file, weight} -> {-weight, file} end)

  buckets =
    Enum.reduce(ranked, List.duplicate({0, []}, min(count, length(files))), fn {file, weight},
                                                                               acc ->
      {_, index} =
        acc
        |> Enum.with_index()
        |> Enum.min_by(fn {{load, _}, index} -> {load, index} end)

      List.update_at(acc, index, fn {load, assigned} -> {load + weight, [file | assigned]} end)
    end)

  assigned = Enum.flat_map(buckets, &elem(&1, 1))

  unless Enum.sort(assigned) == files,
    do: raise("incomplete or duplicated #{tier} shard coverage")

  buckets
  |> Enum.with_index(1)
  |> Enum.map(fn {{_, assigned}, index} -> {"#{tier}-#{index}", tier, Enum.sort(assigned)} end)
end

planned =
  Enum.flat_map(all_jobs, fn
    {"fast", nil} ->
      shard.("fast", 4)

    {"slow", nil} ->
      shard.("slow", 8)

    {name, file} ->
      for worker <- Map.get(case_jobs, name, [name]),
          do: {worker, name, ["test/weld/#{file}.exs"]}
  end)

requested =
  case System.argv() do
    ["--" | args] -> args
    args -> args
  end

plan_only = "--plan" in requested
requested = List.delete(requested, "--plan")
names = Enum.map(all_jobs, &elem(&1, 0)) ++ Enum.map(planned, &elem(&1, 0))
unknown = Enum.reject(requested, &(&1 in names))

if unknown != [] or Enum.uniq(requested) != requested,
  do: raise("unknown or repeated CI lanes: #{Enum.join(requested, ", ")}")

jobs =
  if requested == [],
    do: planned,
    else: Enum.filter(planned, fn {name, group, _} -> name in requested or group in requested end)

layout_output = System.get_env("WELD_QC_LAYOUT_OUTPUT")
selected_layouts = Enum.filter(jobs, &Map.has_key?(layout_jobs, elem(&1, 0)))
mode = if requested == [], do: "complete", else: "PARTIAL retry"

IO.puts("Weld CI (#{mode}): #{length(jobs)} isolated jobs; Blitz manages available resources")

if plan_only do
  for {name, group, paths} <- jobs do
    IO.puts("#{name} [#{group}]: #{Enum.join(paths, " ")}")
  end

  System.halt(0)
end

build = Path.expand(Mix.Project.build_path())
suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
scratch = Path.join(System.tmp_dir!(), "weld-ci-#{suffix}")
File.mkdir!(scratch)

try do
  matrix_root =
    if selected_layouts != [] do
      target =
        if layout_output, do: Path.expand(layout_output), else: Path.join(scratch, "matrix")

      File.mkdir!(target)
      target
    end

  commands =
    Enum.map(jobs, fn {name, group, paths} ->
      build_root = Path.join(scratch, name)
      layout = layout_jobs[name]

      args =
        cond do
          group == "fast" ->
            ["--max-cases", "2" | paths]

          group == "slow" ->
            ["--max-cases", "2", "--only", "slow" | paths]

          layout ->
            ["--max-cases", "1", "--only", "ci_build:hex_consumption" | paths]

          Map.has_key?(case_jobs, group) ->
            ["--max-cases", "1", "--only", "ci_case:#{name}" | paths]

          true ->
            ["--max-cases", "1", "--only", "ci_build:#{name}" | paths]
        end

      env = %{
        "WELD_CI_BUILD_ROOT" => build_root,
        "ERL_CRASH_DUMP" => Path.join(build_root, "erl_crash.dump")
      }

      env =
        if layout do
          Map.merge(env, %{
            "WELD_CI_QC_LAYOUT" => layout,
            "WELD_QC_LAYOUT_OUTPUT" => matrix_root
          })
        else
          env
        end

      # Estimates describe the workload, never the host. Long chains get
      # priority; the scheduler reuses reservations as each command completes.
      resources =
        cond do
          group in ~w(release release_faults_pointer package prepare_cli) ->
            [cpu: 6, memory_mib: 2048, priority: 100]

          group == "slow" and
              Enum.any?(paths, &String.ends_with?(&1, "/source_project_test.exs")) ->
            [cpu: 6, memory_mib: 2048, priority: 100]

          group in ~w(slow formatter internal runtime monolith source_docs_output package_config) ->
            [cpu: 4, memory_mib: 2048, priority: 80]

          group in ~w(component_prepare qualification_faults release_faults_prepare source_consumption) or
              layout ->
            [cpu: 2, memory_mib: 2048, priority: 80]

          group in ~w(monolith_tests graph_consumption bootstrap_relocation probe_timeout) ->
            [cpu: 1, memory_mib: 512, priority: 0]

          true ->
            [cpu: 2, memory_mib: 1536, priority: 40]
        end

      Blitz.command(
        id: name,
        command: "bash",
        args: [
          Path.expand("ci_lane.sh", __DIR__),
          build,
          build_root,
          "mix",
          "test",
          "--no-compile",
          "--warnings-as-errors" | args
        ],
        env: env,
        resources: resources
      )
    end)

  Blitz.run!([%{commands: commands}])

  if length(selected_layouts) == map_size(layout_jobs) do
    Weld.QC.finish_matrix!(matrix_root)
    IO.puts("Weld CI: all four layout results assembled")
  end

  if requested != [], do: IO.puts("Weld CI: selected lanes passed (not full acceptance)")
after
  File.rm_rf!(scratch)
end
