defmodule Weld.Verifier do
  @moduledoc """
  Runs package-level verification against the generated welded Mix project.
  """

  alias Weld.Error
  alias Weld.Hash
  alias Weld.Lockfile
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.SmokeApp

  @spec verify!(Plan.t(), keyword()) :: map()
  def verify!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> verify_locked!(plan, opts) end)
  end

  defp verify_locked!(plan, opts) do
    projection = Projector.project!(plan, opts)
    build_path = projection.build_path
    input_identity = Hash.verification_identity(build_path, projection.verification_files)
    package_identity = Hash.package_identity(build_path, package_patterns(projection))

    workspace = {build_path, cache_root(plan, build_path)}
    verification_results = verify_by_mode!(plan, workspace)
    ensure_verification_inputs!(projection, input_identity, package_identity)

    hex_results = verify_hex!(plan, workspace)
    ensure_verification_inputs!(projection, input_identity, package_identity)
    verification_results = verification_results ++ hex_results
    projection = finalize_projection_identity!(projection)

    lockfile =
      Lockfile.build(
        plan,
        projection
        |> Map.drop([:lockfile_path])
        |> Map.put(:verification_input_identity, input_identity),
        verification_results
      )

    File.write!(projection.lockfile_path, Lockfile.encode!(lockfile))

    tarball_path = tarball_path_for(plan, build_path, hex_results)

    %{
      build_path: build_path,
      lockfile_path: projection.lockfile_path,
      package_files: projection.package_files,
      verification_files: projection.verification_files,
      verification_input_identity: input_identity,
      tarball_path: tarball_path,
      verification_results: verification_results
    }
  end

  defp ensure_verification_inputs!(projection, expected, package_identity) do
    actual = Hash.verification_identity(projection.build_path, projection.verification_files)

    unless actual == expected,
      do:
        raise(
          Error,
          "verification modified projected source or test inputs; refresh and fix the mutating task"
        )

    unless Hash.package_identity(projection.build_path, package_patterns(projection)) ==
             package_identity,
           do:
             raise(
               Error,
               "verification changed the publication inventory; generated files cannot enter a prepared tarball"
             )
  end

  defp package_patterns(projection),
    do: Map.get(projection, :package_patterns, projection.package_files)

  defp finalize_projection_identity!(projection) do
    identity =
      Hash.portable_project_identity(projection.build_path, projection.verification_files)

    path = Weld.Output.source!(projection.build_path, "weld.provenance.json")
    marker = path |> File.read!() |> Jason.decode!()
    temporary = path <> "-" <> Weld.Output.nonce()

    try do
      File.write!(
        temporary,
        Jason.encode!(Map.put(marker, "artifact_id", identity), pretty: true),
        [:exclusive]
      )

      File.chmod!(temporary, Bitwise.band(File.stat!(path).mode, 0o777))
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    Map.put(projection, :artifact_id, identity)
  end

  defp verify_by_mode!(%Plan{artifact: %{mode: :monolith}} = plan, workspace) do
    baseline = run_selected_project_tests!(plan)

    results = [
      baseline,
      run_mix!(workspace, :dev, ["deps.get"]),
      run_mix!(workspace, :dev, ["compile", "--warnings-as-errors"]),
      run_mix!(workspace, :test, ["deps.get"]),
      run_mix!(workspace, :test, ["test"]),
      run_mix!(workspace, :dev, ["docs", "--warnings-as-errors", "--output", "doc"])
    ]

    monolith_test_result = Enum.find(results, &(&1.task == "test"))

    if monolith_test_result.test_count < baseline.test_count do
      raise Error,
            "monolith test surface regressed: monolith ran #{monolith_test_result.test_count} tests but selected-package baseline ran #{baseline.test_count}"
    end

    results
  end

  defp verify_by_mode!(%Plan{} = plan, {build_path, _} = workspace) do
    baseline =
      if plan.artifact.verify.component_tests, do: [run_selected_project_tests!(plan)], else: []

    results = [
      run_mix!(workspace, :dev, ["deps.get"]),
      run_mix!(workspace, :dev, ["deps.compile"]),
      run_mix!(workspace, :dev, ["compile", "--warnings-as-errors", "--no-compile-deps"]),
      run_mix!(workspace, :test, ["deps.get"]),
      run_mix!(workspace, :test, ["test"]),
      run_mix!(workspace, :dev, ["docs", "--warnings-as-errors", "--output", "doc"])
    ]

    if baseline != [] do
      projected = Enum.find(results, &(&1.task == "test"))

      if Map.get(projected, :test_count, -1) < hd(baseline).test_count,
        do: raise(Error, "component test surface regressed in the projected package")
    end

    smoke_results =
      if plan.artifact.verify.smoke.enabled do
        [SmokeApp.verify!(plan, build_path)]
      else
        []
      end

    baseline ++ results ++ smoke_results
  end

  defp verify_hex!(plan, workspace) do
    %{hex_build: build?, hex_publish: publish?} = plan.artifact.verify

    [
      maybe_run_mix!(workspace, :dev, ["hex.build"], build?, reason: :artifact_opted_out),
      maybe_run_mix!(workspace, :dev, ["hex.publish", "--dry-run", "--yes"], build? and publish?,
        reason: if(build?, do: :artifact_opted_out, else: :hex_build_disabled)
      )
    ]
  end

  defp cache_root(plan, build_path) do
    toolchain = "#{System.version()}-otp-#{:erlang.system_info(:otp_release)}"
    projection_id = Hash.sha256_binary(build_path)
    Weld.Output.cache!(plan.manifest.repo_root, projection_id, toolchain)
  end

  defp run_mix!({build_path, build_root}, env, args) do
    env_vars = [
      {"MIX_ENV", Atom.to_string(env)},
      {"MIX_EXS", nil},
      {"MIX_LOCKFILE", nil},
      {"MIX_TARGET", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", Path.join(build_root, "build")},
      {"MIX_DEPS_PATH", Path.join(build_root, "deps")}
    ]

    task = Enum.join(args, " ")
    Mix.shell().info("Weld: MIX_ENV=#{env} mix #{task}")
    started = System.monotonic_time(:millisecond)

    {output, status} =
      System.cmd("mix", args, cd: build_path, env: env_vars, stderr_to_stdout: true)

    if status != 0 do
      raise Error,
            "generated project command failed: MIX_ENV=#{env} mix #{Enum.join(args, " ")}\n\n#{output}"
    end

    elapsed = System.monotonic_time(:millisecond) - started
    Mix.shell().info("Weld: mix #{task} passed in #{elapsed}ms")

    %{task: task, env: env, status: :ok}
    |> maybe_put_test_summary(output)
  end

  defp maybe_run_mix!(build_path, env, args, true, _opts), do: run_mix!(build_path, env, args)

  defp maybe_run_mix!(_build_path, env, args, false, opts) do
    %{task: Enum.join(args, " "), env: env, status: :skipped, reason: opts[:reason]}
  end

  defp run_selected_project_tests!(%Plan{} = plan) do
    stage = Weld.Output.temporary!(plan.manifest.repo_root, "staging")
    mirror = Path.join(stage, "baseline")

    try do
      mirror_source_tree!(plan.manifest.repo_root, mirror)
      run_baseline_tests!(plan, mirror)
    after
      File.rm_rf!(stage)
    end
  end

  defp run_baseline_tests!(plan, mirror) do
    per_project =
      Enum.map(plan.selected_projects, fn project ->
        Mix.shell().info("Weld: testing selected project #{project.id}")

        cache = cache_root(plan, "baseline:" <> project.abs_path)
        project_root = Path.expand(project.id, mirror)
        run_mix!({project_root, cache}, :test, ["deps.get"])

        {output, status} =
          System.cmd("mix", ["test"],
            cd: project_root,
            env: [
              {"MIX_ENV", "test"},
              {"MIX_EXS", nil},
              {"MIX_LOCKFILE", nil},
              {"MIX_TARGET", nil},
              {"MIX_BUILD_PATH", nil},
              {"MIX_BUILD_ROOT", Path.join(cache, "build")},
              {"MIX_DEPS_PATH", Path.join(cache, "deps")}
            ],
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

  defp mirror_source_tree!(source, target) do
    case File.lstat!(source) do
      %{type: :directory} ->
        File.mkdir!(target)

        for name <- File.ls!(source),
            name not in ~w(.git .weld _build deps doc node_modules) do
          mirror_source_tree!(Path.join(source, name), Path.join(target, name))
        end

      %{type: :regular, mode: mode} ->
        File.cp!(source, target)
        File.chmod!(target, Bitwise.band(mode, 0o777))

      _ ->
        raise Error, "baseline verification requires regular source files: #{source}"
    end
  end

  defp maybe_put_test_summary(result, output) do
    case parse_test_summary(output) do
      {:ok, summary} -> Map.merge(result, summary)
      :error -> result
    end
  end

  defp tarball_path_for(plan, build_path, verification_results) do
    if Enum.any?(verification_results, &(&1.task == "hex.build" and &1.status == :ok)) do
      Path.join(build_path, "#{plan.artifact.package.name}-#{plan.artifact.package.version}.tar")
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

      captures = Regex.run(~r/Result:\s+(\d+)\s+passed/, output, capture: :all_but_first) ->
        [test_count] = captures

        {:ok, %{test_count: String.to_integer(test_count), failure_count: 0}}

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
