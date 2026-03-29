defmodule Weld.Verifier do
  @moduledoc """
  Runs package-level verification against the generated welded Mix project.
  """

  alias Weld.Error
  alias Weld.Lockfile
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.SmokeApp

  @spec verify!(Plan.t()) :: map()
  def verify!(%Plan{} = plan) do
    projection = Projector.project!(plan)
    build_path = projection.build_path

    results = [
      run_mix!(build_path, :dev, ["deps.get"]),
      run_mix!(build_path, :dev, ["compile", "--warnings-as-errors"]),
      run_mix!(build_path, :test, ["test"]),
      run_mix!(build_path, :dev, ["docs", "--warnings-as-errors"]),
      run_mix!(build_path, :dev, ["hex.build"]),
      run_mix!(build_path, :dev, ["hex.publish", "--dry-run", "--yes"])
    ]

    smoke_results =
      if plan.artifact.verify.smoke.enabled do
        [SmokeApp.verify!(plan, build_path)]
      else
        []
      end

    verification_results = results ++ smoke_results

    lockfile =
      Lockfile.build(
        plan,
        Map.take(projection, [
          :build_path,
          :copied_files,
          :package_files,
          :git_revision,
          :tree_digest
        ]),
        verification_results
      )

    File.write!(projection.lockfile_path, Lockfile.encode!(lockfile))

    %{
      build_path: build_path,
      lockfile_path: projection.lockfile_path,
      tarball_path:
        Path.join(
          build_path,
          "#{plan.artifact.package.name}-#{plan.artifact.package.version}.tar"
        ),
      verification_results: verification_results
    }
  end

  defp run_mix!(build_path, env, args) do
    env_vars = [{"MIX_ENV", Atom.to_string(env)}]

    {output, status} =
      System.cmd("mix", args, cd: build_path, env: env_vars, stderr_to_stdout: true)

    if status != 0 do
      raise Error,
            "generated project command failed: MIX_ENV=#{env} mix #{Enum.join(args, " ")}\n\n#{output}"
    end

    %{task: Enum.join(args, " "), env: env, status: :ok}
  end
end
