defmodule Weld.ReleaseStatus do
  @moduledoc """
  The strict immutable bundle reader and read-only release classification.
  Historical pins are validated from their stored evidence independently of
  the current workspace manifest.
  """

  alias Weld.Core.Identity
  alias Weld.{Error, Git, Hash, Output, Plan, ReleaseReceipt}
  alias Weld.Plan.Inventory
  alias Weld.Shell.Hex

  @bundle_keys ~w(schema bundle_id artifact layout package version compiler_id input_id plan_id project_id qualification_id package_id archive_sha256 docs_archive_sha256 docs_id source files)
  @qualification_keys ~w(schema qualification_id plan_id project_id package_id archive_sha256 docs_id docs_archive_sha256 gate_schema gates lock_sha256 toolchain trust context_digest source)
  @inventory_keys ~w(schema artifact input_id plan_id compiler_id normalized_metadata contexts selection dependencies inputs watches entries layout qualification_policy lock_slot frozen_project empty_dirs package_entries package_metadata docs_entries docs_empty_dirs)
  @gate_ids for n <- 1..12, do: "G" <> String.pad_leading(to_string(n), 2, "0")
  @type tag_result :: map()

  @doc "Validate closed canonical evidence, all identities, exact trees and both archives."
  def validate_bundle_integrity!(bundle, expected_id \\ nil) do
    Output.reject_tree_links!(bundle)
    metadata = canonical_file!(Path.join(bundle, "bundle.json"), @bundle_keys, "weld.bundle/2")

    unless Identity.valid?(metadata["bundle_id"]) and
             (is_nil(expected_id) or expected_id == metadata["bundle_id"]) and
             Identity.digest("bundle", Map.delete(metadata, "bundle_id")) == metadata["bundle_id"],
           do: raise(Error, "bundle identity mismatch: #{bundle}")

    validate_bundle_fields!(metadata)

    %{inventory: inventory, qualification: qualification} = evidence!(bundle)
    Inventory.validate_portable!(inventory)

    validate_bindings!(metadata, inventory, qualification)
    validate_files!(bundle, metadata)
    validate_bundle_trees!(bundle, metadata, inventory)
    validate_frozen_plan!(inventory)
    validate_lock!(bundle, inventory, qualification)
    validate_qualification!(qualification, inventory)

    if metadata["package_id"], do: validate_bundle_archives!(bundle, inventory)

    metadata
  rescue
    error in [ArgumentError, File.Error, KeyError, MatchError] ->
      reraise Error,
              [
                message:
                  "bundle failed strict integrity verification: #{bundle}: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp validate_bundle_trees!(bundle, metadata, inventory) do
    project = Hash.observation(Path.join(bundle, "project"))
    docs = Hash.observation(Path.join(bundle, "docs"))

    unless project == %{
             "entries" => inventory["frozen_project"],
             "empty_dirs" => inventory["empty_dirs"]
           } and
             docs == %{
               "entries" => inventory["docs_entries"],
               "empty_dirs" => inventory["docs_empty_dirs"]
             } and
             Identity.digest("project", project) == metadata["project_id"] and
             Identity.digest("docs", docs) == metadata["docs_id"],
           do: raise(Error, "bundle project or documentation inventory differs: #{bundle}")

    validate_modes!(Path.join(bundle, "project"), inventory["frozen_project"])
    validate_modes!(Path.join(bundle, "docs"), inventory["docs_entries"])
  end

  defp validate_bundle_archives!(bundle, inventory) do
    package = Hex.package_observation!(Path.join(bundle, "package.tar"))
    Hex.validate_dependency_metadata!(package.metadata, inventory["dependencies"])

    validate_bundle_directories!(package, inventory["empty_dirs"])

    docs_archive = Hex.docs_observation!(Path.join(bundle, "docs.tar.gz"))

    unless package.entries == inventory["package_entries"] and
             package.metadata == inventory["package_metadata"] and
             docs_archive.entries == inventory["docs_entries"] and
             docs_archive.empty_dirs == inventory["docs_empty_dirs"],
           do: raise(Error, "archive contents disagree with exact bundle inventory")
  end

  defp validate_bundle_directories!(package, planned) do
    unless Enum.all?(package.empty_dirs, &(&1 in planned)) and
             Enum.all?(package.directories, fn directory ->
               directory in package.empty_dirs or
                 Enum.any?(package.entries, &String.starts_with?(&1["path"], directory <> "/")) or
                 Enum.any?(package.empty_dirs, &String.starts_with?(&1, directory <> "/"))
             end),
           do: raise(Error, "package contains unplanned empty or structural directories")
  end

  def evidence!(bundle) do
    %{
      inventory:
        canonical_file!(Path.join(bundle, "inventory.json"), @inventory_keys, "weld.inventory/2"),
      qualification:
        canonical_file!(
          Path.join(bundle, "qualification.json"),
          @qualification_keys,
          "weld.qualification/2"
        )
    }
  end

  def canonical_file!(path, keys, schema) do
    Output.reject_link!(path)

    unless File.stat!(path).size <= 32 * 1024 * 1024,
      do: raise(Error, "evidence file exceeds limit")

    bytes = File.read!(path)

    with {:ok, record} when is_map(record) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(record)) == Enum.sort(keys),
         true <- record["schema"] == schema,
         true <- Identity.canonical(record) == bytes do
      record
    else
      _ -> raise Error, "noncanonical or unsupported evidence schema: #{path}"
    end
  end

  defp validate_bundle_fields!(metadata) do
    ReleaseReceipt.from_bundle(metadata)

    validate_bundle_identity_fields!(metadata)
    validate_bundle_descriptors!(metadata)
  end

  defp validate_bundle_identity_fields!(metadata) do
    required = ~w(input_id plan_id project_id qualification_id compiler_id docs_id)
    package = Enum.map(~w(package_id archive_sha256 docs_archive_sha256), &metadata[&1])

    unless metadata["layout"] in ~w(components flat preserve) and
             Enum.all?(required, &Identity.valid?(metadata[&1])) and
             (Enum.all?(package, &is_nil/1) or Enum.all?(package, &Identity.valid?/1)),
           do: raise(Error, "invalid bundle identity fields")
  end

  defp validate_bundle_descriptors!(metadata) do
    files = metadata["files"]

    unless is_map(files) and
             Enum.sort(Map.keys(files)) == ~w(docs_archive inventory package qualification),
           do: raise(Error, "invalid bundle file envelope")

    for {field, path} <- [
          {"inventory", "inventory.json"},
          {"qualification", "qualification.json"},
          {"package", "package.tar"},
          {"docs_archive", "docs.tar.gz"}
        ] do
      optional = field in ["package", "docs_archive"] and is_nil(metadata["package_id"])
      validate_bundle_descriptor!(files[field], field, path, optional)
    end
  end

  defp validate_bundle_descriptor!(nil, _field, _path, true), do: :ok

  defp validate_bundle_descriptor!(value, field, path, false) when is_map(value) do
    unless Enum.sort(Map.keys(value)) == ~w(path sha256 size) and
             value["path"] == path and Identity.valid?(value["sha256"]) and
             is_integer(value["size"]) and value["size"] >= 0,
           do: raise(Error, "invalid bundle file descriptor: #{field}")
  end

  defp validate_bundle_descriptor!(_, field, _, _),
    do: raise(Error, "invalid bundle file descriptor: #{field}")

  defp validate_bindings!(metadata, inventory, qualification) do
    unless inventory["artifact"] == metadata["artifact"] and
             layout(inventory) == metadata["layout"] and
             Enum.all?(~w(input_id plan_id compiler_id), &(inventory[&1] == metadata[&1])) and
             Inventory.input_id(inventory) == metadata["input_id"] and
             Inventory.plan_id(inventory) == metadata["plan_id"] and
             Enum.all?(
               ~w(plan_id project_id package_id archive_sha256 docs_id docs_archive_sha256 qualification_id source),
               &(qualification[&1] == metadata[&1])
             ) and
             Identity.digest("qualification", Map.delete(qualification, "qualification_id")) ==
               metadata["qualification_id"],
           do: raise(Error, "bundle, inventory and qualification disagree")

    validate_source_binding!(metadata["source"], inventory)
    validate_artifact_binding!(metadata, inventory)
    hex? = inventory["qualification_policy"]["hex_build"]

    unless is_boolean(hex?) and hex? == not is_nil(metadata["package_id"]),
      do: raise(Error, "package payload disagrees with qualification policy")

    if hex? do
      unless is_list(inventory["package_entries"]) and is_map(inventory["package_metadata"]) and
               Identity.digest("package", %{
                 "metadata" => inventory["package_metadata"],
                 "entries" => inventory["package_entries"]
               }) == metadata["package_id"] and
               inventory["package_metadata"]["name"] == metadata["package"] and
               inventory["package_metadata"]["version"] == metadata["version"],
             do: raise(Error, "package identity or metadata mismatch")
    else
      unless is_nil(inventory["package_entries"]) and is_nil(inventory["package_metadata"]),
        do: raise(Error, "disabled package contains publication evidence")
    end
  end

  defp validate_source_binding!(source, inventory) do
    manifest = Enum.find(inventory["inputs"], &(&1["id"] == "file:" <> source["manifest_path"]))

    unless is_map(manifest) and manifest["kind"] == "file" and
             manifest["fact"]["sha256"] == source["manifest_sha256"],
           do: raise(Error, "source provenance disagrees with the manifest input fact")
  end

  defp validate_artifact_binding!(metadata, inventory) do
    normalized = inventory["normalized_metadata"]
    artifact = if is_map(normalized), do: normalized["artifact"]
    package = if is_map(artifact), do: artifact["package"]

    modes = %{
      "package_projection" => "components",
      "monolith" => "flat",
      "source_project" => "preserve"
    }

    unless is_map(artifact) and is_map(package) and artifact["id"] == metadata["artifact"] and
             modes[artifact["mode"]] == metadata["layout"] and
             package["name"] == metadata["package"] and package["version"] == metadata["version"],
           do: raise(Error, "normalized artifact identity disagrees with the bundle")
  end

  defp validate_files!(bundle, metadata) do
    expected =
      ~w(bundle.json inventory.json qualification.json project docs) ++
        if(metadata["package_id"], do: ~w(package.tar docs.tar.gz), else: [])

    unless Enum.sort(File.ls!(bundle)) == Enum.sort(expected),
      do: raise(Error, "unexpected or missing bundle entry")

    for name <- expected -- ["project", "docs"] do
      unless Bitwise.band(File.stat!(Path.join(bundle, name)).mode, 0o7777) == 0o644,
        do: raise(Error, "bundle evidence or archive mode is not normalized: #{name}")
    end

    for {_field, file} <- metadata["files"], file do
      target = Path.join(bundle, file["path"])

      unless File.regular?(target) and File.stat!(target).size == file["size"] and
               Hash.sha256_file(target) == file["sha256"],
             do: raise(Error, "bundle file checksum mismatch: #{file["path"]}")
    end

    unless is_nil(metadata["package_id"]) or
             (metadata["files"]["package"]["sha256"] == metadata["archive_sha256"] and
                metadata["files"]["docs_archive"]["sha256"] == metadata["docs_archive_sha256"]),
           do: raise(Error, "archive digest binding mismatch")
  end

  defp validate_modes!(root, entries) do
    for entry <- entries do
      expected = if entry["executable"], do: 0o755, else: 0o644

      unless Bitwise.band(File.stat!(Path.join(root, entry["path"])).mode, 0o7777) == expected,
        do: raise(Error, "bundle file mode is not normalized: #{entry["path"]}")
    end
  end

  defp validate_frozen_plan!(inventory) do
    unless inventory["empty_dirs"] == inventory["layout"]["empty_dirs"],
      do: raise(Error, "frozen empty directory set differs from the compiler layout")

    frozen = Map.new(inventory["frozen_project"], &{&1["path"], &1})
    planned = Enum.map(inventory["entries"], & &1["target"])

    expected_paths =
      if Map.has_key?(frozen, "mix.lock"), do: Enum.uniq(["mix.lock" | planned]), else: planned

    unless Enum.sort(Map.keys(frozen)) == Enum.sort(expected_paths),
      do: raise(Error, "frozen project has missing or unplanned files")

    for entry <- inventory["entries"], entry["target"] != "mix.lock" do
      actual = frozen[entry["target"]]
      want = entry["full"]

      unless actual["sha256"] == want["content_sha256"] and actual["size"] == want["size"] and
               actual["executable"] == want["executable"],
             do:
               raise(Error, "frozen project differs from compiler inventory: #{entry["target"]}")
    end

    if inventory["package_entries"], do: validate_frozen_package!(inventory, frozen)
  end

  defp validate_frozen_package!(inventory, frozen) do
    expected =
      inventory["entries"]
      |> Enum.filter(& &1["package"])
      |> Enum.map(& &1["target"])
      |> Enum.sort()

    observed = Enum.map(inventory["package_entries"], & &1["path"])

    unless expected == observed and
             Enum.all?(inventory["package_entries"], &(frozen[&1["path"]] == &1)),
           do: raise(Error, "package membership differs from compiler publication view")
  end

  defp validate_lock!(bundle, inventory, qualification) do
    path = Path.join([bundle, "project", "mix.lock"])
    actual = if File.regular?(path), do: Hash.sha256_file(path)

    unless actual == qualification["lock_sha256"],
      do: raise(Error, "resolved lock digest mismatch")

    if is_nil(actual) and inventory["lock_slot"]["policy"] != "none" and
         inventory["dependencies"] != [],
       do: raise(Error, "resolved standalone lock is required")
  end

  defp validate_qualification!(proof, inventory) do
    validate_qualification_context!(proof, inventory)
    validate_qualification_gates!(proof, inventory)
  end

  defp validate_qualification_context!(proof, inventory) do
    unless proof["gate_schema"] == "weld.gates/2" and
             is_map(proof["toolchain"]) and
             proof["toolchain"]["compiler_id"] == inventory["compiler_id"] and
             is_map(proof["trust"]) and proof["trust"]["verified"] == true and
             (is_nil(proof["context_digest"]) or Identity.valid?(proof["context_digest"])),
           do: raise(Error, "unsupported or incomplete qualification evidence")
  end

  defp validate_qualification_gates!(proof, inventory) do
    gates = proof["gates"]

    unless is_list(gates) and Enum.map(gates, & &1["id"]) == @gate_ids,
      do: raise(Error, "qualification must record every gate exactly once in order")

    policy = inventory["qualification_policy"]

    for gate <- gates, do: validate_gate!(gate, policy, inventory)

    facts = Map.new(gates, &{&1["id"], &1["facts"]})
    hex? = policy["hex_build"]

    if hex? do
      unless facts["G08"] == %{
               "archive_sha256" => proof["archive_sha256"],
               "package_id" => proof["package_id"],
               "entries" => length(inventory["package_entries"])
             },
             do: raise(Error, "G08 gate observations disagree with the frozen proof")
    end

    unless facts["G11"] == %{
             "docs_id" => proof["docs_id"],
             "docs_archive_sha256" => proof["docs_archive_sha256"],
             "roundtrip_verified" => hex?,
             "archive_policy" => if(hex?, do: "exact_frozen_payload", else: "non_hex_docs_tree")
           },
           do: raise(Error, "G11 gate observations disagree with the frozen proof")
  end

  defp validate_gate!(gate, policy, inventory) do
    required = required_gate?(gate["id"], policy, inventory)

    unless is_map(gate) and Enum.sort(Map.keys(gate)) == ~w(facts id skip_reason status) and
             is_map(gate["facts"]) and
             valid_gate_outcome?(gate["status"], gate["skip_reason"], required),
           do: raise(Error, "required gate missing, failed or improperly skipped: #{gate["id"]}")
  end

  defp valid_gate_outcome?("pass", nil, _required), do: true
  defp valid_gate_outcome?("skip", reason, false) when is_binary(reason), do: reason != ""
  defp valid_gate_outcome?(_, _, _), do: false

  defp required_gate?("G03", policy, inventory),
    do: layout(inventory) == "flat" or policy["component_tests"] == true

  defp required_gate?("G07", policy, _), do: not is_nil(policy["smoke"])
  defp required_gate?(id, policy, _) when id in ["G08", "G10"], do: policy["hex_build"] == true

  defp required_gate?("G09", policy, _),
    do: policy["hex_build"] == true and policy["hex_publish_check"] == true

  defp required_gate?(_, _, _), do: true

  defp layout(inventory),
    do:
      if(is_map(inventory["layout"]), do: inventory["layout"]["name"], else: inventory["layout"])

  def selector(%Plan{} = plan),
    do: %{repo_root: plan.manifest.repo_root, artifact: plan.artifact.id}

  def selector(%{repo_root: root, artifact: artifact})
      when is_binary(root) and is_binary(artifact), do: %{repo_root: root, artifact: artifact}

  def resolve_path!(selection, identity \\ nil) do
    %{repo_root: root, artifact: artifact} = selector(selection)

    identity =
      identity || pointer!(File.read!(Output.path(root, ["current", artifact])), artifact)

    unless Identity.valid?(identity),
      do: raise(Error, "prepared identity must be a full lowercase SHA-256")

    bundle = Output.path(root, ["bundles", artifact, identity])
    unless File.dir?(bundle), do: raise(Error, "release bundle not found: #{bundle}")
    {identity, bundle}
  end

  def pointer!(bytes, artifact) do
    with {:ok,
          %{"schema" => "weld.current/2", "artifact" => ^artifact, "bundle_id" => id} = record} <-
           Jason.decode(bytes),
         true <-
           map_size(record) == 3 and Identity.valid?(id) and Identity.canonical(record) == bytes do
      id
    else
      _ -> raise Error, "invalid Weld current bundle pointer"
    end
  end

  def freshness_reasons(selection, metadata, current_revision) do
    %{repo_root: root} = selector(selection)
    source = metadata["source"]

    base =
      []
      |> add_if(current_revision != source["commit"], :head_moved)
      |> add_if(is_binary(current_revision) and Git.dirty?(root), :dirty_worktree)
      |> add_if(
        not match?({:ok, _}, Git.run(root, ["cat-file", "-e", source["commit"] <> "^{commit}"])),
        :source_commit_missing
      )

    case selection do
      %Plan{} = plan ->
        base
        |> add_if(
          {plan.artifact.package.name, plan.artifact.package.version, plan.artifact.id} !=
            {metadata["package"], metadata["version"], metadata["artifact"]},
          :package_mismatch
        )
        |> add_if(
          Hash.sha256_file(plan.manifest.manifest_path) != source["manifest_sha256"],
          :manifest_changed
        )
        |> Enum.reverse()

      _ ->
        path = Path.join(root, source["manifest_path"])

        base
        |> add_if(not File.regular?(path), :current_manifest_unavailable)
        |> add_if(
          File.regular?(path) and Hash.sha256_file(path) != source["manifest_sha256"],
          :manifest_changed
        )
        |> Enum.reverse()
    end
  end

  def status(selection, opts \\ []) do
    %{repo_root: root, artifact: artifact} = selector(selection)
    revision = Git.revision(root)

    try do
      {id, bundle} = resolve_path!(selection, opts[:identity])
      metadata = validate_bundle_integrity!(bundle, id)
      unless metadata["artifact"] == artifact, do: raise(Error, "artifact and bundle disagree")
      reasons = freshness_reasons(selection, metadata, revision)
      archive = archive_status(root, artifact, id)
      projection = projection_status(root, metadata)
      remote = remote_status(selection, bundle, metadata, opts)
      publication = local_publication(selection, bundle, metadata, opts)

      %{
        artifact: artifact,
        identity: id,
        short_identity: String.slice(id, 0, 12),
        package: metadata["package"],
        version: metadata["version"],
        state: if(reasons == [], do: :ready, else: :stale),
        integrity: :valid,
        freshness: if(reasons == [], do: :fresh, else: :stale),
        qualification: :passed,
        reasons: reasons,
        source_revision: metadata["source"]["commit"],
        current_revision: revision,
        has_tarball: not is_nil(metadata["archive_sha256"]),
        archive_sha256: metadata["archive_sha256"],
        project_id: metadata["project_id"],
        docs_id: metadata["docs_id"],
        archive: archive,
        archived: archive == :matching,
        projection: projection,
        remote: remote,
        package_publish: publication.package,
        docs_publish: publication.docs,
        run: run_status(root, artifact),
        default_tag: default_tag(metadata),
        paths: paths(root, artifact, id),
        warnings: docs_source_ref_warnings(selection, opts[:tag]),
        next_command: next_command(artifact, id, metadata, reasons, publication)
      }
    rescue
      error in [Error, File.Error] ->
        missing =
          match?(%File.Error{reason: :enoent}, error) or
            String.contains?(Exception.message(error), "not found")

        Map.merge(empty_info(selection), %{
          artifact: artifact,
          identity: opts[:identity] || current_identity(root, artifact),
          state: if(missing, do: :unprepared, else: :corrupt_bundle),
          integrity: if(missing, do: :absent, else: :corrupt),
          freshness: :unknown,
          qualification: :not_qualified,
          reasons: [Exception.message(error)],
          current_revision: revision,
          has_tarball: false,
          archived: false,
          paths: paths(root, artifact, opts[:identity]),
          warnings: [],
          next_command: nil
        })
    end
  end

  defp empty_info(%Plan{} = plan) do
    %{
      default_tag: plan.artifact.package.name <> "-v" <> plan.artifact.package.version,
      projection: %{
        branch: "projection/" <> plan.artifact.package.name,
        exists: false,
        state: :untracked,
        matches_identity: false,
        tree_matches: nil,
        tip_sha: nil
      }
    }
  end

  defp empty_info(_), do: %{default_tag: nil, projection: %{state: :untracked}}

  defp current_identity(root, artifact) do
    pointer!(File.read!(Output.path(root, ["current", artifact])), artifact)
  rescue
    _ -> nil
  end

  defp remote_status(selection, bundle, metadata, opts) do
    if opts[:remote] && metadata["package_id"],
      do: Hex.status(selection, bundle, metadata, opts),
      else: :not_checked
  rescue
    error -> %{state: :unavailable, reason: Exception.message(error)}
  end

  defp local_publication(selection, bundle, metadata, opts) do
    if metadata["package_id"] do
      case Hex.local_status(selection, bundle, metadata, opts) do
        nil -> %{package: "not_attempted", docs: "not_attempted"}
        record -> %{package: record["package_state"], docs: record["docs_state"]}
      end
    else
      %{package: "not_applicable", docs: "not_applicable"}
    end
  rescue
    _ -> %{package: "unknown", docs: "unknown"}
  end

  defp run_status(root, artifact) do
    active =
      for {_path, lease} <- Output.leases(root),
          lease["artifact"] == artifact,
          do: %{
            operation: lease["operation"],
            phase: lease["phase"],
            liveness: Output.owner_liveness(lease["owner"])
          }

    if active == [], do: :idle, else: active
  rescue
    _ -> :unknown
  end

  defp next_command(artifact, id, metadata, reasons, publication) do
    states = [publication.package, publication.docs]

    cond do
      Enum.any?(states, &(&1 in ["unknown", "submitting", "staged"])) ->
        "mix weld reconcile --artifact #{artifact} --identity #{id}"

      "conflict" in states ->
        nil

      reasons != [] ->
        "mix weld prepare --artifact #{artifact}"

      states == ["confirmed", "confirmed"] ->
        "mix weld archive --artifact #{artifact} --identity #{id}"

      metadata["package_id"] ->
        "mix weld publish --artifact #{artifact} --identity #{id} --dry-run"

      true ->
        "mix weld archive --artifact #{artifact} --identity #{id}"
    end
  end

  defp archive_status(root, artifact, id) do
    archive = Output.path(root, ["archives", artifact, id])

    if File.exists?(archive) do
      validate_bundle_integrity!(archive, id)
      :matching
    else
      :absent
    end
  rescue
    _ -> :corrupt
  end

  defp projection_status(root, metadata) do
    branch = "projection/" <> metadata["package"]
    ref = "refs/heads/" <> branch

    case ReleaseReceipt.from_commit(root, ref) do
      {:ok, receipt} ->
        tree_matches = Git.project_id(root, ref) == metadata["project_id"]
        matches = receipt == ReleaseReceipt.from_bundle(metadata) and tree_matches

        %{
          branch: branch,
          exists: true,
          state: if(matches, do: :matching, else: :different),
          matches_identity: matches,
          tree_matches: tree_matches,
          tip_sha: Git.ref_oid(root, ref)
        }

      :missing ->
        %{branch: branch, exists: false, state: :untracked, matches_identity: false, tip_sha: nil}

      _ ->
        %{
          branch: branch,
          exists: true,
          state: :conflict,
          matches_identity: false,
          tip_sha: Git.ref_oid(root, ref)
        }
    end
  end

  defp paths(root, artifact, id) do
    %{
      releases: Output.path(root, ["bundles", artifact]),
      bundle: id && Output.path(root, ["bundles", artifact, id]),
      archive: id && Output.path(root, ["archives", artifact, id]),
      live_project: Output.path(root, ["live", artifact]),
      full_project: Output.path(root, ["full", artifact, "project"]),
      current: Output.path(root, ["current", artifact])
    }
  end

  def verify_tag(root, tag, opts \\ []) do
    with {:ok, %{type: :annotated, target_sha: target, receipt: receipt}} <-
           ReleaseReceipt.from_tag(root, tag),
         {:ok, ^receipt} <- ReleaseReceipt.from_commit(root, target),
         true <- Git.project_id(root, target) == receipt["project_id"],
         true <- is_nil(opts[:artifact]) or opts[:artifact] == receipt["artifact"],
         true <- is_nil(opts[:identity]) or opts[:identity] == receipt["bundle_id"] do
      local = local_evidence(root, receipt)
      tar = tar_evidence(receipt, opts[:tarball])

      state =
        cond do
          :mismatch in [local, tar] -> :mismatch
          local == :missing_local and tar != :match -> :missing_local
          true -> :match
        end

      %{
        tag: tag,
        status: state,
        target_sha: target,
        tag_receipt: receipt,
        commit_receipt: receipt,
        tree: :match,
        local_bundle: local,
        local_tarball: tar,
        message:
          "Annotated receipt and actual Git project tree agree; local evidence: #{local}; no publication claim."
      }
    else
      :missing ->
        %{tag: tag, status: :missing_tag, message: "Git tag not found"}

      _ ->
        %{
          tag: tag,
          status: :mismatch,
          message: "Tag annotation, commit receipt or actual Git tree differs"
        }
    end
  rescue
    error -> %{tag: tag, status: :mismatch, message: Exception.message(error)}
  end

  defp local_evidence(root, receipt) do
    path =
      Enum.find_value(["bundles", "archives"], fn category ->
        path = Output.path(root, [category, receipt["artifact"], receipt["bundle_id"]])
        if File.exists?(path), do: path
      end)

    if path do
      metadata = validate_bundle_integrity!(path, receipt["bundle_id"])
      if ReleaseReceipt.from_bundle(metadata) == receipt, do: :match, else: :mismatch
    else
      :missing_local
    end
  rescue
    _ -> :mismatch
  end

  defp tar_evidence(_receipt, nil), do: :not_checked

  defp tar_evidence(receipt, path) do
    cond do
      not File.regular?(path) -> :missing_local
      Hash.sha256_file(path) == receipt["archive_sha256"] -> :match
      true -> :mismatch
    end
  end

  def docs_source_ref_warnings(selection, tag \\ nil)

  def docs_source_ref_warnings(%Plan{} = plan, tag) do
    docs = plan.artifact.package.docs

    []
    |> add_if(
      plan.artifact.mode in [:package_projection, :monolith] and is_binary(docs.source_url) and
        docs.source_ref in [nil, "main", "master", "HEAD"],
      "Set an immutable projection tag in docs.source_ref for accurate source links"
    )
    |> add_if(
      is_binary(tag) and is_binary(docs.source_ref) and docs.source_ref != tag,
      "docs.source_ref differs from the tracked projection tag"
    )
    |> Enum.reverse()
  end

  def docs_source_ref_warnings(_, _), do: []
  def default_tag(metadata), do: metadata["package"] <> "-v" <> metadata["version"]
  defp add_if(values, true, item), do: [item | values]
  defp add_if(values, false, _), do: values
end
