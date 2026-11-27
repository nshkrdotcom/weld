defmodule Weld.GitDependencyPortabilityTest do
  use ExUnit.Case, async: true
  @moduletag :pure

  alias Weld.{Graph, LiteralPlan, Plan}
  alias Weld.Core.Compiler

  test "local Git locators remain distinct from remote URLs and scp syntax" do
    for source <- ["/outside/provider.git", "../provider.git", "./provider:copy",
                   "vendor/provider.git", "vendor/provider:copy", "file:///outside/provider.git",
                   "file://localhost/outside/provider.git", "FILE:///outside/provider.git",
                   "C:/vendor/provider.git", "C:\\vendor\\provider.git", "\\\\host\\provider.git"] do
      assert Graph.local_git_locator?(source), source
    end

    for source <- ["https://example.test/provider.git", "ssh://git@example.test/provider.git",
                   "git://example.test/provider.git", "git@example.test:provider.git",
                   "host:/remote/provider.git", "file:provider.git"] do
      refute Graph.local_git_locator?(source), source
    end
  end

  test "non-Hex compilation rejects effective local Git dependencies before rendering" do
    for source <- ["/outside/provider.git", "file:///outside/provider.git",
                   "../provider.git", "vendor/provider.git"] do
      plan = compile([git: source, ref: "pinned"])
      assert [%{code: :nonportable_git_dependency, project: "apps/a", dependency: :provider,
                details: %{source_kind: :generated}}] = plan.violations
      assert plan.layout == nil
      assert plan.output_inventory == []
    end
  end

  test "canonical remote and Hex replacements eliminate the local generated dependency" do
    for replacement <- [%{requirement: nil, opts: [git: "https://example.test/provider.git", ref: "pinned"]},
                        %{requirement: "~> 1.0", opts: []}] do
      plan = compile([git: "/outside/provider.git", ref: "local-ref"], replacement)
      assert plan.violations == []
      assert [%{requirement: requirement, opts: opts}] = plan.external_deps
      assert requirement == replacement.requirement
      assert opts == replacement.opts
      refute rendered_mix(plan) =~ "/outside/provider.git"
      refute rendered_mix(plan) =~ "local-ref"
    end
  end

  test "remote Git survives non-Hex generation while Hex policy remains enforced" do
    for source <- ["https://example.test/provider.git", "ssh://git@example.test/provider.git",
                   "git@example.test:provider.git"] do
      plan = compile([git: source, ref: "pinned"])
      assert plan.violations == []
      assert rendered_mix(plan) =~ source
      hex_plan = compile([git: source, ref: "pinned"], nil, hex_build: true)
      assert Enum.any?(hex_plan.violations, &(&1.code == :unsupported_publication_dependency))
      refute Enum.any?(hex_plan.violations, &(&1.code == :nonportable_git_dependency))
    end
  end

  test "test-only local Git is checked only when included in the standalone project" do
    source = [git: "/outside/test-provider.git", ref: "pinned", only: :test]
    without_tests = compile(source)
    assert without_tests.violations == []
    refute rendered_mix(without_tests) =~ "/outside/test-provider.git"
    with_tests = compile(source, nil, component_tests: true)
    assert Enum.any?(with_tests.violations, &(&1.code == :nonportable_git_dependency))
    assert with_tests.layout == nil
  end

  test "a canonical graph override cannot make an unchanged native local Git declaration portable" do
    replacement = %{requirement: nil, opts: [git: "https://example.test/provider.git", ref: "pinned"]}
    plan = compile([git: "/outside/provider.git"], replacement, mode: :source_project)
    assert Enum.any?(plan.violations, fn violation ->
      violation.code == :nonportable_git_dependency and violation.details.source_kind == :native
    end)
    assert plan.layout == nil
  end

  test "flat explicitly forced test dependencies cannot reintroduce a local Git locator" do
    policy = %{requirement: nil, opts: [git: "file:///outside/provider.git", ref: "pinned"]}
    plan = compile(nil, policy, mode: :monolith, extra_test_deps: [:provider])
    assert Enum.any?(plan.violations, fn violation ->
      violation.code == :nonportable_git_dependency and
        violation.details.source_kind == :flat_extra_test
    end)
    assert plan.layout == nil
  end

  defp rendered_mix(plan), do: Enum.find(plan.layout.full, &(&1.target == "mix.exs")).content

  defp compile(source_opts, canonical \\ nil, opts \\ []) do
    plan = LiteralPlan.build()
    deps = if source_opts, do: [%{app: :provider, requirement: nil, opts: source_opts,
      original: {:provider, source_opts}}], else: []
    project = %{plan.workspace.projects["apps/a"] | deps: deps,
      deps_by_env: Map.new([:dev, :test, :prod], &{&1, deps})}
    projects = %{project.id => project}
    mode = opts[:mode] || :package_projection
    artifact = %{plan.artifact | mode: mode,
      verify: %{plan.artifact.verify | hex_build: opts[:hex_build] || false,
        component_tests: opts[:component_tests] || false},
      monolith_opts: if(mode == :monolith, do: [extra_test_deps: opts[:extra_test_deps] || []], else: [])}
    artifact = if artifact.mode == :source_project do
      %{artifact | source_project: [files: ["mix.exs", "lib"]],
        package: %{artifact.package | otp_app: project.app, name: project.package_name}}
    else
      artifact
    end
    manifest = %{plan.manifest | dependencies: if(canonical, do: %{provider: canonical}, else: %{}),
      artifacts: %{artifact.id => artifact}}
    graph = Graph.build(manifest, projects)
    workspace = %{plan.workspace | manifest: manifest, projects: projects, graph: graph}
    struct!(Plan, Compiler.compile!(manifest, workspace, artifact, []))
  end
end
