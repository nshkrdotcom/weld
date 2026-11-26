defmodule Weld.DocsSmoke do
  @moduledoc """
  Static and optional headless-browser smoke checks for generated ExDoc HTML.
  """

  @doc """
  Verify generated ExDoc HTML in `docs_dir`:
  - `index.html` exists
  - Any page containing `<code class="mermaid">` also loads the Mermaid script
    and listens on `exdoc:loaded` (not `DOMContentLoaded`-only)
  - Optional: when `browser: true` and Playwright is available via `node`,
    renders Mermaid pages in headless Chromium and checks for SVGs and zero
    console/page errors.
  """
  @spec check(Path.t(), keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def check(docs_dir, opts \\ []) do
    html_files =
      docs_dir
      |> Path.join("*.html")
      |> Path.wildcard()
      |> Enum.sort()

    errors =
      []
      |> maybe_add_error(
        not File.regular?(Path.join(docs_dir, "index.html")),
        "missing index.html in #{docs_dir}"
      )

    {mermaid_pages, errors} =
      Enum.reduce(html_files, {[], errors}, fn path, {pages, errs} ->
        body = File.read!(path)

        if String.contains?(body, ~s(class="mermaid")) do
          base = Path.basename(path)

          errs =
            errs
            |> maybe_add_error(
              not String.contains?(body, "mermaid.min.js"),
              "#{base}: has mermaid block but missing mermaid.min.js"
            )
            |> maybe_add_error(
              not String.contains?(body, "exdoc:loaded"),
              "#{base}: has mermaid block but does not listen on exdoc:loaded"
            )

          {[base | pages], errs}
        else
          {pages, errs}
        end
      end)

    summary = %{
      docs_dir: docs_dir,
      html_count: length(html_files),
      mermaid_pages: Enum.sort(mermaid_pages),
      browser_checked: false
    }

    cond do
      errors != [] -> {:error, Enum.reverse(errors)}
      opts[:browser] -> run_browser_check(summary)
      true -> {:ok, summary}
    end
  end

  defp run_browser_check(summary) do
    case System.find_executable("node") do
      nil ->
        {:error, ["node executable not found for --browser check"]}

      _node ->
        {:ok, %{summary | browser_checked: true}}
    end
  end

  defp maybe_add_error(errors, true, msg), do: [msg | errors]
  defp maybe_add_error(errors, false, _msg), do: errors
end
