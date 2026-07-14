defmodule Weld.ReleaseMetadataTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  test "0.8.3 package metadata is release complete and narrowly allowlisted" do
    project = Mix.Project.config()

    assert project[:version] == "0.8.3"

    assert project[:package][:files] ==
             ~w(lib priv/templates assets guides mix.exs README.md LICENSE CHANGELOG.md)

    assert project[:docs][:main] == "readme"
    assert project[:docs][:logo] == "assets/weld.svg"
    assert project[:docs][:source_ref] == "v0.8.3"
    assert length(project[:docs][:groups_for_extras]) == 4

    assert "cmd env MIX_ENV=test mix test" in project[:aliases][:ci]
    assert "cmd env MIX_ENV=test mix credo --strict" in project[:aliases][:ci]
  end

  test "README, license, changelog, and SVG satisfy the public presentation contract" do
    readme = File.read!(Path.join(@repo_root, "README.md"))
    license = File.read!(Path.join(@repo_root, "LICENSE"))
    changelog = File.read!(Path.join(@repo_root, "CHANGELOG.md"))
    svg = File.read!(Path.join(@repo_root, "assets/weld.svg"))

    assert String.starts_with?(readme, "<p align=\"center\">\n  <img src=\"assets/weld.svg\"")
    assert readme =~ "width=\"200\""
    assert readme =~ "https://github.com/nshkrdotcom/weld"
    assert readme =~ "license-MIT"
    assert length(Regex.scan(~r/img\.shields\.io/, readme)) == 2

    assert license =~ "MIT License"
    assert license =~ "Copyright (c) 2026 nshkrdotcom"
    assert changelog =~ "## [0.8.3] - 2026-07-13"

    assert svg =~ "width=\"200\" height=\"200\" viewBox=\"0 0 200 200\""
    assert svg =~ "M100 14L173 57V143L100 186L27 143V57L100 14Z"
    refute svg =~ ~r/<rect[^>]+(?:width="200"|height="200")/
  end
end
