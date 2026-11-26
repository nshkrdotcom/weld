defmodule Mix.Tasks.Weld.Release.Plan do
  use Mix.Task

  alias Weld.{Plan, TaskSupport}

  @moduledoc """
  Show coordinated multi-artifact release order for all artifacts in a Weld
  manifest, ordering depended-on packages first. Uses each artifact's resolved
  publication dependencies, including canonical dependency declarations and Hex
  package aliases. Checks sibling package requirements against their release
  versions and fails if unsatisfied (use `--no-check` to report only).
  Cycles and ambiguous package identities always fail. Pass `--format json`
  for machine-readable output.
  """

  @shortdoc "Show coordinated multi-artifact release order"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [format: :string, check: :boolean])

    TaskSupport.reject_invalid!(invalid)
    usage = "Usage: mix weld.release.plan [manifest_path] [--no-check] [--format json]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    artifacts =
      manifest_path
      |> Weld.artifact_ids!()
      |> Enum.map(fn id ->
        plan = manifest_path |> Plan.build!(artifact: id) |> Plan.ensure_valid!()

        %{
          artifact: plan.artifact.id,
          package: plan.artifact.package.name,
          version: plan.artifact.package.version,
          mode: Atom.to_string(plan.artifact.mode),
          roots: plan.artifact.roots,
          dependencies: plan.external_deps
        }
      end)

    constraints = constraints(artifacts)
    artifacts = artifacts |> order(constraints) |> Enum.map(&Map.delete(&1, :dependencies))
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

    if bad != [] and Keyword.get(opts, :check, true) do
      Mix.raise(
        "Unsatisfied version constraints: " <>
          Enum.map_join(bad, ", ", &"#{&1.package} -> #{&1.dependency} #{&1.requirement}")
      )
    end
  after
    Mix.Task.reenable("weld.release.plan")
  end

  @doc false
  def constraints(artifacts) do
    ensure_unique_packages!(artifacts)
    versions = Map.new(artifacts, &{&1.package, &1.version})

    for a <- artifacts,
        dep <- a.dependencies,
        is_binary(dep.requirement),
        is_nil(dep.opts[:git]) and is_nil(dep.opts[:github]) and is_nil(dep.opts[:path]),
        package = to_string(dep.opts[:hex] || dep.app),
        version = Map.get(versions, package) do
      requirement =
        case Version.parse_requirement(dep.requirement) do
          {:ok, requirement} -> requirement
          :error ->
            Mix.raise("Invalid requirement for #{a.package} -> #{package}: #{dep.requirement}")
        end

      %{
        package: a.package,
        dependency: package,
        requirement: dep.requirement,
        dependency_version: version,
        satisfied: Version.match?(version, requirement)
      }
    end
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.package, &1.dependency, &1.requirement})
  end

  @doc false
  def order(artifacts, constraints) do
    ensure_unique_packages!(artifacts)
    deps = Enum.group_by(constraints, & &1.package, & &1.dependency)
    order_layers(Enum.sort_by(artifacts, & &1.package), deps, [])
  end

  defp order_layers([], _deps, ordered), do: ordered

  defp order_layers(remaining, deps, ordered) do
    packages = MapSet.new(remaining, & &1.package)

    {ready, blocked} =
      Enum.split_with(remaining, fn artifact ->
        deps
        |> Map.get(artifact.package, [])
        |> Enum.all?(fn dependency -> not MapSet.member?(packages, dependency) end)
      end)

    if ready == [] do
      Mix.raise(
        "Release dependency cycle involving: " <> Enum.map_join(blocked, ", ", & &1.package)
      )
    end

    order_layers(blocked, deps, ordered ++ ready)
  end

  defp ensure_unique_packages!(artifacts) do
    duplicates =
      artifacts
      |> Enum.frequencies_by(& &1.package)
      |> Enum.filter(fn {_package, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [] do
      Mix.raise("Duplicate release package identities: " <> Enum.join(duplicates, ", "))
    end
  end
end
