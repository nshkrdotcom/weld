# Installs one exact Weld Hex archive, then qualifies only its installed code in
# a new Mix VM. The copied script is an external harness, never a product import.
defmodule WeldInstalledQualification do
  @driver_file __ENV__.file
  @registry "weld_qualification"
  @scenarios [
    {"components", "library_bundle", "packaging/weld/fixture_bundle.exs"},
    {"flat", "monolith_bundle", "packaging/weld/monolith_bundle.exs"},
    {"preserve", "source_project", "build_support/weld.exs"}
  ]

  def main(["--installed-child", request]), do: child!(request)

  def main(args) do
    {opts, rest} = OptionParser.parse!(args,
      strict: [archive: :string, sha256: :string, output: :string,
        native: :boolean, native_context: :string])

    unless rest == [] and Enum.all?([:archive, :sha256, :output], &is_binary(opts[&1])),
      do: raise("required: --archive EXACT_WELD_TAR --sha256 RAW_SHA256 --output NEW_DIRECTORY [--native] [--native-context JSON]")

    archive = Path.expand(opts[:archive])
    output = Path.expand(opts[:output])
    expected = opts[:sha256]
    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, expected) and sha256(archive) == expected,
      do: raise("Weld archive checksum differs before installation")

    unless File.dir?(Path.dirname(output)) and is_nil(Weld.Git.root(Path.dirname(output))) and
        Weld.Output.checkout(output) == output,
      do: raise("installed qualification output must be outside every Git checkout")
    plain_ancestors!(output)
    unless File.mkdir(output) == :ok, do: raise("output must be a new directory with an existing parent")

    try do
      prerequisites!(opts[:native] == true)
      bootstrap!(archive, expected, output, opts)
    rescue
      error ->
        write!(Path.join(output, "driver-failure.json"), %{
          "schema" => "weld.installed-qc-failure/1", "status" => "failed",
          "message" => Weld.Shell.Runner.sanitize(Exception.message(error))
        })
        reraise error, __STACKTRACE__
    end
  end

  defp bootstrap!(archive, expected, output, opts) do
    observed = Weld.Shell.Hex.package_observation!(archive)
    unless observed.metadata["name"] == "weld" and observed.metadata["app"] == "weld",
      do: raise("the supplied archive must publish the weld package and OTP application")
    version = observed.metadata["version"]
    frozen = Path.join(output, "package.tar")
    File.cp!(archive, frozen)
    unless sha256(frozen) == expected, do: raise("copied Weld archive checksum differs")

    consumer = Path.join(output, "consumer")
    installed = Weld.SmokeApp.archive!(frozen, consumer, nil,
      expected_app: :weld, expected_name: "weld", expected_version: version)
    write!(Path.join(output, "installation.json"), installed)

    scenarios = if opts[:native],
      do: @scenarios ++ [{"native", "native_hex", "build_support/weld.exs"}],
      else: @scenarios
    sources = Path.join(output, "fixtures")
    File.mkdir!(sources)
    fixtures = Enum.map(scenarios, fn {layout, fixture, manifest} ->
      original = Path.expand("../../test/fixtures/" <> fixture, Path.dirname(@driver_file))
      Weld.Output.reject_tree_links!(original)
      before = tree_sha(original)
      copied = Path.join(sources, layout)
      File.cp_r!(original, copied)
      unless tree_sha(copied) == before, do: raise("fixture copy differs: #{layout}")
      {%{"layout" => layout, "source" => copied, "manifest" => manifest,
         "fixture_tree_sha256" => before}, original}
    end)

    driver = Path.join(output, "installed_weld.exs")
    File.cp!(@driver_file, driver)
    request = %{
      "schema" => "weld.installed-qc-request/1", "output" => output,
      "consumer" => consumer, "archive" => frozen, "archive_sha256" => expected,
      "version" => version, "driver" => driver, "driver_sha256" => sha256(driver),
      "fixtures" => Enum.map(fixtures, &elem(&1, 0)),
      "native_context" => native_context!(opts[:native_context])
    }
    request_path = Path.join(output, "request.json")
    write!(request_path, request)
    args = ["run", "--no-start", "--no-compile", driver, "--installed-child", request_path]
    write!(Path.join(output, "invocation.json"), %{
      "command" => "mix", "args" => args, "cwd" => consumer,
      "mix_env" => "dev", "timeout_seconds" => 14_400
    })

    {tail, status} = Weld.Shell.Runner.run!("mix", args,
      cd: consumer, seconds: 14_400,
      env: Weld.Shell.Runner.mix_env(consumer, Path.join(consumer, "cache"), :dev),
      log_path: Path.join(output, "installed-child.log"))
    write!(Path.join(output, "child-process.json"), %{"exit_status" => status, "tail" => tail})
    unless status == 0, do: raise("installed Weld child failed (exit #{status}); inspect installed-child.log")
    unless sha256(archive) == expected and sha256(frozen) == expected,
      do: raise("Weld archive changed during installed qualification")
    for {fixture, original} <- fixtures do
      unless tree_sha(original) == fixture["fixture_tree_sha256"],
        do: raise("original fixture changed: #{fixture["layout"]}")
    end
    result = read!(Path.join(output, "installed-result.json"))
    unless result["status"] == "passed" and result["archive_sha256"] == expected,
      do: raise("installed child did not produce matching successful evidence")
    write!(Path.join(output, "result.json"), Map.merge(result, %{
      "original_fixtures_unchanged" => true, "supplied_archive_unchanged" => true,
      "child_exit_status" => status, "installation_report" => "installation.json"
    }))
    IO.puts("Installed Weld qualification recorded in #{Path.join(output, "result.json")}")
  end

  defp child!(request_path) do
    request = read!(request_path)
    unless request["schema"] == "weld.installed-qc-request/1" and
        Path.expand(File.cwd!()) == request["consumer"] and
        sha256(@driver_file) == request["driver_sha256"],
      do: raise("installed child request, working directory or copied harness differs")
    consumer = request["consumer"]
    ebin = Path.join([consumer, "cache", "build", "dev", "lib", "weld", "ebin"])
    {:module, Weld} = Code.ensure_loaded(Weld)
    unless Path.expand(to_string(:code.which(Weld))) == Path.join(ebin, "Elixir.Weld.beam"),
      do: raise("Weld did not load from the ordinary consumer's installed build")
    _ = Application.load(:weld)
    unless to_string(Application.spec(:weld, :vsn)) == request["version"],
      do: raise("installed Weld application version differs")
    modules = Application.spec(:weld, :modules) || []
    if modules == [], do: raise("installed Weld application has no module evidence")
    module_evidence = Map.new(modules, fn module ->
      {:module, ^module} = Code.ensure_loaded(module)
      path = Path.expand(to_string(:code.which(module)))
      unless Path.dirname(path) == ebin and File.regular?(path),
        do: raise("Weld module loaded outside the installed consumer: #{inspect(module)}")
      {to_string(module), %{"path" => path, "sha256" => sha256(path)}}
    end)
    installation = installed_bytes!(request, module_evidence)
    write!(Path.join(request["output"], "installed-code.json"), installation)
    context_opts = native_context_opts(request["native_context"])
    results = Enum.map(request["fixtures"], &qualify!(&1, request["output"], context_opts))
    unless installation == installed_bytes!(request, module_evidence),
      do: raise("installed Weld package or source changed during qualification")
    for {module, evidence} <- module_evidence do
      unless sha256(evidence["path"]) == evidence["sha256"],
        do: raise("installed Weld BEAM changed: #{module}")
    end
    write!(Path.join(request["output"], "installed-result.json"), %{
      "schema" => "weld.installed-qc/1", "status" => "passed",
      "archive_sha256" => request["archive_sha256"], "version" => request["version"],
      "driver_sha256" => request["driver_sha256"], "installed_code" => installation,
      "layouts" => results
    })
  end

  defp installed_bytes!(request, modules) do
    consumer = request["consumer"]
    version = request["version"]
    expected = request["archive_sha256"]
    case Mix.Project.config()[:deps] do
      [{:weld, requirement, opts}] ->
        unless requirement == "== " <> version and opts[:hex] == "weld" and
            opts[:repo] == @registry and is_nil(opts[:path]) and is_nil(opts[:git]),
          do: raise("installed consumer does not use the exact ordinary Hex dependency")
      _ -> raise("unexpected installed consumer dependencies")
    end
    case Mix.Dep.Lock.read()[:weld] do
      {:hex, name, ^version, _inner, _tools, _deps, @registry, ^expected} when name in [:weld, "weld"] -> :ok
      _ -> raise("installed Weld lock must reference the exact signed Hex archive")
    end
    cached = Path.join([consumer, "cache", "hex-home", "packages", @registry, "weld-#{version}.tar"])
    unless sha256(cached) == expected and sha256(request["archive"]) == expected,
      do: raise("installed Weld cached tar does not match the pinned raw archive")
    observation = Weld.Shell.Hex.package_observation!(cached)
    dependency = Path.join([consumer, "cache", "deps", "weld"])
    entries = Enum.map(observation.entries, & &1["path"])
    :ok = Weld.Shell.Hex.check_package!(cached, dependency, entries, observation.metadata,
      empty_dirs: observation.empty_dirs)
    source = to_string(Weld.module_info(:compile)[:source]) |> Path.expand()
    unless String.starts_with?(source, dependency <> "/") and File.regular?(source),
      do: raise("installed Weld compile source points outside the Hex dependency")
    %{
      "weld_code_path" => to_string(:code.which(Weld)), "module_beams" => modules,
      "weld_compile_source" => source, "weld_source_sha256" => sha256(source),
      "installed_source_entries_sha256" => Weld.Core.Identity.raw(Weld.Core.Identity.canonical(observation.entries)),
      "cached_archive" => cached, "cached_archive_sha256" => expected,
      "consumer_lock_sha256" => sha256(Path.join(consumer, "mix.lock")),
      "ordinary_hex_dependency" => true, "registry" => @registry
    }
  end

  defp qualify!(fixture, output, context_opts) do
    layout = fixture["layout"]
    source = fixture["source"]
    evidence = Path.join(output, layout)
    File.mkdir!(evidence)
    try do
      unless tree_sha(source) == fixture["fixture_tree_sha256"],
        do: raise("copied fixture changed before installed qualification: #{layout}")
      Weld.Output.setup!(source)
      plan = Weld.Plan.build!(Path.join(source, fixture["manifest"]))
      inventory = Weld.Plan.Inventory.portable(plan)
      expected_layout = if layout == "native", do: "preserve", else: layout
      unless inventory["layout"]["name"] == expected_layout,
        do: raise("fixture did not compile the intended layout: #{layout}")
      write!(Path.join(evidence, "plan.json"), inventory)
      full = Weld.Projector.project!(plan, no_cache: true)
      live = Weld.Projector.project!(plan, kind: :live, no_cache: true)

      qualified =
        Weld.Verifier.verify!(
          plan,
          Keyword.merge(context_opts, no_cache: true, context: "installed_weld_" <> layout)
        )
      :ok = Weld.Projector.recheck_inputs!(plan, inventory["input_id"])
      write!(Path.join(evidence, "qualification.json"), qualified.qualification)
      result = %{
        "layout" => layout, "status" => "passed", "artifact" => plan.artifact.id,
        "fixture_tree_sha256" => fixture["fixture_tree_sha256"],
        "plan_id" => inventory["plan_id"], "input_id" => inventory["input_id"],
        "compiler_id" => inventory["compiler_id"],
        "full_project" => full.build_path, "full_tree_id" => full.tree_digest,
        "full_reused" => full.reused?, "live_reused" => live.reused?,
        "live_project" => live.build_path, "live_linked_files" => length(live.linked_files),
        "live_copied_files" => length(live.copied_files),
        "verification_project" => qualified.build_path,
        "qualification_report" => Path.join(evidence, "qualification.json"),
        "gates" => qualified.gates
      }
      write!(Path.join(evidence, "result.json"), result)
      result
    rescue
      error ->
        write!(Path.join(evidence, "failure.json"), %{"layout" => layout, "status" => "failed",
          "message" => Weld.Shell.Runner.sanitize(Exception.message(error))})
        reraise error, __STACKTRACE__
    end
  end

  defp native_context!(nil), do: %{"native_env" => %{}, "public_facts" => %{}}
  defp native_context!(path) do
    context = read!(Path.expand(path))
    unless Enum.sort(Map.keys(context)) == ["native_env", "public_facts"] and
        is_map(context["native_env"]) and is_map(context["public_facts"]),
      do: raise("native context requires native_env and public_facts objects")
    context
  end
  defp native_context_opts(context) do
    [
      native_env: Enum.sort(context["native_env"] || %{}),
      qualification_context: context["public_facts"] || %{}
    ]
  end
  defp prerequisites!(native?) do
    names = ~w(mix elixir git openssl timeout kill) ++ if(native?, do: ~w(cc make), else: [])
    for name <- names do
      unless System.find_executable(name), do: raise("installed qualification prerequisite unavailable: #{name}")
    end
  end
  defp plain_ancestors!(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, :enoent} -> :ok
      _ -> raise("output ancestor must be an ordinary directory: #{path}")
    end
    parent = Path.dirname(path)
    if parent != path, do: plain_ancestors!(parent)
  end
  defp tree_sha(path), do: path |> Weld.Hash.observation() |> Weld.Core.Identity.canonical() |> Weld.Core.Identity.raw()
  defp sha256(path), do: path |> File.stream!(64_000, []) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1)) |> :crypto.hash_final() |> Base.encode16(case: :lower)
  defp write!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true), [:exclusive, :sync])
  defp read!(path) do
    unless File.stat!(path).size <= 1024 * 1024, do: raise("installed qualification JSON exceeds its bound")
    Jason.decode!(File.read!(path))
  end
end

args = case System.argv() do ["--" | rest] -> rest; values -> values end
WeldInstalledQualification.main(args)
