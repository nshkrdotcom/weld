defmodule Weld.MonolithTestHelperSpikeTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "fails loudly when selected-package helper code assumes its original package otp app" do
    manifest_path = FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
    repo_root = manifest_path |> Path.dirname() |> Path.join("../..") |> Path.expand()

    File.write!(
      Path.join(repo_root, "runtime/api/test/test_helper.exs"),
      """
      ExUnit.start()

      {:ok, _} = Application.ensure_all_started(:fixture_store)
      """
    )

    assert_raise Weld.Error, ~r/fixture_store/, fn ->
      Weld.project!(manifest_path)
    end
  end

  test "fails loudly when package helpers try to globalize database setup" do
    manifest_path = FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
    repo_root = manifest_path |> Path.dirname() |> Path.join("../..") |> Path.expand()

    File.write!(
      Path.join(repo_root, "core/store/test/test_helper.exs"),
      """
      ExUnit.start()

      Fixture.Store.Support.setup_database!()
      """
    )

    assert_raise Weld.Error, ~r/helper side effect/, fn ->
      Weld.project!(manifest_path)
    end
  end
end
