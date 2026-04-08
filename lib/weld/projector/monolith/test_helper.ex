defmodule Weld.Projector.Monolith.TestHelper do
  @moduledoc false

  alias Weld.Error

  @spec generate!([Weld.Workspace.Project.t()], Path.t(), keyword()) :: %{
          copied_files: [String.t()],
          transformations: [map()]
        }
  def generate!(projects, build_path, _opts \\ []) do
    result =
      projects
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce(%{files: [], fragments: [], options: [], transformations: []}, fn project,
                                                                                       acc ->
        helper_path = Path.join(project.abs_path, "test/test_helper.exs")

        if File.regular?(helper_path) do
          slug = project_slug(project.id)
          contents = File.read!(helper_path)
          forms = quoted_forms!(contents, helper_path)
          {options, fragment_forms} = extract_forms(forms, slug, helper_path)

          fragment_relative =
            Path.join(["test", "support", "weld_helpers", "#{slug}_test_helper.exs"])

          fragment_path = Path.join(build_path, fragment_relative)
          fragment_source = render_fragment(fragment_forms)

          File.mkdir_p!(Path.dirname(fragment_path))
          File.write!(fragment_path, fragment_source)

          %{
            files: [fragment_relative | acc.files],
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
    root_helper_path = Path.join(build_path, root_helper_relative)
    File.mkdir_p!(Path.dirname(root_helper_path))

    File.write!(
      root_helper_path,
      root_helper_source(result.options, Enum.reverse(result.fragments))
    )

    %{
      copied_files: [root_helper_relative | result.files] |> Enum.uniq() |> Enum.sort(),
      transformations: Enum.reverse(result.transformations)
    }
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
    Enum.reduce(forms, {[], []}, fn form, {options, kept} ->
      cond do
        exunit_start?(form) ->
          {options ++ exunit_options(form), kept}

        unsupported_helper_side_effect?(form) ->
          raise Error,
                "unsupported helper side effect in #{helper_path}: " <>
                  "move repo/database setup into explicit package test support or case modules before welding"

        normalized_alias?(form) ->
          {options, kept}

        true ->
          {options, kept ++ [rewrite_require_file(form, slug)]}
      end
    end)
  end

  defp exunit_start?({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, _args}), do: true
  defp exunit_start?(_other), do: false

  defp exunit_options({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, []}), do: []

  defp exunit_options({{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, [options]})
       when is_list(options),
       do: options

  defp exunit_options(_other), do: []

  defp unsupported_helper_side_effect?({{:., _, [_module_ast, :setup_database!]}, _, _args}),
    do: true

  defp unsupported_helper_side_effect?(
         {{:., _, [_module_ast, :mode]}, _, [_repo_ast, _mode_ast]}
       ),
       do: true

  defp unsupported_helper_side_effect?(_other), do: false

  defp normalized_alias?({:alias, _, alias_args}) do
    alias_args
    |> List.wrap()
    |> Enum.any?(fn
      {:__aliases__, _, [:Jido, :Integration, :V2, :StorePostgres, :TestSupport]} -> true
      {:__aliases__, _, [:Ecto, :Adapters, :SQL, :Sandbox]} -> true
      _other -> false
    end)
  end

  defp normalized_alias?(_other), do: false

  defp rewrite_require_file(
         {{:., meta, [{:__aliases__, alias_meta, [:Code]}, :require_file]}, call_meta,
          [path, {:__DIR__, _, nil}]},
         slug
       )
       when is_binary(path) do
    rewritten_path = "../#{slug}/" <> String.replace_prefix(path, "support/", "")

    {{:., meta, [{:__aliases__, alias_meta, [:Code]}, :require_file]}, call_meta,
     [rewritten_path, {:__DIR__, [], nil}]}
  end

  defp rewrite_require_file(form, _slug), do: form

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

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end
end
