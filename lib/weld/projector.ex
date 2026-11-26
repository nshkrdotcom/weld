defmodule Weld.Projector do
  @moduledoc """
  Generates the welded Mix project and its initial lockfile.
  """

  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Lockfile
  alias Weld.Output
  alias Weld.Plan
  alias Weld.Plan.Inventory
  alias Weld.Layout.{FilePlan, Flat, Support}
  alias Weld.Projector.SourceProject
  alias Weld.Receipt

  @spec project!(Plan.t(), keyword()) :: map()
  def project!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> project_locked!(plan, opts) end)
  end

  def project_locked!(plan, opts) do
    Plan.ensure_valid!(plan)
    kind = if opts[:live], do: :live, else: :full

    root = plan.manifest.repo_root
    Support.validate_inputs!(plan)
    target = build_path(plan, kind)
    receipt = Output.path(root, ["cache", "projection", plan.artifact.id, "#{kind}.receipt"])
    revision = Git.revision(root)
    input = input_digest(plan, revision, kind)

    case reused_projection(receipt, input, target, kind, opts) do
      {:ok, result} ->
        Map.put(result, :reused?, true)

      :miss ->
        stage_projection!(plan, kind, target, receipt, input, revision)
    end
  end

  defp reused_projection(receipt, input, target, kind, opts) do
    with false <- Keyword.get(opts, :no_cache, false),
         {:ok, {expected, %{build_path: ^target} = projection}} <- Receipt.read(receipt, input),
         ^expected <- output_digest(target, kind) do
      {:ok, projection}
    else
      _ -> :miss
    end
  end

  defp output_digest(target, kind) do
    Receipt.digest(Receipt.tree(target, kind == :live))
  rescue
    Error -> :unsafe
  end

  @doc false
  def input_digest(plan, revision, kind) do
    root = plan.manifest.repo_root

    roots = Enum.map(plan.source_roots, & &1.source)

    # Generated config is read separately from component source roots. Include
    # missing directories so adding the first config file also invalidates reuse.
    config_roots =
      for project <- plan.selected_projects,
          plan.artifact.mode != :source_project,
          do: Inventory.checkout_path(project, "config")

    paths =
      Enum.reduce(plan.source_inventory, roots, fn %{source: source}, covered ->
        if Enum.any?(roots, &Inventory.covered?(source, &1)),
          do: covered,
          else: [source | covered]
      end) ++ plan.structural_inputs ++ config_roots

    files =
      for path <- paths |> Enum.uniq() |> Enum.sort(),
          do: {path, root |> Output.source!(path) |> Receipt.tree()}

    Receipt.digest(
      {Receipt.implementation(), kind, revision, Git.remote_url(root), plan, files,
       Weld.Shell.Inputs.collect!(plan), Hash.sha256_file(plan.manifest.manifest_path)}
    )
  end

  defp stage_projection!(plan, kind, target, receipt, input, revision) do
    root = plan.manifest.repo_root
    stage = Output.temporary!(root, "staging")

    try do
      projection =
        case plan.artifact.mode do
          :source_project -> SourceProject.project!(plan, stage, kind)
          _ -> project_by_mode!(plan, stage, kind)
        end

      linked = Map.get(projection, :linked_files, [])

      inventory =
        Hash.list_files(stage)
        |> Enum.map(&Path.relative_to(&1, stage))
        |> Kernel.++(linked)
        |> Enum.uniq()
        |> Enum.sort()

      if plan.layout do
        expected = Enum.map(plan.output_inventory, & &1.target) |> Enum.sort()

        unless inventory == expected,
          do: raise(Error, "materialized inventory differs from plan")

        if kind == :full do
          observed = Weld.Shell.Files.observe_many!(stage, expected) |> Map.new(&{&1.target, &1})

          unless Enum.all?(
                   Weld.Core.Inventory.diff(plan.output_inventory, observed),
                   &(&1.state == :identical)
                 ), do: raise(Error, "materialized bytes or executable modes differ from plan")
        end
      end

      files = inventory -- linked
      tree_digest = write_marker!(stage, plan.artifact.id, kind)

      projection =
        Map.merge(projection, %{
          copied_files: files,
          linked_files: linked,
          verification_files: inventory,
          build_path: target,
          git_revision: revision,
          tree_digest: tree_digest
        })

      lockname = "projection.lock.json"
      lockfile = Lockfile.build(plan, projection, [])
      File.write!(Path.join(stage, lockname), Lockfile.encode!(lockfile), [:exclusive])
      reject_published_reports!(stage, projection)

      unless input_digest(plan, Git.revision(root), kind) == input do
        raise Error, "source inputs changed during projection"
      end

      digest = output_digest(stage, kind)
      Output.activate!(stage, target, &managed?(&1, plan.artifact.id, kind))
      result = Map.put(projection, :lockfile_path, Path.join(target, lockname))
      Receipt.write!(receipt, input, {digest, result})
      Map.put(result, :reused?, false)
    after
      File.rm_rf!(stage)
    end
  end

  defp reject_published_reports!(stage, %{package_patterns: patterns}) do
    paths = Enum.flat_map(patterns, &expand_report_pattern(stage, &1))

    for report <- ~w(weld.provenance.json projection.lock.json),
        Path.join(stage, report) in paths do
      raise Error, "native package allowlist includes generated publication metadata: #{report}"
    end
  end

  defp reject_published_reports!(_stage, _projection), do: :ok

  defp expand_report_pattern(stage, pattern) do
    Path.wildcard(Path.join(stage, pattern), match_dot: true)
    |> Enum.flat_map(&expand_report_path/1)
  end

  defp expand_report_path(path), do: if(File.dir?(path), do: Hash.list_files(path), else: [path])

  defp write_marker!(stage, artifact, kind) do
    marker = %{schema: "weld.projection/v1", artifact: artifact, kind: kind}
    {marker, digest} = projection_digests!(stage, kind, marker)

    File.write!(Path.join(stage, "weld.provenance.json"), Jason.encode!(marker, pretty: true), [
      :exclusive
    ])

    digest
  end

  defp projection_digests!(stage, :full, marker) do
    Output.reject_tree_links!(stage)
    {Map.put(marker, :artifact_id, Hash.content_identity(stage)), Hash.sha256_tree(stage)}
  end

  defp projection_digests!(_stage, :live, marker), do: {marker, nil}

  defp managed?(target, artifact, kind) do
    path = Path.join(target, "weld.provenance.json")
    Output.reject_link!(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema" => "weld.projection/v1", "artifact" => ^artifact, "kind" => value}} <-
           Jason.decode(bytes) do
      value == Atom.to_string(kind)
    else
      _ -> false
    end
  end

  @doc false
  def with_output_lock(%Plan{} = plan, fun), do: Output.with_lock(plan.manifest.repo_root, fun)

  @spec build_path(Plan.t(), :live | :full) :: Path.t()
  def build_path(plan, kind \\ :full)

  def build_path(%Plan{} = plan, :full),
    do: Output.path(plan.manifest.repo_root, ["full", plan.artifact.id, "project"])

  def build_path(%Plan{} = plan, :live),
    do: Output.path(plan.manifest.repo_root, ["live", plan.artifact.id])

  defp project_by_mode!(%Plan{artifact: %{mode: :monolith}} = plan, build_path, kind) do
    Flat.materialize!(plan, build_path, kind: kind)
  end

  defp project_by_mode!(%Plan{layout: layout} = plan, build_path, kind) do
    operations = Map.fetch!(layout, kind)

    {linked, remaining} =
      if kind == :live do
        linked = Enum.flat_map(layout.live_roots, &materialize_root!(plan, build_path, &1, kind))
        {linked, Enum.reject(operations, &(&1.target in linked))}
      else
        {[], operations}
      end

    files = FilePlan.materialize!(remaining, build_path, kind)

    %{
      copied_files: files,
      linked_files: linked,
      package_files: layout.package_files,
      config_warnings: layout.config_warnings
    }
  end

  defp materialize_root!(plan, build_path, entry, kind) do
    source = Output.source!(plan.manifest.repo_root, entry.source)
    target = Output.source!(build_path, entry.target)
    Output.reject_tree_links!(source)

    unless File.exists?(source), do: raise(Error, "missing planned source: #{entry.source}")
    if File.exists?(target), do: raise(Error, "projection path collision: #{entry.target}")
    File.mkdir_p!(Path.dirname(target))

    files = if File.dir?(source), do: Hash.list_files(source), else: [source]

    projected =
      Enum.map(files, fn path ->
        if path == source,
          do: entry.target,
          else: Path.join(entry.target, Path.relative_to(path, source))
      end)

    case kind do
      :full ->
        File.cp_r!(source, target)

      :live ->
        case File.ln_s(source, target) do
          :ok ->
            :ok

          {:error, reason} ->
            raise Error, "live projection needs symlink support for #{entry.target}: #{reason}"
        end
    end

    projected
  end
end
