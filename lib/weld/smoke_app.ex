defmodule Weld.SmokeApp do
  @moduledoc """
  Generates a temporary smoke app that depends on the welded package by local
  path and compiles it.
  """

  alias Weld.Error
  alias Weld.Hash
  alias Weld.Plan

  @spec verify!(Plan.t(), Path.t()) :: map()
  def verify!(%Plan{} = plan, build_path) do
    smoke = plan.artifact.verify.smoke

    unless smoke.entry_file do
      raise Error, "smoke verification requires verify.smoke.entry_file"
    end

    digest = Hash.sha256_binary("#{build_path}:#{smoke.entry_file}") |> binary_part(0, 12)

    smoke_root =
      Path.join([
        plan.manifest.repo_root,
        "tmp",
        "weld_smoke",
        plan.artifact.package.name,
        digest
      ])

    File.rm_rf!(smoke_root)
    File.mkdir_p!(Path.join(smoke_root, "lib"))

    mixfile =
      """
      defmodule WeldSmoke.MixProject do
        use Mix.Project

        def project do
          [
            app: :weld_smoke,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: [
              {:#{plan.artifact.package.otp_app}, path: #{inspect(build_path)}}
            ]
          ]
        end
      end
      """

    File.write!(Path.join(smoke_root, "mix.exs"), mixfile)

    smoke_source = Path.join(plan.manifest.repo_root, smoke.entry_file)
    File.cp!(smoke_source, Path.join([smoke_root, "lib", "smoke.ex"]))

    run!(smoke_root, ["deps.get"])
    run!(smoke_root, ["compile"])

    %{task: "smoke", env: :dev, status: :ok, smoke_root: smoke_root}
  end

  defp run!(smoke_root, args) do
    {output, status} = System.cmd("mix", args, cd: smoke_root, stderr_to_stdout: true)

    if status != 0 do
      raise Error, "smoke app command failed: mix #{Enum.join(args, " ")}\n\n#{output}"
    end
  end
end
