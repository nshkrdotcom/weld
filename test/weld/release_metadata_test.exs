defmodule Weld.ReleaseMetadataTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  test "0.16.0 package metadata is release complete and narrowly allowlisted" do
    project = Mix.Project.config()

    assert project[:version] == "0.16.0"
    manifest = Weld.Manifest.load!(Path.join(@repo_root, "build_support/weld.exs"))
    artifact = Weld.Manifest.artifact!(manifest, :weld)
    assert artifact.mode == :source_project
    assert artifact.package.version == project[:version]
    assert artifact.package.otp_app == project[:app]
    assert artifact.package.description == project[:description]

    assert project[:package][:files] ==
             ~w(lib assets guides mix.exs README.md LICENSE CHANGELOG.md)

    assert project[:docs][:main] == "readme"
    assert project[:docs][:logo] == "assets/weld.svg"
    assert project[:docs][:source_ref] == "v0.16.0"
    assert length(project[:docs][:groups_for_extras]) == 4

    assert Enum.map(project[:deps], &elem(&1, 0)) == [
             :blitz,
             :credo,
             :dialyxir,
             :ex_doc,
             :jason,
             :multigraph,
             :nimble_options,
             :telemetry
           ]

    refute Enum.any?(project[:deps], fn dependency ->
             options = dependency |> Tuple.to_list() |> Enum.find([], &is_list/1)
             Enum.any?([:path, :git, :github], &Keyword.has_key?(options, &1))
           end)

    assert "cmd env MIX_ENV=test mix run --no-start scripts/test_ci.exs" in project[:aliases][:ci]
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
    assert changelog =~ "## [0.16.0] - 2026-11-24"
    assert changelog =~ "## [0.15.0] - 2026-11-24"

    assert svg =~ "width=\"200\" height=\"200\" viewBox=\"0 0 200 200\""
    refute svg =~ ~r/<rect[^>]+(?:width="200"|height="200")/
  end
end
