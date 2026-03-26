defmodule Weld.AuditTest do
  use ExUnit.Case

  alias Weld.Audit
  alias Weld.FixtureCase
  alias Weld.Manifest

  test "reports app-identity-sensitive code and blocks strict bundles" do
    manifest = Manifest.load!(FixtureCase.manifest_path("strict_bundle", "sample"))
    report = Audit.scan!(manifest)

    assert Enum.any?(report.findings, &(&1.pattern == "Application.app_dir"))

    assert_raise Weld.Error, ~r/app-identity-sensitive/, fn ->
      Weld.audit!(FixtureCase.manifest_path("strict_bundle", "sample"))
    end
  end
end
