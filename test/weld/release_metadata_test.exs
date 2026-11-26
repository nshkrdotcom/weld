defmodule Weld.ReleaseMetadataTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  test "Weld package metadata is release complete and narrowly allowlisted" do
    project = Mix.Project.config()

    manifest = Weld.Manifest.load!(Path.join(@repo_root, "build_support/weld.exs"))
    artifact = Weld.Plan.build!(manifest, artifact: :weld).artifact
    assert artifact.mode == :source_project
    assert artifact.package.version == project[:version]
    assert artifact.package.otp_app == project[:app]
    assert artifact.package.description == project[:description]

    assert project[:package][:files] ==
             ~w(lib assets guides mix.exs README.md LICENSE CHANGELOG.md)

    assert project[:docs][:main] == "readme"
    assert project[:docs][:logo] == "assets/weld.svg"
    assert project[:docs][:source_ref] == "v#{project[:version]}"
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
end
