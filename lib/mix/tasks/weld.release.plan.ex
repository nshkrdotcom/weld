defmodule Mix.Tasks.Weld.Release.Plan do
  use Mix.Task

  alias Weld.{Plan, TaskSupport}

  @moduledoc """
  Show coordinated multi-artifact release order for all artifacts in a Weld
  manifest, ordering depended-on packages first. For every artifact whose root
  `mix.exs` declares a Hex requirement on another artifact's package (parsed via
  Elixir AST), checks the requirement against that artifact's version and fails
  if unsatisfied (use `--no-check` to report only). Pass `--format json` for
  machine-readable output.
  """

  @shortdoc "Show coordinated multi-artifact release order"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [format: :string, no_check: :boolean])

    TaskSupport.reject_invalid!(invalid)
    usage = "Usage: mix weld.release.plan [manifest_path] [--no-check] [--format json]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)
    repo_root = Path.dirname(manifest_path) |> find_repo_root()

    artifacts =
      manifest_path
      |> Weld.artifact_ids!()
      |> Enum.map(fn id ->
        plan = Plan.build!(manifest_path, artifact: id)

        %{
          artifact: plan.artifact.id,
          package: plan.artifact.package.name,
          version: plan.artifact.package.version,
          mode: Atom.to_string(plan.artifact.mode),
          roots: plan.artifact.roots
        }
      end)

    constraints = constraints(artifacts, repo_root)
    artifacts = order(artifacts, constraints)
    bad = Enum.reject(constraints, & &1.satisfied)

    case opts[:format] do
      "json" ->
        Mix.shell().info(
          Jason.encode_to_iodata!(%{order: artifacts, constraints: constraints}, pretty: true)
        )

      _ ->
        artifacts
        |> Enum.with_index(1)
        |> Enum.each(fn {a, idx} ->
          Mix.shell().info("#{idx}. #{a.artifact} (#{a.package} #{a.version}, #{a.mode})")
        end)

        for c <- constraints do
          Mix.shell().info(
            "  #{c.package} requires #{c.dependency} #{c.requirement}: " <>
              if(c.satisfied,
                do: "ok (#{c.dependency_version})",
                else: "UNSATISFIED (#{c.dependency_version})"
              )
          )
        end
    end

    if bad != [] and not (opts[:no_check] || false) do
      Mix.raise(
        "Unsatisfied version constraints: " <>
          Enum.map_join(bad, ", ", &"#{&1.package} -> #{&1.dependency} #{&1.requirement}")
      )
    end
  after
    Mix.Task.reenable("weld.release.plan")
  end

  @doc false
  def constraints(artifacts, repo_root) do
    versions = Map.new(artifacts, &{&1.package, &1.version})

    for a <- artifacts,
        root <- a.roots,
        mix_exs = Path.join([repo_root, root, "mix.exs"]),
        File.regular?(mix_exs),
        {dep, req} <- extract_dep_requirements(File.read!(mix_exs), mix_exs),
        dep != a.package,
        version = Map.get(versions, dep) do
      %{
        package: a.package,
        dependency: dep,
        requirement: req,
        dependency_version: version,
        satisfied: Version.match?(version, req)
      }
    end
  end

  defp extract_dep_requirements(source, file) do
    ast = Code.string_to_quoted!(source, file: file)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {dep, req} = node, acc when is_atom(dep) and is_binary(req) ->
          maybe_collect_req(node, dep, req, acc)

        {:{}, _, [dep, req, opts]} = node, acc
        when is_atom(dep) and is_binary(req) and is_list(opts) ->
          maybe_collect_req(node, dep, req, acc)

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  defp maybe_collect_req(node, dep, req, acc) do
    if match?({:ok, _}, Version.parse_requirement(req)) do
      {node, [{Atom.to_string(dep), req} | acc]}
    else
      {node, acc}
    end
  end

  @doc false
  def order(artifacts, constraints) do
    deps = Enum.group_by(constraints, & &1.package, & &1.dependency)
    Enum.sort_by(artifacts, fn a -> {depth(a.package, deps, MapSet.new()), a.package} end)
  end

  defp depth(package, deps, seen) do
    if MapSet.member?(seen, package) do
      0
    else
      deps
      |> Map.get(package, [])
      |> Enum.map(&(1 + depth(&1, deps, MapSet.put(seen, package))))
      |> Enum.max(fn -> 0 end)
    end
  end

  defp find_repo_root(dir) do
    cond do
      File.dir?(Path.join(dir, ".git")) -> dir
      Path.dirname(dir) == dir -> File.cwd!()
      true -> find_repo_root(Path.dirname(dir))
    end
  end
end
