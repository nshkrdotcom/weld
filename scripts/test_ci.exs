Code.require_file("qc/support.exs", __DIR__)

# Blitz schedules independent test lanes with advisory CPU/memory admission.
# Lanes are grouped by genuine isolation and critical-path boundaries rather
# than lexical file sharding or host-specific worker tables.
layout_lanes = ~w(hex_consumption hex_flat hex_preserve hex_native)

integration_misc_files = [
  "test/weld/qualification_contract_test.exs",
  "test/weld/verifier_test.exs",
  "test/weld/projector_package_mode_test.exs",
  "test/weld/candidate_registry_test.exs",
  "test/weld/projector_monolith_test.exs",
  "test/weld/graph_live_test.exs",
  "test/weld/bootstrap_relocation_test.exs",
  "test/weld/workspace_snapshot_v2_test.exs"
]

planned = [
  {"release", ["--only", "ci_build:release", "test/weld/release_test.exs"], 50},
  {"release_faults", ["--only", "ci_build:release_faults", "test/weld/release_test.exs"], 50},
  {"hex_consumption",
   ["--only", "ci_build:hex_consumption", "test/weld/hex_consumption_contract_test.exs"], 50},
  {"hex_flat", ["--only", "ci_build:hex_flat", "test/weld/hex_consumption_contract_test.exs"],
   50},
  {"hex_preserve",
   ["--only", "ci_build:hex_preserve", "test/weld/hex_consumption_contract_test.exs"], 50},
  {"hex_native", ["--only", "ci_build:hex_native", "test/weld/hex_consumption_contract_test.exs"],
   50},
  {"component_prepare",
   ["--only", "ci_build:component_prepare", "test/weld/component_tests_test.exs"], 40},
  {"source_consumption",
   ["--only", "ci_build:source_consumption", "test/weld/source_consumption_test.exs"], 40},
  {"integration_misc", ["--only", "integration" | integration_misc_files], 30},
  {"slow", ["--only", "slow"], 20},
  {"fast", [], 10}
]

requested =
  case System.argv() do
    ["--" | args] -> args
    args -> args
  end

plan_only = "--plan" in requested
requested = List.delete(requested, "--plan")
names = Enum.map(planned, &elem(&1, 0))
unknown = Enum.reject(requested, &(&1 in names))

if unknown != [] or Enum.uniq(requested) != requested,
  do: raise("unknown or repeated CI lanes: #{Enum.join(requested, ", ")}")

jobs =
  if requested == [],
    do: planned,
    else: Enum.filter(planned, fn {name, _, _} -> name in requested end)

selected_layouts = Enum.filter(jobs, &(elem(&1, 0) in layout_lanes))
all_layouts? = length(selected_layouts) == length(layout_lanes)
mode = if requested == [], do: "complete", else: "PARTIAL retry"

IO.puts("Weld CI (#{mode}): #{length(jobs)} isolated lanes; Blitz manages admission")

if plan_only do
  for {name, args, priority} <- jobs do
    IO.puts("#{name} [priority=#{priority}]: mix test #{Enum.join(args, " ")}")
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
        case System.get_env("WELD_QC_LAYOUT_OUTPUT") do
          nil when all_layouts? ->
            path = Path.expand(".weld/qc/ci-matrix")
            File.rm_rf!(path)
            path

          nil ->
            Path.join(scratch, "matrix")

          explicit ->
            Path.expand(explicit)
        end

      File.mkdir_p!(target)
      target
    end

  commands =
    Enum.map(jobs, fn {name, args, priority} ->
      build_root = Path.join(scratch, name)

      env = %{
        "MIX_BUILD_ROOT" => build_root,
        "ERL_CRASH_DUMP" => Path.join(build_root, "erl_crash.dump")
      }

      env =
        if name in layout_lanes,
          do: Map.put(env, "WELD_QC_LAYOUT_OUTPUT", matrix_root),
          else: env

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
        resources: [cpu: 2, memory_mib: 1536, priority: priority]
      )
    end)

  Blitz.run!([%{commands: commands}])

  if all_layouts? do
    Weld.QC.finish_matrix!(matrix_root)

    IO.puts(
      "Weld CI: all four layout results assembled at #{Path.join(matrix_root, "matrix.json")}"
    )
  end

  if requested != [], do: IO.puts("Weld CI: selected lanes passed (not full acceptance)")
after
  File.rm_rf!(scratch)
end
