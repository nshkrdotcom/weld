defmodule Weld.Workspace.Probe do
  @moduledoc "Bounded, fresh-VM Mix metadata observations; source modules never load in the caller."

  alias Weld.{Error, Shell.Runner}
  @marker "WELD_PROJECT_FACTS/2:"
  @max_response 1024 * 1024
  @max_nodes 100_000
  @environments [:dev, :test, :prod]

  def environments, do: @environments

  def collect!(root, project_ids, opts \\ []) do
    jobs = for id <- Enum.sort(project_ids), env <- @environments, do: {id, env}
    jobs
    |> Task.async_stream(fn {id, env} ->
      path = if id == ".", do: root, else: Path.join(root, id)
      {{id, env}, run!(root, path, id, env, opts)}
    end, max_concurrency: 4, ordered: true, timeout: 40_000, on_timeout: :kill_task)
    |> Enum.map(fn
      {:ok, value} -> value
      {:exit, reason} -> raise Error, code: :probe_failed, phase: :snapshot,
        message: "isolated Mix metadata probe stopped: #{inspect(reason, limit: 5)}"
    end)
    |> Map.new()
  end

  def project!(path, env, opts \\ []) when env in @environments do
    run!(Keyword.get(opts, :root, path), path, Keyword.get(opts, :id, "."), env, opts)
  end

  defp run!(root, path, id, env, opts) do
    seconds = Keyword.get(opts, :seconds, 30)
    unless is_integer(seconds) and seconds > 0 and seconds <= 30, do: raise(Error, "probe timeout must be between 1 and 30 seconds")
    jason_path = :code.which(Jason) |> to_string() |> Path.dirname()
    {output, status} = Runner.capture!("elixir", ["-pa", jason_path, "-e", script(env), "--", root],
      cd: path, seconds: seconds, max_bytes: @max_response + 64 * 1024, env: Map.merge(Map.new(opts[:env] || []), %{"MIX_ENV" => to_string(env)}))
    lines = output |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, @marker))
    with 0 <- status,
         [line] <- lines,
         response = String.replace_prefix(line, @marker, ""),
         true <- byte_size(response) <= @max_response,
         {:ok, %{"schema" => "weld.project-facts/2", "value" => value} = envelope} <- Jason.decode(response),
         true <- Enum.sort(Map.keys(envelope)) == ["schema", "value"] do
      if opts[:verbose] do
        logs = output |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, @marker)) |> Enum.join("\n")
        if String.trim(logs) != "", do: IO.puts(:stderr, excerpt(logs))
      end
      {facts, _remaining} = decode(value, @max_nodes, 0)
      validate!(facts, id, env)
    else
      _ -> raise Error, code: :probe_failed, phase: :snapshot,
        message: "Mix metadata probe failed for #{id} in #{env} (exit #{status})",
        details: %{project: id, environment: env, exit_status: status, excerpt: excerpt(output)}
    end
  end

  defp excerpt(output) do
    if String.valid?(output), do: output |> String.slice(-2048, 2048) |> Runner.sanitize(),
      else: "subprocess produced non-UTF-8 output"
  end

  defp validate!(%{config: config, application: application, required_files: files, environment: environment, target: target} = value, id, env) do
    unless map_size(value) == 5 and environment == env and is_atom(target) and
             Keyword.keyword?(config) and Keyword.keyword?(application) and is_list(files) and
             Enum.all?(files, &is_binary/1) and is_atom(config[:app]) and config[:app] not in [nil, true, false] and
             is_binary(config[:version]) and match?({:ok, _}, Version.parse(config[:version])) do
      raise Error, code: :invalid_project_facts, phase: :snapshot,
        message: "invalid project facts for #{id} in #{env}"
    end
    value
  end
  defp validate!(_, id, env), do: raise(Error, "invalid project facts for #{id} in #{env}")

  # This is a finite typed JSON codec, not an external-term decoder. Its only
  # atom allocations are bounded source-declared metadata identifiers. Arbitrary
  # compiled modules, functions, PIDs, references and ports cannot cross the VM.
  defp decode(_, remaining, depth) when remaining <= 0 or depth > 32,
    do: raise(Error, "Mix metadata exceeds bounded response shape")
  defp decode(value, remaining, _depth) when is_binary(value) or is_number(value) or value in [nil, true, false], do: {value, remaining - 1}
  defp decode(%{"type" => "atom", "value" => value} = tagged, remaining, _depth) when map_size(tagged) == 2 and is_binary(value) and byte_size(value) <= 255 do
    unless String.valid?(value), do: raise(Error, "invalid atom in Mix metadata")
    {String.to_atom(value), remaining - 1}
  end
  defp decode(%{"type" => type, "value" => values} = tagged, remaining, depth) when map_size(tagged) == 2 and type in ["list", "tuple", "map"] and is_list(values) do
    {values, remaining} = Enum.map_reduce(values, remaining - 1, &decode(&1, &2, depth + 1))
    case type do
      "list" -> {values, remaining}
      "tuple" -> {List.to_tuple(values), remaining}
      "map" ->
        unless Enum.all?(values, &match?({_, _}, &1)), do: raise(Error, "invalid map in Mix metadata")
        keys = Enum.map(values, &elem(&1, 0))
        unless Enum.uniq(keys) == keys, do: raise(Error, "duplicate map key in Mix metadata")
        {Map.new(values), remaining}
    end
  end
  defp decode(%{"type" => "regex", "source" => source, "options" => options} = value, remaining, _depth) when map_size(value) == 3 and is_binary(source) and is_binary(options) do
    case Regex.compile(source, options) do
      {:ok, regex} -> {regex, remaining - 1}
      _ -> raise Error, "invalid package exclusion regex"
    end
  end
  defp decode(_, _, _), do: raise(Error, "unsupported Mix metadata value")

  defp script(env) do
    """
    defmodule WeldProbeCodec do
      def encode(value) when is_binary(value) or is_number(value) or value in [nil, true, false], do: value
      def encode(value) when is_atom(value), do: %{"type" => "atom", "value" => Atom.to_string(value)}
      def encode(%Regex{} = value), do: %{"type" => "regex", "source" => Regex.source(value), "options" => Regex.opts(value)}
      def encode(value) when is_list(value), do: %{"type" => "list", "value" => Enum.map(value, &encode/1)}
      def encode(value) when is_tuple(value), do: %{"type" => "tuple", "value" => value |> Tuple.to_list() |> Enum.map(&encode/1)}
      def encode(value) when is_map(value), do: %{"type" => "map", "value" => value |> Enum.sort() |> Enum.map(&encode/1)}
      def encode(_value), do: raise("unsupported dynamic value in selected Mix metadata")
    end
    Mix.start()
    Mix.env(#{inspect(env)})
    [root] = System.argv()
    Mix.Project.in_project(:weld_probe, ".", [], fn module ->
      config = Mix.Project.config()
      keys = ~w(app version package description docs elixir deps elixirc_paths erlc_paths
                erlc_include_path test_paths test_pattern compilers elixirc_options erlc_options)a
      config = Keyword.take(config, keys)
      config = Keyword.update(config, :docs, [], fn
        docs when is_list(docs) -> Keyword.take(docs, [:source_ref, :output, :main, :extras, :assets, :logo])
        _ -> []
      end)
      config = Keyword.update(config, :package, [], fn package ->
        if is_list(package), do: Keyword.take(package, [:name, :files, :exclude_patterns, :licenses, :links, :maintainers, :build_tools, :extra, :description, :secret_scan]), else: []
      end)
      application = if function_exported?(module, :application, 0), do: module.application(), else: []
      required_files = Code.required_files() |> Enum.filter(&(&1 == root or String.starts_with?(&1, root <> "/"))) |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()
      value = %{config: config, application: application, required_files: required_files, environment: Mix.env(), target: Mix.target()}
      response = Jason.encode!(%{"schema" => "weld.project-facts/2", "value" => WeldProbeCodec.encode(value)})
      if byte_size(response) > #{@max_response}, do: raise("Mix metadata response exceeds limit")
      IO.puts("\\n#{@marker}" <> response)
    end)
    """
  end
end
