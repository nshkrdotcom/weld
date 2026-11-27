defmodule Mix.Tasks.Compile.WeldNative do
  use Mix.Task.Compiler
  @recursive true

  def run(_args) do
    for line <- File.read!("checksums.sha256") |> String.split("\n", trim: true) do
      [expected, path] = String.split(line, "  ", parts: 2)
      actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      unless actual == expected, do: Mix.raise("pinned native source checksum differs: #{path}")
    end

    priv = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv)
    File.cp!("data/bootstrap.txt", Path.join(priv, "bootstrap.txt"))
    include = Path.join([to_string(:code.root_dir()), "usr", "include"])

    {output, status} =
      System.cmd("make", ["OUTPUT=" <> priv, "ERL_INCLUDE=" <> include], stderr_to_stdout: true)

    if status != 0, do: Mix.raise("native compile failed: #{output}")
    {:ok, []}
  end
end

defmodule WeldNativeProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :weld_native_probe,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: [:weld_native] ++ Mix.compilers(),
      description: "Pinned C/include/bootstrap qualification fixture",
      deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}],
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://example.test/weld-native-probe"},
        files: ~w(mix.exs Makefile checksums.sha256 c_src data lib README.md LICENSE)
      ],
      docs: [extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
