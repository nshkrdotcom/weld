defmodule Weld.FixtureCase do
  @moduledoc false

  alias Weld.Core.Identity
  alias Weld.{Git, Hash, Output}
  alias Weld.Plan.Inventory
  alias Weld.Shell.Hex

  def fixture_path(name) do
    Path.expand(Path.join(["..", "fixtures", name]), __DIR__)
  end

  def manifest_path(fixture, name) do
    Path.join([fixture_path(fixture), "packaging", "weld", "#{name}.exs"])
  end

  def copied_manifest_path(fixture, name) do
    copied_root = copy_fixture(fixture)
    Path.join([copied_root, "packaging", "weld", "#{name}.exs"])
  end

  def unique_tmp_dir(prefix) do
    tmp_root = System.tmp_dir!()
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(tmp_root, "#{prefix}_#{suffix}")
    File.mkdir!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  def copy_fixture(name) do
    target = raw_copy_fixture(name)
    Weld.Output.setup!(target)
    target
  end

  def raw_copy_fixture(name) do
    parent = unique_tmp_dir("weld_fixture_parent")
    target = Path.join(parent, name)
    File.cp_r!(fixture_path(name), target)
    target
  end

  # Synthetic gate observations are confined to fixture construction. This helper
  # builds real canonical evidence and real Hex archives, never production proof.
  def write_tracking_fixture!(root, manifest, opts \\ []) do
    stage = Output.temporary!(root, "staging")
    project = Path.join(stage, "project")
    docs = Path.join(stage, "docs")
    File.mkdir!(project)
    File.mkdir!(docs)
    File.cp!(Path.join(root, "README.md"), Path.join(project, "README.md"))
    File.chmod!(Path.join(project, "README.md"), 0o644)

    File.write!(
      Path.join(docs, "index.html"),
      "<html>" <> Keyword.get(opts, :docs, "Fixture docs") <> "</html>"
    )

    File.chmod!(Path.join(docs, "index.html"), 0o644)
    hex? = Keyword.get(opts, :hex, false)
    compiler = Identity.raw("test-only strict bundle fixture compiler")
    observed = Hash.observation(project)
    docs_observed = Hash.observation(docs)

    inputs = fixture_inputs(observed)
    entries = fixture_entries(observed)
    package = fixture_package!(stage, project, observed, hex?)

    docs_archive = if hex?, do: Hex.freeze_docs!(docs, Path.join(stage, "docs.tar.gz"))
    manifest_path = Path.relative_to(manifest, root)
    [manifest_file] = Hash.entries(root, [manifest_path])

    manifest_input = %{
      "id" => "file:" <> manifest_path,
      "kind" => "file",
      "roles" => ["structure"],
      "owners" => [],
      "fact" => Map.put(manifest_file, "mode", Bitwise.band(File.stat!(manifest).mode, 0o777))
    }

    inputs = Enum.sort_by([manifest_input | inputs], & &1["id"])
    artifact = Weld.Manifest.load!(manifest).artifacts["fixture_bundle"]

    normalized_artifact = %{
      "id" => artifact.id,
      "mode" => Atom.to_string(artifact.mode),
      "package" => %{"name" => artifact.package.name, "version" => artifact.package.version}
    }

    inventory = %{
      "schema" => "weld.inventory/2",
      "artifact" => "fixture_bundle",
      "compiler_id" => compiler,
      "input_id" => nil,
      "plan_id" => nil,
      "normalized_metadata" => %{"artifact" => normalized_artifact},
      "contexts" => %{},
      "selection" => %{
        "dependency_members" => ["fixture"],
        "compiled_owners" => ["fixture"],
        "verification_only" => [],
        "inventory_only" => [],
        "excluded" => [],
        "reasons" => []
      },
      "dependencies" => [],
      "inputs" => inputs,
      "watches" => [manifest_input["id"]],
      "entries" => entries,
      "layout" => %{"name" => "components", "empty_dirs" => observed["empty_dirs"]},
      "qualification_policy" => %{
        "artifact_tests" => [],
        "component_tests" => false,
        "hex_build" => hex?,
        "hex_publish_check" => false,
        "smoke" => nil,
        "context" => []
      },
      "lock_slot" => %{"path" => "mix.lock", "policy" => "none"},
      "frozen_project" => observed["entries"],
      "empty_dirs" => observed["empty_dirs"],
      "package_entries" => package && package.entries,
      "package_metadata" => package && package.metadata,
      "docs_entries" => docs_observed["entries"],
      "docs_empty_dirs" => docs_observed["empty_dirs"]
    }

    inventory = Map.put(inventory, "input_id", Inventory.input_id(inventory))

    inventory =
      Map.put(inventory, "plan_id", Inventory.plan_id(inventory))
      |> Inventory.validate_portable!()

    source = %{
      "git_algorithm" => Git.object_format(root),
      "commit" => Git.revision(root),
      "manifest_path" => manifest_path,
      "manifest_sha256" => manifest_file["sha256"]
    }

    package_id =
      if package,
        do:
          Identity.digest("package", %{
            "entries" => package.entries,
            "metadata" => package.metadata
          })

    archive_sha256 = if hex?, do: Hash.sha256_file(Path.join(stage, "package.tar"))
    docs_id = Identity.digest("docs", docs_observed)

    gates = fixture_gates(hex?, package, package_id, archive_sha256, docs_id, docs_archive)

    proof = %{
      "schema" => "weld.qualification/2",
      "plan_id" => inventory["plan_id"],
      "project_id" => Identity.digest("project", observed),
      "package_id" => package_id,
      "archive_sha256" => archive_sha256,
      "docs_id" => docs_id,
      "docs_archive_sha256" => docs_archive && docs_archive.sha256,
      "gate_schema" => "weld.gates/2",
      "gates" => gates,
      "lock_sha256" => nil,
      "toolchain" => %{"compiler_id" => compiler, "fixture" => true},
      "trust" =>
        Keyword.get(opts, :trust, %{"verified" => true, "policy" => "synthetic-test-fixture/2"}),
      "context_digest" => nil,
      "source" => source
    }

    proof = Map.put(proof, "qualification_id", Identity.digest("qualification", proof))
    File.write!(Path.join(stage, "inventory.json"), Identity.canonical(inventory))
    File.write!(Path.join(stage, "qualification.json"), Identity.canonical(proof))

    seal_fixture!(root, stage, inventory, proof, hex?)
  end

  defp fixture_inputs(observed) do
    for file <- observed["entries"] do
      %{
        "id" => "file:" <> file["path"],
        "kind" => "file",
        "roles" => ["metadata"],
        "owners" => ["fixture"],
        "fact" => Map.put(file, "mode", if(file["executable"], do: 0o755, else: 0o644))
      }
    end
  end

  defp fixture_entries(observed) do
    for file <- observed["entries"] do
      variant = %{
        "strategy" => "copy",
        "source" => "file:" <> file["path"],
        "content_sha256" => file["sha256"],
        "size" => file["size"],
        "executable" => file["executable"],
        "group" => nil
      }

      %{
        "target" => file["path"],
        "kind" => "file",
        "roles" => ["metadata"],
        "owners" => ["fixture"],
        "origins" => ["file:" <> file["path"]],
        "full" => variant,
        "live" => variant,
        "package" => true,
        "verify" => true
      }
    end
  end

  defp fixture_package!(_stage, _project, _observed, false), do: nil

  defp fixture_package!(stage, project, observed, true) do
    metadata = %{
      "name" => "fixture_bundle",
      "app" => "fixture_bundle",
      "version" => "0.1.0",
      "files" => Enum.map(observed["entries"], & &1["path"]),
      "requirements" => %{},
      "build_tools" => ["mix"]
    }

    files =
      for file <- observed["entries"],
          do: {String.to_charlist(file["path"]), File.read!(Path.join(project, file["path"]))}

    {:ok, %{tarball: bytes}} = :hex_tarball.create(metadata, files)
    File.write!(Path.join(stage, "package.tar"), bytes)
    Hex.package_observation!(Path.join(stage, "package.tar"))
  end

  defp fixture_gates(hex?, package, package_id, archive_sha256, docs_id, docs_archive) do
    for number <- 1..12 do
      id = "G" <> String.pad_leading(to_string(number), 2, "0")
      skip = id in ["G03", "G07", "G09"] or (not hex? and id in ["G08", "G10"])

      facts =
        fixture_gate_facts(id, hex?, package, package_id, archive_sha256, docs_id, docs_archive)

      %{
        "id" => id,
        "status" => if(skip, do: "skip", else: "pass"),
        "facts" => facts,
        "skip_reason" => if(skip, do: "fixture policy disables this gate")
      }
    end
  end

  defp fixture_gate_facts(
         "G08",
         true,
         package,
         package_id,
         archive_sha256,
         _docs_id,
         _docs_archive
       ) do
    %{
      "archive_sha256" => archive_sha256,
      "package_id" => package_id,
      "entries" => length(package.entries)
    }
  end

  defp fixture_gate_facts(
         "G11",
         hex?,
         _package,
         _package_id,
         _archive_sha256,
         docs_id,
         docs_archive
       ) do
    %{
      "docs_id" => docs_id,
      "docs_archive_sha256" => docs_archive && docs_archive.sha256,
      "roundtrip_verified" => hex?,
      "archive_policy" => if(hex?, do: "exact_frozen_payload", else: "non_hex_docs_tree")
    }
  end

  defp fixture_gate_facts(_, _, _, _, _, _, _), do: %{"synthetic_fixture" => true}

  defp seal_fixture!(root, stage, inventory, proof, hex?) do
    descriptor = fn name ->
      %{
        "path" => name,
        "sha256" => Hash.sha256_file(Path.join(stage, name)),
        "size" => File.stat!(Path.join(stage, name)).size
      }
    end

    metadata = %{
      "schema" => "weld.bundle/2",
      "artifact" => "fixture_bundle",
      "layout" => "components",
      "package" => "fixture_bundle",
      "version" => "0.1.0",
      "compiler_id" => inventory["compiler_id"],
      "input_id" => inventory["input_id"],
      "plan_id" => inventory["plan_id"],
      "project_id" => proof["project_id"],
      "qualification_id" => proof["qualification_id"],
      "package_id" => proof["package_id"],
      "archive_sha256" => proof["archive_sha256"],
      "docs_id" => proof["docs_id"],
      "docs_archive_sha256" => proof["docs_archive_sha256"],
      "source" => proof["source"],
      "files" => %{
        "inventory" => descriptor.("inventory.json"),
        "qualification" => descriptor.("qualification.json"),
        "package" => if(hex?, do: descriptor.("package.tar")),
        "docs_archive" => if(hex?, do: descriptor.("docs.tar.gz"))
      }
    }

    id = Weld.Release.identity(metadata)
    metadata = Map.put(metadata, "bundle_id", id)
    File.write!(Path.join(stage, "bundle.json"), Identity.canonical(metadata))

    for name <- ~w(bundle.json inventory.json qualification.json package.tar docs.tar.gz),
        path = Path.join(stage, name),
        File.regular?(path),
        do: File.chmod!(path, 0o644)

    Weld.ReleaseStatus.validate_bundle_integrity!(stage, id)
    bundle = Output.path(root, ["bundles", "fixture_bundle", id])
    File.mkdir_p!(Path.dirname(bundle))
    if File.exists?(bundle), do: File.rm_rf!(stage), else: File.rename!(stage, bundle)

    Output.write_atomic!(
      Output.path(root, ["current", "fixture_bundle"]),
      Identity.canonical(%{
        "schema" => "weld.current/2",
        "artifact" => "fixture_bundle",
        "bundle_id" => id
      })
    )

    %{
      identity: id,
      bundle_path: bundle,
      tarball_path: if(hex?, do: Path.join(bundle, "package.tar")),
      archive_sha256: metadata["archive_sha256"],
      docs_id: metadata["docs_id"],
      metadata: metadata
    }
  end

  def init_git!(repo_root) do
    run!(repo_root, ["init"])

    Weld.Output.setup!(repo_root)
    ignore_generated_files!(repo_root)

    run!(repo_root, ["config", "user.name", "Weld Test"])
    run!(repo_root, ["config", "user.email", "weld@example.test"])
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", "initial"])
  end

  def ignore_generated_files!(repo_root) do
    File.write!(
      Path.join(repo_root, ".git/info/exclude"),
      "\n**/_build/\n**/deps/\n**/mix.lock\n/dist/\n/tmp/\n",
      [:append]
    )
  end

  def init_bare_git!(repo_root) do
    File.rm_rf!(repo_root)
    File.mkdir_p!(repo_root)

    {output, status} =
      System.cmd("git", ["init", "--bare", repo_root], stderr_to_stdout: true)

    if status != 0 do
      raise "git init --bare failed:\n#{output}"
    end
  end

  def commit_all!(repo_root, message) do
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", message])
  end

  def git_output!(repo_root, args) do
    {output, status} = git(repo_root, args)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end

    String.trim(output)
  end

  def branch_exists?(repo_root, branch) do
    {_output, status} =
      git(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"])

    status == 0
  end

  def remote_branch_exists?(repo_root, remote, branch) do
    {_output, status} = git(repo_root, ["ls-remote", "--exit-code", "--heads", remote, branch])
    status == 0
  end

  def tag_exists?(repo_root, tag) do
    {_output, status} = git(repo_root, ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"])
    status == 0
  end

  def git(repo_root, args) do
    System.cmd("git", args, cd: repo_root, stderr_to_stdout: true)
  end

  defp run!(repo_root, args) do
    {output, status} = git(repo_root, args)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end
  end
end
