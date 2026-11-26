defmodule Mix.Tasks.Weld.Release.Prepare do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Prepare deterministic release bundles for one or all welded artifacts.
  """

  @shortdoc "Prepare a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [artifact: :string, all: :boolean, reuse: :string, cache: :boolean]
      )

    usage =
      "Usage: mix weld.release.prepare [manifest_path] [--artifact name | --all] [--reuse context] [--no-cache]"

    TaskSupport.reject_invalid!(invalid)
    if opts[:artifact] && opts[:all], do: Mix.raise("Pass either --artifact or --all, not both")
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    base_opts = Keyword.put(opts, :no_cache, opts[:cache] == false)

    if opts[:all] do
      TaskSupport.each_release_artifact!(manifest_path, fn id ->
        result = Weld.release_prepare!(manifest_path, Keyword.put(base_opts, :artifact, id))
        print_result(result, manifest_path)
      end)
    else
      result = Weld.release_prepare!(manifest_path, base_opts)
      print_result(result, manifest_path)
    end
  after
    Mix.Task.reenable("weld.release.prepare")
  end

  defp print_result(result, manifest_path) do
    action = if result.reused?, do: "Reused release bundle in", else: "Prepared release bundle in"
    Mix.shell().info("#{action} #{result.bundle_path}")
    Mix.shell().info("Identity #{result.identity}")
    Mix.shell().info("Project #{result.project_path}")
    Mix.shell().info("Docs #{Path.join(result.docs_path, "index.html")}")
    if result.tarball_path, do: Mix.shell().info("Archive #{result.tarball_path}")

    next = TaskSupport.release_command("track", manifest_path, result.artifact, result.identity)
    Mix.shell().info("Next: #{next} --tag-release --push")

    Enum.each(result.warnings, fn warning ->
      Mix.shell().error("Warning: #{warning}")
    end)
  end
end
