defmodule Mix.Tasks.Weld.Docs.Check do
  use Mix.Task

  alias Weld.{DocsSmoke, TaskSupport}

  @moduledoc """
  Run static (and optional `--browser`) smoke checks on a generated ExDoc
  directory, verifying `index.html` and Mermaid `exdoc:loaded` hook integrity.
  """

  @shortdoc "Smoke-check generated ExDoc HTML and Mermaid hooks"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [browser: :boolean, format: :string])

    TaskSupport.reject_invalid!(invalid)
    docs_dir = List.first(positional) || "doc"

    case DocsSmoke.check(docs_dir, browser: opts[:browser] || false) do
      {:ok, summary} ->
        case opts[:format] do
          "json" ->
            Mix.shell().info(Jason.encode_to_iodata!(summary, pretty: true))

          _ ->
            Mix.shell().info(
              "Docs smoke check passed: #{summary.html_count} HTML pages, " <>
                "#{length(summary.mermaid_pages)} Mermaid page(s) in #{summary.docs_dir}"
            )
        end

      {:error, errors} ->
        Mix.raise("Docs smoke check failed:\n" <> Enum.map_join(errors, "\n", &("  - " <> &1)))
    end
  after
    Mix.Task.reenable("weld.docs.check")
  end
end
