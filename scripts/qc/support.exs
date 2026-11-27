defmodule Weld.QC do
  @moduledoc false
  alias Weld.Core.Identity
  alias Weld.{Git, Hash, Output, Plan, SmokeApp, Verifier}

  def matrix!(target, scenarios \\ scenarios()) do
    target = Path.expand(target)
    unless File.mkdir(target) == :ok, do: raise("QC output must be a new directory: #{target}")
    results = Enum.map(scenarios, &run_scenario!(target, &1))
    write_matrix!(target, results)
    results
  end

  # CI lanes own different scenario directories under one caller-owned root.
  # The standalone driver keeps the same sequential matrix API and wire format.
  def scenario!(target, layout) do
    scenario = Enum.find(scenarios(), fn {name, _, _} -> name == layout end)
    unless scenario, do: raise("unknown QC layout: #{layout}")
    run_scenario!(Path.expand(target), scenario)
  end

  def finish_matrix!(target) do
    results =
      for {layout, _, _} <- scenarios() do
        result = Jason.decode!(File.read!(Path.join([target, layout, "result.json"])))
        unless result["layout"] == layout, do: raise("QC layout result does not match: #{layout}")
        result
      end

    write_matrix!(target, results)
  end

  defp write_matrix!(target, results) do
    File.write!(
      Path.join(target, "matrix.json"),
      Jason.encode!(%{schema: "weld.qc-matrix/2", results: results}, pretty: true),
      [:exclusive]
    )
  end

  defp run_scenario!(target, {layout, fixture, manifest}) do
    run = Path.join(target, layout)
    File.mkdir!(run)
    source = Path.join(run, "source")
    fixture = Path.expand("../../test/fixtures/" <> fixture, __DIR__)
    Output.reject_tree_links!(fixture)
    File.cp_r!(fixture, source)
    # A managed QC run may be nested under the tool checkout. Give each
    # disposable fixture its own canonical Git root before loading it.
    Git.run!(source, ["init", "--quiet"])
    Output.setup!(source)
    Git.run!(source, ["add", "."])

    Git.run!(source, [
      "-c",
      "user.name=Weld QC",
      "-c",
      "user.email=weld-qc@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      "Disposable exact archive qualification fixture"
    ])

    unless Git.root(source) == source,
      do: raise("fixture canonical root escaped its disposable checkout")

    plan = Plan.build!(Path.join(source, manifest))
    # The flat fixture declares an unused Git override. It must stay outside
    # the actual selected graph; the harness never removes dependencies.
    if layout == "flat" and Enum.any?(plan.external_deps, &(&1.app == :git_dep)),
      do: raise("unused Git declaration entered the selected publication graph")

    qualified = Verifier.verify!(plan, no_cache: true, context: "qc_" <> layout)
    tar = Path.join(run, "package.tar")
    File.cp!(qualified.tarball_path, tar)
    File.cp!(qualified.docs_archive_path, Path.join(run, "docs.tar.gz"))
    File.cp_r!(qualified.docs_path, Path.join(run, "docs"))
    evidence = Path.join(run, "evidence")
    File.mkdir!(evidence)
    qualification_root = Path.dirname(qualified.build_path)

    for name <- ~w(gates.json verification.json),
        do: File.cp!(Path.join(qualification_root, name), Path.join(evidence, name))

    for log <- Path.wildcard(Path.join(qualification_root, "**/*.log")) do
      relative = Path.relative_to(log, qualification_root)
      destination = Path.join(evidence, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(log, destination)
    end

    File.write!(
      Path.join(evidence, "qualification.json"),
      Identity.canonical(qualified.qualification),
      [:exclusive]
    )

    smoke =
      if plan.artifact.verify.smoke.entry_file,
        do: File.read!(Output.source!(source, plan.artifact.verify.smoke.entry_file))

    File.rm_rf!(source)
    if File.exists?(source), do: raise("original fixture checkout remains")

    consumer =
      SmokeApp.archive!(tar, Path.join(run, "detached-consumer"), smoke,
        offline_rebuild: layout == "native"
      )

    result = %{
      "layout" => layout,
      "archive_sha256" => Hash.sha256_file(tar),
      "docs_archive_sha256" => Hash.sha256_file(Path.join(run, "docs.tar.gz")),
      "original_source_removed" => true,
      "canonical_checkout_root_isolated" => true,
      "ordinary_hex_consumer" => consumer,
      "selected_projects" => plan.selected_ids,
      "selected_external_dependencies" => Enum.map(plan.external_deps, &to_string(&1.app)),
      "gates" => qualified.gates,
      "source_pins" =>
        if(layout == "native", do: File.read!(Path.join(fixture, "checksums.sha256")))
    }

    File.write!(Path.join(run, "result.json"), Jason.encode!(result, pretty: true), [:exclusive])
    result
  end

  def scenarios do
    [
      {"components", "library_bundle", "packaging/weld/fixture_bundle.exs"},
      {"flat", "monolith_bundle", "packaging/weld/monolith_bundle.exs"},
      {"preserve", "source_project", "build_support/weld.exs"},
      {"native", "native_hex", "build_support/weld.exs"}
    ]
  end

  def native_context!(nil), do: :ok

  def native_context!(path) do
    context = Jason.decode!(File.read!(path))

    unless Enum.sort(Map.keys(context)) == ["native_env", "public_facts"] and
             is_map(context["native_env"]) and is_map(context["public_facts"]),
           do: raise("native context requires native_env and public_facts objects")

    Application.put_env(:weld, :native_env, Enum.sort(context["native_env"]))
    Application.put_env(:weld, :qualification_context, context["public_facts"])
    :ok
  end
end
