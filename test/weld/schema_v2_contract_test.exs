defmodule Weld.SchemaV2ContractTest do
  use ExUnit.Case, async: true
  alias Weld.Core.Manifest

  test "closed schema reports every nested duplicate and unknown key before defaults" do
    spec = base()
    spec = Keyword.put(spec, :classify, tooling: [], tooling: [], mystery: [])

    spec =
      Keyword.put(spec, :dependencies,
        dep: [requirement: "~> 1.0", opts: [runtime: false, runtime: true, path: "../dep"]]
      )

    spec =
      put_in(spec, [:artifacts, :demo, :docs],
        mermaid: true,
        hook_file: "hook.html",
        hook_file: "other.html",
        unknown: true
      )

    spec =
      put_in(spec, [:artifacts, :demo, :verify], smoke: [entry_file: "smoke.exs", stray: true])

    assert {:error, diagnostics} = Manifest.normalize(spec)
    paths = MapSet.new(diagnostics, & &1.details.path)

    for path <-
          ~w(classify.tooling classify.mystery dependencies.dep.opts.runtime dependencies.dep.opts.path artifacts.demo.docs.hook_file artifacts.demo.docs.unknown artifacts.demo.verify.smoke.stray) do
      assert MapSet.member?(paths, path)
    end

    assert Enum.all?(diagnostics, &(&1.phase == :manifest and &1.severity == :error))
    assert Enum.any?(diagnostics, &(&1.code == :unknown_key and is_list(&1.details.allowed)))
  end

  test "normalized identifiers and declarations have one deterministic representation" do
    spec = base() |> Keyword.put(:publication, optional: [native: ["native/codec"]])
    spec = put_in(spec, [:artifacts, :demo, :features], ["native"])

    spec =
      Keyword.put(spec, :project_inputs, [
        {"native/codec", [[path: "native", type: :tree, roles: [:native], target: :relative]]}
      ])

    assert {:ok, normalized} = Manifest.normalize(spec)
    assert [{"demo", artifact}] = normalized[:artifacts]
    assert artifact[:features] == ["native"]
    assert normalized[:publication][:optional] == [{"native", ["native/codec"]}]
    assert normalized[:project_inputs]["native/codec"] |> hd() |> Keyword.fetch!(:publish)
    assert {:ok, ^normalized} = Manifest.normalize(Enum.reverse(spec))
  end

  test "normalized duplicate collection keys cannot disappear in a map conversion" do
    for {key, value} <- [
          {:artifacts, [{:demo, base()[:artifacts][:demo]}, {"demo", base()[:artifacts][:demo]}]},
          {:project_inputs, [{:"core/a", []}, {"core/a", []}]},
          {:dependencies, [{:dep, [requirement: "~> 1.0"]}, {"dep", [requirement: "~> 1.0"]}]}
        ] do
      assert {:error, diagnostics} = Manifest.normalize(Keyword.put(base(), key, value))
      assert Enum.any?(diagnostics, &(&1.code == :duplicate_key))
    end
  end

  test "path escaping, forbidden state and literal/glob confusion are rejected" do
    for path <- [
          "../outside",
          "/tmp/outside",
          "lib/../secret",
          "lib//x",
          "C:/outside",
          ".git/config",
          "_build/cache",
          "lib\\x",
          "native/*"
        ] do
      spec = put_in(base(), [:artifacts, :demo, :inputs], [[path: path, type: :file]])

      assert {:error, [%{code: :unsafe_path, details: %{path: "artifacts.demo.inputs[0].path"}}]} =
               Manifest.normalize(spec)
    end

    assert {:ok, _} =
             Manifest.normalize(
               put_in(base(), [:artifacts, :demo, :inputs], [
                 [path: "native/**/*", type: :glob, required: false]
               ])
             )
  end

  test "layout combinations and publication roles are validated rather than ignored" do
    invalid = [
      put_in(base(), [:artifacts, :demo, :flat], []),
      put_in(base(), [:artifacts, :demo, :docs], hook_file: "hook.html"),
      put_in(base(), [:artifacts, :demo, :verify], hex_build: false),
      put_in(base(), [:artifacts, :demo, :external], ["."]),
      put_in(base(), [:artifacts, :demo, :features], ["missing"]),
      Keyword.put(base(), :publication, internal_only: ["."], separate: ["."]),
      Keyword.put(base(), :classify, tooling: ["."], proofs: ["."])
    ]

    for spec <- invalid, do: assert(match?({:error, [_ | _]}, Manifest.normalize(spec)))

    assert {:ok, _} =
             Manifest.normalize(
               put_in(base(), [:artifacts, :demo, :verify],
                 hex_build: false,
                 hex_publish_check: false
               )
             )
  end

  test "preserve paths are disjoint and own their native metadata and tests" do
    preserve = [layout: :preserve, roots: ["."], preserve: [files: ["mix.exs", "lib"]]]
    assert {:ok, _} = Manifest.normalize(Keyword.put(base(), :artifacts, demo: preserve))

    for extra <- [
          package: [],
          docs: [],
          files: [],
          include: ["core/other"],
          verify: [artifact_tests: ["tests"]]
        ] do
      assert {:error, _} =
               Manifest.normalize(
                 Keyword.put(base(), :artifacts, demo: Keyword.merge(preserve, [extra]))
               )
    end

    overlapping = put_in(preserve, [:preserve, :files], ["mix.exs", "lib", "lib/nested"])

    assert {:error, [%{code: :overlapping_paths}]} =
             Manifest.normalize(Keyword.put(base(), :artifacts, demo: overlapping))
  end

  test "dependency source, scope and requirement options are closed and meaningful" do
    valid = [
      requirement: nil,
      opts: [git: "https://example.test/dep.git", ref: "abcdef", runtime: false]
    ]

    assert {:ok, _} = Manifest.normalize(Keyword.put(base(), :dependencies, dep: valid))

    for dep <- [
          [opts: []],
          [requirement: "invalid"],
          [requirement: 1],
          [requirement: "~> 1.0", opts: [branch: "main"]],
          [opts: [git: "https://example.test/dep.git", github: "org/dep"]],
          [opts: [git: "https://example.test/dep.git", ref: "a", tag: "v1"]],
          [requirement: "~> 1.0", opts: [only: ["test"]]],
          [requirement: "~> 1.0", opts: [unknown: true]]
        ] do
      assert {:error, _} = Manifest.normalize(Keyword.put(base(), :dependencies, dep: dep))
    end
  end

  test "mixed input roles require an explicit publication decision and target" do
    input = [path: "native", type: :tree, roles: [:native, :test], target: :relative]
    spec = Keyword.put(base(), :project_inputs, [{".", [input]}])
    assert {:error, [%{code: :unsupported_combination}]} = Manifest.normalize(spec)

    assert {:ok, _} =
             Manifest.normalize(
               Keyword.put(base(), :project_inputs, [{".", [Keyword.put(input, :publish, false)]}])
             )

    input = input |> Keyword.put(:publish, true) |> Keyword.put(:target, :none)

    assert {:error, [%{code: :unsupported_combination}]} =
             Manifest.normalize(Keyword.put(base(), :project_inputs, [{".", [input]}]))
  end

  defp base do
    [
      schema: 2,
      workspace: [root: "..", projects: ["."]],
      artifacts: [
        demo: [
          layout: :components,
          roots: ["."],
          package: [name: "demo", otp_app: :demo, version: "1.0.0"]
        ]
      ]
    ]
  end
end
