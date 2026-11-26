defmodule Weld.CLI do
  @moduledoc false
  alias Weld.{
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
  alias Weld.Shell.Diff
  alias Weld.Shell.GC

  @common [manifest: :string, root: :string, format: :string, verbose: :boolean, help: :boolean]
  @selection [artifact: :string, all: :boolean]
  @pin [identity: :string, current: :boolean]
  @registry %{
    "setup" => {0, []},
    "plan" => {0, @selection},
    "graph" => {0, @selection ++ [view: :string]},
    "query" => {:query, @selection ++ [view: :string]},
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
    "release-plan" => {0, [check: :boolean]},
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
  @batch ~w(plan project verify prepare archive affected)
  @views %{
    "all" => :all,
    "runtime" => :runtime,
    "compile" => :compile,
    "docs" => :docs,
    "test" => :test,
    "package" => :package,
    "smoke" => :smoke
  }

  def help,
    do:
      "Usage: mix weld COMMAND [arguments] [options]\nCommands: " <>
        Enum.join(Enum.sort(Map.keys(@registry)), ", ")

  def help(command) do
    case Map.fetch(@registry, command) do
      {:ok, {_, flags}} ->
        "mix weld #{command}\nOptions: " <>
          Enum.map_join(@common ++ flags, " ", fn {name, _} ->
            "--" <> String.replace(to_string(name), "_", "-")
          end)

      :error ->
        raise Error, "unknown command: #{command}"
    end
  end

  def parse!(command, args) do
    {arity, flags} = Map.get(@registry, command) || raise(Error, "unknown command: #{command}")
    {opts, positional, invalid} = OptionParser.parse(args, strict: @common ++ flags)
    if invalid != [], do: raise(Error, "invalid command options: #{inspect(invalid)}")
    if Enum.uniq(Keyword.keys(opts)) != Keyword.keys(opts), do: raise(Error, "duplicate options")

    unless opts[:help] == true or valid_arity?(arity, positional),
      do: raise(Error, "invalid arguments for #{command}")

    %{command: command, arguments: positional, options: opts}
  end

  defp valid_arity?(:query, ["deps", _]), do: true
  defp valid_arity?(:query, ["why", _, _]), do: true
  defp valid_arity?(:query, _), do: false
  defp valid_arity?(arity, args), do: length(args) == arity

  def execute(%{command: command} = request, overrides) do
    command = to_string(command)
    args = Map.get(request, :arguments, [])
    opts = Keyword.merge(Map.get(request, :options, []), overrides)
    {arity, flags} = Map.get(@registry, command) || raise(Error, "unknown command: #{command}")
    unless valid_arity?(arity, args), do: raise(Error, "invalid command arguments")

    unless Enum.all?(opts, &typed_option?(&1, @common ++ flags)),
      do: raise(Error, "unsupported command option or value")

    validate!(command, opts)
    dispatch_result(command, args, opts)
  rescue
    error in [Error, ArgumentError] ->
      {:error, [diagnostic(:invalid_arguments, Exception.message(error))]}
  end

  def execute(_, _), do: {:error, [diagnostic(:invalid_request, "expected command request map")]}

  defp typed_option?({name, value}, flags) do
    case flags[name] do
      :string -> is_binary(value)
      :boolean -> is_boolean(value)
      :integer -> is_integer(value)
      nil -> false
    end
  end

  defp dispatch_result(command, args, opts) do
    {:ok, dispatch(command, args, opts)}
  rescue
    error in [
      Error,
      ArgumentError,
      File.Error,
      KeyError,
      NimbleOptions.ValidationError,
      Mix.Error
    ] ->
      {:error, [diagnostic(:operation_failed, Exception.message(error))]}
  end

  defp validate!(command, opts) do
    if opts[:artifact] && opts[:all],
      do: raise(Error, "--artifact and --all are mutually exclusive")

    validate_pin!(command, opts)
    validate_context!(opts)
    validate_command_options!(command, opts)
  end

  defp validate_pin!(command, opts) do
    identity = opts[:identity]
    if identity, do: validate_identity!(identity, opts)

    if command in ~w(track stage publish archive) and is_nil(identity) and opts[:current] != true,
      do: raise(Error, "pass --identity ID or --current explicitly")
  end

  defp validate_identity!(identity, opts) do
    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, identity),
      do: raise(Error, "identity must be 64 lower-hex characters")

    if opts[:current], do: raise(Error, "--identity and --current are mutually exclusive")
    if opts[:all], do: raise(Error, "identity requires one artifact")
  end

  defp validate_context!(opts) do
    if opts[:fresh] && opts[:reuse],
      do: raise(Error, "--fresh and --reuse are mutually exclusive")

    if opts[:reuse] && opts[:context] && opts[:reuse] != opts[:context],
      do: raise(Error, "reuse context mismatch")
  end

  defp validate_command_options!(command, opts) do
    formats = if command == "graph", do: ~w(text json dot), else: ~w(text json)
    format = opts[:format] || "text"
    if format not in formats, do: raise(Error, "unsupported format")

    if opts[:apply] && opts[:dry_run],
      do: raise(Error, "--apply and --dry-run are mutually exclusive")

    if opts[:view] && not Map.has_key?(@views, opts[:view]),
      do: raise(Error, "unsupported graph view")

    validate_affected!(command, opts)
  end

  defp validate_affected!("affected", opts) do
    if is_nil(opts[:base]) or is_nil(opts[:head]) or
         opts[:task] not in ~w(verify package docs project release),
       do: raise(Error, "affected requires --base, --head and --task")
  end

  defp validate_affected!(_, _), do: :ok

  defp root(opts), do: Path.expand(opts[:root] || Git.root(File.cwd!()) || File.cwd!())

  defp manifest(opts) do
    path =
      case opts[:manifest] do
        nil -> Path.join(root(opts), "build_support/weld.exs")
        override -> Path.expand(override)
      end

    unless File.regular?(path), do: raise(Error, "manifest not found: #{path}; use --manifest")

    if opts[:root] && Manifest.load!(path).repo_root != root(opts),
      do: raise(Error, "manifest workspace does not match --root")

    path
  end

  defp dispatch("doctor", _, _),
    do: %{
      elixir: System.version(),
      otp: System.otp_release(),
      git: not is_nil(System.find_executable("git")),
      mix: not is_nil(System.find_executable("mix")),
      hex_loaded: Code.ensure_loaded?(Hex)
    }

  defp dispatch("docs-check", [dir], _), do: unwrap!(Weld.DocsSmoke.check(dir))
  defp dispatch("lint", _, opts), do: unwrap!(Weld.AgentsVerifier.verify(root(opts)))

  defp dispatch("gc", _, opts),
    do: GC.prune(root(opts), keep: opts[:keep] || 2, dry_run: opts[:apply] != true)

  defp dispatch("recover", _, opts), do: Weld.Output.recovery_report(root(opts))

  defp dispatch("setup", _, opts) do
    root =
      if opts[:manifest] || is_nil(opts[:root]),
        do: Manifest.load!(manifest(opts)).repo_root,
        else: root(opts)

    Output.setup!(root)
    %{path: Output.path(root, [])}
  end

  defp dispatch("verify-tag", [tag], opts) do
    location = if opts[:manifest], do: Manifest.load!(manifest(opts)).repo_root, else: root(opts)
    ReleaseStatus.verify_tag(location, tag, opts)
  end

  defp dispatch("release-plan", _, opts) do
    manifest = Manifest.load!(manifest(opts))
    workspace = Workspace.load!(manifest)

    artifacts =
      for id <- manifest.artifacts |> Map.keys() |> Enum.sort() do
        plan =
          manifest |> Plan.build_from_workspace!(workspace, artifact: id) |> Plan.ensure_valid!()

        %{
          artifact: id,
          package: plan.artifact.package.name,
          version: plan.artifact.package.version,
          dependencies: plan.external_deps
        }
      end

    constraints = ReleaseOrder.constraints(artifacts)

    if Keyword.get(opts, :check, true) and Enum.any?(constraints, &(not &1.satisfied)),
      do: raise(Error, "unsatisfied release version constraints")

    %{
      order:
        artifacts
        |> ReleaseOrder.order(constraints)
        |> Enum.map(&Map.delete(&1, :dependencies)),
      constraints: constraints
    }
  end

  defp dispatch("status", _, opts) do
    Commands.release_status!(manifest(opts), opts)
    |> List.wrap()
    |> Enum.map(&with_next_command/1)
  end

  defp dispatch(command, args, opts) do
    path = manifest(opts)

    if command in @batch && (opts[:all] || (command == "affected" && is_nil(opts[:artifact]))) do
      dispatch_batch(command, args, Manifest.load!(path), opts)
    else
      one(command, args, path, opts)
    end
  end

  defp dispatch_batch(command, args, manifest, opts) do
    revision = Git.revision(manifest.repo_root)
    workspace = if command == "affected", do: nil, else: Workspace.load!(manifest)

    results =
      for id <- manifest.artifacts |> Map.keys() |> Enum.sort() do
        if Git.revision(manifest.repo_root) != revision,
          do: raise(Error, "source changed during batch")

        options = opts |> Keyword.delete(:all) |> Keyword.put(:artifact, id)
        batch_entry(command, args, manifest, workspace, options)
      end

    %{results: results, partial_failure: Enum.any?(results, &(not &1.ok))}
  end

  defp batch_entry(command, args, manifest, workspace, opts) do
    result =
      if command == "affected",
        do: one(command, args, manifest.manifest_path, opts),
        else: run_from_plan(command, Plan.build_from_workspace!(manifest, workspace, opts), opts)

    %{artifact: opts[:artifact], ok: true, data: result}
  rescue
    error in [Error, ArgumentError, File.Error, File.RenameError, KeyError, Mix.Error] ->
      %{
        artifact: opts[:artifact],
        ok: false,
        diagnostics: [diagnostic(:operation_failed, Exception.message(error))]
      }
  end

  defp run_from_plan("plan", plan, _opts), do: Commands.inspect_plan(plan)

  defp run_from_plan("project", plan, opts) do
    Projector.project!(plan,
      live: kind!(opts, ~w(full live)) == :live,
      no_cache: opts[:fresh] == true
    )
  end

  defp run_from_plan("verify", plan, opts), do: Verifier.verify!(plan, opts)

  defp run_from_plan("prepare", plan, opts),
    do: Release.prepare!(plan, opts ++ [no_cache: opts[:fresh] == true])

  defp run_from_plan("archive", plan, opts), do: Release.archive!(plan, opts)

  defp one("plan", _, path, opts), do: Commands.inspect!(path, opts)

  defp one("graph", _, path, opts) do
    opts = graph_options(opts)

    if opts[:format] == "dot",
      do: Commands.graph_dot!(path, opts),
      else: Commands.graph!(path, opts)
  end

  defp one("query", ["deps", project], path, opts),
    do: Commands.query_deps!(path, project, graph_options(opts))

  defp one("query", ["why", from, to], path, opts),
    do: Commands.query_why!(path, from, to, graph_options(opts))

  defp one("affected", _, path, opts), do: Commands.affected!(path, opts)

  defp one("project", _, path, opts),
    do:
      Commands.project!(
        path,
        opts ++ [live: kind!(opts, ~w(full live)) == :live, no_cache: opts[:fresh] == true]
      )

  defp one("verify", _, path, opts),
    do: Commands.verify!(path, opts ++ [no_cache: opts[:fresh] == true])

  defp one("prepare", _, path, opts),
    do: Commands.release_prepare!(path, opts ++ [no_cache: opts[:fresh] == true])

  defp one("track", _, path, opts), do: Commands.release_track!(path, opts)
  defp one("archive", _, path, opts), do: Commands.release_archive!(path, opts)
  defp one("stage", _, path, opts), do: Commands.release_stage!(path, opts)

  defp one("publish", _, path, opts),
    do: Commands.release_publish!(path, opts ++ [allow_stale: opts[:allow_source_drift] == true])

  defp one("reconcile", _, path, opts), do: Release.reconcile!(Plan.build!(path, opts), opts)

  defp one("diff", _, path, opts) do
    plan = Plan.build!(path, opts)
    kind = kind!(opts, ~w(full live bundle))

    target =
      if kind == :bundle,
        do: Path.join(Release.bundle_path(plan, opts[:identity]), "project"),
        else: Projector.build_path(plan, kind)

    Diff.compare(plan, target, kind)
  end

  defp one("path", _, path, opts) do
    plan = Plan.build!(path, opts)
    kind = kind!(opts, ~w(full live bundle docs archive run))

    location =
      case kind do
        kind when kind in [:full, :live] ->
          Projector.build_path(plan, kind)

        :bundle ->
          Release.bundle_path(plan, opts[:identity])

        :docs ->
          Path.join(Release.bundle_path(plan, opts[:identity]), "docs")

        :archive ->
          bundle = Release.bundle_path(plan, opts[:identity])
          metadata = ReleaseStatus.validate_bundle_integrity!(bundle, Path.basename(bundle))
          Path.join(bundle, metadata["tarball_path"] || raise(Error, "no archive"))

        :run ->
          run = opts[:run] || raise(Error, "--kind run requires --run ID")
          Output.path(plan.manifest.repo_root, ["runs", plan.artifact.id, run, "project"])
      end

    %{path: location, exists: File.exists?(location)}
  end

  defp graph_options(opts), do: Keyword.update(opts, :view, :all, &Map.fetch!(@views, &1))

  defp kind!(opts, allowed) do
    kind = opts[:kind] || "full"
    unless kind in allowed, do: raise(Error, "unsupported kind #{kind}")
    String.to_existing_atom(kind)
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, result}), do: raise(Error, inspect(result))

  defp with_next_command(entry) do
    base = "mix weld "

    action =
      if entry.state == :ready,
        do: if(entry.has_tarball, do: "publish", else: "track"),
        else: "prepare"

    pin = if action == "prepare", do: "", else: " --identity " <> entry.identity
    dry_run = if action == "publish", do: " --dry-run", else: ""

    Map.put(
      entry,
      :next_command,
      base <>
        action <>
        " --manifest " <>
        quote_arg(entry.manifest_path) <>
        " --artifact " <> quote_arg(entry.artifact) <> pin <> dry_run
    )
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  def diagnostic(code, message),
    do: %{
      code: code,
      severity: :error,
      phase: :command,
      artifact: nil,
      project: nil,
      source: nil,
      target: nil,
      hint: nil,
      details: %{},
      message: message
    }

  def json_value(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.sort() |> json_value()
  def json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  def json_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_value(v)} end)

  def json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  def json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  def json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  def json_value(value), do: value
end
