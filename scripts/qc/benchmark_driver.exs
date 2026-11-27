# Benchmark-only adapters run unchanged against the requested historical Weld
# checkout. They are not product manifest/state readers or qualification gates.
# Erlang trace counter API: https://www.erlang.org/docs/29/apps/kernel/trace.html
defmodule WeldBenchmark do
  @phase_functions [
    {"snapshot_call_ms", {Weld.Shell.Snapshot, :collect!, 2}},
    {"snapshot_recheck_call_ms", {Weld.Shell.Snapshot, :recheck!, 2}},
    {"compiler_call_ms", {Weld.Core.Compiler, :compile!, 4}},
    {"layout_call_ms", {Weld.Layout.Components, :plan!, 1}},
    {"layout_call_ms", {Weld.Layout.Flat, :plan!, 1}},
    {"layout_call_ms", {Weld.Layout.Preserve, :plan!, 1}},
    {"materialization_call_ms", {Weld.Shell.Materializer, :execute!, 4}}
  ]
  @count_functions [
    {"source_probe_count", {Weld.Workspace.Probe, :run!, 5}},
    {"source_probe_count", {Weld.Workspace, :probe_project_config, 3}}
  ]
  @message_functions [
    {Weld.Verifier, :run_mix!, 5},
    {Weld.Verifier, :run_mix!, 3},
    {Weld.SmokeApp, :archive!, 4},
    {:erlang, :open_port, 2},
    {:file, :copy, 2},
    {:file, :copy, 3}
  ]

  def main do
    args = case System.argv() do ["--" | values] -> values; values -> values end
    {opts, rest} = OptionParser.parse!(args, strict: [request: :string, operation: :string, report: :string, sample: :string])
    unless rest == [] and Enum.all?([:request, :operation, :report], &is_binary(opts[&1])),
      do: raise("benchmark_driver requires --request FILE --operation OP --report NEW_FILE")
    request = Jason.decode!(File.read!(opts[:request])) |> Map.put("sample", opts[:sample])
    native_env = request["native_env"] || %{}
    allowed = ~w(CC CXX AR CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS RUSTFLAGS RUSTUP_TOOLCHAIN CARGO_HOME RUSTUP_HOME)
    unless is_map(native_env) and Enum.all?(native_env, fn {key, value} -> key in allowed and is_binary(value) end),
      do: raise("native_env contains undeclared keys or non-string values")
    Application.put_env(:weld, :native_env, Enum.sort(native_env))
    Application.put_env(:weld, :qualification_context, request["qualification_context"] || %{})
    report = opts[:report]
    if File.exists?(report), do: raise("benchmark report already exists: #{report}")
    if opts[:operation] == "setup" do
      setup!(request["source"])
      File.write!(report, Jason.encode!(%{status: "ok", operation: "setup"}), [:exclusive])
      File.chmod!(report, 0o600)
    else
      run!(request, opts[:operation], report)
    end
  end

  defp setup!(root) do
    Code.ensure_loaded!(Weld.Output)
    if function_exported?(Weld.Output, :setup!, 1) do
      apply(Weld.Output, :setup!, [root])
    else
      # 0.19 performed setup on the first lock acquisition. Confined to the
      # disposable historical input; the current product keeps explicit setup.
      apply(Weld.Output, :with_lock, [root, fn -> :ok end])
    end
  end

  defp run!(request, operation, report) do
    tracing = start_tracing()
    started = System.monotonic_time(:microsecond)
    outcome = try do
      {manifest, manifest_ms} = timed(fn -> apply(Weld.Manifest, :load!, [request["manifest"]]) end)
      {plans, plan_metrics} = plans!(manifest, request["artifacts"])
      {results, operation_metrics} = execute!(operation, plans, request)
      outputs = Enum.map(results, &output_summary/1)
      %{"status" => "ok", "metrics" => Map.merge(plan_metrics, operation_metrics) |> Map.put("manifest_ms", manifest_ms)
          |> Map.put("regular_output_bytes", Enum.reduce(outputs, 0, &((&1["regular_output_bytes"] || 0) + &2))),
        "artifacts" => Enum.map(plans, fn plan -> %{"id" => plan.artifact.id,
          "selected_projects" => length(plan.selected_ids), "workspace_projects" => map_size(plan.workspace.projects)} end),
        "outputs" => outputs}
    rescue
      error ->
        IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
        %{"status" => "failed", "error" => Exception.message(error), "metrics" => %{}}
    catch
      kind, reason ->
        %{"status" => "failed", "error" => Exception.format(kind, reason, __STACKTRACE__), "metrics" => %{}}
    end
    elapsed = (System.monotonic_time(:microsecond) - started) / 1000
    {counters, capability} = stop_tracing(tracing, request["native"] == true)
    outcome = outcome |> Map.put("operation", operation)
      |> Map.put("toolchain", %{"elixir" => System.version(), "otp" => otp_version(),
        "hex" => app_version(:hex), "hex_core" => app_version(:hex_core),
        "architecture" => to_string(:erlang.system_info(:system_architecture))})
      |> Map.put("instrumentation", capability)
      |> Map.update!("metrics", &(Map.merge(counters, &1) |> Map.put("driver_ms", elapsed)))
    File.write!(report, Jason.encode!(outcome, pretty: true), [:exclusive])
    File.chmod!(report, 0o600)
    if outcome["status"] != "ok", do: System.halt(1)
  end

  defp plans!(manifest, artifacts) do
    Code.ensure_loaded!(Weld.Plan)
    if function_exported?(Weld.Plan, :build_from_workspace!, 3) do
      {workspace, workspace_ms} = timed(fn -> apply(Weld.Workspace, :load!, [manifest]) end)
      {plans, compiler_ms} = timed(fn ->
        for artifact <- artifacts do
          apply(Weld.Plan, :build_from_workspace!, [manifest, workspace, [artifact: artifact]])
          |> then(&apply(Weld.Plan, :ensure_valid!, [&1]))
        end
      end)
      {plans, %{"workspace_ms" => workspace_ms, "compiler_ms" => compiler_ms, "plan_ms" => workspace_ms + compiler_ms}}
    else
      {plans, plan_ms} = timed(fn ->
        for artifact <- artifacts do
          apply(Weld.Plan, :build!, [manifest, [artifact: artifact]])
          |> then(&apply(Weld.Plan, :ensure_valid!, [&1]))
        end
      end)
      {plans, %{"workspace_ms" => nil, "compiler_ms" => nil, "plan_ms" => plan_ms}}
    end
  end

  defp execute!("plan", _plans, _request), do: {[], %{}}
  defp execute!(operation, plans, request) when operation in ["full", "live", "full_cache", "live_cache"] do
    cache? = operation in ["full_cache", "live_cache"]
    {outputs, milliseconds} = timed(fn ->
      for plan <- plans, do: apply(Weld.Projector, :project!, [plan, [live: operation in ["live", "live_cache"], no_cache: not cache?]])
    end)
    hits = Enum.count(outputs, &(Map.get(&1, :reused?) == true))
    if cache? and request["sample"] != "cold" and hits != length(outputs),
      do: raise("warm cache benchmark rebuilt #{length(outputs) - hits} artifacts; no cache-hit result claimed")
    {outputs, %{"projection_ms" => milliseconds,
      "cache_hit_count" => hits,
      "output_count" => length(outputs)}}
  end
  defp execute!("verify", plans, _request) do
    {outputs, milliseconds} = timed(fn ->
      for plan <- plans, do: apply(Weld.Verifier, :verify!, [plan, []])
    end)
    {outputs, %{"qualification_ms" => milliseconds}}
  end
  defp execute!(operation, plans, request) when operation in ["docs", "native"] do
    {outputs, projection_ms} = timed(fn ->
      for plan <- plans, do: apply(Weld.Projector, :project!, [plan, []])
    end)
    {_, dependency_ms} = timed(fn ->
      for {output, plan} <- Enum.zip(outputs, plans) do
        commands = [["mix", "deps.get"]] ++ if(operation == "docs", do: [["mix", "deps.compile"]], else: [])
        for {argv, index} <- Enum.with_index(commands) do
          log = Path.join(request["log_root"], "#{request["sample"]}-#{plan.artifact.id}-dependency-#{index}.log")
          subprocess!(argv, output.build_path, request["timeout"] || 900, log)
        end
      end
    end)
    {_, milliseconds} = timed(fn ->
      for {output, plan} <- Enum.zip(outputs, plans) do
        argv = if operation == "docs", do: request["docs_command"] || ["mix", "docs", "--warnings-as-errors"],
          else: request["native_command"] || raise("native requires a declared native_command")
        log = Path.join(request["log_root"], "#{request["sample"]}-#{plan.artifact.id}-#{operation}.log")
        subprocess!(argv, output.build_path, request["timeout"] || 900, log)
      end
    end)
    {outputs, %{"projection_ms" => projection_ms, "dependency_setup_ms" => dependency_ms, operation <> "_ms" => milliseconds}}
  end
  defp execute!(operation, _plans, _request), do: raise("unsupported benchmark operation #{operation}")

  defp subprocess!([command | args], cwd, timeout, log) when is_binary(command) do
    unless Enum.all?(args, &is_binary/1), do: raise("command arguments must be strings")
    env = for name <- ~w(MIX_EXS MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_TARGET), do: {name, nil}
    env = env ++ Application.get_env(:weld, :native_env, [])
    env = if Code.ensure_loaded?(Weld.Shell.Runner) and function_exported?(Weld.Shell.Runner, :mix_env, 3),
      do: apply(Weld.Shell.Runner, :mix_env, [cwd, Path.join(Path.dirname(log), "command-cache"), :dev]),
      else: [{"MIX_ENV", "dev"} | env]
    options = [cd: cwd, seconds: timeout, log_path: log, env: env]
    {output, status} = if Code.ensure_loaded?(Weld.Shell.Runner) and function_exported?(Weld.Shell.Runner, :run!, 3) do
      apply(Weld.Shell.Runner, :run!, [command, args, options])
    else
      # Historical baseline has no bounded Runner; the outer Python process
      # session timeout/log bound remains active. Report this limitation.
      System.cmd(command, args, Keyword.take(options, [:cd, :env]) ++ [stderr_to_stdout: true])
    end
    IO.write(output)
    if status != 0, do: raise("benchmark command failed with exit #{status}")
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, (System.monotonic_time(:microsecond) - started) / 1000}
  end

  defp app_version(app) do
    _ = Application.load(app)
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end
  defp otp_version do
    path = Path.join([to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"])
    case File.read(path) do
      {:ok, value} -> String.trim(value)
      _ -> System.otp_release()
    end
  end

  defp output_summary(output) do
    path = Map.get(output, :build_path) || Map.get(output, :project_path)
    %{"path" => path, "regular_output_bytes" => if(is_binary(path), do: regular_bytes(path), else: nil),
      "reused" => Map.get(output, :reused?)}
  end
  defp regular_bytes(path) do
    case File.lstat!(path) do
      %{type: :regular, size: size} -> size
      %{type: :directory} -> Enum.reduce(File.ls!(path), 0, fn name, sum -> sum + regular_bytes(Path.join(path, name)) end)
      %{type: :symlink} -> 0
      _ -> raise("special file in benchmark output")
    end
  end

  defp start_tracing do
    modules = Enum.map(@phase_functions ++ @count_functions, fn {_, {module, _, _}} -> module end) ++
      Enum.map(@message_functions, &elem(&1, 0))
    Enum.each(Enum.uniq(modules), &Code.ensure_loaded/1)
    phases = for {metric, mfa} <- @phase_functions, enable(mfa, true, [:call_time]), do: {metric, mfa}
    counts = for {metric, mfa} <- @count_functions, enable(mfa, true, [:call_count]), do: {metric, mfa}
    messages = Enum.filter(@message_functions, &enable(&1, [{:_, [], [{:return_trace}]}], trace_flags(&1)))
    tracer = spawn(fn -> trace_loop(%{stacks: %{}, copy_depths: %{}, docs: 0, compile: 0, archive: 0, copied: 0, subprocesses: 0}) end)
    :erlang.trace(:all, true, [:call, :set_on_spawn, :monotonic_timestamp, {:tracer, tracer}])
    %{phases: phases, counts: counts, messages: messages, tracer: tracer}
  end

  defp enable(mfa, pattern, flags) do
    :erlang.trace_pattern(mfa, pattern, flags) > 0
  rescue
    ArgumentError -> false
  end
  defp trace_flags({:erlang, :open_port, 2}), do: [:global]
  defp trace_flags(_), do: [:local]

  defp stop_tracing(tracing, native?) do
    # Counters avoid sending large compiler/snapshot terms to a tracer. Only
    # small Mix command and file-copy return values generate trace messages.
    :erlang.trace(:all, false, [:call, :set_on_spawn])
    reference = :erlang.trace_delivered(:all)
    receive do
      {:trace_delivered, :all, ^reference} -> :ok
    after
      10_000 -> raise("benchmark trace delivery did not complete")
    end
    send(tracing.tracer, {:finish, self()})
    messages = receive do
      {:metrics, value} -> value
    after
      10_000 -> raise("benchmark trace collector did not complete")
    end
    initial = Map.new(Enum.uniq(Enum.map(@phase_functions ++ @count_functions, &elem(&1, 0))), &{&1, nil})
    values = Enum.reduce(tracing.phases, initial, fn {metric, mfa}, acc ->
      case :erlang.trace_info(mfa, :call_time) do
        {:call_time, rows} when is_list(rows) ->
          milliseconds = Enum.reduce(rows, 0, fn {_pid, _count, seconds, microseconds}, sum -> sum + seconds * 1000 + microseconds / 1000 end)
          Map.update!(acc, metric, &((&1 || 0) + milliseconds))
        _ -> acc
      end
    end)
    values = Enum.reduce(tracing.counts, values, fn {metric, mfa}, acc ->
      case :erlang.trace_info(mfa, :call_count) do
        {:call_count, count} when is_integer(count) -> Map.update!(acc, metric, &((&1 || 0) + count))
        _ -> acc
      end
    end)
    has_mix = Enum.any?(tracing.messages, fn {module, function, _} -> module == Weld.Verifier and function == :run_mix! end)
    values = Map.merge(values, %{"docs_ms" => if(has_mix, do: messages.docs),
      "native_compile_ms" => if(native? and has_mix, do: messages.compile),
      "exact_archive_consumer_ms" => if({Weld.SmokeApp, :archive!, 4} in tracing.messages, do: messages.archive),
      "copied_bytes" => if(Enum.any?(tracing.messages, fn {module, function, _} -> module == :file and function == :copy end), do: messages.copied),
      "subprocess_count" => if({:erlang, :open_port, 2} in tracing.messages, do: messages.subprocesses)})
    for {_metric, mfa} <- tracing.phases, do: :erlang.trace_pattern(mfa, false, [:call_time])
    for {_metric, mfa} <- tracing.counts, do: :erlang.trace_pattern(mfa, false, [:call_count])
    for mfa <- tracing.messages, do: :erlang.trace_pattern(mfa, false, trace_flags(mfa))
    capabilities = %{"phase_clock" => "Erlang per-function call_time counters; *_ms without call are monotonic wall durations",
      "phase_functions" => Enum.map(tracing.phases, fn {metric, mfa} -> %{metric: metric, function: inspect(mfa)} end),
      "counter_functions" => Enum.map(tracing.counts, fn {metric, mfa} -> %{metric: metric, function: inspect(mfa)} end),
      "message_functions" => Enum.map(tracing.messages, &inspect/1),
      "explicit_command_adapter" => if(Code.ensure_loaded?(Weld.Shell.Runner) and function_exported?(Weld.Shell.Runner, :run!, 3),
        do: "bounded_Runner", else: "historical_System.cmd_buffered_with_outer_session_bound"),
      "missing_metric_policy" => "not_available_as_null",
      "probe_unit" => "project/environment probe on v2; in-VM project metadata probe on historical baseline"}
    {values, capabilities}
  end

  defp trace_loop(state) do
    receive do
      {:trace_ts, pid, :call, {module, function, args}, timestamp} ->
        mfa = {module, function, length(args)}
        label = trace_label(mfa, args)
        state = if label == :subprocess, do: %{state | subprocesses: state.subprocesses + 1}, else: state
        depth = Map.get(state.copy_depths, pid, 0)
        state = if label == :copy, do: %{state | copy_depths: Map.put(state.copy_depths, pid, depth + 1)}, else: state
        label = if label == :copy and depth > 0, do: :nested_copy, else: label
        key = {pid, mfa}
        stacks = Map.update(state.stacks, key, [{timestamp, label}], &[{timestamp, label} | &1])
        trace_loop(%{state | stacks: stacks})
      {:trace_ts, pid, :return_from, mfa, result, timestamp} ->
        key = {pid, mfa}
        case Map.get(state.stacks, key, []) do
          [{started, label} | rest] ->
            # monotonic_timestamp is nanoseconds (not native time units).
            elapsed = (timestamp - started) / 1_000_000
            state = %{state | stacks: Map.put(state.stacks, key, rest)}
            state = if label in [:copy, :nested_copy], do: %{state | copy_depths: Map.update!(state.copy_depths, pid, &(&1 - 1))}, else: state
            state = if label in [:docs, :compile, :archive], do: Map.update!(state, label, &(&1 + elapsed)), else: state
            state = case {label, result} do
              {:copy, {:ok, bytes}} when is_integer(bytes) -> %{state | copied: state.copied + bytes}
              _ -> state
            end
            trace_loop(state)
          _ -> trace_loop(state)
        end
      {:finish, parent} -> send(parent, {:metrics, Map.drop(state, [:stacks, :copy_depths])})
      _ -> trace_loop(state)
    end
  end
  defp trace_label({:file, :copy, arity}, _) when arity in [2, 3], do: :copy
  defp trace_label({:erlang, :open_port, 2}, [{:spawn_executable, _}, _]), do: :subprocess
  defp trace_label({Weld.SmokeApp, :archive!, 4}, _), do: :archive
  defp trace_label({Weld.Verifier, :run_mix!, arity}, args) do
    command = Enum.at(args, if(arity == 5, do: 3, else: 2))
    case command do
      ["docs" | _] -> :docs
      [task | _] when task in ["compile", "deps.compile"] -> :compile
      _ -> nil
    end
  end
  defp trace_label(_, _), do: nil
end

WeldBenchmark.main()
