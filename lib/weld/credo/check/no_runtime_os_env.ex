defmodule Weld.Credo.Check.NoRuntimeOsEnv do
  @moduledoc """
  Credo check that rejects direct OS environment API calls in runtime code.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    tags: [:runtime, :configuration],
    explanations: [
      check: """
      Runtime application code should not read or mutate OS environment variables
      directly. Read deployment env at config/runtime.exs or a Config.Provider
      boundary, then pass explicit options, config structs, credential providers,
      or caller-supplied maps into libraries and SDKs.
      """
    ]

  @forbidden %{
    get_env: "System.get_env",
    fetch_env: "System.fetch_env",
    fetch_env!: "System.fetch_env!",
    put_env: "System.put_env",
    delete_env: "System.delete_env"
  }

  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    if runtime_lib_file?(source_file.filename) do
      ctx = Context.build(source_file, params, __MODULE__)

      source_file
      |> Credo.Code.prewalk(&walk/2, ctx)
      |> Map.fetch!(:issues)
      |> Enum.reverse()
    else
      []
    end
  end

  defp runtime_lib_file?(filename) when is_binary(filename) do
    filename == "lib" or String.starts_with?(filename, "lib/") or
      String.contains?(filename, "/lib/")
  end

  defp runtime_lib_file?(_filename), do: false

  defp walk({{:., meta, [{:__aliases__, _, [:System]}, function]}, _, _args} = ast, ctx)
       when is_map_key(@forbidden, function) do
    trigger = Map.fetch!(@forbidden, function)
    {ast, put_issue(ctx, issue_for(ctx, meta, trigger))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "#{trigger} is not allowed in runtime lib code; use runtime config or explicit caller-supplied options.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
