defmodule Weld.DocsSmoke do
  @moduledoc """
  Static and optional headless-browser smoke checks for generated ExDoc HTML.
  """

  @doc """
  Verify generated ExDoc HTML in `docs_dir`:
  - `index.html` exists
  - Any page containing `<code class="mermaid">` also loads the Mermaid script
    and listens on `exdoc:loaded` (not `DOMContentLoaded`-only)
  - Optional `browser: true`: renders Mermaid pages in headless Chromium (light
    and dark, direct load and in-site navigation) via Playwright and fails on
    page errors or missing SVGs.
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
      opts[:browser] -> run_browser_check(summary, opts)
      true -> {:ok, summary}
    end
  end

  # Needs node and a Playwright install (pass `playwright: "/path/to/node_modules"`
  # or set WELD_PLAYWRIGHT). Renders every Mermaid page in light and dark mode,
  # follows an in-site link to it, and fails on page errors or missing SVGs.
  defp run_browser_check(summary, opts) do
    modules = opts[:playwright] || System.get_env("WELD_PLAYWRIGHT")
    node = System.find_executable("node")

    cond do
      is_nil(node) ->
        {:error, ["node executable not found for browser check"]}

      is_nil(modules) ->
        {:error, ["browser check needs playwright: pass playwright: path or set WELD_PLAYWRIGHT"]}

      true ->
        script = Path.join(:code.priv_dir(:weld), "docs_smoke.cjs")

        {out, status} =
          System.cmd(node, [script, summary.docs_dir],
            env: [{"NODE_PATH", modules}],
            stderr_to_stdout: true
          )

        if status == 0 do
          {:ok, %{summary | browser_checked: true}}
        else
          {:error, ["browser check failed: " <> String.trim(out)]}
        end
    end
  end

  defp maybe_add_error(errors, true, msg), do: [msg | errors]
  defp maybe_add_error(errors, false, _msg), do: errors
end
