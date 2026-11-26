defmodule Weld.DocsSmoke do
  @moduledoc """
  Static smoke checks for generated ExDoc HTML.
  """

  @comments ~r/<!--.*?-->/s
  @scripts ~r/<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>(.*?)<\/script\s*>/is
  @code_tags ~r/<code\b(?:[^>"']|"[^"]*"|'[^']*')*>/i
  @attributes ~r/([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/i
  @mermaid_source ~r/(?:^|\/)mermaid\.min\.js(?:[?#].*)?\z/
  @javascript_token ~r{\A(?://[^\r\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][A-Za-z0-9_$]*|\+\+|--|=>|[^\s])}s
  @javascript_regexp ~r{\A/(?:\\.|\[(?:\\.|[^\]\\\r\n])*\]|[^/\\\[\r\n])+/[a-z]*}

  @doc """
  Verify generated ExDoc HTML in `docs_dir`:
  - `index.html` exists
  - Every HTML page, including nested extras, containing a `code` element with
    the `mermaid` class also loads the Mermaid script and contains an inline
    `exdoc:loaded` listener (not `DOMContentLoaded`-only)

  This inspects markup and script declarations; it does not execute JavaScript
  or prove that a diagram renders in a browser.
  """
  @spec check(Path.t()) :: {:ok, map()} | {:error, [String.t()]}
  def check(docs_dir) do
    html_files =
      docs_dir
      |> Path.join("**/*.html")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    errors =
      []
      |> maybe_add_error(
        not File.regular?(Path.join(docs_dir, "index.html")),
        "missing index.html in #{docs_dir}"
      )

    {mermaid_pages, errors} =
      Enum.reduce(html_files, {[], errors}, fn path, {pages, errs} ->
        body = Regex.replace(@comments, File.read!(path), "")
        scripts = executable_scripts(body)
        markup = Regex.replace(@scripts, body, "")

        if mermaid_code?(markup) do
          relative = Path.relative_to(path, docs_dir)

          errs =
            errs
            |> maybe_add_error(
              not mermaid_loader?(scripts),
              "#{relative}: has mermaid block but missing mermaid.min.js"
            )
            |> maybe_add_error(
              not loaded_listener?(scripts),
              "#{relative}: has mermaid block but does not listen on exdoc:loaded"
            )

          {[relative | pages], errs}
        else
          {pages, errs}
        end
      end)

    summary = %{
      docs_dir: docs_dir,
      html_count: length(html_files),
      mermaid_pages: Enum.sort(mermaid_pages)
    }

    cond do
      errors != [] -> {:error, Enum.reverse(errors)}
      true -> {:ok, summary}
    end
  end

  defp mermaid_code?(markup) do
    @code_tags
    |> Regex.scan(markup)
    |> Enum.any?(fn [tag] -> "mermaid" in String.split(attribute(tag, "class")) end)
  end

  defp executable_scripts(body) do
    @scripts
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.filter(fn [attrs, _code] ->
      String.downcase(attribute(attrs, "type")) in [
        "",
        "module",
        "text/javascript",
        "application/javascript"
      ]
    end)
    |> Enum.map(fn [attrs, code] -> {attrs, code} end)
  end

  defp mermaid_loader?(scripts) do
    Enum.any?(scripts, fn {attrs, _code} ->
      Regex.match?(@mermaid_source, attribute(attrs, "src"))
    end)
  end

  defp loaded_listener?(scripts) do
    Enum.any?(scripts, fn {attrs, code} ->
      is_nil(attribute(attrs, "src", nil)) and listener_call?(code)
    end)
  end

  # Tokenize enough to exclude examples and comments. This recognizes a call
  # declaration, not whether JavaScript reaches it or renders a diagram.
  defp listener_call?(code) do
    code
    |> javascript_tokens(nil, [])
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.any?(fn
      ["addEventListener", "(", event, ","] ->
        event in ["\"exdoc:loaded\"", "'exdoc:loaded'"]

      _ ->
        false
    end)
  end

  defp javascript_tokens(code, previous, tokens) do
    case String.trim_leading(code) do
      "" ->
        Enum.reverse(tokens)

      remaining ->
        [token] = Regex.run(@javascript_token, remaining)

        token =
          if token == "/" and regexp_context?(previous) do
            case Regex.run(@javascript_regexp, remaining) do
              [regexp] -> regexp
              nil -> token
            end
          else
            token
          end

        rest = binary_part(remaining, byte_size(token), byte_size(remaining) - byte_size(token))

        if String.starts_with?(token, ["//", "/*"]) do
          javascript_tokens(rest, previous, tokens)
        else
          javascript_tokens(rest, token, [token | tokens])
        end
    end
  end

  # A slash after an expression is division, not the start of a regexp. This
  # intentionally remains a static declaration check rather than a JS parser.
  defp regexp_context?(previous) do
    previous in [
      nil,
      "(",
      "[",
      "{",
      "=",
      ":",
      ",",
      ";",
      "!",
      "?",
      "~",
      "+",
      "-",
      "*",
      "/",
      "%",
      "&",
      "|",
      "^",
      "<",
      ">",
      "=>",
      "return",
      "throw",
      "case",
      "delete",
      "void",
      "typeof",
      "instanceof",
      "in",
      "of",
      "yield",
      "await"
    ]
  end

  defp attribute(tag, name, default \\ "") do
    @attributes
    |> Regex.scan(tag, capture: :all_but_first)
    |> Enum.find_value(default, fn [key | values] ->
      if String.downcase(key) == name, do: Enum.find(values, "", &(&1 != ""))
    end)
  end

  defp maybe_add_error(errors, true, msg), do: [msg | errors]
  defp maybe_add_error(errors, false, _msg), do: errors
end
