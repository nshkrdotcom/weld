defmodule Weld.DocsPreview do
  @moduledoc false

  @makeup_block ~r/<code class="makeup [^"]+"[^>]*>.*?<\/code>/s
  @makeup_group ~r/(<span class="[^"]+" data-group-id=")([0-9]{10})-([0-9]+)"/

  def copy!(source, target) do
    File.mkdir!(target)

    # ExDoc's EPUB includes a random UUID, wall-clock time and ZIP timestamps.
    for entry <- File.ls!(source), Path.extname(entry) != ".epub" do
      File.cp_r!(Path.join(source, entry), Path.join(target, entry))
    end

    for path <- Path.wildcard(Path.join(target, "**/*.html")) do
      bytes = File.read!(path)
      normalized = stable_groups(bytes)
      if bytes != normalized, do: File.write!(path, normalized)
    end
  end

  def stable_groups(html) do
    @makeup_block
    |> Regex.split(html, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join(fn
      {block, index} when rem(index, 2) == 1 -> stable_block(block, div(index, 2))
      {block, _index} -> block
    end)
  end

  defp stable_block(block, index) do
    # Keep all matching delimiters in the same group. The block position keeps
    # the highlighter's page-wide selector from matching adjacent blocks.
    prefixes =
      Regex.scan(@makeup_group, block, capture: [2])
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    Regex.replace(@makeup_group, block, fn _, attr, prefix, group ->
      ~s(#{attr}weld-#{index}-#{Map.fetch!(prefixes, prefix)}-#{group}")
    end)
  end
end
