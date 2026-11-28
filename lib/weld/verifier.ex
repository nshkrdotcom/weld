defmodule Weld.Verifier do
  @moduledoc "One isolated G01–G12 qualification path for verify and release preparation."
  alias Weld.Core.Identity

  alias Weld.{
    DocsPreview,
    DocsSmoke,
    Error,
    Hash,
    Output,
    Plan,
    Projector,
    ReleaseInputs,
    SmokeApp
  }

  alias Weld.Shell.{Hex, Runner}
  alias Weld.Workspace.Probe

  @gate_ids Enum.map(1..12, &("G" <> String.pad_leading(to_string(&1), 2, "0")))
  @test_args ["test", "--warnings-as-errors", "--seed", "0", "--max-cases", "1"]

  @spec verify!(Plan.t(), keyword()) :: map()
  def verify!(%Plan{} = plan, opts \\ []) do
    case opts[:parent_lease] do
      nil ->
        Output.with_lease(
          plan.manifest.repo_root,
          "verify",
          plan.artifact.id,
          "verify:" <> plan.artifact.id,
          [],
          &verify_with_lease!(plan, &1, opts)
        )

      lease ->
        validate_parent_lease!(plan, lease)
        verify_with_lease!(plan, lease, opts)
    end
  end

  defp validate_parent_lease!(plan, lease) do
    root = Output.checkout(plan.manifest.repo_root)

    unless lease.root == root and lease.record["artifact"] == plan.artifact.id and
             lease.record["operation"] == "prepare" and
             Enum.any?(Output.leases(root), fn {path, record} ->
               path == lease.path and record == lease.record
             end),
           do:
             raise(
               Error,
               "qualification requires the active parent prepare lease for this artifact"
             )
  end

  defp verify_with_lease!(plan, lease, opts) do
    run =
      Output.run!(plan.manifest.repo_root, "verify", plan.artifact.id, lease,
        plan_id: Weld.Plan.Inventory.portable(plan)["plan_id"]
      )

    Output.update_run!(run, %{"phase" => "executing"})

    try do
      result = verify_run!(plan, run.path, opts)
      Output.finish_run!(run, "completed")
      result
    rescue
      error ->
        record_failure!(run.path)

        Output.finish_run!(run, "failed", [
          %{
            "code" => "qualification_failed",
            "message" => Runner.sanitize(Exception.message(error))
          }
        ])

        reraise error, __STACKTRACE__
    end
  end

  def reuse_facts(plan, context, opts \\ []), do: ReleaseInputs.eligible(plan, context, opts)

  @doc "Typed gate specs, including the only permitted policy skips."
  def gate_specs(plan) do
    baseline? = plan.artifact.mode == :monolith or plan.artifact.verify.component_tests
    smoke? = plan.artifact.mode != :monolith and plan.artifact.verify.smoke.enabled
    hex? = plan.artifact.verify.hex_build
    preflight? = hex? and plan.artifact.verify.hex_publish

    specs = [
      {"G01", "all", [], true, ["project"], nil},
      {"G02", "dev,test", ["deps.get"], true, ["resolved_lock", "metadata"], nil},
      {"G03", "test", @test_args, baseline?, ["source_test_identities"],
       "no_selected_source_suites"},
      {"G04", "dev", ["deps.compile", "compile --warnings-as-errors --no-compile-deps"], true,
       ["compiled_project"], nil},
      {"G05", "test", @test_args, true, ["executed_test_identities"], nil},
      {"G06", "dev", ["docs", "--warnings-as-errors", "--output", "doc"], true,
       ["docs_tree", "static_docs_check"], nil},
      {"G07", "dev", ["deps.get", "compile --warnings-as-errors"], smoke?, ["configured_smoke"],
       "smoke_not_configured"},
      {"G08", "dev", ["hex.build"], hex?, ["package.tar", "package_entries", "package_metadata"],
       "hex_build_disabled"},
      {"G09", "dev", ["hex.publish", "--dry-run", "--yes"], preflight?,
       ["matching_rebuilt_archive"],
       if(hex?, do: "hex_publish_check_disabled", else: "hex_build_disabled")},
      {"G10", "test", ["signed_registry_install", "deps.compile", "compile", "test"], hex?,
       ["exact_hex_consumer"], "hex_build_disabled"},
      {"G11", "all", [], true, ["frozen_docs", "docs.tar.gz_if_hex"], nil},
      {"G12", "all", [], true, ["complete_frozen_inventory", "source_provenance", "all_gates"],
       nil}
    ]

    Enum.map(specs, fn {id, env, args, required, expected_outputs, reason} ->
      %{
        id: id,
        env: env,
        args: args,
        required: required,
        expected_outputs: expected_outputs,
        timeout: 900,
        skip_reason: if(required, do: nil, else: reason)
      }
    end)
  end

  defp verify_run!(plan, run_root, opts) do
    plan = Plan.ensure_valid!(plan)

    opts =
      opts
      |> Keyword.put(:candidate_registry, Runner.candidate_registry!(opts))
      |> Keyword.put(:native_env, Runner.native_env!(opts[:native_env]))
      |> Keyword.drop([:registry_url, :registry_public_key])

    specs = Map.new(gate_specs(plan), &{&1.id, &1})

    {state, projection, metadata, gates, operations} =
      materialize_and_resolve!(plan, run_root, opts, specs["G08"])

    {baseline, baseline_ops, gate} = check_source_tests!(state, specs["G03"])
    gates = gates ++ [gate]
    boundary!(state, "G03", gates)

    compile_ops = compile_project!(state)
    gates = gates ++ [pass("G04", %{"dependency_compile" => true, "warnings_as_errors" => true})]
    boundary!(state, "G04", gates)

    {test_operation, gate} =
      check_project_tests!(state, baseline, metadata.test.config, projection.verification_files)

    gates = gates ++ [gate]
    boundary!(state, "G05", gates)

    {docs, docs_frozen, docs_operation, gate} = build_docs!(state)
    gates = gates ++ [gate]
    boundary!(state, "G06", gates)

    {smoke_source, smoke_ops, gate} = check_path_consumer!(state, specs["G07"])
    gates = gates ++ [gate]
    boundary!(state, "G07", gates)

    {tarball, package, hex_ops, gate} = build_package!(state, specs["G08"])
    gates = gates ++ [gate]
    boundary!(state, "G08", gates)

    {preflight, gate} = check_package_preflight!(state, specs["G09"], tarball)
    gates = gates ++ [gate]
    boundary!(state, "G09", gates)

    {consumer, gate} = check_archive_consumer!(state, specs["G10"], tarball, smoke_source)
    gates = gates ++ [gate]
    boundary!(state, "G10", gates)

    {docs_archive, gate} = freeze_docs!(state, docs, docs_frozen, tarball)
    gates = gates ++ [gate]
    boundary!(state, "G11", gates)

    check_frozen_outputs!(docs, docs_frozen, tarball, package, docs_archive)

    gates =
      gates ++
        [
          pass("G12", %{
            "complete_inventory_rechecked" => true,
            "source_provenance_rechecked" => true,
            "lock_sha256" => state.lock_sha
          })
        ]

    validate_gates!(gates, gate_specs(plan))
    boundary!(state, "G12", gates)

    operations =
      operations ++
        baseline_ops ++
        compile_ops ++
        [test_operation, docs_operation] ++
        smoke_ops ++ hex_ops ++ preflight ++ consumer

    outputs = %{
      docs: docs,
      docs_frozen: docs_frozen,
      docs_archive: docs_archive,
      tarball: tarball,
      package: package
    }

    report_verification!(state, outputs, gates, operations)
  end

  defp materialize_and_resolve!(plan, run_root, opts, package_spec) do
    project = Path.join(run_root, "project")
    File.mkdir!(project)
    source_id = Weld.Plan.Inventory.portable(plan)["input_id"]
    projection = Projector.materialize_verification!(plan, project)
    initial = observe_project!(project, [])

    unless Enum.map(initial.entries, & &1["path"]) == Enum.sort(projection.verification_files),
      do: raise(Error, "G01: complete materialization membership differs from compiled inventory")

    gates = [
      pass("G01", %{
        "project_id" => tree_id("project", initial),
        "files" => length(initial.entries)
      })
    ]

    :ok = Projector.recheck_inputs!(plan, source_id)
    write_gates!(run_root, gates)
    before_resolution = observe_project!(project, ["mix.lock"])
    before_metadata = probe!(project, run_root, opts)

    operations =
      for env <- [:dev, :test],
          do: run_mix!(project, run_root, env, ["deps.get"], "G02-#{env}", opts)

    after_metadata = probe!(project, run_root, opts)

    unless before_metadata == after_metadata,
      do: raise(Error, "G02: effective Mix metadata changed after resolving the standalone lock")

    unless before_resolution == observe_project!(project, ["mix.lock"]),
      do:
        raise(
          Error,
          "G02: dependency resolution modified project bytes, modes or membership outside the lock slot"
        )

    lock_sha = freeze_lock!(project)
    frozen = observe_project!(project, [])

    if is_nil(lock_sha) and
         Enum.any?(after_metadata, fn {_env, facts} -> facts.config[:deps] != [] end),
       do: raise(Error, "G02: dependency closure has no frozen standalone mix.lock")

    package_files = Enum.sort(projection.package_files)

    package_config = after_metadata.dev.config

    expected_metadata =
      if package_spec.required, do: package_metadata!(package_config, package_files)

    package_empty_dirs = package_empty_dirs!(project, package_config, frozen.empty_dirs)

    state = %{
      plan: plan,
      root: run_root,
      project: project,
      frozen: frozen,
      package_files: package_files,
      expected_metadata: expected_metadata,
      package_empty_dirs: package_empty_dirs,
      source_id: source_id,
      opts: opts,
      lock_sha: lock_sha
    }

    gates =
      gates ++
        [
          pass("G02", %{
            "lock_sha256" => lock_sha,
            "metadata_sha256" =>
              Identity.raw(Identity.canonical(portable(after_metadata, project)))
          })
        ]

    boundary!(state, "G02", gates)

    {state, projection, after_metadata, gates, operations}
  end

  defp check_source_tests!(state, %{required: true}) do
    {baseline, result} = baseline!(state)
    {baseline, [result], pass("G03", %{"tests" => baseline, "count" => length(baseline)})}
  end

  defp check_source_tests!(_state, spec), do: {[], [], skip(spec)}

  defp compile_project!(%{project: project, root: run_root, opts: opts}) do
    [
      run_mix!(project, run_root, :dev, ["deps.compile"], "G04-deps", opts),
      run_mix!(
        project,
        run_root,
        :dev,
        ["compile", "--warnings-as-errors", "--no-compile-deps"],
        "G04-compile",
        opts
      )
    ]
  end

  defp check_project_tests!(state, baseline, config, verification_files) do
    %{plan: plan, project: project, root: run_root, opts: opts} = state
    {test_operation, tests} = run_tests!(project, run_root, "G05", opts)
    validate_test_mapping!(plan, baseline, tests)

    declared_tests =
      declared_test_files!(project, config, verification_files)

    if tests == [] and declared_tests != [],
      do: raise(Error, "G05: declared test files produced no execution identities")

    gate =
      pass("G05", %{
        "tests" => tests,
        "count" => length(tests),
        "source_mapping_verified" => true,
        "zero_tests_reason" => if(tests == [], do: "no_declared_or_discovered_tests", else: nil)
      })

    {test_operation, gate}
  end

  defp build_docs!(%{project: project, root: run_root, opts: opts}) do
    docs_operation =
      run_mix!(
        project,
        run_root,
        :dev,
        ["docs", "--warnings-as-errors", "--output", "doc"],
        "G06",
        opts
      )

    docs = Path.join(run_root, "docs")
    DocsPreview.copy!(Path.join(project, "doc"), docs)

    docs_check =
      case DocsSmoke.check(docs) do
        {:ok, summary} ->
          Map.take(summary, [:html_count, :mermaid_pages])

        {:error, errors} ->
          raise Error, "G06: documentation smoke failed: #{Enum.join(errors, "; ")}"
      end

    docs_frozen = observe_tree!(docs)

    gate =
      pass(
        "G06",
        Map.merge(portable(docs_check, docs), %{
          "browser_rendering" => "not_claimed",
          "policy" => "html_stable_groups_no_epub/2"
        })
      )

    {docs, docs_frozen, docs_operation, gate}
  end

  defp check_path_consumer!(state, spec) do
    %{plan: plan, project: project, root: run_root} = state

    smoke_source =
      if plan.artifact.verify.smoke.entry_file,
        do:
          File.read!(
            Output.source!(plan.manifest.repo_root, plan.artifact.verify.smoke.entry_file)
          )

    if spec.required do
      result =
        SmokeApp.verify_project!(plan, project, Path.join(run_root, "project-smoke"), state.opts)

      {smoke_source, [result],
       pass("G07", %{
         "consumer" => "ordinary_mix_path",
         "entry_sha256" => Identity.raw(smoke_source)
       })}
    else
      {smoke_source, [], skip(spec)}
    end
  end

  defp build_package!(state, %{required: true}) do
    %{plan: plan, project: project, root: run_root, package_files: package_files} = state
    %{expected_metadata: expected_metadata, package_empty_dirs: empty_dirs} = state

    operation = run_mix!(project, run_root, :dev, ["hex.build"], "G08", state.opts)
    produced = Path.join(project, archive_name(plan))

    :ok =
      Hex.check_package!(produced, project, package_files, expected_metadata,
        empty_dirs: empty_dirs
      )

    package = Hex.package_observation!(produced)

    :ok =
      Hex.validate_dependency_metadata!(
        package.metadata,
        Weld.Plan.Inventory.portable(plan)["dependencies"]
      )

    target = Path.join(run_root, "package.tar")
    File.rename!(produced, target)

    {target, package, [operation],
     pass("G08", %{
       "archive_sha256" => Hash.sha256_file(target),
       "package_id" => package_id(package),
       "entries" => length(package.entries)
     })}
  end

  defp build_package!(_state, spec) do
    {nil, nil, [disabled("hex.build", :artifact_opted_out)], skip(spec)}
  end

  defp check_package_preflight!(state, %{required: true}, tarball) do
    result = preflight!(state, tarball)

    {[result],
     pass("G09", %{
       "isolated" => true,
       "archive_sha256" => Hash.sha256_file(tarball),
       "matching_rebuild" => true
     })}
  end

  defp check_package_preflight!(_state, spec, tarball) do
    reason = if tarball, do: :artifact_opted_out, else: :hex_build_disabled
    {[disabled("hex.publish --dry-run --yes", reason)], skip(spec)}
  end

  defp check_archive_consumer!(state, %{required: true}, tarball, smoke_source) do
    %{plan: plan, root: run_root, opts: opts} = state

    result =
      SmokeApp.verify_archive!(
        plan,
        tarball,
        Path.join(run_root, "hex-consumer"),
        smoke_source,
        opts
      )

    {[result], pass("G10", portable(Map.drop(result, [:task, :env, :status]), run_root))}
  end

  defp check_archive_consumer!(_state, spec, _tarball, _smoke_source), do: {[], skip(spec)}

  defp freeze_docs!(%{root: run_root}, docs, docs_frozen, tarball) do
    unless docs_frozen == observe_tree!(docs),
      do: raise(Error, "G11: docs payload changed after generation")

    docs_archive = if tarball, do: Hex.freeze_docs!(docs, Path.join(run_root, "docs.tar.gz"))

    {docs_archive,
     pass("G11", %{
       "docs_id" => tree_id("docs", docs_frozen),
       "docs_archive_sha256" => docs_archive && docs_archive.sha256,
       "roundtrip_verified" => not is_nil(docs_archive),
       "archive_policy" => if(tarball, do: "exact_frozen_payload", else: "non_hex_docs_tree")
     })}
  end

  defp check_frozen_outputs!(docs, docs_frozen, tarball, package, docs_archive) do
    if tarball do
      unless package == Hex.package_observation!(tarball),
        do: raise(Error, "G12: frozen package archive changed")
    end

    unless docs_frozen == observe_tree!(docs), do: raise(Error, "G12: frozen docs tree changed")

    if docs_archive && Hash.sha256_file(docs_archive.path) != docs_archive.sha256,
      do: raise(Error, "G12: frozen docs archive changed")
  end

  defp report_verification!(state, outputs, gates, operations) do
    %{
      plan: plan,
      project: project,
      root: run_root,
      frozen: frozen,
      opts: opts,
      lock_sha: lock_sha,
      package_files: package_files
    } = state

    %{
      docs: docs,
      docs_frozen: docs_frozen,
      docs_archive: docs_archive,
      tarball: tarball,
      package: package
    } = outputs

    observations = ReleaseInputs.observations(plan, opts[:context] || opts[:reuse], opts)

    qualification = %{
      "gate_schema" => "weld.gates/2",
      "gates" => gates,
      "project_id" => tree_id("project", frozen),
      "package_id" => package && package_id(package),
      "archive_sha256" => tarball && Hash.sha256_file(tarball),
      "docs_id" => tree_id("docs", docs_frozen),
      "docs_archive_sha256" => docs_archive && docs_archive.sha256,
      "lock_sha256" => lock_sha,
      "toolchain" => observations.toolchain,
      "trust" => observations.trust,
      "context_digest" => observations.context_digest
    }

    report = Path.join(run_root, "verification.json")

    File.write!(
      report,
      Jason.encode!(%{schema: "weld.verification-report/2", gates: gates, operations: operations},
        pretty: true
      ),
      [:exclusive]
    )

    %{
      build_path: project,
      lockfile_path: report,
      package_files: package_files,
      verification_files: Enum.map(frozen.entries, & &1["path"]),
      frozen_project: frozen.entries,
      empty_dirs: frozen.empty_dirs,
      package_entries: package && package.entries,
      package_metadata: package && package.metadata,
      docs_path: docs,
      docs_entries: docs_frozen.entries,
      docs_empty_dirs: docs_frozen.empty_dirs,
      tarball_path: tarball,
      docs_archive_path: docs_archive && docs_archive.path,
      archive_sha256: qualification["archive_sha256"],
      docs_archive_sha256: qualification["docs_archive_sha256"],
      qualification: qualification,
      gates: gates,
      verification_results: operations
    }
  end

  defp boundary!(state, gate, gates) do
    if callback = state.opts[:after_gate], do: callback.(gate, state.project)
    verify_registry_boundary!(state.root, state.opts[:candidate_registry])

    assert_frozen_project!(
      state.project,
      ["doc", archive_name(state.plan)],
      state.frozen,
      state.lock_sha,
      gate
    )

    :ok = Projector.recheck_inputs!(state.plan, state.source_id)
    write_gates!(state.root, gates)
  end

  @doc false
  def verify_registry_boundary!(_root, nil), do: :ok

  def verify_registry_boundary!(root, registry) do
    config = Path.join([root, "cache", "hex-home", "hex.config"])
    Runner.validate_registry_config!(config, registry)
  end

  @doc false
  def assert_frozen_project!(project, excluded, frozen, lock_sha, gate) do
    unless observe_project!(project, excluded) == frozen,
      do:
        raise(Error, "#{gate}: frozen project bytes, modes, lock or complete membership changed")

    unless optional_sha(Path.join(project, "mix.lock")) == lock_sha,
      do: raise(Error, "#{gate}: resolved lock changed during qualification")

    :ok
  end

  defp archive_name(plan),
    do: "#{plan.artifact.package.name}-#{plan.artifact.package.version}.tar"

  defp probe!(project, root, opts) do
    # Initialize/validate the shared isolated registry configuration in the
    # caller before starting independent read-only metadata VMs. In particular,
    # candidate registry setup must never race on its exclusive PEM/config.
    mix_opts = mix_opts(opts)

    jobs =
      for env <- Probe.environments(),
          do: {env, Runner.mix_env(project, Path.join(root, "cache"), env, mix_opts)}

    jobs
    |> Probe.observe_independent!(fn {env, variables} ->
      {env, Probe.project!(project, env, env: variables)}
    end)
    |> Map.new()
  end

  defp run_mix!(project, root, env, args, label, opts) do
    IO.puts(:stderr, "Weld: #{label} MIX_ENV=#{env} mix #{Enum.join(args, " ")}")

    {output, status} =
      Runner.run!("mix", args,
        cd: project,
        seconds: 900,
        env: Runner.mix_env(project, Path.join(root, "cache"), env, mix_opts(opts)),
        log_path: Path.join(root, "logs/#{label}.log")
      )

    unless status == 0,
      do: raise(Error, "#{label}: Mix command failed (exit #{status})\n#{output}")

    %{task: Enum.join(args, " "), env: env, status: :ok}
  end

  defp preflight!(state, tarball) do
    root = Path.join(state.root, "hex-preflight")
    project = Path.join(root, "project")
    copy_exact!(state.project, project, state.frozen)
    _ = run_mix!(project, root, :dev, ["deps.get", "--check-locked"], "G09-deps", state.opts)
    capture = Path.join(root, "rebuilt-package.tar")
    hook = Path.join(root, "capture.exs")
    File.write!(hook, preflight_capture(capture), [:exclusive])
    hex_beam = :code.where_is_file(~c"Elixir.Hex.Tar.beam")

    unless is_list(hex_beam),
      do: raise(Error, "G09 requires the installed Hex.Tar instrumentation point")

    mix_opts = mix_opts(state.opts)

    {output, status} =
      Runner.run!(
        "elixir",
        [
          "-pa",
          Path.dirname(to_string(hex_beam)),
          "-r",
          hook,
          "-S",
          "mix",
          "hex.publish",
          "--dry-run",
          "--yes"
        ],
        cd: project,
        seconds: 900,
        env: Runner.mix_env(project, Path.join(root, "cache"), :dev, mix_opts),
        log_path: Path.join(root, "logs/G09.log")
      )

    unless status == 0,
      do: raise(Error, "G09: isolated Hex dry run failed (exit #{status})\n#{output}")

    unless File.regular?(capture) and Hash.sha256_file(capture) == Hash.sha256_file(tarball),
      do: raise(Error, "G09: Hex preflight rebuilt bytes that differ from G08")

    docs_output =
      Probe.project!(project, :dev,
        env: Runner.mix_env(project, Path.join(root, "cache"), :dev, mix_opts)
      ).config[:docs][:output] || "doc"

    Weld.Core.Inventory.validate_path!(docs_output)

    unless observe_project!(project, Enum.uniq(["doc", docs_output, archive_name(state.plan)])) ==
             state.frozen,
           do: raise(Error, "G09: isolated preflight modified the frozen project")

    %{task: "hex.publish --dry-run --yes", env: :dev, status: :ok}
  end

  # Hex 2.7.0 builds its dry-run package in memory, not a file. Observe the
  # actual return of Hex.Tar.create!/3 without changing its code or result.
  defp preflight_capture(path) do
    """
    defmodule WeldPreflightCapture do
      use GenServer
      def init(_), do: {:ok, 0}
      def handle_info({:trace, _, :return_from, {Hex.Tar, :create!, 3}, %{tarball: bytes}}, count) do
        File.write!(#{inspect(path)}, bytes, [:exclusive])
        {:noreply, count + 1}
      end
      def handle_info(_, count), do: {:noreply, count}
      def handle_call(:count, _, count), do: {:reply, count, count}
    end
    {:module, Hex.Tar} = Code.ensure_loaded(Hex.Tar)
    {:ok, tracer} = GenServer.start(WeldPreflightCapture, [])
    1 = :erlang.trace_pattern({Hex.Tar, :create!, 3}, [{:_, [], [{:return_trace}]}], [])
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    System.at_exit(fn status ->
      ref = :erlang.trace_delivered(:all)
      receive do {:trace_delivered, :all, ^ref} -> :ok after 5000 -> System.halt(1) end
      count = GenServer.call(tracer, :count)
      if status == 0 and count != 1, do: System.halt(1)
    end)
    """
  end

  defp baseline!(state) do
    mirror = Path.join(state.root, "source-baseline")
    mirror_source_tree!(state.plan.manifest.repo_root, mirror)
    projects = Enum.sort_by(state.plan.selected_projects, & &1.id)

    {tests, counts} =
      Enum.reduce(projects, {[], []}, fn project, {tests, counts} ->
        {records, count} = baseline_project!(state, mirror, project)
        {tests ++ records, counts ++ [count]}
      end)

    {Enum.sort_by(tests, &test_key/1),
     %{
       task: "selected_tests_baseline",
       env: :test,
       status: :ok,
       test_count: length(tests),
       project_test_counts: counts
     }}
  end

  defp baseline_project!(state, mirror, project) do
    root = Path.join([state.root, "baseline-work", Identity.raw(project.id)])
    project_root = if project.id == ".", do: mirror, else: Path.join(mirror, project.id)
    _ = run_mix!(project_root, root, :test, ["deps.get"], "G03-resolve", state.opts)
    frozen = observe_tree!(mirror)
    {result, records} = run_tests!(project_root, root, "G03", state.opts)

    unless frozen == observe_tree!(mirror),
      do: raise(Error, "G03: source baseline modified frozen source mirror")

    records = Enum.map(records, &prefix_baseline_file(&1, project.id))
    {records, %{project_id: project.id, app: project.app, test_count: result.test_count}}
  end

  defp prefix_baseline_file(record, "."), do: record

  defp prefix_baseline_file(record, project_id),
    do: Map.update!(record, "file", &(project_id <> "/" <> &1))

  defp run_tests!(project, root, gate, opts) do
    File.mkdir_p!(root)
    event_path = Path.join(root, "#{gate}-test-events.tsv")
    formatter = Path.join(root, "#{gate}-formatter.exs")
    File.write!(formatter, formatter_source(event_path), [:exclusive])

    args =
      ["-r", formatter, "-S", "mix"] ++
        @test_args ++
        ["--formatter", "ExUnit.CLIFormatter", "--formatter", "WeldQualificationFormatter"]

    {output, status} =
      Runner.run!("elixir", args,
        cd: project,
        seconds: 900,
        env: Runner.mix_env(project, Path.join(root, "cache"), :test, mix_opts(opts)),
        log_path: Path.join(root, "logs/#{gate}.log")
      )

    unless status == 0,
      do: raise(Error, "#{gate}: test execution failed (exit #{status})\n#{output}")

    tests = read_test_events!(event_path, project, output)

    {%{
       task: "test --warnings-as-errors",
       env: :test,
       status: :ok,
       test_count: length(tests),
       failure_count: 0,
       test_identities: tests,
       seed: 0
     }, tests}
  end

  defp mix_opts(opts), do: Keyword.take(opts, [:candidate_registry, :native_env])

  @doc false
  def validate_test_mapping!(plan, baseline, actual) do
    mapping =
      for entry <- plan.output_inventory, input <- entry.inputs, reduce: %{} do
        acc -> Map.update(acc, input.source, [entry.target], &[entry.target | &1])
      end

    actual = Map.new(actual, &{test_key(&1), &1["state"]})

    for test <- baseline do
      targets = Map.get(mapping, test["file"], []) |> Enum.uniq()

      matches =
        for target <- targets,
            key = {target, test["module"], test["name"]},
            Map.has_key?(actual, key),
            do: key

      unless length(matches) == 1 and Map.fetch!(actual, hd(matches)) == test["state"],
        do:
          raise(
            Error,
            "source test identity disappeared or changed execution state: #{inspect(test_key(test))}"
          )
    end

    :ok
  end

  defp test_key(test), do: {test["file"], test["module"], test["name"]}

  defp read_test_events!(path, project, output) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= 16 * 1024 * 1024 ->
        parse_test_events!(bytes, project)

      {:error, :enoent} ->
        if output =~ "There are no tests to run",
          do: [],
          else: raise(Error, "missing ExUnit execution evidence")

      _ ->
        raise Error, "invalid bounded ExUnit execution evidence"
    end
  end

  defp parse_test_events!(bytes, project) do
    lines = String.split(bytes, "\n", trim: true)

    unless List.first(lines) == "suite_started" and List.last(lines) == "suite_finished",
      do: raise(Error, "incomplete ExUnit execution evidence")

    tests =
      lines
      |> Enum.slice(1, max(length(lines) - 2, 0))
      |> Enum.map(&parse_test_event!(&1, project))

    unless length(Enum.uniq_by(tests, &test_key/1)) == length(tests),
      do: raise(Error, "ambiguous duplicate ExUnit test identities")

    Enum.sort_by(tests, &test_key/1)
  end

  defp parse_test_event!(line, project) do
    case String.split(line, "\t") do
      ["test", file, module, name, state] when state in ~w(pass skip excluded) ->
        file = file |> Base.decode64!() |> Path.relative_to(project)
        Weld.Core.Inventory.validate_path!(file)

        %{
          "file" => file,
          "module" => Base.decode64!(module),
          "name" => Base.decode64!(name),
          "state" => state
        }

      _ ->
        raise Error, "unsupported or failed ExUnit test identity"
    end
  end

  defp formatter_source(path) do
    """
    defmodule WeldQualificationFormatter do
      use GenServer
      def init(_opts), do: {:ok, #{inspect(path)}}
      def handle_cast({:suite_started, _}, path) do
        File.write!(path, "suite_started\\n", [:exclusive])
        {:noreply, path}
      end
      def handle_cast({:test_finished, test}, path) do
        state = case test.state do
          nil -> "pass"
          {:skipped, _} -> "skip"
          {:excluded, _} -> "excluded"
          _ -> "fail"
        end
        fields = ["test", Base.encode64(to_string(test.tags.file)), Base.encode64(to_string(test.module)), Base.encode64(to_string(test.name)), state]
        File.write!(path, Enum.join(fields, "\\t") <> "\\n", [:append])
        {:noreply, path}
      end
      def handle_cast({:suite_finished, _}, path) do
        File.write!(path, "suite_finished\\n", [:append])
        {:noreply, path}
      end
      def handle_cast(_, path), do: {:noreply, path}
    end
    """
  end

  defp observe_tree!(root) do
    observed = Hash.observation(root)
    %{entries: observed["entries"], empty_dirs: observed["empty_dirs"]}
  end

  defp freeze_lock!(project) do
    path = Output.source!(project, "mix.lock")

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) == 0 ->
        File.chmod!(path, 0o644)
        Hash.sha256_file(path)

      {:error, :enoent} ->
        nil

      _ ->
        raise Error, "G02: resolved mix.lock must be a regular non-executable file"
    end
  end

  defp observe_project!(project, excluded) do
    tree = observe_tree!(project)

    ignored? = fn path ->
      Enum.any?(excluded, &(path == &1 or String.starts_with?(path, &1 <> "/")))
    end

    entries = Enum.reject(tree.entries, &ignored?.(&1["path"]))

    for entry <- entries do
      expected = if entry["executable"], do: 0o755, else: 0o644
      actual = File.lstat!(Output.source!(project, entry["path"]))

      unless actual.type == :regular and Bitwise.band(actual.mode, 0o777) == expected,
        do: raise(Error, "frozen project contains non-normalized mode: #{entry["path"]}")
    end

    %{entries: entries, empty_dirs: Enum.reject(tree.empty_dirs, ignored?)}
  end

  defp copy_exact!(source, target, tree) do
    File.mkdir_p!(target)
    for directory <- tree.empty_dirs, do: File.mkdir_p!(Path.join(target, directory))

    for entry <- tree.entries do
      from = Output.source!(source, entry["path"])
      to = Path.join(target, entry["path"])
      File.mkdir_p!(Path.dirname(to))
      File.cp!(from, to)
      File.chmod!(to, if(entry["executable"], do: 0o755, else: 0o644))
    end
  end

  defp mirror_source_tree!(source, target) do
    case File.lstat!(source) do
      %{type: :directory} ->
        File.mkdir!(target)

        for name <- File.ls!(source),
            name not in ~w(.git .weld _build deps doc node_modules),
            do: mirror_source_tree!(Path.join(source, name), Path.join(target, name))

      %{type: :regular, mode: mode} ->
        File.cp!(source, target)
        File.chmod!(target, Bitwise.band(mode, 0o777))

      _ ->
        raise Error, "baseline requires regular source files: #{source}"
    end
  end

  defp package_metadata!(config, files) do
    package = config[:package] || []

    requirements = Enum.reduce(config[:deps] || [], %{}, &add_publication_requirement!/2)

    %{
      "name" => to_string(package[:name] || config[:app]),
      "version" => config[:version],
      "app" => to_string(config[:app]),
      "elixir" => config[:elixir],
      "description" => trim_description(package[:description] || config[:description]),
      "licenses" => package[:licenses],
      "links" => package[:links],
      "build_tools" => package[:build_tools] || build_tools(files),
      "requirements" => requirements,
      "files" => files,
      "extra" => package[:extra],
      "secret_scan" => package[:secret_scan]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp add_publication_requirement!(dep, acc) do
    {app, requirement, opts} = publication_dep(dep)

    if is_nil(opts[:only]) or :prod in List.wrap(opts[:only]),
      do: put_publication_requirement!(acc, app, requirement, opts),
      else: acc
  end

  defp publication_dep({app, requirement, opts}), do: {app, requirement, opts}
  defp publication_dep({app, opts}) when is_list(opts), do: {app, nil, opts}
  defp publication_dep({app, requirement}), do: {app, requirement, []}

  defp put_publication_requirement!(acc, app, requirement, opts) do
    unless is_binary(requirement) and is_nil(opts[:path]) and is_nil(opts[:git]) and
             is_nil(opts[:github]),
           do:
             raise(Error, "Hex qualification requires ordinary registry publication dependencies")

    name = to_string(opts[:hex] || app)
    if Map.has_key?(acc, name), do: raise(Error, "duplicate Hex publication dependency")

    Map.put(acc, name, %{
      "app" => to_string(app),
      "requirement" => requirement,
      "optional" => opts[:optional] || false,
      "repository" => publication_repository(opts)
    })
  end

  defp publication_repository(opts) do
    (opts[:repo] || if(opts[:organization], do: "hexpm:" <> opts[:organization], else: "hexpm"))
    |> to_string()
    |> String.split(":", parts: 2)
    |> List.last()
  end

  defp package_empty_dirs!(project, config, empty_dirs) do
    package = config[:package] || []

    patterns = package[:files] || Weld.Core.Inventory.default_hex_files()

    matches =
      Enum.flat_map(patterns, fn pattern ->
        Path.wildcard(Path.join(project, pattern), match_dot: true)
        |> Enum.map(&Path.relative_to(&1, project))
      end)

    Enum.filter(empty_dirs, fn directory ->
      Enum.any?(matches, &(directory == &1 or String.starts_with?(directory, &1 <> "/"))) and
        not Enum.any?(package[:exclude_patterns] || [], &(directory =~ &1))
    end)
  end

  defp trim_description(nil), do: nil
  defp trim_description(description), do: String.trim(description)

  defp build_tools(files) do
    pairs = [
      {"mix.exs", "mix"},
      {"rebar", "rebar3"},
      {"rebar.lock", "rebar3"},
      {"rebar.config", "rebar3"},
      {"rebar.config.script", "rebar3"},
      {"erlang.mk", "make"},
      {"Makefile", "make"},
      {"Makefile.win", "make"}
    ]

    case Enum.uniq(for {file, tool} <- pairs, file in files, do: tool) do
      [] -> ["mix"]
      tools -> tools
    end
  end

  defp declared_test_files!(project, config, inventory) do
    paths =
      config[:test_paths] || if(File.dir?(Path.join(project, "test")), do: ["test"], else: [])

    pattern = config[:test_pattern]

    unless is_nil(pattern) or is_binary(pattern),
      do: raise(Error, "unsupported test discovery pattern")

    discovered =
      for directory <- paths,
          file <- inventory,
          String.starts_with?(file, directory <> "/") and Path.extname(file) in [".ex", ".exs"] and
            not String.ends_with?(file, "_helper.exs"),
          do: file

    # A custom loader may select files that do not end in _test.exs. Treat all
    # candidate source files conservatively when no tests actually execute.
    if pattern do
      Enum.uniq(
        discovered ++
          Enum.flat_map(paths, fn directory ->
            Path.wildcard(Path.join([project, directory, "**", pattern]))
            |> Enum.map(&Path.relative_to(&1, project))
          end)
      )
    else
      discovered
    end
  end

  defp record_failure!(root) do
    completed =
      case File.read(Path.join(root, "gates.json")) do
        {:ok, bytes} -> Jason.decode!(bytes)["gates"]
        _ -> []
      end

    completed = if length(completed) == 12, do: Enum.take(completed, 11), else: completed
    failed_id = Enum.at(@gate_ids, length(completed))

    remaining =
      Enum.drop(@gate_ids, length(completed))
      |> Enum.map(fn id ->
        %{
          "id" => id,
          "status" => "fail",
          "skip_reason" => nil,
          "facts" =>
            if(id == failed_id,
              do: %{"code" => "qualification_failed"},
              else: %{"code" => "not_executed", "blocked_by" => failed_id}
            )
        }
      end)

    write_gates!(root, completed ++ remaining)
  rescue
    _ -> :ok
  end

  defp tree_id(domain, tree),
    do: Identity.digest(domain, %{"entries" => tree.entries, "empty_dirs" => tree.empty_dirs})

  defp package_id(package),
    do:
      Identity.digest("package", %{"metadata" => package.metadata, "entries" => package.entries})

  defp optional_sha(path), do: if(File.regular?(path), do: Hash.sha256_file(path))

  defp pass(id, facts),
    do: %{"id" => id, "status" => "pass", "facts" => facts, "skip_reason" => nil}

  defp skip(spec),
    do: %{"id" => spec.id, "status" => "skip", "facts" => %{}, "skip_reason" => spec.skip_reason}

  defp disabled(task, reason), do: %{task: task, env: :dev, status: :skipped, reason: reason}

  defp write_gates!(root, gates),
    do:
      File.write!(
        Path.join(root, "gates.json"),
        Identity.canonical(%{"schema" => "weld.gates/2", "gates" => gates})
      )

  @doc false
  def validate_gates!(gates, specs) do
    unless Enum.map(gates, & &1["id"]) == @gate_ids,
      do: raise(Error, "qualification must record G01–G12 exactly once in order")

    for {gate, spec} <- Enum.zip(gates, specs) do
      unless valid_gate_fields?(gate) and valid_gate_status?(gate, spec),
        do: raise(Error, "invalid or skipped mandatory qualification gate #{spec.id}")
    end

    :ok
  end

  defp valid_gate_fields?(gate),
    do: Enum.sort(Map.keys(gate)) == ~w(facts id skip_reason status) and is_map(gate["facts"])

  defp valid_gate_status?(%{"status" => "pass", "skip_reason" => nil}, _spec), do: true

  defp valid_gate_status?(%{"status" => "skip", "skip_reason" => reason}, spec),
    do: not spec.required and reason == spec.skip_reason

  defp valid_gate_status?(_, _), do: false

  defp portable(%Regex{} = regex, _root),
    do: %{"regex" => Regex.source(regex), "options" => Regex.opts(regex)}

  defp portable(value, root) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), portable(item, root)} end)

  defp portable(value, root) when is_list(value), do: Enum.map(value, &portable(&1, root))

  # Erlang include paths can be charlists. Preserve the option's encoding while
  # dropping the operational root of this qualification run.
  defp portable({:i, path}, root) when is_list(path) do
    case Weld.Core.Inventory.portable_erlc_include(path, root) do
      nil -> ["i", portable(path, root)]
      descriptor -> ["i", descriptor]
    end
  end

  defp portable(value, root) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&portable(&1, root))

  defp portable(value, root) when is_binary(value),
    do: if(Path.type(value) == :absolute, do: Path.relative_to(value, root), else: value)

  defp portable(value, _root) when value in [nil, true, false], do: value
  defp portable(value, _root) when is_atom(value), do: to_string(value)
  defp portable(value, _root) when is_integer(value), do: value
end
