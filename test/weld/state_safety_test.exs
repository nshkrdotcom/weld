defmodule Weld.StateSafetyTest do
  use ExUnit.Case, async: false
  alias Weld.{Error, FixtureCase, Output}
  alias Weld.Shell.GC
  alias Weld.Core.Identity

  @moduletag timeout: 60_000

  setup do
    root = FixtureCase.unique_tmp_dir("weld-state-contract")
    FixtureCase.git_output!(root, ["init", "--quiet"])
    Output.setup!(root)
    %{root: root}
  end

  test "distinct artifact leases progress while the same resource and cache key are exclusive", %{
    root: root
  } do
    Output.with_lease(root, "project", "one", "projection:full", [], fn _ ->
      assert :other =
               Output.with_lease(root, "project", "two", "projection:full", [], fn -> :other end)

      assert_raise Error, ~r/reserved/, fn ->
        Output.reserve!(root, "project", "one", "projection:full", [])
      end
    end)

    Output.with_lease(root, "cache", "one", "cache:shared", [], fn _ ->
      assert_raise Error, ~r/reserved/, fn ->
        Output.reserve!(root, "cache", "two", "cache:shared", [])
      end
    end)

    assert Output.leases(root) == []
  end

  test "owner validation rejects foreign hosts, unavailable boot facts and reused PIDs", %{
    root: root
  } do
    owner = Output.owner()
    assert Output.owner_liveness(owner) == :alive
    assert Output.owner_liveness(Map.put(owner, "host", "foreign-host")) == :unknown
    assert Output.owner_liveness(Map.put(owner, "boot_id", "unknown")) == :unknown
    assert Output.owner_liveness(Map.put(owner, "token", "0." <> Output.nonce())) == :dead
    assert_raise Error, fn -> Output.owner_liveness(Map.put(owner, "unexpected", true)) end

    Output.with_lease(root, "verify", "one", "verify", [], fn lease ->
      assert_raise Error, ~r/active or unknown/, fn ->
        Output.recover!(root, lease: lease.record["id"], yes: true)
      end
    end)
  end

  test "every mutable activation boundary preserves a complete prior or new view", %{root: root} do
    target = Output.path(root, ["full", "demo", "project"])

    for transition <- [:reserved, :backed_up, :activated, :committed, :cleaned] do
      File.mkdir_p!(target)
      File.write!(Path.join(target, "value"), "old")

      Output.with_lease(root, "project", "demo", "projection:full", [], fn lease ->
        stage = Path.join(lease.stage, "project")
        File.mkdir!(stage)
        File.write!(Path.join(stage, "value"), "new")

        assert_raise Error, ~r/injected/, fn ->
          Output.activate!(stage, target, &File.regular?(Path.join(&1, "value")),
            lease: lease,
            failpoint: transition
          )
        end

        assert File.read!(Path.join(target, "value")) in ["old", "new"]
      end)
    end
  end

  test "immutable seal faults never advance a pointer after an ordinary failed call", %{
    root: root
  } do
    pointer = Output.path(root, ["current", "demo"])

    old =
      Identity.canonical(%{
        "schema" => "weld.current/2",
        "artifact" => "demo",
        "bundle_id" => String.duplicate("a", 64)
      })

    new =
      Identity.canonical(%{
        "schema" => "weld.current/2",
        "artifact" => "demo",
        "bundle_id" => String.duplicate("b", 64)
      })

    for transition <- [
          :reserved,
          :bundle_inserted,
          :before_pointer,
          :pointer_replaced,
          :committed
        ] do
      Output.write_atomic!(pointer, old)

      Output.with_lease(root, "prepare", "demo", "prepare", [], fn lease ->
        stage = Path.join(lease.stage, "bundle")
        File.mkdir!(stage)
        File.write!(Path.join(stage, "proof"), "sealed")
        target = Output.path(root, ["bundles", "demo", Output.nonce()])
        validate = fn path -> assert File.read!(Path.join(path, "proof")) == "sealed" end

        assert_raise Error, ~r/injected/, fn ->
          Output.seal!(root, stage, target, pointer, new, validate,
            lease: lease,
            failpoint: transition
          )
        end

        assert File.read!(pointer) == old
      end)
    end
  end

  test "slow immutable validation leaves the checkout lock available to another artifact", %{
    root: root
  } do
    parent = self()

    task =
      Task.async(fn ->
        Output.with_lease(root, "prepare", "one", "prepare", [], fn lease ->
          stage = Path.join(lease.stage, "bundle")
          File.mkdir!(stage)
          File.write!(Path.join(stage, "proof"), "sealed")
          target = Output.path(root, ["bundles", "one", String.duplicate("b", 64)])
          pointer = Output.path(root, ["current", "one"])

          validate = fn path ->
            send(parent, {:validating, self(), path})

            receive do
              :continue_validation -> :ok
            after
              10_000 -> flunk("validation barrier was not released")
            end

            assert File.read!(Path.join(path, "proof")) == "sealed"
          end

          transition = fn
            :reserved -> assert File.regular?(Output.path(root, ["lock", "owner.json"]))
            _ -> :ok
          end

          Output.seal!(root, stage, target, pointer, "new-pointer", validate,
            lease: lease,
            failpoint: transition
          )
        end)
      end)

    for _ <- 1..2 do
      assert_receive {:validating, worker, _path}, 10_000

      assert :available =
               Output.with_lease(
                 root,
                 "project",
                 "two",
                 "projection:full",
                 [],
                 fn -> :available end,
                 lock_timeout: 100
               )

      send(worker, :continue_validation)
    end

    assert Task.await(task, 10_000) == :ok
  end

  test "mutable ownership validation runs outside its short rename section", %{root: root} do
    target = Output.path(root, ["full", "one", "project"])
    File.mkdir_p!(target)
    File.write!(Path.join(target, "value"), "old")

    Output.with_lease(root, "project", "one", "projection:full", [], fn lease ->
      stage = Path.join(lease.stage, "project")
      File.mkdir!(stage)
      File.write!(Path.join(stage, "value"), "new")

      ownership = fn _ ->
        assert :available =
                 Output.with_lease(
                   root,
                   "project",
                   "two",
                   "projection:full",
                   [],
                   fn -> :available end,
                   lock_timeout: 100
                 )

        true
      end

      transition = fn
        :reserved -> assert File.regular?(Output.path(root, ["lock", "owner.json"]))
        _ -> :ok
      end

      assert :ok = Output.activate!(stage, target, ownership, lease: lease, failpoint: transition)
      assert File.read!(Path.join(target, "value")) == "new"
    end)
  end

  @tag :process_contract
  test "independent OS processes exclude one resource while distinct artifacts remain available",
       %{root: root} do
    ready = Path.join(root, "first-ready")

    child =
      child!(root, """
      Weld.Output.with_lease(root, "verify", "one", "verify", [], fn _ ->
        File.write!(#{inspect(ready)}, "ready")
        Process.sleep(:infinity)
      end)
      """)

    await_file!(ready)
    on_exit(fn -> stop_child(child) end)
    assert :free = Output.with_lease(root, "verify", "two", "verify", [], fn -> :free end)

    assert_raise Error, ~r/reserved/, fn ->
      Output.reserve!(root, "verify", "one", "verify", [])
    end

    [{_, lease}] = Output.leases(root)
    stop_child(child)
    await_dead!(lease["owner"])
    assert %{recovered: [id]} = Output.recover!(root, lease: lease["id"], yes: true)
    assert id == lease["id"]
    assert Output.leases(root) == []
  end

  @tag :process_contract
  test "killed owner after backup rename restores durable old view before releasing lease", %{
    root: root
  } do
    target = Output.path(root, ["full", "demo", "project"])
    File.mkdir_p!(target)
    File.write!(Path.join(target, "value"), "old")
    ready = Path.join(root, "renamed-ready")

    child =
      child!(root, """
      Weld.Output.with_lease(root, "project", "demo", "projection:full", [], fn lease ->
        stage = Path.join(lease.stage, "project")
        File.mkdir!(stage)
        File.write!(Path.join(stage, "value"), "new")
        Weld.Output.activate!(stage, #{inspect(target)}, fn path -> File.regular?(Path.join(path, "value")) end,
          lease: lease, failpoint: fn phase ->
            if phase == :backed_up do
              File.write!(#{inspect(ready)}, lease.record["id"])
              Process.sleep(:infinity)
            end
          end)
      end)
      """)

    on_exit(fn -> stop_child(child) end)
    await_file!(ready)
    id = File.read!(ready)

    assert_raise Error, ~r/lock busy/, fn ->
      Output.with_lock(root, fn -> :ok end, lock_timeout: 25)
    end

    stop_child(child)
    report = Output.recovery_report(root)
    await_dead!(report.lock.owner)
    assert %{recovered: ["lock"]} = Output.recover!(root, lease: "lock", yes: true)

    unrelated = fn
      :recovery_observed ->
        assert :available =
                 Output.with_lease(
                   root,
                   "project",
                   "other",
                   "projection:full",
                   [],
                   fn -> :available end,
                   lock_timeout: 100
                 )

      _ ->
        :ok
    end

    assert %{recovered: [^id]} = Output.recover!(root, lease: id, yes: true, failpoint: unrelated)
    assert File.read!(Path.join(target, "value")) == "old"
  end

  @tag :process_contract
  test "GC never races an active independent run and retains unknown ownership", %{root: root} do
    ready = Path.join(root, "run-ready")

    child =
      child!(root, """
      Weld.Output.with_lease(root, "verify", "one", "verify", [], fn lease ->
        run = Weld.Output.run!(root, "verify", "one", lease)
        Weld.Output.update_run!(run, %{"phase" => "executing"})
        File.write!(#{inspect(ready)}, run.path)
        Process.sleep(:infinity)
      end)
      """)

    on_exit(fn -> stop_child(child) end)
    await_file!(ready)
    run_path = File.read!(ready)
    assert run_path in GC.prune(root, keep: 0).active
    assert GC.prune(root, keep: 0, dry_run: false).removed == []
    assert File.dir?(run_path)
    stop_child(child)
    assert GC.prune(root, keep: 0, dry_run: false).removed == []
    File.write!(Output.path(root, ["leases", "corrupt.json"]), "{}")
    assert GC.prune(root, keep: 0).unknown_ownership
    assert GC.prune(root, keep: 0, dry_run: false).removed == []
  end

  test "GC defaults to read-only and removes only complete strict run records", %{root: root} do
    run =
      Output.with_lease(root, "stage", "one", "review", [], fn lease ->
        run = Output.run!(root, "stage", "one", lease)
        Output.finish_run!(run, "completed")
        run
      end)

    before = File.read!(Path.join(run.path, "run.json"))
    assert GC.prune(root, keep: 0).removed == [run.path]
    assert File.read!(Path.join(run.path, "run.json")) == before
    assert GC.prune(root, keep: 0, dry_run: false).removed == [run.path]
    refute File.exists?(run.path)
  end

  defp child!(root, body) do
    executable =
      System.find_executable("elixir") || flunk("Elixir executable required for process contract")

    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    script = "Application.ensure_all_started(:crypto)\nroot = #{inspect(root)}\n" <> body

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      {:args, paths ++ ["-e", script]}
    ])
  end

  defp stop_child(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end
  end

  defp await_file!(path, attempts \\ 500)
  defp await_file!(path, 0), do: flunk("child never wrote #{path}")

  defp await_file!(path, attempts) do
    if File.regular?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_file!(path, attempts - 1)
        )
  end

  defp await_dead!(owner, attempts \\ 500)
  defp await_dead!(_owner, 0), do: flunk("killed owner remained live or unknown")

  defp await_dead!(owner, attempts) do
    if Output.owner_liveness(owner) == :dead,
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_dead!(owner, attempts - 1)
        )
  end
end
