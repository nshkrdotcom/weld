defmodule Weld.CandidateRegistryTest do
  use ExUnit.Case, async: false

  alias Mix.Dep.Lock
  alias Weld.{CLI, Error, FixtureCase, Hash, Release, ReleaseInputs, SmokeApp, Verifier}
  alias Weld.Core.Identity
  alias Weld.Shell.Runner
  alias Weld.Workspace.Probe

  test "verify_registry_boundary!/2 fails closed when isolated hex.config is missing or tampered" do
    root = FixtureCase.unique_tmp_dir("registry-boundary")
    pem = :hex_core.default_config().repo_public_key
    key_path = Path.join(root, "public.pem")
    File.write!(key_path, pem)

    registry =
      Runner.candidate_registry!(
        registry_url: "http://127.0.0.1:1234",
        registry_public_key: key_path
      )

    # Deleting the original key file after normalization does not affect the normalized registry.
    File.rm!(key_path)
    assert Runner.candidate_registry!(candidate_registry: registry) == registry

    # Missing hex.config must fail closed.
    assert_raise Error, ~r/differs from selected public inputs/, fn ->
      Verifier.verify_registry_boundary!(root, registry)
    end

    # Valid hex.config passes.
    hex_dir = Path.join([root, "cache", "hex-home"])
    File.mkdir_p!(hex_dir)
    config = Path.join(hex_dir, "hex.config")

    File.write!(
      config,
      :io_lib.format("~tp.~n", [
        {:"$repos", %{"hexpm" => %{url: registry.url, public_key: registry.public_key}}}
      ])
    )

    assert :ok = Verifier.verify_registry_boundary!(root, registry)

    # Tampered hex.config fails closed.
    File.write!(
      config,
      :io_lib.format("~tp.~n", [
        {:"$repos",
         %{
           "hexpm" => %{
             url: "http://127.0.0.1:9999",
             public_key: registry.public_key
           }
         }}
      ])
    )

    assert_raise Error, ~r/differs from selected public inputs/, fn ->
      Verifier.verify_registry_boundary!(root, registry)
    end
  end

  test "candidate registry selection fails closed on incomplete or non-loopback inputs" do
    assert Runner.candidate_registry!() == nil

    assert_raise Error, ~r/requires both/, fn ->
      Runner.candidate_registry!(registry_url: "http://127.0.0.1:1234")
    end

    assert_raise Error, ~r/public PEM/, fn ->
      Runner.candidate_registry!(
        registry_url: "http://127.0.0.1:1234",
        registry_public_key: "/no-such-public-key.pem"
      )
    end

    assert_raise Error, ~r/127.0.0.1/, fn ->
      Runner.candidate_registry!(
        registry_url: "https://example.test",
        registry_public_key: "/no-such-public-key.pem"
      )
    end

    assert_raise Error, ~r/requires both/, fn ->
      CLI.parse!("verify", ["--registry-url", "http://127.0.0.1:1234"])
    end

    assert_raise Error, ~r/127.0.0.1/, fn ->
      CLI.parse!("prepare", [
        "--registry-url",
        "https://example.test",
        "--registry-public-key",
        "/no-such-public-key.pem"
      ])
    end
  end

  @tag integration: true, ci_build: "candidate_registry", timeout: 120_000
  test "fresh Mix homes and the exact archive consumer resolve the same signed unpublished input" do
    root = FixtureCase.unique_tmp_dir("candidate-registry")
    public = Path.join(root, "registry")
    tarballs = Path.join(public, "tarballs")
    File.mkdir_p!(tarballs)
    upstream = package!(tarballs, "weld_candidate_dependency", [])
    downstream = package!(root, "weld_candidate_consumer", [:weld_candidate_dependency])
    project!(root, "weld_registry_builder", [])
    key = Path.join(root, "private.pem")
    {_, 0} = Runner.run!("openssl", ["genrsa", "-out", key, "2048"], cd: root, seconds: 10)

    mix!(root, Path.join(root, "builder-cache"), [
      "hex.registry",
      "build",
      public,
      "--name",
      "hexpm",
      "--private-key",
      key
    ])

    File.rm!(key)
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"weld-candidate-test",
        server_root: to_charlist(public),
        document_root: to_charlist(public)
      )

    on_exit(fn -> :inets.stop(:httpd, server) end)
    port = :httpd.info(server) |> Keyword.fetch!(:port)

    registry_opts = [
      registry_url: "http://127.0.0.1:#{port}",
      registry_public_key: Path.join(public, "public_key")
    ]

    verify_dependency_homes!(root, upstream, registry_opts)
    verify_detached_archive!(root, upstream, downstream, registry_opts)
    verify_candidate_proof!(registry_opts)
    verify_wrong_key!(root, port)
  end

  defp verify_dependency_homes!(root, archive, registry_opts) do
    consumer = Path.join(root, "project")
    project!(consumer, "weld_candidate_project", [:weld_candidate_dependency])
    mix!(consumer, Path.join(root, "first-cache"), ["deps.get"], registry_opts)
    mix!(consumer, Path.join(root, "second-cache"), ["deps.get", "--check-locked"], registry_opts)
    assert_exact_dependency!(consumer, archive)

    cache = Path.join(root, "metadata-cache")

    jobs =
      for env <- Probe.environments(),
          do: {env, Runner.mix_env(consumer, cache, env, registry_opts)}

    observations =
      Probe.observe_independent!(jobs, fn {env, variables} ->
        Probe.project!(consumer, env, env: variables)
      end)

    assert Enum.map(observations, & &1.environment) == Probe.environments()
  end

  defp verify_detached_archive!(root, upstream, downstream, registry_opts) do
    consumer = Path.join(root, "detached")
    result = SmokeApp.archive!(downstream, consumer, nil, registry_opts)
    assert result.archive_sha256 == Hash.sha256_file(downstream)
    assert %{registry_signed: true, lock_verified: true, application_started: true} = result
    assert_exact_dependency!(consumer, upstream)
  end

  defp assert_exact_dependency!(consumer, archive) do
    sha = Hash.sha256_file(archive)

    assert {:hex, :weld_candidate_dependency, "1.0.0", _, _, _, "hexpm", ^sha} =
             Lock.read(Path.join(consumer, "mix.lock"))[:weld_candidate_dependency]
  end

  defp verify_candidate_proof!(registry_opts) do
    _ = Mix.Hex.start()
    trust = ReleaseInputs.registry_trust(registry_opts)
    assert trust["policy"] == "isolated-signed-candidate-hex/1"
    assert trust["verified"] and trust["signature_verification"] and trust["origin_verification"]
    refute trust["tls_peer_verification"]

    assert trust["public_key_sha256"] ==
             Identity.raw(Runner.candidate_registry!(registry_opts).public_key)

    assert trust["endpoint"] == "loopback"

    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Path.expand("../../..", manifest)
    FixtureCase.init_git!(root)
    bundle = FixtureCase.write_tracking_fixture!(root, manifest, hex: true, trust: trust)
    selection = %{repo_root: root, artifact: "fixture_bundle"}

    assert_raise Error, ~r/fresh official prepare/, fn ->
      Release.publish!(selection, identity: bundle.identity)
    end

    assert %{dry_run: true} =
             Release.publish!(selection, identity: bundle.identity, dry_run: true)
  end

  defp verify_wrong_key!(root, port) do
    wrong = Path.join(root, "wrong-public.pem")
    File.write!(wrong, :hex_core.default_config().repo_public_key)
    consumer = Path.join(root, "wrong-key-project")
    project!(consumer, "weld_wrong_key_project", [:weld_candidate_dependency])

    wrong_opts = [
      registry_url: "http://127.0.0.1:#{port}",
      registry_public_key: wrong
    ]

    {_, status} =
      Runner.run!("mix", ["deps.get"],
        cd: consumer,
        seconds: 20,
        env: Runner.mix_env(consumer, Path.join(root, "wrong-key-cache"), :dev, wrong_opts)
      )

    assert status != 0
    refute Map.has_key?(Lock.read(Path.join(consumer, "mix.lock")), :weld_candidate_dependency)
  end

  defp mix!(project, cache, args, opts \\ []) do
    {output, status} =
      Runner.run!("mix", args,
        cd: project,
        seconds: 20,
        env: Runner.mix_env(project, cache, :dev, opts)
      )

    assert status == 0, output
  end

  defp project!(path, name, deps) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), project_source(name, deps))
  end

  defp project_source(name, deps) do
    declarations = Enum.map(deps, &{&1, "== 1.0.0"})

    """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "1.0.0", deps: #{inspect(declarations)}]
      def application, do: []
    end
    """
  end

  defp package!(directory, name, deps) do
    lib = "lib/#{name}.ex"
    files = ["mix.exs", lib]

    requirements =
      Map.new(deps, fn dep ->
        {to_string(dep),
         %{
           "app" => to_string(dep),
           "requirement" => "== 1.0.0",
           "optional" => false,
           "repository" => "hexpm"
         }}
      end)

    metadata = %{
      "name" => name,
      "app" => name,
      "version" => "1.0.0",
      "files" => files,
      "build_tools" => ["mix"],
      "requirements" => requirements
    }

    source = "defmodule #{Macro.camelize(name)} do\n  def ready?, do: true\nend\n"
    contents = [{~c"mix.exs", project_source(name, deps)}, {to_charlist(lib), source}]
    {:ok, %{tarball: bytes}} = :hex_tarball.create(metadata, contents)
    path = Path.join(directory, "#{name}-1.0.0.tar")
    File.write!(path, bytes)
    path
  end
end
