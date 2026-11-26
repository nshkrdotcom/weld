defmodule Weld.Receipt do
  @moduledoc false

  alias Weld.{Error, Hash, Output}

  def read(path, input) do
    with {:ok, <<checksum::binary-64, body::binary>>} <- File.read(path),
         ^checksum <- Hash.sha256_binary(body),
         {1, ^input, value} <- :erlang.binary_to_term(body, [:safe]) do
      {:ok, value}
    else
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def write!(path, input, value) do
    body = :erlang.term_to_binary({1, input, value}, [:deterministic])
    temporary = path <> "-" <> Output.nonce()
    File.mkdir_p!(Path.dirname(path))

    try do
      File.write!(temporary, [Hash.sha256_binary(body), body], [:exclusive])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  def digest(term), do: term |> :erlang.term_to_binary([:deterministic]) |> Hash.sha256_binary()

  def implementation do
    _ = Application.load(:weld)

    modules =
      for module <- Application.spec(:weld, :modules) |> Enum.sort(),
          beam = :code.which(module),
          is_list(beam) do
        {module, Hash.sha256_file(List.to_string(beam))}
      end

    {modules, System.version(), System.otp_release(), System.build_info(),
     :erlang.system_info(:version), :erlang.system_info(:system_architecture)}
  end

  def tree(path, links? \\ false), do: tree_entry!(path, links?)

  defp tree_entry!(path, links?) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        {:file, Bitwise.band(mode, 0o777), Hash.sha256_file(path)}

      {:ok, %{type: :directory}} ->
        children = File.ls!(path) |> Enum.sort()
        {:directory, Enum.map(children, &{&1, tree_entry!(Path.join(path, &1), links?)})}

      {:ok, %{type: :symlink}} when links? ->
        {:link, File.read_link!(path)}

      {:ok, %{type: :symlink}} ->
        raise Error, "symlink is not permitted: #{path}"

      {:error, :enoent} ->
        :missing

      _ ->
        raise Error, "unsafe cache input: #{path}"
    end
  end
end
