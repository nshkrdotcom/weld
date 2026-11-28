defmodule Weld.SmokeApp do
  @moduledoc "Detached ordinary Mix consumers for project smoke and exact signed Hex archives."
  alias Mix.Dep.Lock
  alias Weld.{Error, Hash, Output, Plan}
  alias Weld.Shell.{Hex, Runner}

  @spec verify!(Plan.t(), Path.t(), keyword()) :: map()
  def verify!(%Plan{} = plan, project, opts \\ []) do
    Output.with_lease(
      plan.manifest.repo_root,
      "verify",
      plan.artifact.id,
      "smoke:" <> plan.artifact.id,
      [],
      fn lease ->
        run = Output.run!(plan.manifest.repo_root, "verify", plan.artifact.id, lease)

        try do
          result = verify_project!(plan, project, run.path, opts)
          Output.finish_run!(run, "completed")
          result
        rescue
          error ->
            Output.finish_run!(run, "failed", [%{"code" => "smoke_failed"}])
            reraise error, __STACKTRACE__
        end
      end
    )
  end

  def verify_project!(plan, project, root \\ nil, opts \\ []) do
    smoke = plan.artifact.verify.smoke

    unless smoke.entry_file,
      do: raise(Error, "smoke verification requires verify.smoke.entry_file")

    root = root || Output.temporary!(plan.manifest.repo_root, "smoke")
    source = Output.source!(plan.manifest.repo_root, smoke.entry_file) |> File.read!()
    consumer!(root, plan.artifact.package.otp_app, {:path, project}, source)
    run!(root, ["deps.get"], "project-deps", :dev, [], opts)
    run!(root, ["compile", "--warnings-as-errors"], "project-compile", :dev, [], opts)
    %{task: "smoke", env: :dev, status: :ok, consumer: "ordinary_mix_path"}
  end

  @doc "Install the exact archive through the ordinary Hex resolver and a signed loopback registry."
  def verify_archive!(plan, tarball, root, smoke_source \\ nil, opts \\ []) do
    archive!(
      tarball,
      root,
      smoke_source,
      Keyword.merge(opts,
        expected_app: plan.artifact.package.otp_app,
        expected_name: plan.artifact.package.name,
        expected_version: plan.artifact.package.version
      )
    )
  end

  @doc "Standalone G10 harness; does not require a plan or the original source checkout."
  def archive!(tarball, root, smoke_source \\ nil, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:candidate_registry, Runner.candidate_registry!(opts))
      |> Keyword.put(:native_env, Runner.native_env!(opts[:native_env]))
      |> Keyword.drop([:registry_url, :registry_public_key])

    observation = Hex.package_observation!(tarball)
    metadata = observation.metadata
    name = metadata["name"]
    version = metadata["version"]
    app = metadata["app"]

    validate_archive_identity!(app, name, version, opts)
    registry = "weld_qualification"
    consumer!(root, app, {:hex, name, version, registry}, smoke_source)
    public = Path.join(root, "registry")
    tarballs = Path.join(public, "tarballs")
    File.mkdir_p!(tarballs)
    frozen_tar = Path.join(tarballs, "#{name}-#{version}.tar")
    File.cp!(tarball, frozen_tar)
    private = Path.join(root, "registry-private.pem")
    command!("openssl", ["genrsa", "-out", private, "2048"], root, "registry-key", :dev, [], opts)
    File.chmod!(private, 0o600)

    run!(
      root,
      ["hex.registry", "build", public, "--name", registry, "--private-key", private],
      "registry-build",
      :dev,
      [],
      opts
    )

    File.rm!(private)
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"weld-qualification",
        server_root: to_charlist(public),
        document_root: to_charlist(public)
      )

    port = :httpd.info(server) |> Keyword.fetch!(:port)

    try do
      run!(
        root,
        [
          "hex.repo",
          "add",
          registry,
          "http://127.0.0.1:#{port}",
          "--public-key",
          Path.join(public, "public_key")
        ],
        "registry-config",
        :dev,
        [],
        opts
      )

      run!(root, ["deps.get"], "hex-install", :dev, [], opts)
      installed_lock!(root, app, name, version, registry, observation.outer_checksum)

      cached =
        Path.join([root, "cache", "hex-home", "packages", registry, "#{name}-#{version}.tar"])

      unless File.regular?(cached) and Hash.sha256_file(cached) == observation.outer_checksum,
        do: raise(Error, "Hex consumer did not retrieve the exact frozen archive")

      run!(root, ["deps.compile"], "hex-deps-compile", :dev, [], opts)

      run!(
        root,
        ["compile", "--warnings-as-errors", "--no-compile-deps"],
        "hex-compile",
        :dev,
        [],
        opts
      )

      run!(
        root,
        ["test", "--warnings-as-errors", "--seed", "0", "--max-cases", "1"],
        "hex-test",
        :test,
        [],
        opts
      )

      if opts[:offline_rebuild], do: offline_archive_rebuild!(root, server, opts)

      unless Hash.sha256_file(frozen_tar) == observation.outer_checksum and
               Hash.sha256_file(tarball) == observation.outer_checksum,
             do: raise(Error, "archive changed during detached Hex qualification")

      %{
        task: "hex.archive.consumer",
        env: :test,
        status: :ok,
        consumer: "ordinary_mix_hex",
        archive_sha256: observation.outer_checksum,
        registry_signed: true,
        lock_verified: true,
        compile: true,
        application_started: true,
        configured_smoke: not is_nil(smoke_source),
        offline_rebuild: opts[:offline_rebuild] == true
      }
    after
      :inets.stop(:httpd, server)
    end
  end

  defp validate_archive_identity!(app, name, version, opts) do
    for {key, actual} <- [expected_app: app, expected_name: name, expected_version: version],
        opts[key] do
      unless to_string(opts[key]) == actual,
        do: raise(Error, "archive consumer identity mismatch")
    end

    unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, app), do: raise(Error, "invalid archive OTP app")
  end

  defp offline_archive_rebuild!(root, server, opts) do
    :inets.stop(:httpd, server)
    File.rm_rf!(Path.join(root, "cache/build"))
    File.rm_rf!(Path.join(root, "cache/deps"))

    run!(
      root,
      ["deps.get", "--check-locked"],
      "offline-install",
      :dev,
      [{"HEX_OFFLINE", "1"}],
      opts
    )

    run!(root, ["deps.compile"], "offline-native-compile", :dev, [{"HEX_OFFLINE", "1"}], opts)

    run!(
      root,
      ["test", "--warnings-as-errors", "--seed", "0", "--max-cases", "1"],
      "offline-test",
      :test,
      [{"HEX_OFFLINE", "1"}],
      opts
    )
  end

  defp consumer!(root, app, dependency, smoke_source) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    dep =
      case dependency do
        {:path, path} ->
          "{#{inspect(String.to_atom(to_string(app)))}, path: #{inspect(path)}}"

        {:hex, name, version, registry} ->
          "{#{inspect(String.to_atom(to_string(app)))}, #{inspect("== " <> version)}, hex: #{inspect(name)}, repo: #{inspect(registry)}}"
      end

    File.write!(
      Path.join(root, "mix.exs"),
      """
      defmodule WeldDetachedConsumer.MixProject do
        use Mix.Project
        def project, do: [app: :weld_detached_consumer, version: "0.1.0", deps: [#{dep}]]
        def application, do: []
      end
      """,
      [:exclusive]
    )

    if smoke_source, do: File.write!(Path.join(root, "lib/smoke.ex"), smoke_source, [:exclusive])
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n", [:exclusive])

    File.write!(
      Path.join(root, "test/archive_test.exs"),
      """
      defmodule WeldDetachedConsumerTest do
        use ExUnit.Case
        test "exact installed package loads and starts without Weld or source paths" do
          app = #{inspect(String.to_atom(to_string(app)))}
          assert Application.load(app) in [:ok, {:error, {:already_loaded, app}}]
          assert {:ok, _} = Application.ensure_all_started(app)
          for module <- Application.spec(app, :modules) || [] do
            assert {:module, ^module} = Code.ensure_loaded(module)
          end
          if Code.ensure_loaded?(WeldSmoke) do
            cond do
              function_exported?(WeldSmoke, :verify!, 0) -> assert apply(WeldSmoke, :verify!, []) in [:ok, true]
              function_exported?(WeldSmoke, :ready?, 0) -> assert apply(WeldSmoke, :ready?, []) == true
              true -> :ok
            end
          end
        end
      end
      """,
      [:exclusive]
    )
  end

  defp installed_lock!(root, app, name, version, registry, outer_sha) do
    lock = Lock.read(Path.join(root, "mix.lock"))
    entry = Map.get(lock, String.to_atom(app))

    case entry do
      {:hex, actual_name, ^version, _inner, _tools, _dependencies, ^registry, ^outer_sha} ->
        unless to_string(actual_name) == name,
          do: raise(Error, "Hex consumer resolved a different package")

      _ ->
        raise Error,
              "Hex consumer must use the exact signed archive, not a path or Git dependency"
    end
  end

  defp run!(root, arguments, label, env, extra, opts) do
    command!("mix", arguments, root, label, env, extra, opts)
  end

  defp command!(command, arguments, root, label, env, extra, opts) do
    mix_opts =
      opts
      |> Keyword.take([:candidate_registry, :registry_url, :registry_public_key, :native_env])
      |> Keyword.put(:extra, extra)

    {output, status} =
      Runner.run!(command, arguments,
        cd: root,
        seconds: 900,
        env: Runner.mix_env(root, Path.join(root, "cache"), env, mix_opts),
        log_path: Path.join(root, "logs/#{label}.log")
      )

    unless status == 0,
      do: raise(Error, "detached consumer failed (#{label}, exit #{status})\n#{output}")
  end
end
