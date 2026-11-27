defmodule Weld.SnapshotIndexTest do
  use ExUnit.Case, async: true

  alias Weld.{Error, FixtureCase}
  alias Weld.Shell.Snapshot

  test "overlapping watched roots refresh once without refreshing prefix siblings" do
    root = FixtureCase.unique_tmp_dir("snapshot-index")
    for dir <- ["lib/nested", "library", "other"], do: File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join(root, "lib/old.ex"), "old")
    File.write!(Path.join(root, "library/keep.ex"), "keep")
    File.write!(Path.join(root, "other/keep.ex"), "keep")
    facts = Snapshot.observe!(root)

    File.rm!(Path.join(root, "lib/old.ex"))
    File.write!(Path.join(root, "lib/nested/new.ex"), "new")
    File.write!(Path.join(root, "library/keep.ex"), "unselected change")
    File.mkdir!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/runtime.exs"), "appeared")

    inputs = [
      %{"kind" => "tree", "fact" => %{"root" => "lib"}},
      %{"kind" => "file", "fact" => %{"path" => "lib/nested/new.ex"}},
      %{"kind" => "absence", "fact" => %{"path" => "config"}}
    ]

    refreshed = Snapshot.refresh!(facts, inputs)
    refute Map.has_key?(refreshed.nodes, Path.join(root, "lib/old.ex"))
    assert refreshed.nodes[Path.join(root, "lib/nested/new.ex")].content == "new"
    assert refreshed.nodes[Path.join(root, "config/runtime.exs")].content == "appeared"

    assert refreshed.nodes[Path.join(root, "library/keep.ex")] ==
             facts.nodes[Path.join(root, "library/keep.ex")]

    whole = [%{"kind" => "tree", "fact" => %{"root" => "."}} | inputs]
    assert Snapshot.refresh!(facts, whole).nodes == Snapshot.observe!(root).nodes
  end

  test "selected paths cannot escape the workspace" do
    root = FixtureCase.unique_tmp_dir("snapshot-index")
    facts = Snapshot.observe!(root)
    inputs = [%{"kind" => "file", "fact" => %{"path" => "../outside.txt"}}]
    assert_raise Error, ~r/unsafe source path/, fn -> Snapshot.refresh!(facts, inputs) end
  end
end
