defmodule Weld.Output do
  @moduledoc """
  Checkout-owned state, short metadata locks, explicit resource leases and
  recoverable activation. Slow work always runs outside the metadata lock.
  """

  alias Weld.Core.Identity
  alias Weld.{Error, Git}

  @owner "weld.state/2\n"
  @ignore_rules [".weld", "/.weld", ".weld/", "/.weld/"]
  @forbidden ~w(.git .weld _build deps)
  @lease_keys ~w(schema id operation artifact owner resource stage pinned_ids phase created_at)
  @run_keys ~w(schema id operation artifact lease_id plan_id bundle_id phase started_at finished_at logs diagnostics)
  @journal_keys ~w(schema id owner kind target stage backup old new phase)
  @operations ~w(project verify prepare publish reconcile stage track archive cache)

  def checkout(root) do
    expanded = Path.expand(root)
    find_checkout(expanded) || expanded
  end

  defp find_checkout(directory) do
    case File.lstat(Path.join(directory, ".git")) do
      {:ok, %{type: type}} when type in [:regular, :directory] ->
        directory

      _ ->
        parent = Path.dirname(directory)
        if parent != directory, do: find_checkout(parent)
    end
  end

  def path(root, parts) do
    checkout = checkout(root)
    reject_ancestors!(checkout)
    base = Path.join(checkout, ".weld")
    reject_link!(base)

    Enum.reduce(["v2" | parts], base, fn part, parent ->
      segment!(part)
      reject_link!(parent)
      target = Path.join(parent, part)
      reject_link!(target)
      target
    end)
  end

  defp segment!(part) do
    unless is_binary(part) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, part) and
             part not in [".", ".."] do
      raise Error, "invalid Weld output path segment: #{inspect(part)}"
    end

    part
  end

  @doc "The only command allowed to initialize state or edit the source ignore rule."
  def setup!(root) do
    root = checkout(root)
    ensure_untracked!(root)
    base = path(root, [])
    File.mkdir_p!(base)

    with_metadata_lock(
      root,
      fn ->
        marker = Path.join(base, "OWNER")
        reject_link!(marker)

        case File.read(marker) do
          {:ok, @owner} ->
            :ok

          {:error, :enoent} ->
            unless Enum.sort(File.ls!(base)) == ["lock"],
              do: raise(Error, "unmanaged Weld output: #{base}")

            File.write!(marker, @owner, [:exclusive, :sync])

          _ ->
            raise Error, "unmanaged Weld output: #{base}"
        end
      end,
      []
    )

    ensure_ignore!(root, base)
  end

  @doc "Run only a bounded metadata operation; this function is not reentrant."
  def with_lock(root, fun, opts \\ []) do
    root = checkout(root)
    ensure_managed!(root)
    with_metadata_lock(root, fun, opts)
  end

  def ensure_managed!(root) do
    root = checkout(root)
    ensure_untracked!(root)
    base = path(root, [])
    owner_path = Path.join(base, "OWNER")
    reject_link!(owner_path)

    unless File.read(owner_path) == {:ok, @owner},
      do: raise(Error, "unmanaged Weld state; run mix weld setup: #{base}")

    check_ignore!(root)
    base
  end

  defp with_metadata_lock(root, fun, opts) do
    lock = path(root, ["lock"])
    timeout = Keyword.get(opts, :lock_timeout, 5_000)

    unless is_integer(timeout) and timeout >= 0 and timeout <= 60_000,
      do: raise(Error, "invalid metadata lock timeout")

    owner = owner()
    acquire!(lock, System.monotonic_time(:millisecond) + timeout)
    owner_path = Path.join(lock, "owner.json")

    try do
      File.write!(owner_path, Identity.canonical(owner), [:exclusive, :sync])
      fun.()
    after
      # Do not delete another owner's lock after replacement or corruption.
      if read_owner(owner_path) == {:ok, owner} do
        File.rm!(owner_path)
        File.rmdir!(lock)
      end
    end
  end

  defp acquire!(lock, deadline) do
    case File.mkdir(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(lock) do
          {:ok, %{type: :directory}} -> :ok
          {:error, :enoent} -> :ok
          _ -> raise Error, "unmanaged mutation lock: #{lock}"
        end

        if System.monotonic_time(:millisecond) >= deadline do
          raise Error, "Weld metadata lock busy; inspect recover report: #{lock}"
        end

        Process.sleep(20)
        acquire!(lock, deadline)

      {:error, reason} ->
        raise Error, "cannot acquire #{lock}: #{reason}"
    end
  end

  defp check_ignore!(root) do
    if Git.root(root) &&
         not match?(
           {:ok, _},
           Git.run(root, ["check-ignore", "--quiet", "--no-index", "--", ".weld/v2/probe"])
         ) do
      raise Error, "Weld state must be ignored; run mix weld setup and commit the ignore rule"
    end
  end

  defp ensure_untracked!(root) do
    if Git.root(root) && Git.run!(root, ["ls-files", "--", ".weld"]) != "",
      do: raise(Error, "tracked .weld output at #{root}; resolve the index before writing")
  end

  @doc "Reserve a resource briefly, execute outside the lock, then release the exact token."
  def with_lease(root, operation, artifact, resource, pinned_ids, fun, opts \\ []) do
    lease = reserve!(root, operation, artifact, resource, pinned_ids, opts)

    try do
      if is_function(fun, 1), do: fun.(lease), else: fun.()
    after
      unless unresolved_journals?(lease), do: release!(lease)
    end
  end

  defp unresolved_journals?(lease) do
    Enum.any?(journals(path(lease.root, [])), fn item ->
      is_nil(item.record) or
        (item.record["owner"] == lease.record["owner"] and
           item.record["phase"] not in ["cleaned", "committed"])
    end)
  end

  def reserve!(root, operation, artifact, resource, pinned_ids, opts \\ []) do
    root = checkout(root)
    unless operation in @operations, do: raise(Error, "invalid lease operation")
    segment!(artifact)

    unless is_binary(resource) and resource != "" and byte_size(resource) <= 1024,
      do: raise(Error, "invalid lease resource")

    unless is_list(pinned_ids) and Enum.all?(pinned_ids, &Identity.valid?/1),
      do: raise(Error, "invalid lease pinned identities")

    # Publication exclusion spans bundle/artifact IDs for one destination/version.
    resource =
      if operation in ["publish", "reconcile", "cache"],
        do: resource,
        else: artifact <> ":" <> resource

    with_lock(
      root,
      fn ->
        leases = leases(root)

        if Enum.any?(leases, fn {_path, record} -> record["resource"] == resource end),
          do: raise(Error, "resource is reserved; inspect its owner before recovery: #{resource}")

        id = nonce()
        stage = path(root, ["staging", id])
        File.mkdir_p!(stage)

        record = %{
          "schema" => "weld.lease/2",
          "id" => id,
          "operation" => operation,
          "artifact" => artifact,
          "owner" => owner(),
          "resource" => resource,
          "stage" => "staging/" <> id,
          "pinned_ids" => Enum.sort(Enum.uniq(pinned_ids)),
          "phase" => "reserved",
          "created_at" => now()
        }

        target = path(root, ["leases", id <> ".json"])
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, Identity.canonical(record), [:exclusive, :sync])
        %{root: root, path: target, stage: stage, record: record}
      end,
      opts
    )
  end

  def release!(%{root: root, path: target, record: record}) do
    with_lock(root, fn ->
      case read_record(target, @lease_keys, "weld.lease/2") do
        {:ok, ^record} ->
          File.rm!(target)

        {:ok, other} ->
          if other["owner"] == record["owner"] and other["id"] == record["id"],
            do: File.rm!(target),
            else: raise(Error, "lease ownership changed: #{target}")

        _ ->
          raise Error, "lease disappeared or is corrupt: #{target}"
      end
    end)
  end

  def leases(root) do
    directory = path(root, ["leases"])

    for file <- children(directory), reduce: [] do
      records ->
        case read_record(file, @lease_keys, "weld.lease/2") do
          {:ok, record} ->
            validate_lease!(record)

            unless Path.basename(file) == record["id"] <> ".json",
              do: raise(Error, "lease filename does not match identity")

            [{file, record} | records]

          _ ->
            raise Error, "corrupt lease; ownership is unknown: #{file}"
        end
    end
    |> Enum.reverse()
  end

  defp validate_lease!(record) do
    segment!(record["id"])
    segment!(record["artifact"])
    valid_owner!(record["owner"])

    unless record["operation"] in @operations and record["stage"] == "staging/" <> record["id"] and
             record["phase"] in ["reserved", "executing", "completed", "failed"] and
             is_binary(record["resource"]) and record["resource"] != "" and
             is_list(record["pinned_ids"]) and Enum.all?(record["pinned_ids"], &Identity.valid?/1) and
             record["pinned_ids"] == Enum.sort(Enum.uniq(record["pinned_ids"])) and
             valid_time?(record["created_at"]),
           do: raise(Error, "invalid lease record")

    record
  end

  def run!(root, operation, artifact, lease, opts \\ []) do
    unless operation in ~w(verify prepare publish stage),
      do: raise(Error, "invalid run operation")

    id = nonce()
    directory = path(root, ["runs", operation, artifact, id])

    record = %{
      "schema" => "weld.run/2",
      "id" => id,
      "operation" => operation,
      "artifact" => artifact,
      "lease_id" => lease.record["id"],
      "plan_id" => opts[:plan_id],
      "bundle_id" => opts[:bundle_id],
      "phase" => "reserved",
      "started_at" => now(),
      "finished_at" => nil,
      "logs" => [],
      "diagnostics" => []
    }

    with_lock(root, fn ->
      File.mkdir_p!(Path.dirname(directory))
      File.mkdir!(directory)

      File.write!(Path.join(directory, "run.json"), Identity.canonical(record), [
        :exclusive,
        :sync
      ])
    end)

    %{id: id, path: directory, record: record, root: checkout(root)}
  end

  def update_run!(run, updates) do
    target = Path.join(run.path, "run.json")
    {:ok, record} = read_record(target, @run_keys, "weld.run/2")
    updated = Map.merge(record, updates)
    validate_run!(updated)
    with_lock(run.root, fn -> atomic_write!(target, Identity.canonical(updated)) end)
    %{run | record: updated}
  end

  def finish_run!(run, phase, diagnostics \\ [])
      when phase in ["completed", "failed", "interrupted"] do
    update_run!(run, %{"phase" => phase, "finished_at" => now(), "diagnostics" => diagnostics})
  end

  def read_run!(directory) do
    case read_record(Path.join(directory, "run.json"), @run_keys, "weld.run/2") do
      {:ok, record} ->
        validate_run!(record)

        unless record["id"] == Path.basename(directory) and
                 record["artifact"] == Path.basename(Path.dirname(directory)) and
                 record["operation"] == Path.basename(Path.dirname(Path.dirname(directory))),
               do: raise(Error, "run path binding mismatch")

        record

      _ ->
        raise Error, "invalid run record: #{directory}"
    end
  end

  defp validate_run!(record) do
    segment!(record["id"])
    segment!(record["artifact"])
    segment!(record["lease_id"])

    unless record["operation"] in ~w(verify prepare publish stage) and
             record["phase"] in ~w(reserved executing completed failed interrupted) and
             Enum.all?(
               [record["plan_id"], record["bundle_id"]],
               &(is_nil(&1) or Identity.valid?(&1))
             ) and
             valid_time?(record["started_at"]) and
             (is_nil(record["finished_at"]) or valid_time?(record["finished_at"])) and
             is_list(record["logs"]) and is_list(record["diagnostics"]),
           do: raise(Error, "invalid run record")

    record
  end

  def run_path(root, artifact, id) do
    segment!(id)

    matches =
      for operation <- ~w(verify prepare publish stage),
          directory = path(root, ["runs", operation, artifact, id]),
          File.dir?(directory),
          do: directory

    case matches do
      [directory] ->
        record = read_run!(directory)

        unless record["id"] == id and record["artifact"] == artifact,
          do: raise(Error, "run identity mismatch")

        directory

      [] ->
        raise Error, "run not found: #{id}"

      _ ->
        raise Error, "ambiguous run identity: #{id}"
    end
  end

  @doc "Atomic regular-file replacement with a durable temp file on the same filesystem."
  def atomic_write!(target, bytes) do
    _ = managed_base!(target)
    reject_link!(target)
    File.mkdir_p!(Path.dirname(target))
    temporary = target <> "-" <> nonce()

    try do
      File.write!(temporary, bytes, [:exclusive, :sync])
      reject_link!(target)
      File.rename!(temporary, target)
      sync_parent(target)
    after
      File.rm(temporary)
    end

    :ok
  end

  def write_atomic!(target, bytes), do: atomic_write!(target, bytes)

  defp sync_parent(path) do
    case :file.open(String.to_charlist(Path.dirname(path)), [:read, :raw]) do
      {:ok, io} ->
        :file.sync(io)
        :file.close(io)

      _ ->
        :ok
    end
  end

  @doc "Observe and validate under the artifact lease; lock only journal and rename transitions."
  def activate!(stage, target, valid_existing?, opts \\ []) do
    base = managed_base!(target)
    root = base |> Path.dirname() |> Path.dirname()
    confine!(base, stage)
    reject_link!(stage)
    unless File.dir?(stage), do: raise(Error, "activation stage missing: #{stage}")
    active_lease!(root, opts[:lease])
    confine!(opts[:lease].stage, stage)
    old_node = node_token!(target)
    stage_node = node_token!(stage)
    old = if old_node, do: tree_record(target)
    if old && not valid_existing?.(target), do: raise(Error, "unmanaged output: #{target}")
    id = nonce()
    journal_dir = Path.join([base, "staging", id])
    File.mkdir_p!(journal_dir)
    backup = Path.join(journal_dir, "backup")

    record = %{
      "schema" => "weld.journal/2",
      "id" => id,
      "owner" => journal_owner(opts),
      "kind" => "view",
      "target" => Path.relative_to(target, base),
      "stage" => Path.relative_to(stage, base),
      "backup" => Path.relative_to(backup, base),
      "old" => old,
      "new" => tree_record(stage),
      "phase" => "reserved"
    }

    journal = Path.join(journal_dir, "journal.json")

    try do
      with_lock(
        root,
        fn ->
          active_lease!(root, opts[:lease])
          same_node!(target, old_node)
          same_node!(stage, stage_node)
          journal!(journal, record, "reserved", opts)
          File.mkdir_p!(Path.dirname(target))
          if old, do: File.rename!(target, backup)
          journal!(journal, record, "backed_up", opts)
          File.rename!(stage, target)
          journal!(journal, record, "activated", opts)
        end,
        opts
      )

      unless tree_record(target) == record["new"], do: raise(Error, "activated view changed")
      if old && tree_record(backup) != old, do: raise(Error, "activation backup changed")

      with_lock(
        root,
        fn ->
          active_lease!(root, opts[:lease])
          same_node!(target, stage_node)
          journal!(journal, record, "committed", opts)
        end,
        opts
      )

      if old, do: remove_observed!(base, backup, old)
      with_lock(root, fn -> journal!(journal, record, "cleaned", opts) end, opts)
      :ok
    rescue
      error ->
        rollback_view!(root, base, stage, target, backup, record, journal, opts)
        reraise error, __STACKTRACE__
    end
  end

  defp rollback_view!(root, base, stage, target, backup, record, journal, opts) do
    actual_node = node_token!(target)
    saved_node = node_token!(backup)
    actual = if actual_node, do: tree_record(target)
    saved = if saved_node, do: tree_record(backup)

    with_lock(
      root,
      fn ->
        active_lease!(root, opts[:lease])
        same_node!(target, actual_node)
        same_node!(backup, saved_node)

        cond do
          actual == record["old"] and is_nil(saved) ->
            :ok

          actual == record["new"] and is_nil(saved) and record["old"] != nil ->
            :ok

          actual == record["new"] and (saved == record["old"] or is_nil(record["old"])) ->
            confine!(base, stage)
            if File.exists?(stage), do: raise(Error, "activation rollback stage is occupied")
            File.rename!(target, stage)
            if saved, do: File.rename!(backup, target)

          is_nil(actual) and saved == record["old"] and not is_nil(saved) ->
            File.rename!(backup, target)

          is_nil(actual) and is_nil(record["old"]) ->
            :ok

          true ->
            raise Error, "activation rollback is ambiguous; retain journal for recovery"
        end

        atomic_write!(journal, Identity.canonical(Map.put(record, "phase", "cleaned")))
      end,
      opts
    )
  end

  defp remove_observed!(base, target, expected) do
    confine!(base, target)
    unless tree_record(target) == expected, do: raise(Error, "activation backup changed")
    # File.rm_rf removes generated live symlinks themselves without traversing.
    File.rm_rf!(target)
  end

  defp journal!(path, record, phase, opts) do
    atomic_write!(path, Identity.canonical(Map.put(record, "phase", phase)))
    failpoint(opts, String.to_atom(phase))
  end

  @doc false
  def failpoint(opts, phase) do
    case opts[:failpoint] do
      fun when is_function(fun, 1) -> fun.(phase)
      ^phase -> raise Error, "injected failure at #{phase}"
      _ -> :ok
    end
  end

  @doc "Record immutable insertion and pointer transitions, leaving any old pointer intact until rename."
  def seal!(root, stage, target, pointer, pointer_bytes, validate!, opts \\ []) do
    base = path(root, [])
    for item <- [stage, target, pointer], do: confine!(base, item)
    active_lease!(root, opts[:lease])
    confine!(opts[:lease].stage, stage)
    validate!.(stage)
    stage_node = node_token!(stage)
    target_node = node_token!(target)
    if target_node, do: validate!.(target)
    id = nonce()
    journal_dir = Path.join([base, "staging", id])
    File.mkdir_p!(journal_dir)
    journal = Path.join(journal_dir, "journal.json")
    old = pointer_bytes!(pointer)

    record = %{
      "schema" => "weld.journal/2",
      "id" => id,
      "owner" => journal_owner(opts),
      "kind" => "bundle",
      "target" => Path.relative_to(target, base),
      "stage" => Path.relative_to(stage, base),
      "backup" => Path.relative_to(pointer, base),
      "old" => old,
      "new" => %{"pointer" => pointer_bytes, "tree" => tree_record(stage)},
      "phase" => "reserved"
    }

    try do
      with_lock(
        root,
        fn ->
          active_lease!(root, opts[:lease])
          same_node!(stage, stage_node)
          same_node!(target, target_node)

          unless pointer_bytes!(pointer) == old,
            do: raise(Error, "current pointer changed before bundle insertion")

          journal!(journal, record, "reserved", opts)

          unless target_node do
            File.mkdir_p!(Path.dirname(target))
            File.rename!(stage, target)
          end

          journal!(journal, record, "bundle_inserted", opts)
        end,
        opts
      )

      validate!.(target)

      unless tree_record(target) == record["new"]["tree"],
        do: raise(Error, "sealed bundle changed after insertion")

      failpoint(opts, :before_pointer)

      with_lock(
        root,
        fn ->
          active_lease!(root, opts[:lease])
          same_node!(target, target_node || stage_node)

          unless pointer_bytes!(pointer) == old,
            do: raise(Error, "current pointer changed before activation")

          atomic_write!(pointer, pointer_bytes)
          journal!(journal, record, "pointer_replaced", opts)
          journal!(journal, record, "committed", opts)
        end,
        opts
      )

      :ok
    rescue
      error ->
        with_lock(
          root,
          fn ->
            active_lease!(root, opts[:lease])
            actual = pointer_bytes!(pointer)

            cond do
              actual == old -> :ok
              actual == pointer_bytes and is_nil(old) -> File.rm!(pointer)
              actual == pointer_bytes -> atomic_write!(pointer, old)
              true -> raise Error, "pointer rollback is ambiguous; retain journal for recovery"
            end

            atomic_write!(journal, Identity.canonical(Map.put(record, "phase", "cleaned")))
          end,
          opts
        )

        reraise error, __STACKTRACE__
    end
  end

  def insert_immutable!(root, stage, target, opts \\ []) do
    base = path(root, [])
    for item <- [stage, target], do: confine!(base, item)
    active_lease!(root, opts[:lease])
    confine!(opts[:lease].stage, stage)
    reject_tree_links!(stage)
    unless File.dir?(stage), do: raise(Error, "immutable stage is missing")
    if File.exists?(target), do: raise(Error, "immutable destination already exists")
    stage_node = node_token!(stage)
    id = nonce()
    directory = Path.join([base, "staging", id])
    File.mkdir_p!(directory)

    record = %{
      "schema" => "weld.journal/2",
      "id" => id,
      "owner" => journal_owner(opts),
      "kind" => "immutable",
      "target" => Path.relative_to(target, base),
      "stage" => Path.relative_to(stage, base),
      "backup" => Path.relative_to(target, base),
      "old" => nil,
      "new" => tree_record(stage),
      "phase" => "reserved"
    }

    journal = Path.join(directory, "journal.json")

    with_lock(
      root,
      fn ->
        active_lease!(root, opts[:lease])
        same_node!(stage, stage_node)
        same_node!(target, nil)
        journal!(journal, record, "reserved", opts)
        File.mkdir_p!(Path.dirname(target))
        File.rename!(stage, target)
        journal!(journal, record, "committed", opts)
      end,
      opts
    )

    :ok
  end

  defp active_lease!(root, %{
         root: lease_root,
         path: lease_path,
         stage: lease_stage,
         record: expected
       }) do
    validate_lease!(expected)

    unless checkout(root) == lease_root and
             lease_path == path(root, ["leases", expected["id"] <> ".json"]) and
             lease_stage == path(root, ["staging", expected["id"]]) and
             read_record(lease_path, @lease_keys, "weld.lease/2") == {:ok, expected},
           do: raise(Error, "transition requires its unchanged active lease")

    :ok
  end

  defp active_lease!(_, _), do: raise(Error, "transition requires an active artifact lease")

  # Directory identity is a bounded CAS guard. The complete byte observations
  # are made outside the checkout lock while the exclusive resource lease holds.
  defp node_token!(path) do
    reject_link!(path)

    case File.lstat(path) do
      {:ok, stat} -> {stat.type, stat.major_device, stat.minor_device, stat.inode}
      {:error, :enoent} -> nil
      {:error, reason} -> raise Error, "cannot observe transition path: #{reason}"
    end
  end

  defp same_node!(path, expected) do
    unless node_token!(path) == expected, do: raise(Error, "transition path changed: #{path}")
  end

  defp pointer_bytes!(path) do
    reject_link!(path)

    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= 4096 -> File.read!(path)
      {:error, :enoent} -> nil
      _ -> raise Error, "cannot read bounded current pointer"
    end
  end

  defp journal_owner(opts), do: opts[:lease].record["owner"]

  def recovery_report(root) do
    base = path(root, [])
    lock = Path.join(base, "lock")

    lock_owner =
      case read_owner(Path.join(lock, "owner.json")) do
        {:ok, owner} -> %{owner: owner, liveness: owner_liveness(owner)}
        _ -> if File.exists?(lock), do: %{owner: nil, liveness: :unknown}
      end

    records =
      for file <- children(Path.join(base, "leases")) do
        case read_record(file, @lease_keys, "weld.lease/2") do
          {:ok, record} -> %{path: file, record: record, liveness: safe_liveness(record["owner"])}
          _ -> %{path: file, record: nil, liveness: :unknown}
        end
      end

    %{
      path: base,
      lock: lock_owner,
      leases: records,
      journals: journals(base),
      action:
        "Recover only an explicitly selected owner proved dead; publication intents remain unknown."
    }
  end

  def recover!(root, opts) do
    unless opts[:yes] == true and is_binary(opts[:lease]),
      do: raise(Error, "recovery requires explicit selection of a dead lease")

    id = segment!(opts[:lease])
    root = checkout(root)
    base = ensure_managed!(root)

    if id == "lock" do
      lock = path(root, ["lock"])

      case read_owner(Path.join(lock, "owner.json")) do
        {:ok, owner} ->
          unless owner_liveness(owner) == :dead,
            do: raise(Error, "lock owner is active or unknown")

          # Compare the same nonce immediately before deletion; never age-reap.
          unless read_owner(Path.join(lock, "owner.json")) == {:ok, owner},
            do: raise(Error, "lock owner changed")

          File.rm!(Path.join(lock, "owner.json"))
          File.rmdir!(lock)
          %{recovered: ["lock"]}

        _ ->
          raise Error, "lock ownership cannot be established"
      end
    else
      {lease_path, lease, selected} =
        with_lock(root, fn ->
          lease_path = path(root, ["leases", id <> ".json"])

          case read_record(lease_path, @lease_keys, "weld.lease/2") do
            {:ok, lease} ->
              validate_lease!(lease)
              unless lease["id"] == id, do: raise(Error, "lease path binding mismatch")

              unless owner_liveness(lease["owner"]) == :dead,
                do: raise(Error, "lease owner is active or unknown")

              all = journals(base)

              if Enum.any?(all, &is_nil(&1.record)),
                do: raise(Error, "corrupt journal ownership is unknown")

              selected = Enum.filter(all, &(&1.record["owner"] == lease["owner"]))
              {lease_path, lease, selected}

            _ ->
              raise Error, "lease ownership cannot be established"
          end
        end)

      # The dead lease continues to reserve its artifact while full trees are
      # checked. A racing recovery must compare this exact lease and journal
      # record again before it can apply any metadata transition.
      observations = Enum.map(selected, &observe_recovery!(base, &1.path, &1.record))
      failpoint(opts, :recovery_observed)

      with_lock(root, fn ->
        unless read_record(lease_path, @lease_keys, "weld.lease/2") == {:ok, lease} and
                 owner_liveness(lease["owner"]) == :dead,
               do: raise(Error, "recovery lease changed before completion")

        for observed <- observations do
          unless read_record(observed.path, @journal_keys, "weld.journal/2") ==
                   {:ok, observed.record},
                 do: raise(Error, "recovery journal changed before completion")

          for {target, token} <- observed.nodes, do: same_node!(target, token)
        end

        actions = Enum.map(observations, &complete_recovery!/1)
        File.rm!(lease_path)
        %{recovered: [id], actions: actions}
      end)
    end
  end

  defp observe_recovery!(base, path, record) do
    unless record["phase"] in ~w(reserved backed_up activated committed cleaned bundle_inserted pointer_replaced),
      do: raise(Error, "unknown journal phase")

    target = confine!(base, Path.join(base, record["target"]))
    stage = confine!(base, Path.join(base, record["stage"]))
    backup = confine!(base, Path.join(base, record["backup"]))
    nodes = Map.new([target, stage, backup], &{&1, node_token!(&1)})

    action =
      case record["kind"] do
        "view" ->
          actual = if File.exists?(target), do: tree_record(target)
          saved = if File.exists?(backup), do: tree_record(backup)

          cond do
            actual == record["new"] ->
              if saved do
                # Removal only discards the previously observed backup after the
                # complete installed view matches the durable new-tree digest.
                remove_observed!(base, backup, record["old"])
                {:removed_backup, backup}
              else
                :none
              end

            is_nil(actual) and saved == record["old"] and not is_nil(saved) and
                record["phase"] not in ["committed", "cleaned"] ->
              {:restore, backup, target}

            actual == record["old"] and is_nil(saved) and
                record["phase"] in ["reserved", "cleaned"] ->
              :none

            is_nil(actual) and is_nil(record["old"]) and File.dir?(stage) and
                record["phase"] == "reserved" ->
              :none

            true ->
              raise Error, "ambiguous activation; retained all paths: #{path}"
          end

        "immutable" ->
          unless (File.exists?(target) and tree_record(target) == record["new"]) or
                   (not File.exists?(target) and File.exists?(stage) and
                      tree_record(stage) == record["new"]),
                 do: raise(Error, "ambiguous immutable insertion; retained all paths: #{path}")

          :none

        "bundle" ->
          # Recovery never activates an unreferenced bundle or rewrites a newer pointer.
          actual =
            case File.read(backup) do
              {:ok, bytes} -> bytes
              {:error, :enoent} -> nil
              _ -> :unreadable
            end

          expected = record["new"]

          unless is_map(expected) and Enum.sort(Map.keys(expected)) == ~w(pointer tree),
            do: raise(Error, "invalid pointer journal")

          unless actual == record["old"] or
                   (actual == expected["pointer"] and File.dir?(target) and
                      tree_record(target) == expected["tree"]),
                 do: raise(Error, "pointer or sealed tree changed; retained all paths: #{path}")

          :none

        _ ->
          raise Error, "unknown journal kind"
      end

    {nodes, action} =
      case action do
        {:removed_backup, removed} -> {Map.put(nodes, removed, nil), :none}
        other -> {nodes, other}
      end

    %{path: path, record: record, nodes: nodes, action: action}
  end

  defp complete_recovery!(observed) do
    case observed.action do
      {:restore, backup, target} -> File.rename!(backup, target)
      :none -> :ok
    end

    atomic_write!(observed.path, Identity.canonical(Map.put(observed.record, "phase", "cleaned")))
    %{journal: observed.path, action: :recovered}
  end

  defp journals(base) do
    for directory <- children(Path.join(base, "staging")),
        File.dir?(directory),
        file = Path.join(directory, "journal.json"),
        File.exists?(file) do
      case read_record(file, @journal_keys, "weld.journal/2") do
        {:ok, record} ->
          try do
            valid_owner!(record["owner"])

            unless record["id"] == Path.basename(directory),
              do: raise(Error, "journal path binding mismatch")

            %{path: file, record: record}
          rescue
            _ -> %{path: file, record: nil}
          end

        _ ->
          %{path: file, record: nil}
      end
    end
  end

  def owner do
    %{
      "host" => host(),
      "boot_id" => boot_id(),
      "pid" => System.pid(),
      "token" => (process_start(System.pid()) || "unknown") <> "." <> nonce()
    }
  end

  def owner_liveness(owner) do
    valid_owner!(owner)
    [start, _nonce] = String.split(owner["token"], ".", parts: 2)

    cond do
      owner["host"] == "unknown" or owner["host"] != host() ->
        :unknown

      owner["boot_id"] == "unknown" or boot_id() == "unknown" or start == "unknown" ->
        :unknown

      owner["boot_id"] != boot_id() ->
        :dead

      true ->
        case process_start(owner["pid"]) do
          ^start -> :alive
          nil -> if File.exists?("/proc/" <> owner["pid"]), do: :unknown, else: :dead
          _other -> :dead
        end
    end
  end

  defp safe_liveness(owner) do
    owner_liveness(owner)
  rescue
    _ -> :unknown
  end

  defp valid_owner!(owner) do
    unless is_map(owner) and Enum.sort(Map.keys(owner)) == ~w(boot_id host pid token) and
             Enum.all?(Map.values(owner), &is_binary/1) and
             Regex.match?(~r/\A[0-9]+\z/, owner["pid"]) and
             Regex.match?(~r/\A(?:[0-9]+|unknown)\.[0-9a-f]{24}\z/, owner["token"]) and
             owner["host"] != "" and owner["boot_id"] != "",
           do: raise(Error, "invalid owner record")

    owner
  end

  defp read_owner(path) do
    case read_record(path, ~w(host boot_id pid token), nil) do
      {:ok, record} -> {:ok, valid_owner!(record)}
      other -> other
    end
  rescue
    _ -> {:error, :invalid_owner}
  end

  defp host do
    {:ok, hostname} = :inet.gethostname()

    machine =
      case File.read("/etc/machine-id") do
        {:ok, bytes} -> String.trim(bytes)
        _ -> "unknown"
      end

    if machine == "unknown",
      do: "unknown",
      else: Identity.raw([to_string(hostname), "\n", machine])
  end

  defp boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, bytes} -> String.trim(bytes)
      _ -> "unknown"
    end
  end

  defp process_start(pid) do
    with {:ok, bytes} <- File.read("/proc/" <> pid <> "/stat"),
         [_, fields] <- String.split(bytes, ") ", parts: 2),
         value when is_binary(value) <- fields |> String.split() |> Enum.at(19) do
      value
    else
      _ -> nil
    end
  end

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp read_record(path, keys, schema) do
    reject_link!(path)

    with {:ok, %{type: :regular, size: size}} when size <= 1024 * 1024 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(keys),
         true <- is_nil(schema) or value["schema"] == schema,
         true <- Identity.canonical(value) == bytes do
      {:ok, value}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp children(directory) do
    reject_link!(directory)

    case File.ls(directory) do
      {:ok, entries} ->
        Enum.sort(entries)
        |> Enum.map(fn name ->
          child = Path.join(directory, name)
          reject_link!(child)
          child
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise Error, "cannot list #{directory}: #{reason}"
    end
  end

  defp managed_base!(path) do
    parts = Path.split(Path.expand(path))
    index = Enum.find_index(Enum.chunk_every(parts, 2, 1, :discard), &(&1 == [".weld", "v2"]))
    unless is_integer(index), do: raise(Error, "path is outside managed Weld state")
    base = parts |> Enum.take(index + 2) |> Path.join()
    reject_ancestors!(base)
    reject_link!(Path.join(base, "OWNER"))

    unless File.read(Path.join(base, "OWNER")) == {:ok, @owner},
      do: raise(Error, "unmanaged Weld state")

    confine!(base, path)
    base
  end

  def confine!(base, target) do
    expanded = Path.expand(target)
    relative = Path.relative_to(expanded, Path.expand(base))

    if relative == "." or Path.type(relative) != :relative or String.starts_with?(relative, "../"),
      do: raise(Error, "refusing state root or out-of-root operation: #{target}")

    Enum.reduce(String.split(relative, "/"), base, fn part, parent ->
      segment!(part)
      child = Path.join(parent, part)
      reject_link!(child)
      child
    end)
  end

  def safe_remove!(base, target) do
    target = confine!(base, target)
    reject_tree_links!(target)
    File.rm_rf!(target)
  end

  defp tree_record(root) do
    entries = tree_entries(root, root)
    %{"sha256" => Identity.raw(Identity.canonical(entries))}
  end

  defp tree_entries(root, directory) do
    File.ls!(directory)
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      absolute = Path.join(directory, name)
      relative = Path.relative_to(absolute, root)

      case File.lstat!(absolute) do
        %{type: :directory} ->
          [%{"path" => relative, "type" => "directory"} | tree_entries(root, absolute)]

        %{type: :regular, mode: mode, size: size} ->
          [
            %{
              "path" => relative,
              "type" => "file",
              "sha256" => raw_file(absolute),
              "size" => size,
              "executable" => Bitwise.band(mode, 0o111) != 0
            }
          ]

        %{type: :symlink} ->
          [%{"path" => relative, "type" => "link", "target" => File.read_link!(absolute)}]

        _ ->
          raise Error, "unsafe activation entry: #{absolute}"
      end
    end)
  end

  defp raw_file(path) do
    path
    |> File.stream!(64_000, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp ensure_ignore!(checkout, base) do
    target = Path.join(checkout, ".gitignore")
    before = read_regular!(target)
    old = if before, do: elem(before, 0), else: ""
    updated = normalize_ignore!(old, base)

    if updated != old do
      with_metadata_lock(
        checkout,
        fn ->
          current = read_regular!(target)

          unless current && elem(current, 0) == updated do
            replace_ignore!(target, base, before, updated)
          end
        end,
        []
      )
    end

    if Git.root(checkout) do
      for path <- ~w(.weld/v2/live/probe .weld/v2/full/probe/project .weld/v2/cache/probe) do
        Git.run!(checkout, ["check-ignore", "--quiet", "--no-index", "--", path])
      end
    end
  end

  defp normalize_ignore!(old, base) do
    newline = if String.contains?(old, "\r\n"), do: "\r\n", else: "\n"
    lines = String.split(old, ~r/(?<=\n)/, trim: true)
    check_negations!(lines, base)

    {lines, found?} =
      Enum.map_reduce(lines, false, fn line, found? ->
        raw = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
        rule = Regex.replace(~r/\\(.)/, String.trim_trailing(raw, " "), fn _, char -> char end)

        cond do
          rule not in @ignore_rules -> {line, found?}
          found? -> {"", true}
          true -> {".weld/" <> String.replace_prefix(line, raw, ""), true}
        end
      end)

    contents = IO.iodata_to_binary(lines)

    cond do
      found? -> contents
      contents == "" or String.ends_with?(contents, "\n") -> contents <> ".weld/" <> newline
      true -> contents <> newline <> ".weld/" <> newline
    end
  end

  defp replace_ignore!(target, base, before, updated) do
    temp = Path.join(base, "ignore-" <> nonce())

    try do
      File.write!(temp, updated, [:exclusive])
      if before, do: File.chmod!(temp, elem(before, 1))
      if read_regular!(target) != before, do: raise(Error, ".gitignore changed during setup")
      File.rename!(temp, target)
    after
      File.rm(temp)
    end
  end

  # Ask Git to match the first rooted component. This handles wildcards,
  # bracket expressions, escapes and trailing spaces using its own grammar.
  # Explicit child exceptions are conflicts even if a later rule masks them.
  defp check_negations!(lines, base) do
    candidates =
      for "!" <> pattern <- lines,
          first = first_component(pattern),
          first != "",
          do: "/" <> first <> "/"

    unless candidates == [] do
      scratch = Path.join(base, "ignore-check-" <> nonce())
      File.mkdir!(scratch)

      try do
        Git.run!(scratch, ["-c", "init.templateDir=", "init", "--quiet"])
        File.write!(Path.join(scratch, ".gitignore"), Enum.join(candidates, "\n") <> "\n")

        args = [
          "-c",
          "core.excludesFile=/dev/null",
          "check-ignore",
          "--no-index",
          "--",
          ".weld/probe"
        ]

        case System.cmd("git", args, cd: scratch, stderr_to_stdout: true) do
          {_path, 0} -> raise Error, "conflicting .gitignore negation for .weld/"
          {_output, 1} -> :ok
          {output, _status} -> raise Error, "unable to check .gitignore exceptions: #{output}"
        end
      after
        File.rm_rf!(scratch)
      end
    end
  end

  defp first_component(pattern) do
    pattern
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
    |> String.trim_trailing(" ")
    |> String.trim_leading("/")
    |> String.replace(~r/^(?:\*\*\/)+/, "")
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp read_regular!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> {File.read!(path), Bitwise.band(mode, 0o7777)}
      {:error, :enoent} -> nil
      _ -> raise Error, "expected a regular file: #{path}"
    end
  end

  defp reject_ancestors!(path) do
    Path.split(Path.expand(path))
    |> Enum.reduce("", fn part, parent ->
      child = if parent == "", do: part, else: Path.join(parent, part)
      reject_link!(child)
      child
    end)

    :ok
  end

  def reject_link!(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> raise Error, "symlink is not permitted: #{path}"
      {:ok, %{type: type}} when type in [:regular, :directory] -> :ok
      {:ok, _} -> raise Error, "unsafe filesystem node: #{path}"
      {:error, :enoent} -> :ok
      {:error, reason} -> raise Error, "cannot inspect #{path}: #{reason}"
    end
  end

  def source!(root, relative) do
    parts = if is_binary(relative), do: String.split(relative, "/"), else: []

    if not is_binary(relative) or Path.type(relative) != :relative or
         String.contains?(relative, ["\\", <<0>>]) or
         Enum.any?(parts, &(&1 in ["", ".", ".." | @forbidden])) do
      raise Error, "unsafe source path: #{inspect(relative)}"
    end

    reject_ancestors!(root)

    Enum.reduce(parts, root, fn part, parent ->
      path = Path.join(parent, part)
      reject_link!(path)
      path
    end)
  end

  def cache!(root, key, toolchain) do
    with_lock(root, fn ->
      directory = path(root, ["cache", key, toolchain])
      marker = Path.join(directory, "OWNER")
      reject_link!(marker)

      if File.exists?(directory) do
        unless File.read(marker) == {:ok, @owner},
          do: raise(Error, "unmanaged cache: #{directory}")
      else
        File.mkdir_p!(directory)
        File.write!(marker, @owner, [:exclusive, :sync])
      end

      for child <- ["build", "deps"], do: reject_link!(Path.join(directory, child))
      directory
    end)
  end

  def temporary!(root, category) do
    ensure_managed!(root)
    directory = path(root, [category, nonce()])
    File.mkdir_p!(Path.dirname(directory))
    File.mkdir!(directory)
    directory
  end

  def reject_tree_links!(root) do
    reject_ancestors!(root)
    reject_tree_nodes!(root)
  end

  defp reject_tree_nodes!(root) do
    reject_link!(root)
    if File.dir?(root), do: Enum.each(File.ls!(root), &reject_tree_nodes!(Path.join(root, &1)))
    :ok
  end

  def nonce, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
