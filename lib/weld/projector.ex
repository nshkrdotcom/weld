defmodule Weld.Projector do
  @moduledoc "Materialize all three layouts from the compiler's single closed inventory."
  alias Weld.Core.Identity
  alias Weld.{Error, Git, Hash, Output, Plan, Receipt}
  alias Weld.Plan.Inventory
  alias Weld.Shell.{Materializer, Native, Snapshot}

  def project!(%Plan{} = plan, opts \\ []) do
    Plan.ensure_valid!(plan)
    kind = if(opts[:live] or opts[:kind] in [:live, "live"], do: :live, else: :full)

    Output.with_lease(
      plan.manifest.repo_root,
      "project",
      plan.artifact.id,
      "projection:" <> Atom.to_string(kind),
      [],
      fn lease ->
        project_with_lease!(plan, kind, lease, opts)
      end,
      opts
    )
  end

  defp project_with_lease!(plan, kind, lease, opts) do
    root = plan.manifest.repo_root
    target = build_path(plan, kind)
    receipt = Output.path(root, ["views", plan.artifact.id, "#{kind}.json"])
    owner = Output.path(root, ["views", plan.artifact.id, "#{kind}.owner.json"])
    inventory = Inventory.portable(plan)
    record = read_receipt(receipt)
    recheck_inputs!(plan, inventory["input_id"])

    reusable =
      not (opts[:no_cache] or opts[:fresh]) and
        reusable?(plan, kind, target, record, inventory)

    if reusable do
      write_receipt!(receipt, plan, kind, target, inventory)
      projection(plan, target, kind, true)
    else
      stage = Path.join(lease.stage, "project")
      File.mkdir_p!(stage)
      Materializer.execute!(plan.layout, plan.facts, stage, kind)
      if plan.source_root, do: Native.validate!(plan, stage, kind)
      recheck_inputs!(plan, inventory["input_id"])
      if kind == :full and File.exists?(target), do: Output.reject_tree_links!(target)

      Output.with_lock(root, fn ->
        # Reserve ownership before the first replace, but never label an
        # existing unmanaged target. A crash can leave an owned empty slot.
        if File.exists?(target) and not owned?(owner, plan.artifact.id, kind),
          do: raise(Error, "unmanaged output: #{target}")

        Output.write_atomic!(owner, Identity.canonical(owner_record(plan.artifact.id, kind)))
      end)

      Output.activate!(stage, target, fn _ -> owned?(owner, plan.artifact.id, kind) end,
        lease: lease,
        failpoint: opts[:failpoint]
      )

      write_receipt!(receipt, plan, kind, target, inventory)
      projection(plan, target, kind, false)
    end
  end

  def materialize_verification!(plan, stage) do
    Plan.ensure_valid!(plan)
    inventory = Inventory.portable(plan)
    recheck_inputs!(plan, inventory["input_id"])
    File.mkdir_p!(stage)
    Materializer.execute!(plan.layout, plan.facts, stage, :full)
    if plan.source_root, do: Native.validate!(plan, stage)
    recheck_inputs!(plan, inventory["input_id"])
    projection(plan, stage, :full, false)
  end

  def recheck_inputs!(plan, expected) do
    inputs = Inventory.portable(plan)["inputs"]
    facts = Snapshot.refresh!(plan.facts, inputs)

    projects =
      Map.new(plan.workspace.projects, fn {id, project} -> {id, %{project | facts: facts}} end)

    workspace = %{plan.workspace | facts: facts, projects: projects}

    refreshed = %{
      plan
      | facts: facts,
        workspace: workspace,
        selected_projects: Enum.map(plan.selected_projects, &Map.fetch!(projects, &1.id))
    }

    unless Inventory.portable(refreshed)["input_id"] == expected,
      do:
        raise(Error,
          code: :inputs_changed,
          phase: :materialize,
          message: "source inputs changed after planning; build a new plan"
        )

    :ok
  end

  defp reusable?(_plan, _kind, _target, nil, _inventory), do: false

  defp reusable?(plan, kind, target, record, inventory) do
    identity_matches = kind == :live or record["plan_id"] == inventory["plan_id"]

    unless record["artifact"] == plan.artifact.id and record["kind"] == Atom.to_string(kind),
      do: raise(Error, "projection cache ownership mismatch")

    identity_matches and record["local_link_locator_digest"] == locator_digest(plan, kind) and
      record["observed_tree_digest"] == output_digest(target, kind) and
      is_map(Materializer.validate!(plan.layout, plan.facts, target, kind))
  rescue
    _ -> false
  end

  defp read_receipt(path) do
    with {:ok, bytes} <- File.read(path),
         record <- Identity.decode!(bytes),
         {:ok, valid} <- Receipt.read(path, record["plan_id"]) do
      valid
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp write_receipt!(path, plan, kind, target, inventory) do
    record = %{
      "schema" => "weld.projection_cache/2",
      "artifact" => plan.artifact.id,
      "kind" => Atom.to_string(kind),
      "plan_id" => inventory["plan_id"],
      "local_link_locator_digest" => locator_digest(plan, kind),
      "observed_tree_digest" => output_digest(target, kind)
    }

    Output.with_lock(plan.manifest.repo_root, fn -> Receipt.write!(path, record) end)
  end

  defp locator_digest(_plan, :full), do: nil
  defp locator_digest(plan, :live), do: Identity.raw(plan.manifest.repo_root)
  defp output_digest(target, kind), do: Receipt.digest(Receipt.tree(target, kind == :live))

  defp owner_record(artifact, kind),
    do: %{"schema" => "weld.view/2", "artifact" => artifact, "kind" => Atom.to_string(kind)}

  defp owned?(path, artifact, kind) do
    case File.read(path) do
      {:ok, bytes} -> Identity.decode!(bytes) == owner_record(artifact, kind)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp projection(plan, target, kind, reused?) do
    observation = Materializer.validate!(plan.layout, plan.facts, target, kind)

    Map.merge(observation, %{
      build_path: target,
      package_files: plan.layout.package_files,
      package_patterns: Map.get(plan.layout, :package_patterns),
      verification_files: Enum.map(plan.output_inventory, & &1.target),
      empty_dirs: Map.get(plan.layout, :empty_dirs, []),
      git_revision: Git.revision(plan.manifest.repo_root),
      tree_digest: if(kind == :full, do: Identity.digest("project", Hash.observation(target))),
      config_warnings: plan.layout.config_warnings,
      mode: plan.artifact.mode,
      reused?: reused?
    })
    |> Map.merge(
      Map.take(plan.layout, [
        :file_remaps,
        :migration_layout,
        :migration_remaps,
        :helper_transformations,
        :source_mappings,
        :repo_infos,
        :test_support_projects
      ])
    )
  end

  def build_path(plan, kind \\ :full)

  def build_path(plan, :full),
    do: Output.path(plan.manifest.repo_root, ["full", plan.artifact.id, "project"])

  def build_path(plan, :live),
    do: Output.path(plan.manifest.repo_root, ["live", plan.artifact.id])
end
