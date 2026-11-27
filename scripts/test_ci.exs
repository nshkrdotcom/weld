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
    ~w(qualification_faults-g02 qualification_faults-gc qualification_faults-include)
}

# Affinity is inherited by all descendants, including Weld's fresh VMs whose
# environment isolation deliberately removes ERL_FLAGS. Respect the host's
# current CPU mask; no production runner or qualification changes are needed.
cores = System.schedulers_online()

cpus =
  with true <- match?({:unix, :linux}, :os.type()),
       true <- System.find_executable("taskset") != nil,
       true <- System.find_executable("flock") != nil,
       {status, 0} <- System.cmd("taskset", ["-pc", System.pid()], env: [{"LC_ALL", "C"}]),
       [_, allowed] <- Regex.run(~r/:\s+([0-9,-]+)\s*$/, status) do
    allowed
    |> String.split(",")
    |> Enum.flat_map(fn item ->
      case String.split(item, "-") do
        [cpu] -> [String.to_integer(cpu)]
        [first, last] -> Enum.to_list(String.to_integer(first)..String.to_integer(last))
      end
    end)
    |> Enum.take(cores)
  else
    _ -> []
  end

# Twelve independent workers on a 24-scheduler Linux host; retain the safe
# bounded fallback when CPU affinity is unavailable. Overrides remain explicit.
default_jobs =
  if cpus == [],
    do: cores |> div(6) |> max(1) |> min(4),
    else: length(cpus) |> div(2) |> max(1) |> min(12)

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
      shard.("fast", min(4, default_jobs))

    {"slow", nil} ->
      shard.("slow", min(8, default_jobs))

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

limit = if cpus == [], do: length(planned), else: min(length(planned), length(cpus))

max_jobs =
  case Integer.parse(System.get_env("WELD_CI_JOBS", Integer.to_string(default_jobs))) do
    {count, ""} when count > 0 and count <= limit ->
      min(count, length(jobs))

    _ ->
      raise "WELD_CI_JOBS must be positive and no larger than the available worker budget (#{limit})"
  end

source_cases =
  if cpus == [],
    do: cores |> div(8) |> max(1) |> min(4),
    else: length(cpus) |> div(max_jobs) |> max(1) |> min(2)

layout_output = System.get_env("WELD_QC_LAYOUT_OUTPUT")
selected_layouts = Enum.filter(jobs, &Map.has_key?(layout_jobs, elem(&1, 0)))
mode = if requested == [], do: "complete", else: "PARTIAL retry"

IO.puts(
  "Weld CI (#{mode}): #{length(jobs)} isolated workers, #{max_jobs} at a time, " <>
    "#{source_cases} source cases per worker"
)

if cpus != [],
  do: IO.puts("CPU slots: #{length(cpus)} allowed CPUs divided among #{max_jobs} workers"),
  else: IO.puts("CPU affinity unavailable; using bounded portable fallback")

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
  slots =
    if cpus == [] do
      ""
    else
      dir = Path.join(scratch, "cpu-slots")
      File.mkdir!(dir)

      cpus
      |> Enum.with_index()
      |> Enum.group_by(fn {_cpu, index} -> rem(index, max_jobs) end, &elem(&1, 0))
      |> Enum.each(fn {index, mask} ->
        File.write!(Path.join(dir, "#{index}.cpus"), Enum.join(mask, ","))
      end)

      dir
    end

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
            ["--max-cases", Integer.to_string(source_cases) | paths]

          group == "slow" ->
            ["--max-cases", Integer.to_string(source_cases), "--only", "slow" | paths]

          layout ->
            ["--max-cases", "1", "--only", "ci_build:hex_consumption" | paths]

          Map.has_key?(case_jobs, group) ->
            ["--max-cases", "1", "--only", "ci_case:#{name}" | paths]

          true ->
            ["--max-cases", "1", "--only", "ci_build:#{name}" | paths]
        end

      env = %{
        "WELD_CI_BUILD_ROOT" => build_root,
        "ERL_CRASH_DUMP" => Path.join(build_root, "erl_crash.dump"),
        "ERL_FLAGS" => System.get_env("ERL_FLAGS", "+S 4:4")
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

      Blitz.command(
        id: name,
        command: "bash",
        args: [
          Path.expand("ci_lane.sh", __DIR__),
          build,
          build_root,
          slots,
          "mix",
          "test",
          "--no-compile",
          "--warnings-as-errors" | args
        ],
        env: env
      )
    end)

  Blitz.run!(commands, max_concurrency: max_jobs)

  if length(selected_layouts) == map_size(layout_jobs) do
    Weld.QC.finish_matrix!(matrix_root)
    IO.puts("Weld CI: all four layout results assembled")
  end

  if requested != [], do: IO.puts("Weld CI: selected lanes passed (not full acceptance)")
after
  File.rm_rf!(scratch)
end
