Code.require_file("support.exs", __DIR__)
args = case System.argv() do ["--" | args] -> args; args -> args end
{opts, rest} = OptionParser.parse!(args, strict: [output: :string, native_context: :string])
if rest != [] or not opts[:output], do: raise("usage: mix run scripts/qc/qualify_layouts.exs -- --output NEW_DIRECTORY [--native-context FILE]")
Weld.QC.native_context!(opts[:native_context])
Weld.QC.matrix!(opts[:output])
IO.puts("Recorded real layout/native qualification evidence in #{Path.expand(opts[:output])}")
