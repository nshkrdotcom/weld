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

    verification_results = verify_by_mode!(plan, build_path)

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

  defp verify_by_mode!(%Plan{artifact: %{mode: :monolith}} = plan, build_path) do
    baseline = run_selected_project_tests!(plan)

    results = [
      baseline,
      run_mix!(build_path, :dev, ["deps.get"]),
      run_mix!(build_path, :dev, ["compile", "--warnings-as-errors"]),
      run_mix!(build_path, :test, ["test"]),
      run_mix!(build_path, :dev, ["docs", "--warnings-as-errors"]),
      run_mix!(build_path, :dev, ["hex.build"])
    ]

    monolith_test_result = Enum.find(results, &(&1.task == "test"))

    if monolith_test_result.test_count < baseline.test_count do
      raise Error,
            "monolith test surface regressed: monolith ran #{monolith_test_result.test_count} tests but selected-package baseline ran #{baseline.test_count}"
    end

    results
  end

  defp verify_by_mode!(%Plan{} = plan, build_path) do
    results = [
      run_mix!(build_path, :dev, ["deps.get"]),
      run_mix!(build_path, :dev, ["deps.compile"]),
      run_mix!(build_path, :dev, ["compile", "--warnings-as-errors", "--no-compile-deps"]),
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

    results ++ smoke_results
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
    |> maybe_put_test_summary(output)
  end

  defp run_selected_project_tests!(%Plan{} = plan) do
    per_project =
      Enum.map(plan.selected_projects, fn project ->
        {output, status} =
          System.cmd("mix", ["test"],
            cd: project.abs_path,
            env: [{"MIX_ENV", "test"}],
            stderr_to_stdout: true
          )

        if status != 0 do
          raise Error,
                "selected project test baseline failed for #{project.id}: MIX_ENV=test mix test\n\n#{output}"
        end

        %{test_count: test_count} = parse_test_summary!(output, "selected project #{project.id}")

        %{
          project_id: project.id,
          app: project.app,
          test_count: test_count
        }
      end)

    %{
      task: "selected_tests_baseline",
      env: :test,
      status: :ok,
      test_count: Enum.sum(Enum.map(per_project, & &1.test_count)),
      project_test_counts: per_project
    }
  end

  defp maybe_put_test_summary(result, output) do
    case parse_test_summary(output) do
      {:ok, summary} -> Map.merge(result, summary)
      :error -> result
    end
  end

  defp parse_test_summary(output) do
    cond do
      Regex.match?(~r/There are no tests to run/, output) ->
        {:ok, %{test_count: 0, failure_count: 0}}

      captures =
          Regex.run(~r/(\d+)\s+tests?,\s+(\d+)\s+failures?/, output, capture: :all_but_first) ->
        [test_count, failure_count] = captures

        {:ok,
         %{
           test_count: String.to_integer(test_count),
           failure_count: String.to_integer(failure_count)
         }}

      true ->
        :error
    end
  end

  defp parse_test_summary!(output, label) do
    case parse_test_summary(output) do
      {:ok, summary} ->
        summary

      :error ->
        raise Error, "unable to parse ExUnit summary for #{label}"
    end
  end
end
