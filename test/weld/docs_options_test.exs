defmodule Weld.DocsOptionsTest do
  use ExUnit.Case, async: false

  alias Weld.{FixtureCase, Manifest, Plan, Projector}

  test "root docs options do not load Mix projects while project configuration is being built" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Manifest.load!(manifest).repo_root
    File.write!(Path.join(root, "runtime/local/mix.exs"), "raise \"recursive project load\"")

    options = Weld.docs_options!(manifest)

    assert options[:main] == "readme"
    assert options[:before_closing_body_tag].(:html) == Projector.mermaid_hook()
  end

  test "generated docs options preserve complete large custom hooks" do
    manifest = hook_manifest!("library_bundle", "fixture_bundle")
    root = Manifest.load!(manifest).repo_root
    hook = "<!-- " <> String.duplicate("long hook body ", 600) <> " -->\n"
    File.write!(Path.join(root, "build_support/docs_hook.html"), hook)
    plan = Plan.build!(manifest)

    {options, []} = plan |> Projector.render_docs_options() |> Code.eval_string()

    assert options[:before_closing_body_tag].(:html) == hook
    assert options[:before_closing_body_tag].(:epub) == ""
  end

  test "hook changes invalidate full and live projections in both generated modes" do
    for {fixture, artifact} <- [
          {"library_bundle", "fixture_bundle"},
          {"monolith_bundle", "monolith_bundle"}
        ] do
      manifest = hook_manifest!(fixture, artifact)
      plan = Plan.build!(manifest)
      hook_path = Path.join(plan.manifest.repo_root, "build_support/docs_hook.html")

      assert "build_support/docs_hook.html" in plan.structural_inputs

      for live? <- [false, true] do
        before = Weld.project!(manifest, live: live?)
        assert Weld.project!(manifest, live: live?).reused?
        hook = "<!-- #{artifact} live=#{live?} updated hook -->\n"
        File.write!(hook_path, hook)

        after_change = Weld.project!(manifest, live: live?)

        refute after_change.reused?
        assert after_change.build_path == before.build_path

        assert File.read!(Path.join(after_change.build_path, "mix.exs")) =~
                 String.trim(hook)
      end
    end
  end

  test "custom hook paths reject traversal and symlink targets" do
    manifest = hook_manifest!("library_bundle", "fixture_bundle")
    plan = Plan.build!(manifest)
    outside = Path.join(FixtureCase.unique_tmp_dir("weld_outside_hook"), "hook.html")
    File.write!(outside, "<!-- outside -->")
    File.write!(Path.expand("../hook.html", plan.manifest.repo_root), "<!-- traversed -->")
    link = Path.join(plan.manifest.repo_root, "build_support/linked_hook.html")
    File.ln_s!(outside, link)

    for path <- ["../hook.html", outside, "build_support/linked_hook.html"] do
      unsafe = put_in(plan.artifact.package.docs.hook_file, path)

      assert_raise Weld.Error, fn -> Projector.mermaid_hook(unsafe) end
    end
  end

  defp hook_manifest!(fixture, artifact) do
    manifest = FixtureCase.copied_manifest_path(fixture, artifact)
    root = Manifest.load!(manifest).repo_root
    File.mkdir_p!(Path.join(root, "build_support"))
    File.write!(Path.join(root, "build_support/docs_hook.html"), "<!-- original -->\n")
    {raw, _binding} = Code.eval_file(manifest)

    raw =
      update_in(raw, [:artifacts, String.to_existing_atom(artifact), :package, :docs], fn docs ->
        Keyword.merge(docs, mermaid: true, hook_file: "build_support/docs_hook.html")
      end)

    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
    manifest
  end
end
