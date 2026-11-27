defmodule Weld.CLI do
  @moduledoc false
  alias Weld.{
    Affected,
    Commands,
    Error,
    Git,
    Manifest,
    Output,
    Plan,
    Projector,
    Release,
    ReleaseStatus,
    Verifier,
    Workspace
  }

  alias Weld.Core.ReleaseOrder
  alias Weld.Shell.{Diff, GC, Runner}

  @common [manifest: :string, root: :string, format: :string, verbose: :boolean, help: :boolean]
  @selection [artifact: :string, all: :boolean]
  @pin [identity: :string, current: :boolean]
  @registry %{
    "setup" => {0, []},
    "plan" => {0, @selection},
    "graph" => {0, [artifact: :string, view: :string]},
    "query" => {:query, [artifact: :string, view: :string]},
    "affected" => {0, @selection ++ [base: :string, head: :string, task: :string]},
    "project" => {0, @selection ++ [kind: :string, fresh: :boolean]},
    "verify" => {0, @selection ++ [fresh: :boolean, context: :string]},
    "prepare" => {0, @selection ++ [fresh: :boolean, context: :string, reuse: :string]},
    "status" => {0, @selection ++ [identity: :string, remote: :boolean]},
    "diff" => {0, [artifact: :string, kind: :string, identity: :string]},
    "path" => {0, [artifact: :string, kind: :string, identity: :string, run: :string]},
    "doctor" => {0, []},
    "docs-check" => {1, []},
    "lint" => {0, []},
    "release-plan" => {0, [all: :boolean, check: :boolean]},
    "track" =>
      {0,
       [
         artifact: :string,
         tag: :string,
         tag_release: :boolean,
         push: :boolean,
         remote: :string,
         branch: :string
       ] ++ @pin},
    "verify-tag" => {1, [artifact: :string, identity: :string, tarball: :string]},
    "stage" => {0, [artifact: :string] ++ @pin},
    "publish" =>
      {0,
       [
         artifact: :string,
         tag: :string,
         dry_run: :boolean,
         yes: :boolean,
         allow_source_drift: :boolean
       ] ++ @pin},
    "reconcile" => {0, [artifact: :string, identity: :string]},
    "archive" => {0, @selection ++ @pin},
    "gc" => {0, [keep: :integer, dry_run: :boolean, apply: :boolean]},
    "recover" => {0, [lease: :string]}
  }
  @batch ~w(plan project verify prepare)
  @store ~w(track stage publish reconcile archive)
  @views %{
    "all" => :all,
    "runtime" => :runtime,
    "compile" => :compile,
    "docs" => :docs,
    "test" => :test,
    "package" => :package,
    "smoke" => :smoke,
    "tooling" => :tooling,
    "dev" => :dev
  }
  @descriptions %{
    "setup" => "Initialize managed state and report the source ignore-rule edit.",
    "plan" => "Compile artifact membership, dependency boundaries and exact inventory.",
    "graph" => "Show the workspace graph; --artifact adds a publication boundary overlay.",
    "query" => "Query deps PROJECT or why FROM TO, with direct and transitive reasons.",
    "affected" => "Compare exact Git trees using --base REF --head REF --task TASK.",
    "project" => "Materialize --kind full (default) or live; --fresh bypasses work cache.",
    "verify" => "Qualify an isolated full candidate without changing CURRENT.",
    "prepare" => "Qualify and seal a clean committed bundle, then activate CURRENT.",
    "status" => "Read local state (all artifacts by default); --remote only queries evidence.",
    "diff" => "Compare the planned inventory with --kind full, live or bundle.",
    "path" => "Print only the exact path; kinds: full, live, bundle, docs, archive, run.",
    "doctor" => "Inspect toolchain, declarations, state and leases without changing files.",
    "docs-check" => "Statically inspect documentation in DIR (no JavaScript execution).",
    "lint" => "Check source runtime environment policy.",
    "release-plan" =>
      "Order actual publication dependencies; --no-check reports unsatisfied constraints.",
    "track" => "Track a pinned bundle; --tag NAME and --tag-release are exclusive.",
    "verify-tag" => "Verify an annotated receipt TAG and its Git tree without a manifest.",
    "stage" => "Create a distinct writable review run from a pinned bundle.",
    "publish" => "Submit exact qualified archives; --dry-run performs no remote writes.",
    "reconcile" => "Read authoritative remote evidence for an explicit --identity.",
    "archive" => "Copy a sealed bundle exactly; --all requires --current.",
    "gc" => "List completed-run pruning by default; --apply performs it; --keep defaults to 2.",
    "recover" =>
      "Inspect interruption records; --lease ID explicitly selects a dead owner for recovery."
  }

  def registry, do: @registry

  def help do
    "Usage: mix weld COMMAND [arguments] [options]\n\n" <>
      Enum.map_join(Enum.sort(Map.keys(@registry)), "\n", &"  #{&1}  #{@descriptions[&1]}") <>
      "\n\nRun mix weld help COMMAND for flags. JSON uses weld.result/2."
  end

  def help(command) do
    {_arity, flags} = registry_entry!(command)
    positional = help_positionals(command)
    options = Enum.map_join(@common ++ flags, "\n", &help_option/1)

    "Usage: mix weld #{command}#{positional} [options]\n#{@descriptions[command]}\n\nOptions:\n" <>
      options <> "\n"
  end

  defp help_positionals("query"), do: " deps PROJECT | why FROM TO"
  defp help_positionals("verify-tag"), do: " TAG"
  defp help_positionals("docs-check"), do: " DIR"
  defp help_positionals(_), do: ""

  defp help_option({name, type}) do
    name = name |> to_string() |> String.replace("_", "-")

    suffix =
      case type do
        :string -> " VALUE"
        :integer -> " N"
        :boolean -> " / --no-" <> name
      end

    "  --" <> name <> suffix
  end

  def parse!(command, args) when is_binary(command) and is_list(args) do
    {_arity, flags} = registry_entry!(command)
    reject_duplicate_switches!(args)
    {opts, positional, invalid} = OptionParser.parse(args, strict: @common ++ flags)
    if invalid != [], do: raise(Error, "invalid command options: #{inspect(invalid)}")
    validate_request!(%{command: command, arguments: positional, options: opts})
  end

  def execute(request, overrides \\ []) do
    request = validate_request!(request, overrides)
    started = System.monotonic_time(:millisecond)

    result =
      with_stderr(fn ->
        if request.options[:help],
          do: {:ok, help(request.command)},
          else: dispatch_result(request.command, request.arguments, request.options)
      end)

    if request.options[:verbose],
      do:
        IO.puts(
          :stderr,
          "weld #{request.command}: #{System.monotonic_time(:millisecond) - started}ms; cwd=#{Runner.sanitize(File.cwd!())}"
        )

    result
  rescue
    error in [Error, ArgumentError] ->
      {:error, [diagnostic(:invalid_arguments, Exception.message(error))]}
  end

  defp validate_request!(request, overrides \\ [])

  defp validate_request!(%{command: command} = request, overrides)
       when is_atom(command) or is_binary(command) do
    unless Enum.all?(Map.keys(request), &(&1 in [:command, :arguments, :options])),
      do: raise(Error, "unknown request fields")

    command = to_string(command)
    {arity, flags} = registry_entry!(command)
    args = Map.get(request, :arguments, [])
    opts = Map.get(request, :options, [])

    opts = request_options!(args, opts, overrides)

    unless Enum.all?(opts, &typed_option?(&1, @common ++ flags)),
      do: raise(Error, "unsupported command option or value")

    unless opts[:help] == true or valid_arity?(arity, args),
      do: raise(Error, "invalid arguments for #{command}")

    validate!(command, opts)
    opts = if opts[:reuse], do: Keyword.put(opts, :context, opts[:reuse]), else: opts
    %{command: command, arguments: args, options: opts}
  end

  defp validate_request!(_, _), do: raise(Error, "expected a command request map")

  defp request_options!(args, opts, overrides) do
    unless is_list(args) and Enum.all?(args, &is_binary/1) and Keyword.keyword?(opts) and
             Keyword.keyword?(overrides),
           do: raise(Error, "invalid request arguments/options")

    if Enum.any?([opts, overrides], &duplicate_options?/1),
      do: raise(Error, "duplicate options")

    Keyword.merge(opts, overrides)
  end

  defp duplicate_options?(options) do
    keys = Keyword.keys(options)
    Enum.uniq(keys) != keys
  end

  defp registry_entry!(command),
    do: Map.get(@registry, command) || raise(Error, "unknown command: #{command}")

  defp valid_arity?(:query, ["deps", _]), do: true
  defp valid_arity?(:query, ["why", _, _]), do: true
  defp valid_arity?(:query, _), do: false
  defp valid_arity?(arity, args), do: length(args) == arity

  defp typed_option?({name, value}, flags) do
    case flags[name] do
      :string ->
        is_binary(value) and value != "" and String.valid?(value) and
          not String.contains?(value, <<0>>)

      :boolean ->
        is_boolean(value)

      :integer ->
        is_integer(value)

      nil ->
        false
    end
  end

  defp reject_duplicate_switches!(args) do
    flags =
      args
      |> Enum.take_while(&(&1 != "--"))
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(
        &(&1
          |> String.split("=", parts: 2)
          |> hd()
          |> String.replace_prefix("--no-", "--"))
      )

    if Enum.uniq(flags) != flags, do: raise(Error, "duplicate options")
  end

  defp validate!(command, opts) do
    validate_selection_and_format!(command, opts)
    validate_identity!(opts)
    validate_reuse!(opts)
    validate_mutation!(opts)
    validate_kind!(command, opts)
    unless opts[:help], do: require_options!(command, opts)
  end

  defp validate_selection_and_format!(command, opts) do
    if opts[:artifact] && opts[:all],
      do: raise(Error, "--artifact and --all are mutually exclusive")

    for key <- [:artifact, :run, :lease], opts[key], do: segment!(opts[key], key)
    formats = if command == "graph", do: ~w(text json dot), else: ~w(text json)
    unless (opts[:format] || "text") in formats, do: raise(Error, "unsupported format")

    if opts[:view] && not Map.has_key?(@views, opts[:view]),
      do: raise(Error, "unsupported graph view")
  end

  defp validate_identity!(opts) do
    if opts[:identity] do
      unless Regex.match?(~r/\A[0-9a-f]{64}\z/, opts[:identity]),
        do: raise(Error, "identity must be 64 lower-hex characters")

      if opts[:current] == true or opts[:all] == true,
        do: raise(Error, "identity requires one artifact and is exclusive with --current")
    end
  end

  defp validate_reuse!(opts) do
    if opts[:fresh] && opts[:reuse],
      do: raise(Error, "--fresh and --reuse are mutually exclusive")

    if opts[:reuse] && opts[:context] && opts[:reuse] != opts[:context],
      do: raise(Error, "reuse context mismatch")
  end

  defp validate_mutation!(opts) do
    if opts[:apply] && opts[:dry_run],
      do: raise(Error, "--apply and --dry-run are mutually exclusive")

    if opts[:keep] && opts[:keep] < 0, do: raise(Error, "--keep must be non-negative")

    if opts[:tag] && opts[:tag_release],
      do: raise(Error, "--tag and --tag-release are mutually exclusive")
  end

  defp validate_kind!(command, opts) do
    kind = Keyword.get(opts, :kind, "full")
    validate_allowed_kind!(command, kind)
    validate_pinned_kind!(command, opts[:identity], kind)

    if opts[:run] && kind != "run", do: raise(Error, "--run is only valid with --kind run")
  end

  defp validate_allowed_kind!(command, kind) do
    allowed =
      case command do
        "project" -> ~w(full live)
        "diff" -> ~w(full live bundle)
        "path" -> ~w(full live bundle docs archive run)
        _ -> nil
      end

    if allowed && kind not in allowed, do: raise(Error, "unsupported kind #{kind}")
  end

  defp validate_pinned_kind!(command, identity, kind) when command in ~w(path diff) do
    if identity && kind not in ~w(bundle docs archive),
      do: raise(Error, "identity is only valid for a bundle, docs or archive path")
  end

  defp validate_pinned_kind!(_, _, _), do: :ok

  defp require_options!("affected", opts) do
    if is_nil(opts[:base]) or is_nil(opts[:head]) or
         opts[:task] not in ~w(verify package docs project release),
       do:
         raise(
           Error,
           "affected requires --base, --head and --task verify|package|docs|project|release"
         )
  end

  defp require_options!("reconcile", opts) do
    if is_nil(opts[:identity]), do: raise(Error, "reconcile requires --identity ID")
  end

  defp require_options!("path", opts) do
    if opts[:kind] == "run" and is_nil(opts[:run]),
      do: raise(Error, "--kind run requires --run ID")
  end

  defp require_options!("archive", opts) do
    require_pin!(opts)

    if opts[:all] == true and opts[:current] != true,
      do: raise(Error, "archive --all requires --current")
  end

  defp require_options!(command, opts) when command in ~w(track stage publish),
    do: require_pin!(opts)

  defp require_options!(_, _), do: :ok

  defp require_pin!(opts) do
    if is_nil(opts[:identity]) and opts[:current] != true,
      do: raise(Error, "pass --identity ID or --current explicitly")
  end

  defp segment!(value, key) do
    unless Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value) and value not in [".", ".."],
      do: raise(Error, "invalid --#{key} identifier")
  end

  defp root(opts, optional? \\ false) do
    case opts[:root] || Git.root(File.cwd!()) do
      nil ->
        if(optional?,
          do: File.cwd!(),
          else: raise(Error, "workspace root unavailable outside Git; pass --root or --manifest")
        )

      path ->
        Path.expand(path)
    end
  end

  defp manifest_path(opts) do
    case opts[:manifest] do
      nil -> Path.join(root(opts), "build_support/weld.exs")
      override -> Path.expand(override)
    end
  end

  defp load_manifest!(opts) do
    path = manifest_path(opts)
    unless File.regular?(path), do: raise(Error, "manifest not found: #{path}; use --manifest")
    manifest = Manifest.load!(path, checkout_root: opts[:root])

    if opts[:root] && manifest.repo_root != root(opts),
      do: raise(Error, "manifest workspace does not match --root")

    manifest
  end

  defp selector!(opts) do
    if opts[:root] && opts[:artifact] do
      %{repo_root: root(opts), artifact: opts[:artifact]}
    else
      manifest = load_manifest!(opts)
      artifact = Manifest.artifact!(manifest, opts[:artifact])
      %{repo_root: manifest.repo_root, artifact: artifact.id}
    end
  end

  defp dispatch_result(command, args, opts) do
    {:ok, dispatch(command, args, opts)}
  rescue
    error ->
      if opts[:verbose],
        do: IO.puts(:stderr, Runner.sanitize(Exception.format(:error, error, __STACKTRACE__)))

      {:error, error_diagnostics(error, command, opts[:artifact])}
  end

  defp dispatch("docs-check", [dir], _), do: unwrap!(Weld.DocsSmoke.check(Path.expand(dir)))
  defp dispatch("lint", _, opts), do: unwrap!(Weld.AgentsVerifier.verify(root(opts, true)))

  defp dispatch("gc", _, opts),
    do: GC.prune(root(opts), keep: opts[:keep] || 2, dry_run: opts[:apply] != true)

  defp dispatch("recover", _, opts) do
    if opts[:lease],
      do: Output.recover!(root(opts), lease: opts[:lease], yes: true),
      else: Output.recovery_report(root(opts))
  end

  defp dispatch("setup", _, opts) do
    location =
      if opts[:manifest] || is_nil(opts[:root]),
        do: load_manifest!(opts).repo_root,
        else: root(opts)

    ignore = Path.join(location, ".gitignore")
    before = File.read(ignore)
    Output.setup!(location)

    %{
      path: Output.path(location, []),
      gitignore_changed: File.read(ignore) != before,
      next_action: "Commit the .gitignore change when reported."
    }
  end

  defp dispatch("verify-tag", [tag], opts) do
    location = if opts[:manifest], do: load_manifest!(opts).repo_root, else: root(opts)
    ReleaseStatus.verify_tag(location, tag, opts)
  end

  defp dispatch("affected", _, opts), do: Affected.compare!(manifest_path(opts), opts)
  defp dispatch("doctor", _, opts), do: doctor(opts)

  defp dispatch("release-plan", _, opts) do
    manifest = load_manifest!(opts)
    workspace = Workspace.load!(manifest, opts)

    results =
      Enum.map(Enum.sort(Map.keys(manifest.artifacts)), fn id ->
        try do
          plan =
            Plan.build_from_workspace!(manifest, workspace, artifact: id) |> Plan.ensure_valid!()

          %{
            artifact: id,
            ok: true,
            data: %{
              artifact: id,
              package: plan.artifact.package.name,
              version: plan.artifact.package.version,
              dependencies: Plan.external_deps_for_view(plan, :package)
            }
          }
        rescue
          error ->
            %{artifact: id, ok: false, diagnostics: error_diagnostics(error, "release-plan", id)}
        end
      end)

    failures = Enum.reject(results, & &1.ok)

    if failures != [] do
      %{
        results: results,
        invalid_plan: true,
        diagnostics: Enum.flat_map(failures, & &1.diagnostics)
      }
    else
      artifacts = Enum.map(results, & &1.data)
      constraints = ReleaseOrder.constraints(artifacts)
      order = ReleaseOrder.order(artifacts, constraints)

      if Keyword.get(opts, :check, true) and Enum.any?(constraints, &(not &1.satisfied)),
        do:
          raise(Error,
            code: :unsatisfied_constraint,
            phase: :plan,
            message: "unsatisfied release version constraints",
            details: %{constraints: constraints}
          )

      %{order: Enum.map(order, &Map.delete(&1, :dependencies)), constraints: constraints}
    end
  end

  defp dispatch("status", _, opts) do
    if opts[:root] && opts[:artifact] do
      selector = selector!(opts)
      [ReleaseStatus.status(selector, opts) |> with_next_command(opts, selector.repo_root)]
    else
      manifest = load_manifest!(opts)
      ids = selected_ids(manifest, opts, true)
      workspace = Workspace.load!(manifest, opts)

      Enum.map(ids, fn id ->
        try do
          plan = Plan.build_from_workspace!(manifest, workspace, Keyword.put(opts, :artifact, id))

          ReleaseStatus.status(plan, opts)
          |> with_next_command(
            Keyword.put(opts, :manifest, manifest.manifest_path),
            manifest.repo_root
          )
        rescue
          error ->
            %{
              artifact: id,
              state: :invalid_plan,
              diagnostics: error_diagnostics(error, "status", id),
              next_command: nil
            }
        end
      end)
    end
  end

  defp dispatch("archive", _, opts) when is_list(opts) do
    if opts[:all] do
      manifest = load_manifest!(opts)

      results =
        Enum.map(Enum.sort(Map.keys(manifest.artifacts)), fn id ->
          store_entry(
            "archive",
            %{repo_root: manifest.repo_root, artifact: id},
            Keyword.put(opts, :artifact, id)
          )
        end)

      batch_result(results)
    else
      store("archive", selector!(opts), opts)
    end
  end

  defp dispatch(command, _, opts) when command in @store,
    do: store(command, selector!(opts), opts)

  defp dispatch("path", _, opts) when is_list(opts) do
    kind = kind(opts)

    if kind in [:bundle, :docs, :archive, :run] do
      selection = selector!(opts)

      path_result(stored_path!(selection, kind, opts))
    else
      manifest = load_manifest!(opts)
      Manifest.artifact!(manifest, opts[:artifact])
      plan = Plan.build!(manifest, opts)
      path_result(Projector.build_path(plan, kind))
    end
  end

  defp dispatch(command, args, opts) do
    manifest = load_manifest!(opts)

    if command in @batch and opts[:all] do
      dispatch_batch(command, manifest, opts)
    else
      if command in @batch or command == "diff", do: Manifest.artifact!(manifest, opts[:artifact])
      one(command, args, manifest, opts)
    end
  end

  defp stored_path!(selection, :run, opts),
    do: Output.run_path(selection.repo_root, selection.artifact, opts[:run])

  defp stored_path!(selection, kind, opts) do
    bundle = Release.bundle_path(selection, opts[:identity])
    metadata = ReleaseStatus.validate_bundle_integrity!(bundle, Path.basename(bundle))

    case kind do
      :bundle ->
        bundle

      :docs ->
        Path.join(bundle, "docs")

      :archive ->
        Output.path(selection.repo_root, ["archives", selection.artifact, metadata["bundle_id"]])
    end
  end

  defp dispatch_batch(command, manifest, opts) do
    workspace = Workspace.load!(manifest, opts)
    revision = Git.revision(manifest.repo_root)
    ids = manifest.artifacts |> Map.keys() |> Enum.sort()

    {results, _stopped} =
      Enum.map_reduce(ids, false, fn id, stopped ->
        options = opts |> Keyword.delete(:all) |> Keyword.put(:artifact, id)
        dispatch_batch_entry(command, manifest, workspace, revision, options, stopped)
      end)

    batch_result(results)
  end

  defp dispatch_batch_entry(_command, _manifest, _workspace, _revision, opts, true) do
    id = opts[:artifact]

    error =
      diagnostic(:inputs_changed, "source changed during batch; remaining writes stopped",
        artifact: id
      )

    {%{artifact: id, ok: false, diagnostics: [error]}, true}
  end

  defp dispatch_batch_entry(command, manifest, workspace, revision, opts, false) do
    result = batch_entry(command, manifest, workspace, revision, opts)
    changed = Enum.any?(Map.get(result, :diagnostics, []), &(&1.code == :inputs_changed))
    {result, changed}
  end

  defp selected_ids(manifest, opts, all_default?) do
    cond do
      opts[:artifact] -> [Manifest.artifact!(manifest, opts[:artifact]).id]
      opts[:identity] -> [Manifest.artifact!(manifest, nil).id]
      opts[:all] || all_default? -> Enum.sort(Map.keys(manifest.artifacts))
      true -> [Manifest.artifact!(manifest, nil).id]
    end
  end

  defp batch_entry(command, manifest, workspace, revision, opts) do
    if command != "plan" do
      if Git.revision(manifest.repo_root) != revision,
        do:
          raise(Error,
            code: :inputs_changed,
            phase: :snapshot,
            message: "source revision changed during batch"
          )
    end

    plan = Plan.build_from_workspace!(manifest, workspace, opts)
    if command == "plan", do: Plan.ensure_valid!(plan)
    %{artifact: opts[:artifact], ok: true, data: run_from_plan(command, plan, opts)}
  rescue
    error ->
      %{
        artifact: opts[:artifact],
        ok: false,
        diagnostics: error_diagnostics(error, command, opts[:artifact])
      }
  end

  defp batch_result(results),
    do: %{
      results: results,
      partial_failure: Enum.any?(results, &(not &1.ok)),
      diagnostics: Enum.flat_map(results, &Map.get(&1, :diagnostics, []))
    }

  defp store_entry(command, selector, opts) do
    %{artifact: selector.artifact, ok: true, data: store(command, selector, opts)}
  rescue
    error ->
      %{
        artifact: selector.artifact,
        ok: false,
        diagnostics: error_diagnostics(error, command, selector.artifact)
      }
  end

  defp store("track", selector, opts), do: Release.track!(selector, opts)
  defp store("stage", selector, opts), do: Release.stage!(selector, opts)
  defp store("archive", selector, opts), do: Release.archive!(selector, opts)
  defp store("reconcile", selector, opts), do: Release.reconcile!(selector, opts)

  defp store("publish", selector, opts),
    do:
      Release.publish!(
        selector,
        Keyword.put(opts, :allow_stale, opts[:allow_source_drift] == true)
      )

  defp run_from_plan("plan", plan, _), do: Commands.inspect_plan(plan)

  defp run_from_plan("project", plan, opts),
    do: Projector.project!(plan, live: kind(opts) == :live, no_cache: opts[:fresh] == true)

  defp run_from_plan("verify", plan, opts),
    do: Verifier.verify!(plan, Keyword.put(opts, :no_cache, opts[:fresh] == true))

  defp run_from_plan("prepare", plan, opts),
    do: Release.prepare!(plan, Keyword.put(opts, :no_cache, opts[:fresh] == true))

  defp one("graph", _, manifest, opts) do
    options = Keyword.put(opts, :view, Map.fetch!(@views, opts[:view] || "all"))

    if opts[:format] == "dot",
      do: Commands.graph_dot!(manifest, options),
      else: Commands.graph!(manifest, options)
  end

  defp one("query", ["deps", id], manifest, opts),
    do:
      Commands.query_deps!(
        manifest,
        id,
        Keyword.put(opts, :view, Map.fetch!(@views, opts[:view] || "all"))
      )

  defp one("query", ["why", from, to], manifest, opts),
    do:
      Commands.query_why!(
        manifest,
        from,
        to,
        Keyword.put(opts, :view, Map.fetch!(@views, opts[:view] || "all"))
      )

  defp one("diff", _, manifest, opts) do
    plan = Plan.build!(manifest, opts)
    kind = kind(opts)

    target =
      if kind == :bundle do
        bundle = Release.bundle_path(plan, opts[:identity])
        ReleaseStatus.validate_bundle_integrity!(bundle, Path.basename(bundle))
        Path.join(bundle, "project")
      else
        Projector.build_path(plan, kind)
      end

    Diff.compare(plan, target, kind)
  end

  defp one(command, _, manifest, opts),
    do: run_from_plan(command, Plan.build!(manifest, opts), opts)

  defp kind(opts), do: String.to_existing_atom(opts[:kind] || "full")

  defp path_result(path),
    do: %{
      path: path,
      exists: File.exists?(path),
      state: if(File.exists?(path), do: :present, else: :absent)
    }

  defp unwrap!({:ok, result}), do: result

  defp unwrap!({:error, result}),
    do: raise(Error, message: inspect(result), code: :verification_failed, phase: :verify)

  defp doctor(opts) do
    candidate =
      Path.expand(opts[:manifest] || Path.join(root(opts, true), "build_support/weld.exs"))

    {manifest, manifest_errors} = doctor_manifest(candidate, opts)
    location = if manifest, do: manifest.repo_root, else: root(opts, true)

    checks = [
      %{name: :elixir, state: :ok, value: System.version()},
      %{name: :otp, state: :ok, value: System.otp_release()},
      %{name: :git, state: if(System.find_executable("git"), do: :ok, else: :error)},
      %{name: :mix, state: if(System.find_executable("mix"), do: :ok, else: :error)},
      %{
        name: :hex,
        state: if(Code.ensure_loaded?(Hex), do: :ok, else: :warning),
        authentication: :not_checked
      },
      %{
        name: :environment,
        state: :ok,
        value:
          "Subprocess Mix overrides are cleared; only declared public context enters qualification."
      }
    ]

    {state, state_errors} = doctor_state(location)
    {declarations, graph_errors} = doctor_declarations(manifest, opts)

    tool_errors =
      Enum.flat_map(checks, fn check ->
        if check.state == :error,
          do: [diagnostic(:tool_unavailable, "required tool unavailable: #{check.name}")],
          else: []
      end)

    diagnostics = state_errors ++ manifest_errors ++ graph_errors ++ tool_errors

    %{
      root: location,
      checks: checks,
      state: state,
      declarations: declarations,
      diagnostics: diagnostics,
      errors: length(diagnostics)
    }
  end

  defp doctor_manifest(candidate, opts) do
    cond do
      File.regular?(candidate) ->
        {load_manifest!(Keyword.put(opts, :manifest, candidate)), []}

      opts[:manifest] ->
        {nil, [diagnostic(:manifest_missing, "manifest not found: #{candidate}")]}

      true ->
        {nil, []}
    end
  rescue
    error -> {nil, error_diagnostics(error, "doctor", nil)}
  end

  defp doctor_state(location) do
    path = Output.path(location, [])
    if File.exists?(path), do: Output.ensure_managed!(location)
    {Output.recovery_report(location), []}
  rescue
    error -> {nil, error_diagnostics(error, "doctor", nil)}
  end

  defp doctor_declarations(nil, _opts), do: {nil, []}

  defp doctor_declarations(manifest, opts) do
    workspace = Workspace.load!(manifest, opts)

    declarations = %{
      project_ids: workspace.discovery.project_ids,
      artifacts: Enum.sort(Map.keys(manifest.artifacts))
    }

    errors =
      Enum.map(graph_violations(workspace), fn violation ->
        diagnostic(violation.code, violation.message, phase: :plan, project: violation.project)
      end)

    {declarations, errors}
  rescue
    error -> {nil, error_diagnostics(error, "doctor", nil)}
  end

  defp graph_violations(workspace), do: Weld.Graph.violations(workspace.graph)

  defp with_next_command(entry, opts, location) do
    command = render_next_command(next_action(entry), entry, opts, location)

    entry
    |> Map.put(:next_command, command)
    |> Map.put(:manifest_path, opts[:manifest])
    |> Map.put(:repo_root, location)
  end

  defp next_action(entry) do
    existing_action = command_action(entry[:next_command])
    states = [entry[:package_publish], entry[:docs_publish]]

    cond do
      entry[:integrity] == :corrupt or entry[:state] == :corrupt_bundle -> nil
      Enum.any?(states, &(&1 in ["conflict", :conflict])) -> nil
      existing_action in ~w(prepare publish track archive reconcile) -> existing_action
      entry[:state] != :ready -> "prepare"
      entry[:has_tarball] -> "publish"
      true -> "track"
    end
  end

  defp command_action("mix weld " <> rest), do: rest |> String.split() |> hd()
  defp command_action(_), do: nil

  defp render_next_command(nil, _entry, _opts, _location), do: nil

  defp render_next_command(action, entry, opts, location) do
    locator =
      if opts[:manifest],
        do: ["--manifest", Path.expand(opts[:manifest])],
        else: ["--root", location]

    selection = ["--artifact", entry.artifact]

    pin =
      if action in ~w(publish track archive reconcile),
        do: ["--identity", entry.identity],
        else: []

    extra = if action == "publish", do: ["--dry-run"], else: []
    "mix weld " <> action <> " " <> render_args(locator ++ selection ++ pin ++ extra)
  end

  defp render_args(args),
    do:
      Enum.map_join(args, " ", fn value ->
        if String.starts_with?(value, "--"), do: value, else: quote_arg(value)
      end)

  def quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  def error_diagnostics(%Error{diagnostics: errors}, _command, _artifact) when is_list(errors),
    do: errors

  def error_diagnostics(error, command, artifact) do
    message = Runner.sanitize(Exception.message(error))
    {code, phase, details} = diagnostic_details(error, command, message)
    [diagnostic(code, message, phase: phase, artifact: artifact, details: details)]
  end

  defp diagnostic_details(%Error{} = error, command, message) do
    {error.code || diagnostic_code(error, command, message), error.phase || :command,
     error.details || %{}}
  end

  defp diagnostic_details(error, command, message),
    do: {diagnostic_code(error, command, message), :command, %{}}

  defp diagnostic_code(error, command, message) do
    cond do
      manifest_exception?(error) ->
        :invalid_manifest

      String.contains?(message, ["inputs_changed", "source changed"]) ->
        :inputs_changed

      String.contains?(message, [
        "invalid manifest",
        "schema",
        "unknown artifact",
        "pass --artifact"
      ]) ->
        :invalid_manifest

      command in ~w(plan graph query release-plan) and
          not String.starts_with?(message, "manifest not found:") ->
        :invalid_plan

      String.contains?(message, ["corrupt", "integrity"]) ->
        :corrupt_bundle

      String.contains?(message, "lease") ->
        :lease_busy

      true ->
        :operation_failed
    end
  end

  defp manifest_exception?(error),
    do: error.__struct__ in [SyntaxError, TokenMissingError, CompileError]

  def diagnostic(code, message, opts \\ []),
    do: %{
      code: code,
      severity: opts[:severity] || :error,
      phase: opts[:phase] || :command,
      artifact: opts[:artifact],
      project: opts[:project],
      source: opts[:source],
      target: opts[:target],
      hint: opts[:hint],
      details: opts[:details] || %{},
      message: message
    }

  def exit_status(command, {:error, diagnostics}) do
    cond do
      Enum.any?(
        diagnostics,
        &(to_string(diagnostic_field(&1, :code)) in ~w(unknown_publish_outcome publication_conflict conflict))
      ) ->
        4

      command == "doctor" ->
        3

      Enum.any?(
        diagnostics,
        &(to_string(diagnostic_field(&1, :phase)) in ~w(manifest plan) or
              to_string(diagnostic_field(&1, :code)) in ~w(invalid_arguments invalid_request invalid_manifest invalid_plan unknown_project dependency_cycle duplicate_package unsatisfied_constraint duplicate_app conflicting_project_identity invalid_project_facts))
      ) ->
        2

      true ->
        3
    end
  end

  def exit_status("release-plan", {:ok, %{invalid_plan: true}}), do: 2

  def exit_status(_command, {:ok, %{partial_failure: failure}}) when failure not in [nil, false],
    do: 5

  def exit_status(command, {:ok, data}) when is_map(data), do: command_exit_status(command, data)
  def exit_status(_command, {:ok, _data}), do: 0

  defp command_exit_status("doctor", data), do: if(data[:errors] > 0, do: 3, else: 0)

  defp command_exit_status("verify-tag", data) do
    if data[:status] in [:match, :missing_local, "match", "missing_local"], do: 0, else: 3
  end

  defp command_exit_status(command, data) when command in ~w(publish reconcile) do
    if data[:state] in [
         "unknown",
         "conflict",
         "submitting",
         "staged",
         :unknown,
         :conflict,
         :submitting,
         :staged
       ],
       do: 4,
       else: 0
  end

  defp command_exit_status(command, data) when command in ~w(plan graph) do
    if Map.get(data, :violations, []) == [], do: 0, else: 2
  end

  defp command_exit_status(_command, _data), do: 0

  @doc false
  def diagnostic_field(diagnostic, key),
    do: Map.get(diagnostic, key) || Map.get(diagnostic, Atom.to_string(key))

  def envelope(command, result) do
    status = exit_status(command, result)

    case result do
      {:ok, data} ->
        %{
          schema: "weld.result/2",
          command: command,
          ok: status == 0,
          data: data,
          diagnostics: if(is_map(data), do: Map.get(data, :diagnostics, []), else: [])
        }

      {:error, diagnostics} ->
        %{
          schema: "weld.result/2",
          command: command,
          ok: false,
          data: nil,
          diagnostics: diagnostics
        }
    end
  end

  def render_text("path", %{path: path}), do: path
  def render_text(_, value) when is_binary(value), do: value
  def render_text(_, value), do: inspect(value, pretty: true, limit: :infinity)

  # Canonical ordering here is presentation only. Portable identity uses Core.Identity.
  def encode_json(value), do: value |> json_value() |> ordered_json() |> IO.iodata_to_binary()

  defp ordered_json(value) when is_map(value),
    do: [
      "{",
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ":", ordered_json(value)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp ordered_json(value) when is_list(value),
    do: ["[", Enum.map(value, &ordered_json/1) |> Enum.intersperse(","), "]"]

  defp ordered_json(value), do: Jason.encode!(value)
  def json_value(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.sort() |> json_value()
  def json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  def json_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_value(v)} end)

  def json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  def json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  def json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  def json_value(value), do: value

  defp with_stderr(fun) do
    leader = Process.group_leader()
    proxy = spawn(fn -> log_device() end)
    Process.group_leader(self(), proxy)

    try do
      fun.()
    after
      Process.group_leader(self(), leader)
      send(proxy, :stop)
    end
  end

  defp log_device do
    receive do
      {:io_request, from, reply_as, request} ->
        reply = log_request(request)
        send(from, {:io_reply, reply_as, reply})
        log_device()

      :stop ->
        :ok

      _ ->
        log_device()
    end
  end

  defp log_request({:put_chars, _encoding, chars}), do: log_chars(chars)
  defp log_request({:put_chars, chars}), do: log_chars(chars)

  defp log_request({:put_chars, _encoding, module, function, arguments}),
    do: log_chars(apply(module, function, arguments))

  defp log_request({:put_chars, module, function, arguments}),
    do: log_chars(apply(module, function, arguments))

  defp log_request({:requests, requests}),
    do: Enum.reduce(requests, :ok, fn request, _ -> log_request(request) end)

  defp log_request(:getopts), do: {:ok, [binary: false, encoding: :unicode]}
  defp log_request({:setopts, _}), do: :ok
  defp log_request(_), do: {:error, :enotsup}

  defp log_chars(chars) do
    bytes = IO.chardata_to_string(chars)

    text =
      if byte_size(bytes) <= 16 * 1024,
        do: Runner.sanitize(bytes),
        else: "[REDACTED overlong source log]\n"

    IO.write(:stderr, text)
  rescue
    _ -> {:error, :put_chars}
  end
end
