defmodule Weld.ReleaseTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias Weld.Core.Identity
  alias Weld.FixtureCase
  alias Weld.Plan.Inventory
  alias Weld.Shell.{GC, Hex}

  @tag integration: true, ci_build: "release"
  test "prepares, archives and tracks a reproducible release bundle" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(repo_root)
    manifest_path = Path.join(repo_root, "packaging/weld/fixture_bundle.exs")
    Weld.Commands.project!(manifest_path)

    owner = self()

    gc_barrier = fn
      :prepare_qualified ->
        [record] = Path.wildcard(Path.join(repo_root, ".weld/v2/runs/verify/*/*/run.json"))
        run = Path.dirname(record)
        proof_run = Weld.Output.read_run!(run)
        assert proof_run["phase"] == "completed"

        assert Enum.any?(Weld.Output.leases(repo_root), fn {_path, lease} ->
                 lease["operation"] == "prepare" and lease["id"] == proof_run["lease_id"]
               end)

        collected =
          Task.async(fn -> Weld.Shell.GC.prune(repo_root, keep: 0, dry_run: false) end)
          |> Task.await(30_000)

        assert run in collected.active
        refute run in collected.removed
        assert File.regular?(Path.join(run, "project/mix.exs"))
        send(owner, :qualified_run_retained)

      _ ->
        :ok
    end

    prepared = Weld.Commands.release_prepare!(manifest_path, failpoint: gc_barrier)
    assert_receive :qualified_run_retained

    assert File.dir?(prepared.bundle_path)
    assert prepared.identity =~ ~r/^[0-9a-f]{64}$/

    assert prepared.bundle_path ==
             Path.join([repo_root, ".weld/v2/bundles", "fixture_bundle", prepared.identity])

    assert Weld.Commands.release_bundle_path!(manifest_path) == prepared.bundle_path
    assert File.regular?(prepared.release_metadata_path)
    assert File.regular?(prepared.tarball_path)
    assert File.regular?(Path.join(prepared.docs_path, "index.html"))
    assert File.read!(Path.join(prepared.docs_path, "readme.html")) =~ "mermaid@11.12.2"
    assert Path.dirname(prepared.docs_path) == prepared.bundle_path

    {:ok, outer} = :erl_tar.extract(String.to_charlist(prepared.tarball_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])
    refute List.keymember?(files, ~c"projection.lock.json", 0)
    assert File.regular?(Path.join(prepared.project_path, "mix.lock"))
    assert File.regular?(Path.join(prepared.project_path, "test/runtime_test.exs"))
    refute File.exists?(Path.join(prepared.project_path, "_build"))
    refute File.exists?(Path.join(prepared.project_path, "deps"))
    refute File.exists?(Path.join(prepared.project_path, "doc"))
    refute File.exists?(Path.join(prepared.project_path, "fixture_bundle-0.1.0.tar"))

    dry_run =
      Weld.Commands.release_publish!(manifest_path,
        identity: prepared.identity,
        dry_run: true
      )

    assert dry_run.dry_run
    refute dry_run.completed?
    assert dry_run.archive_sha256 == Weld.Hash.sha256_file(prepared.tarball_path)

    publish = Weld.Commands.release_stage!(manifest_path, current: true)

    assert publish.project_path ==
             Path.join([
               repo_root,
               ".weld/v2/runs",
               "stage",
               "fixture_bundle",
               publish.run,
               "project"
             ])

    assert Weld.Hash.observation(publish.project_path) ==
             Weld.Hash.observation(prepared.project_path)

    File.mkdir!(Path.join(publish.project_path, "doc"))
    File.write!(Path.join(publish.project_path, "doc/index.html"), "generated documentation")

    assert File.regular?(Path.join(publish.project_path, "doc/index.html"))
    refute File.exists?(Path.join(prepared.project_path, "doc"))

    refreshed = Weld.Commands.release_stage!(manifest_path, current: true, fresh: true)
    assert refreshed.refreshed?
    refute refreshed.project_path == publish.project_path
    refute File.exists?(Path.join(refreshed.project_path, "doc/index.html"))

    archived = Weld.Commands.release_archive!(manifest_path, current: true)

    assert File.dir?(archived.archive_path)
    assert File.regular?(Path.join(archived.archive_path, "bundle.json"))
    tracked = Weld.Commands.release_track!(manifest_path, current: true)
    assert tracked.committed?

    assert Weld.Git.project_id(repo_root, tracked.commit_sha) ==
             Jason.decode!(File.read!(prepared.release_metadata_path))["project_id"]

    refute File.exists?(Path.join(prepared.project_path, "projection.lock.json"))
    refute File.exists?(Path.join(prepared.project_path, "weld.provenance.json"))
    assert_release_metadata(manifest_path, prepared)
    assert_bundle_metadata(repo_root, prepared)
    assert_reproducible(repo_root, prepared)
  end

  test "snapshot failure retains the previous exact current bundle" do
    assert_prepare_failures!(prepare_failure_fixture!(:fixture), [:prepare_snapshot])
  end

  test "release finalization failpoints retain the previous exact current bundle" do
    %{plan: plan, pointer: pointer, old: old, first: first} = prepare_failure_fixture!(:fixture)
    root = plan.manifest.repo_root
    revision = Weld.Git.revision(root)
    verification = canonical_verification!(plan, first)

    for boundary <- [:prepare_qualified, :prepare_copied, :prepare_sealed] do
      assert_raise Weld.Error, "injected failure at #{boundary}", fn ->
        Weld.Output.with_lease(root, "prepare", plan.artifact.id, "prepare", [], fn lease ->
          Weld.Release.finalize_prepared!(plan, verification, revision, lease,
            failpoint: boundary
          )
        end)
      end

      assert File.read!(pointer) == old

      assert Weld.ReleaseStatus.validate_bundle_integrity!(first.bundle_path, first.identity)[
               "bundle_id"
             ] == first.identity
    end
  end

  @tag integration: true,
       ci_build: "release_faults_prepare",
       ci_case: "release_faults_prepare-g02",
       timeout: 1_800_000
  test "G02 frozen input mutation retains the previous exact current bundle" do
    %{plan: plan, pointer: pointer, old: old, first: first} = prepare_failure_fixture!(:fixture)

    IO.puts("Release rollback: G02 frozen input mutation")

    assert_raise Weld.Error, ~r/frozen|changed/, fn ->
      Weld.Release.prepare!(plan,
        fresh: true,
        after_gate: fn
          "G02", project -> File.write!(Path.join(project, "mix.exs"), "mutated by a gate")
          _, _ -> :ok
        end
      )
    end

    assert File.read!(pointer) == old

    assert Weld.ReleaseStatus.validate_bundle_integrity!(first.bundle_path, first.identity)[
             "bundle_id"
           ] == first.identity
  end

  @tag integration: true, ci_build: "release_faults_pointer", timeout: 1_800_000
  test "pointer failure boundaries retain the previous exact current bundle" do
    # Seed a valid canonical prior bundle and roll back a real newly qualified
    # candidate through the full release prepare -> seal transaction.
    assert_prepare_failures!(prepare_failure_fixture!(:fixture), [:pointer_replaced])
  end

  defp canonical_verification!(plan, fixture_bundle) do
    stage = FixtureCase.unique_tmp_dir("weld_canonical_verification")
    project = Path.join(stage, "project")
    File.mkdir!(project)
    projection = Weld.Projector.materialize_verification!(plan, project)
    lock_path = Path.join(project, "mix.lock")
    File.write!(lock_path, "%{}\n")
    File.chmod!(lock_path, 0o644)
    lock_sha = Weld.Hash.sha256_file(lock_path)
    observed = Weld.Hash.observation(project)
    evidence = Weld.ReleaseStatus.evidence!(fixture_bundle.bundle_path)
    inventory = evidence.inventory
    docs_path = Path.join(fixture_bundle.bundle_path, "docs")
    docs_archive = Path.join(fixture_bundle.bundle_path, "docs.tar.gz")

    files =
      for path <- Enum.sort(projection.package_files),
          do: {String.to_charlist(path), File.read!(Path.join(project, path))}

    portable = Weld.Plan.Inventory.portable(plan)

    requirements = %{
      "jason" => %{
        "app" => "jason",
        "optional" => false,
        "repository" => "hexpm",
        "requirement" => "~> 1.4"
      }
    }

    metadata = %{
      "name" => plan.artifact.package.name,
      "app" => Atom.to_string(plan.artifact.package.otp_app),
      "version" => plan.artifact.package.version,
      "files" => Enum.sort(projection.package_files),
      "requirements" => requirements,
      "build_tools" => ["mix"]
    }

    {:ok, %{tarball: bytes}} = :hex_tarball.create(metadata, files)
    tarball = Path.join(stage, "package.tar")
    File.write!(tarball, bytes)
    package = Weld.Shell.Hex.package_observation!(tarball)

    package_id =
      Identity.digest("package", %{
        "entries" => package.entries,
        "metadata" => package.metadata
      })

    archive_sha = Weld.Hash.sha256_file(tarball)

    gates =
      Enum.map(evidence.qualification["gates"], fn
        %{"id" => "G07"} = gate ->
          Map.merge(gate, %{"status" => "pass", "skip_reason" => nil})

        %{"id" => "G08"} = gate ->
          put_in(gate, ["facts"], %{
            "archive_sha256" => archive_sha,
            "package_id" => package_id,
            "entries" => length(package.entries)
          })

        %{"id" => "G12"} = gate ->
          put_in(gate, ["facts", "lock_sha256"], lock_sha)

        gate ->
          gate
      end)

    compiler_id = portable["compiler_id"]

    qualification =
      evidence.qualification
      |> Map.merge(%{
        "project_id" => Identity.digest("project", observed),
        "package_id" => package_id,
        "archive_sha256" => archive_sha,
        "lock_sha256" => lock_sha,
        "toolchain" => %{"compiler_id" => compiler_id, "fixture" => true},
        "gates" => gates
      })

    %{
      build_path: project,
      frozen_project: observed["entries"],
      empty_dirs: observed["empty_dirs"],
      package_entries: package.entries,
      package_metadata: package.metadata,
      docs_path: docs_path,
      docs_entries: inventory["docs_entries"],
      docs_empty_dirs: inventory["docs_empty_dirs"],
      tarball_path: tarball,
      docs_archive_path: docs_archive,
      qualification: qualification
    }
  end

  defp prepare_failure_fixture!(:fixture) do
    root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(root)
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    first = FixtureCase.write_tracking_fixture!(root, manifest, hex: true)
    pointer = Weld.Output.path(root, ["current", "fixture_bundle"])
    old = File.read!(pointer)
    # A new committed provenance identity keeps identical project bytes possible.
    File.write!(Path.join(root, "UNRELATED_RELEASE_NOTE"), "new committed provenance\n")
    FixtureCase.commit_all!(root, "advance qualification provenance")
    %{plan: Weld.Plan.build!(manifest), pointer: pointer, old: old, first: first}
  end

  defp assert_prepare_failures!(
         %{plan: plan, pointer: pointer, old: old, first: first},
         boundaries
       ) do
    for boundary <- boundaries do
      IO.puts("Release rollback: #{boundary}")

      assert_raise Weld.Error, "injected failure at #{boundary}", fn ->
        Weld.Release.prepare!(plan, fresh: true, failpoint: boundary)
      end

      assert File.read!(pointer) == old

      assert Weld.ReleaseStatus.validate_bundle_integrity!(first.bundle_path, first.identity)[
               "bundle_id"
             ] == first.identity
    end
  end

  @tag :slow
  test "projected package bundles preserve root mix tooling config" do
    manifest_path = FixtureCase.copied_manifest_path("package_repo_bundle", "package_repo_bundle")
    FixtureCase.init_git!(Path.expand("../../..", manifest_path))
    projected = Weld.Commands.project!(manifest_path)
    project_path = projected.build_path

    assert File.regular?(Path.join(project_path, ".formatter.exs"))

    {output, status} =
      System.cmd("mix", ["format", "--check-formatted"],
        cd: project_path,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp assert_release_metadata(_manifest_path, prepared) do
    metadata = Jason.decode!(File.read!(prepared.release_metadata_path))
    evidence = Weld.ReleaseStatus.evidence!(prepared.bundle_path)
    assert metadata["source"]["manifest_path"] == "packaging/weld/fixture_bundle.exs"
    refute Path.type(metadata["source"]["manifest_path"]) == :absolute
    assert metadata["bundle_id"] == Weld.Release.identity(metadata)

    assert evidence.qualification["lock_sha256"] ==
             Weld.Hash.sha256_file(Path.join(prepared.project_path, "mix.lock"))

    assert Enum.map(evidence.qualification["gates"], & &1["id"]) ==
             for(number <- 1..12, do: "G" <> String.pad_leading(to_string(number), 2, "0"))

    refute File.exists?(Path.join(prepared.project_path, "weld.provenance.json"))
    refute File.exists?(Path.join(prepared.project_path, "projection.lock.json"))
  end

  defp assert_bundle_metadata(root, prepared) do
    metadata =
      Weld.ReleaseStatus.validate_bundle_integrity!(prepared.bundle_path, prepared.identity)

    assert metadata["schema"] == "weld.bundle/2"
    assert metadata["package"] == "fixture_bundle"
    assert metadata["source"]["commit"] =~ ~r/^[0-9a-f]{40}$/

    assert metadata["source"]["manifest_sha256"] ==
             Weld.Hash.sha256_file(Path.join(root, metadata["source"]["manifest_path"]))

    assert metadata["project_id"] ==
             Identity.digest("project", Weld.Hash.observation(prepared.project_path))

    assert metadata["files"]["package"]["path"] == "package.tar"
    assert metadata["archive_sha256"] == Weld.Hash.sha256_file(prepared.tarball_path)
  end

  defp assert_reproducible(repo_root, prepared_a) do
    checkout = FixtureCase.unique_tmp_dir("weld_checkout")
    FixtureCase.git_output!(repo_root, ["clone", "--quiet", repo_root, checkout])
    Weld.Output.setup!(checkout)
    FixtureCase.ignore_generated_files!(checkout)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        File.cd!(checkout, fn ->
          Mix.Task.rerun("weld", [
            "prepare",
            "--manifest",
            "packaging/weld/fixture_bundle.exs",
            "--no-cache",
            "--format",
            "json"
          ])
        end)
      end)

    assert %{"ok" => true, "data" => %{"bundle_path" => bundle_b}} = Jason.decode!(output)
    assert File.regular?(Path.join(bundle_b, "bundle.json"))
    assert Path.basename(prepared_a.bundle_path) == Path.basename(bundle_b)

    assert Weld.Hash.observation(prepared_a.project_path) ==
             Weld.Hash.observation(Path.join(bundle_b, "project"))

    assert Weld.Hash.observation(prepared_a.docs_path) ==
             Weld.Hash.observation(Path.join(bundle_b, "docs"))

    assert Weld.Hash.sha256_file(prepared_a.tarball_path) ==
             Weld.Hash.sha256_file(Path.join(bundle_b, "package.tar"))
  end

  @tag :slow
  test "track and archive reject a changed prepared project" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(repo_root)
    manifest_path = Path.join(repo_root, "packaging/weld/fixture_bundle.exs")
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    assert %{archive_sha256: nil} = Weld.Commands.release_stage!(manifest_path, current: true)

    bundle = Weld.Commands.release_bundle_path!(manifest_path)
    File.write!(Path.join(bundle, "project/README.md"), "changed after prepare")

    assert_raise Weld.Error, ~r/bundle|inventory|integrity|changed/, fn ->
      Weld.Commands.release_stage!(manifest_path, current: true)
    end

    assert_raise Weld.Error, ~r/bundle|inventory|integrity|changed/, fn ->
      Weld.Commands.release_track!(manifest_path, current: true)
    end

    assert_raise Weld.Error, ~r/bundle|inventory|integrity|changed/, fn ->
      Weld.Commands.release_archive!(manifest_path, current: true)
    end

    refute FixtureCase.branch_exists?(repo_root, "projection/fixture_bundle")
  end

  @tag :slow
  test "release tracking uses projection package-name branches with orphan history" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    result = Weld.Commands.release_track!(manifest_path, current: true)

    assert result.branch == "projection/fixture_bundle"
    assert result.branch_created?
    assert result.committed?
    assert FixtureCase.branch_exists?(repo_root, "projection/fixture_bundle")

    assert result.commit_sha ==
             FixtureCase.git_output!(repo_root, ["rev-parse", "projection/fixture_bundle"])

    assert FixtureCase.git_output!(repo_root, ["rev-list", "--count", "projection/fixture_bundle"]) ==
             "1"

    {_output, status} =
      FixtureCase.git(repo_root, ["merge-base", "HEAD", "projection/fixture_bundle"])

    assert status != 0
  end

  @tag :slow
  test "release tracking is a no-op when the prepared bundle has not changed" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    first = Weld.Commands.release_track!(manifest_path, current: true)
    second = Weld.Commands.release_track!(manifest_path, current: true)

    assert first.committed?
    refute second.branch_created?
    refute second.committed?
    assert second.commit_sha == first.commit_sha
  end

  @tag :slow
  test "release tracking commits a new projection revision when the bundle changes" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    first = Weld.Commands.release_track!(manifest_path, current: true)

    readme_path = Path.join(repo_root, "README.md")
    File.write!(readme_path, File.read!(readme_path) <> "\nprojection drift\n")

    assert_raise Weld.Error, ~r/repo is dirty/, fn ->
      Weld.Commands.release_prepare!(manifest_path)
    end

    FixtureCase.commit_all!(repo_root, "Update release source")
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)
    second = Weld.Commands.release_track!(manifest_path, current: true)

    assert second.committed?
    refute second.branch_created?
    refute second.commit_sha == first.commit_sha
  end

  @tag :slow
  test "release tracking can tag and push the projection branch" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])
    remote_root = FixtureCase.unique_tmp_dir("weld_remote")

    FixtureCase.init_git!(repo_root)
    FixtureCase.init_bare_git!(remote_root)
    FixtureCase.git_output!(repo_root, ["remote", "add", "origin", remote_root])

    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    result =
      Weld.Commands.release_track!(manifest_path,
        current: true,
        tag: "fixture_bundle/rc/2026-04-13-test",
        push: true
      )

    assert result.pushed?
    assert result.tag == "fixture_bundle/rc/2026-04-13-test"
    assert FixtureCase.tag_exists?(repo_root, "fixture_bundle/rc/2026-04-13-test")
    assert FixtureCase.remote_branch_exists?(repo_root, "origin", "projection/fixture_bundle")
  end

  @tag integration: true, ci_build: "internal"
  test "prepares and archives internal-only bundles without a tarball" do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = write_internal_only_monolith_manifest(repo_root)
    write_internal_only_web_test!(repo_root)
    FixtureCase.init_git!(repo_root)
    prepared = Weld.Commands.release_prepare!(manifest_path)

    assert File.dir?(prepared.bundle_path)
    assert File.dir?(prepared.project_path)
    assert File.regular?(prepared.release_metadata_path)
    refute prepared.tarball_path

    metadata =
      prepared.release_metadata_path
      |> File.read!()
      |> Jason.decode!()

    assert metadata["files"]["package"] == nil

    proof = Weld.ReleaseStatus.evidence!(prepared.bundle_path).qualification
    gates = Map.new(proof["gates"], &{&1["id"], &1})

    assert %{"status" => "pass", "facts" => %{"count" => 1, "tests" => [source_test]}} =
             gates["G03"]

    assert source_test["file"] == "apps/web/test/internal_release_test.exs"
    assert source_test["state"] == "pass"

    assert %{"status" => "pass", "facts" => %{"count" => 1, "tests" => [projected_test]}} =
             gates["G05"]

    assert projected_test == %{source_test | "file" => "test/apps_web/internal_release_test.exs"}

    assert Enum.any?(proof["gates"], fn result ->
             result["id"] == "G08" and result["status"] == "skip" and
               is_binary(result["skip_reason"])
           end)

    archived = Weld.Commands.release_archive!(manifest_path, current: true)

    assert File.dir?(archived.archive_path)
    refute File.exists?(Path.join(archived.archive_path, "root_web_monolith-0.1.0.tar"))

    result = Weld.Commands.release_track!(manifest_path, current: true)

    assert result.branch == "projection/root_web_monolith"
    assert result.branch_created?
    assert result.committed?
    assert FixtureCase.branch_exists?(repo_root, "projection/root_web_monolith")
  end

  defp write_internal_only_web_test!(repo_root) do
    test_dir = Path.join(repo_root, "apps/web/test")
    File.mkdir_p!(test_dir)
    File.write!(Path.join(test_dir, "test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(test_dir, "internal_release_test.exs"), """
    defmodule RootWorkspace.InternalReleaseTest do
      use ExUnit.Case, async: true

      test "the web project uses its runtime dependency and test-only support" do
        assert RootWorkspace.Web.page_title() == "core web"
        assert RootWorkspace.TestSupport.helper() == :ok
      end
    end
    """)
  end

  defp write_internal_only_monolith_manifest(repo_root) do
    manifest_path = Path.join([repo_root, "packaging", "weld", "web_monolith.exs"])

    File.write!(
      manifest_path,
      """
      [
        schema: 2,
        workspace: [
          root: "../..",
      projects: [".", "apps/*", "proofs/*", "tooling/*"]
      ],
        classify: [
          tooling: [".", "tooling/test_support"],
          proofs: ["proofs/demo"]
        ],
        publication: [
          internal_only: ["tooling/test_support"]
        ],
        artifacts: [
          web_monolith: [
            layout: :flat,
            flat: [test_support: ["tooling/test_support"]],
            roots: ["apps/web"],
            package: [
              name: "root_web_monolith",
              otp_app: :root_web_monolith,
              version: "0.1.0",
              description: "Root web monolith"
            ],
            files: [
              docs: ["README.md"]
            ],
            verify: [
              hex_build: false, hex_publish_check: false
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end
end
