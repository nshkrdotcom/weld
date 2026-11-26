defmodule Mix.Tasks.Weld.Release.Plan do
  use Mix.Task

  alias Weld.{Plan, TaskSupport}

  @moduledoc """
  Show coordinated multi-artifact release order for all artifacts in a Weld
  manifest, ordering base packages before dependent extension packages.
  Pass `--format json` for machine-readable output.
  """

  @shortdoc "Show coordinated multi-artifact release order"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [format: :string])
    TaskSupport.reject_invalid!(invalid)
    usage = "Usage: mix weld.release.plan [manifest_path] [--format json]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

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
          external_projects: plan.artifact.external_projects
        }
      end)
      |> Enum.sort_by(fn a -> {length(a.external_projects), a.artifact} end)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(artifacts, pretty: true))

      _ ->
        artifacts
        |> Enum.with_index(1)
        |> Enum.each(fn {a, idx} ->
          Mix.shell().info("#{idx}. #{a.artifact} (#{a.package} #{a.version}, #{a.mode})")
        end)
    end
  after
    Mix.Task.reenable("weld.release.plan")
  end
end
