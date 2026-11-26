defmodule Weld.Core.ReleaseOrder do
  @moduledoc "Pure dependency ordering for a coordinated release."

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
      raise(
        Weld.Error,
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
      raise(Weld.Error, "Duplicate release package identities: " <> Enum.join(duplicates, ", "))
    end
  end
end
