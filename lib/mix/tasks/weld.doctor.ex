defmodule Mix.Tasks.Weld.Doctor do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Check local toolchain prerequisites for Weld (Elixir, Mix, Git, Hex, Node).
  Pass `--format json` for machine-readable output.
  """

  @shortdoc "Check Weld toolchain prerequisites"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: [format: :string])
    TaskSupport.reject_invalid!(invalid)

    report = %{
      elixir: System.version(),
      otp: System.otp_release(),
      git: System.find_executable("git") != nil,
      mix: System.find_executable("mix") != nil,
      node: System.find_executable("node") != nil,
      hex_loaded: Code.ensure_loaded?(Hex)
    }

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true))

      _ ->
        Mix.shell().info("""
        Elixir: #{report.elixir} (OTP #{report.otp})
        git: #{report.git}
        mix: #{report.mix}
        node: #{report.node}
        hex: #{report.hex_loaded}
        """)
    end
  after
    Mix.Task.reenable("weld.doctor")
  end
end
