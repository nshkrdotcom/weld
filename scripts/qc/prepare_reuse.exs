# Positive proof reuse and forced requalification, using a disposable locked
# preserve checkout and the same public Release.prepare! path as the CLI.
alias Weld.{Git, Output, Plan, Release, ReleaseInputs}
alias Weld.Shell.Runner

args = case System.argv() do ["--" | args] -> args; args -> args end
{opts, rest} = OptionParser.parse!(args, strict: [output: :string])
unless rest == [] and is_binary(opts[:output]), do: raise("usage: mix run scripts/qc/prepare_reuse.exs -- --output NEW_DIRECTORY")
tool_root = Git.root(File.cwd!())
if tool_root && Git.dirty?(tool_root), do: raise("positive proof reuse requires a clean identified Weld implementation checkout or installed archive")
output = Path.expand(opts[:output])
unless File.mkdir(output) == :ok, do: raise("reuse driver output must be a new directory")
source = Path.join(output, "source")
File.cp_r!(Path.expand("../../test/fixtures/source_project", __DIR__), source)
manifest = Path.join(source, "build_support/weld.exs")
for env <- [:dev, :test] do
  {tail, status} = Runner.run!("mix", ["deps.get"], cd: source, seconds: 900,
    env: Runner.mix_env(source, Path.join(output, "initial-resolution"), env),
    log_path: Path.join(output, "resolve-#{env}.log"))
  unless status == 0, do: raise("standalone lock resolution failed: #{tail}")
end
unless File.regular?(Path.join(source, "mix.lock")), do: raise("fixture needs an actual standalone resolved lock")
{definition, _} = Code.eval_file(manifest)
artifacts = Keyword.update!(definition[:artifacts], :sprout, fn artifact ->
  Keyword.update!(artifact, :preserve, fn preserve ->
    Keyword.update!(preserve, :files, &Enum.uniq(&1 ++ ["mix.lock"]))
  end)
end)
File.write!(manifest, inspect(Keyword.put(definition, :artifacts, artifacts), pretty: true, limit: :infinity) <> "\n")
for command <- [["init"], ["config", "user.name", "Weld QC"], ["config", "user.email", "qc@example.test"]], do: Git.run!(source, command)
Output.setup!(source)
Git.run!(source, ["add", "."])
Git.run!(source, ["commit", "-m", "Disposable locked preserve qualification fixture"])
plan = Plan.build!(manifest)
context = "qc_locked_preserve"
case ReleaseInputs.eligible(plan, context) do
  {:ok, _} -> :ok
  {:ineligible, reasons} -> raise("reuse prerequisites are not met: #{inspect(reasons)}")
end
first = Release.prepare!(plan, context: context)
if first.reused?, do: raise("first preparation unexpectedly reused proof")
stop_if_qualified = fn _, _ -> raise "QC_GATE_EXECUTED" end
second = Release.prepare!(plan, reuse: context, after_gate: stop_if_qualified)
unless second.reused? and second.identity == first.identity, do: raise("eligible locked preserve preparation did not reuse the exact proof")
assert_requalifies = fn options ->
  try do
    Release.prepare!(plan, Keyword.merge([reuse: context, after_gate: stop_if_qualified], options))
    raise "expected fresh qualification did not execute"
  rescue
    exception ->
      unless Exception.message(exception) == "QC_GATE_EXECUTED", do: reraise(exception, __STACKTRACE__)
  end
end
assert_requalifies.([reuse: "changed_public_context"])
assert_requalifies.([fresh: true])
current = Jason.decode!(File.read!(Output.path(source, ["current", "sprout"])))
unless current["bundle_id"] == first.identity, do: raise("failed requalification changed current")
report = %{"schema" => "weld.reuse-observation/2", "bundle_id" => first.identity,
  "locked_preserve_positive_reuse" => true, "context_change_requalifies" => true,
  "fresh_requalifies" => true, "failed_requalification_preserves_current" => true,
  "compiler_id" => Jason.decode!(File.read!(second.release_metadata_path))["compiler_id"]}
File.write!(Path.join(output, "reuse.json"), Jason.encode!(report, pretty: true), [:exclusive])
IO.puts("Recorded positive reuse and forced qualification evidence in #{output}")
