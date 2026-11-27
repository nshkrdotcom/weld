defmodule Weld.Layout.Flat.TestHelper do
  @moduledoc false

  alias Weld.Core.Facts
  alias Weld.Error
  alias Weld.Layout.FilePlan

  def plan!(projects) do
    result =
      projects
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce(%{files: [], fragments: [], options: [], transformations: []}, fn project,
                                                                                       acc ->
        helper_path = Path.join(project.abs_path, "test/test_helper.exs")

        if Facts.regular?(project.facts, helper_path) do
          slug = project_slug(project.id)
          contents = Facts.read!(project.facts, helper_path)
          forms = quoted_forms!(contents, helper_path)
          validate_requires!(forms, project.facts, helper_path)
          {options, fragment_forms} = extract_forms(forms, slug, helper_path)

          fragment_relative =
            Path.join(["test", "support", "weld_helpers", "#{slug}_test_helper.exs"])

          fragment_source = render_fragment(fragment_forms)

          %{
            files: [
              FilePlan.generated(
                fragment_relative,
                fragment_source,
                :test,
                [helper_path],
                :transform
              )
              | acc.files
            ],
            fragments: [fragment_relative | acc.fragments],
            options: merge_exunit_options(acc.options, options, helper_path),
            transformations: [
              %{
                project_id: project.id,
                helper_path: helper_path,
                fragment: fragment_relative,
                exunit_options: options
              }
              | acc.transformations
            ]
          }
        else
          acc
        end
      end)

    root_helper_relative = Path.join(["test", "test_helper.exs"])
    transformations = Enum.reverse(result.transformations)

    root =
      FilePlan.generated(
        root_helper_relative,
        root_helper_source(result.options, Enum.reverse(result.fragments)),
        :test,
        Enum.map(transformations, & &1.helper_path)
      )

    operations = [root | Enum.reverse(result.files)]

    %{
      operations: operations,
      copied_files: Enum.map(operations, & &1.target) |> Enum.sort(),
      transformations: transformations
    }
  end

  defp validate_requires!(forms, facts, helper_path) do
    Macro.prewalk(forms, fn
      {{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, [relative, {:__DIR__, _, _}]} =
          node
      when is_binary(relative) ->
        path = Path.expand(relative, Path.dirname(helper_path))
        unless Facts.regular?(facts, path), do: raise(Error, "missing test helper input: #{path}")
        node

      node ->
        node
    end)
  end

  defp quoted_forms!(contents, helper_path) do
    case Code.string_to_quoted(contents, file: helper_path) do
      {:ok, {:__block__, _, forms}} ->
        forms

      {:ok, form} ->
        [form]

      {:error, error} ->
        raise Error, "unable to parse #{helper_path}: #{format_parse_error(error)}"
    end
  end

  defp extract_forms(forms, slug, helper_path) do
    Enum.reduce(forms, {[], []}, &extract_form(&1, &2, slug, helper_path))
  end

  defp extract_form(form, {options, kept}, slug, helper_path) do
    cond do
      exunit_start?(form) ->
        {options ++ literal_exunit_options!(form, helper_path), kept}

      unsupported_helper_side_effect?(form) ->
        raise Error,
              "unsupported helper side effect in #{helper_path}: " <>
                "move repo/database setup into explicit package test support or case modules before welding"

      true ->
        {options, kept ++ [rewrite_require_file(form, slug)]}
    end
  end

  defp literal_exunit_options!(form, helper_path) do
    additions = exunit_options(form)

    unless Keyword.keyword?(additions) and Macro.quoted_literal?(additions),
      do: raise(Error, "unsupported dynamic ExUnit options in #{helper_path}")

    additions
  end

  defp exunit_start?({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, _args}), do: true
  defp exunit_start?(_other), do: false

  defp exunit_options({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, []}), do: []

  defp exunit_options({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, [options]})
       when is_list(options),
       do: options

  defp exunit_options(_other), do: raise(Error, "unsupported dynamic ExUnit.start options")

  defp unsupported_helper_side_effect?({{:., _, [_module_ast, :setup_database!]}, _, _args}),
    do: true

  defp unsupported_helper_side_effect?(
         {{:., _, [_module_ast, :mode]}, _, [_repo_ast, _mode_ast]}
       ),
       do: true

  defp unsupported_helper_side_effect?(_other), do: false

  defp rewrite_require_file(form, slug), do: Macro.prewalk(form, &rewrite_require_node(&1, slug))

  defp rewrite_require_node(
         {{:., meta, [{:__aliases__, alias_meta, [:Code]}, :require_file]}, call_meta,
          [path, {:__DIR__, _, nil}]},
         slug
       )
       when is_binary(path) do
    if Path.type(path) != :relative or
         Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) do
      raise Error, "unsupported test helper require path: #{path}"
    end

    rewritten_path =
      if String.starts_with?(path, "support/"),
        do: "../#{slug}/" <> String.replace_prefix(path, "support/", ""),
        else: "../../#{slug}/" <> path

    {{:., meta, [{:__aliases__, alias_meta, [:Code]}, :require_file]}, call_meta,
     [rewritten_path, {:__DIR__, [], nil}]}
  end

  defp rewrite_require_node({{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, _}, _slug),
    do: raise(Error, "monolith test helper requires must use a literal relative path and __DIR__")

  defp rewrite_require_node(form, _slug), do: form

  defp format_parse_error({metadata, message, token}) when is_list(metadata) do
    location =
      metadata
      |> parse_error_location()
      |> case do
        "" -> ""
        value -> value <> ": "
      end

    detail =
      case token do
        "" -> message
        _other -> "#{message} #{inspect(token)}"
      end

    location <> detail
  end

  defp parse_error_location(metadata) do
    line = metadata[:line]
    column = metadata[:column]

    cond do
      is_integer(line) and is_integer(column) -> "line #{line}, column #{column}"
      is_integer(line) -> "line #{line}"
      true -> ""
    end
  end

  defp render_fragment([]), do: ""

  defp render_fragment(forms) do
    Enum.map_join(forms, "\n\n", &Macro.to_string/1) <> "\n"
  end

  defp root_helper_source(options, fragments) do
    rendered_options =
      case options do
        [] -> ""
        values -> Macro.to_string(values)
      end

    exunit_start =
      if rendered_options == "" do
        "ExUnit.start()\n"
      else
        "ExUnit.start(#{rendered_options})\n"
      end

    requires =
      fragments
      |> Enum.map_join("", fn fragment ->
        "Code.require_file(\"#{Path.relative_to(fragment, "test")}\", __DIR__)\n"
      end)

    IO.iodata_to_binary([exunit_start, "\n", requires])
  end

  defp merge_exunit_options(existing, additions, helper_path) do
    Enum.reduce(additions, existing, fn {key, value}, acc ->
      case Keyword.fetch(acc, key) do
        :error ->
          Keyword.put(acc, key, value)

        {:ok, ^value} ->
          acc

        {:ok, other} ->
          raise Error,
                "conflicting ExUnit option #{inspect(key)} in #{helper_path}: #{inspect(other)} vs #{inspect(value)}"
      end
    end)
  end

  defp project_slug(project_id), do: FilePlan.slug(project_id)
end
