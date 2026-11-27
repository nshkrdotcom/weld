defmodule Weld.Core.ReleaseOrder do
  @moduledoc "Pure dependency ordering for a coordinated release."

  @doc false
  def constraints(artifacts) do
    ensure_unique_packages!(artifacts)
    versions = Map.new(artifacts, fn artifact ->
      unless match?({:ok, _}, Version.parse(artifact.version)),
        do: raise(Weld.Error, code: :invalid_plan, phase: :plan, message: "Invalid release version for #{artifact.package}")
      {artifact.package, artifact.version}
    end)

    for a <- artifacts,
        dep <- a.dependencies,
        is_binary(dep.requirement),
        is_nil(dep.opts[:git]) and is_nil(dep.opts[:github]) and is_nil(dep.opts[:path]),
        package = to_string(dep.opts[:hex] || dep.app),
        version = Map.get(versions, package) do
      requirement =
        case Version.parse_requirement(dep.requirement) do
          {:ok, requirement} ->
            requirement

          :error ->
            raise(
              Weld.Error,
              "Invalid requirement for #{a.package} -> #{package}: #{dep.requirement}"
            )
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
      witness = cycle_witness(Enum.map(blocked, & &1.package), deps)
      raise(Weld.Error, code: :dependency_cycle, phase: :plan,
        message: "Release dependency cycle: " <> Enum.join(witness, " -> "),
        details: %{cycle: witness})
    end

    order_layers(blocked, deps, ordered ++ ready)
  end

  defp cycle_witness(vertices, deps) do
    graph = %{Weld.Graph.new() | projects: Map.new(vertices, &{&1, nil})}
    graph = Enum.reduce(vertices, graph, fn from, graph ->
      Enum.reduce(Map.get(deps, from, []), graph, fn to, graph ->
        Weld.Graph.add_edge(graph, %Weld.Graph.Edge{from: from, to: to, app: :release, kind: :runtime, opts: []})
      end)
    end)
    case Weld.Graph.topology(graph, :package) do
      {:cycle, witness} -> witness
      _ -> vertices
    end
  end

  defp ensure_unique_packages!(artifacts) do
    duplicates =
      artifacts
      |> Enum.frequencies_by(& &1.package)
      |> Enum.filter(fn {_package, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [] do
      raise(Weld.Error, code: :duplicate_package, phase: :plan, message: "Duplicate release package identities: " <> Enum.join(duplicates, ", "))
    end
  end
end
