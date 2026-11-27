Code.require_file("support.exs", __DIR__)
args = case System.argv() do ["--" | args] -> args; args -> args end
{opts, rest} = OptionParser.parse!(args, strict: [archive: :string, sha256: :string, output: :string,
  smoke: :string, native_context: :string, offline_rebuild: :boolean])
unless rest == [] and Enum.all?([:archive, :sha256, :output], &is_binary(opts[&1])),
  do: raise("required: --archive EXACT_TAR --sha256 EXPECTED_SHA --output NEW_DIRECTORY [--smoke FILE] [--offline-rebuild] [--native-context JSON]")
archive = Path.expand(opts[:archive])
output = Path.expand(opts[:output])
unless Weld.Hash.sha256_file(archive) == opts[:sha256], do: raise("archive checksum differs before consumer setup")
if File.exists?(output), do: raise("output must not already exist")
Weld.QC.native_context!(opts[:native_context])
smoke = if opts[:smoke], do: File.read!(opts[:smoke])
result = Weld.SmokeApp.archive!(archive, output, smoke, offline_rebuild: opts[:offline_rebuild] == true)
File.write!(Path.join(output, "consumer-result.json"), Jason.encode!(result, pretty: true), [:exclusive])
IO.puts("Recorded ordinary signed Hex consumption in #{output}")
