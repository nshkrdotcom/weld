defmodule Weld.TarFixture do
  @moduledoc false

  # Deliberately independent, small USTAR builder for adversarial archive tests.
  def tar(members) do
    Enum.map_join(members, &member/1) <> :binary.copy(<<0>>, 1024)
  end

  def package(members, metadata_transform \\ & &1) do
    metadata = %{"name" => "probe", "app" => "probe", "version" => "1.0.0",
      "requirements" => %{}, "files" => Enum.map(members, & &1.path)}
    {:ok, %{tarball: normal}} = :hex_tarball.create(metadata, [])
    {:ok, outer} = :erl_tar.extract({:binary, normal}, [:memory])
    {_, raw_metadata} = List.keyfind(outer, ~c"metadata.config", 0)
    raw_metadata = metadata_transform.(raw_metadata)
    compressed = :zlib.gzip(tar(members))
    checksum = :crypto.hash(:sha256, "3" <> raw_metadata <> compressed) |> Base.encode16()
    tar([
      %{path: "VERSION", bytes: "3"}, %{path: "CHECKSUM", bytes: checksum},
      %{path: "metadata.config", bytes: raw_metadata}, %{path: "contents.tar.gz", bytes: compressed}
    ])
  end

  defp member(input) do
    bytes = input[:bytes] || ""
    size = input[:size] || byte_size(bytes)
    type = input[:type] || "0"
    mode = input[:mode] || if(type == "5", do: 0o755, else: 0o644)
    header = field(input.path, 100) <> octal(mode, 8) <> octal(0, 8) <> octal(0, 8) <>
      octal(size, 12) <> octal(0, 12) <> "        " <> type <> field(input[:link] || "", 100) <>
      "ustar\0" <> "00" <> field("", 32) <> field("", 32) <> octal(0, 8) <> octal(0, 8) <>
      field(input[:prefix] || "", 155) <> :binary.copy(<<0>>, 12)
    512 = byte_size(header)
    sum = header |> :binary.bin_to_list() |> Enum.sum()
    <<left::binary-size(148), _old::binary-size(8), right::binary>> = header
    check = Integer.to_string(sum, 8) |> String.pad_leading(6, "0")
    left <> check <> <<0, 32>> <> right <> bytes <> :binary.copy(<<0>>, rem(512 - rem(byte_size(bytes), 512), 512))
  end
  defp octal(value, width), do: field(Integer.to_string(value, 8) |> String.pad_leading(width - 1, "0"), width)
  defp field(value, width) when byte_size(value) <= width, do: value <> :binary.copy(<<0>>, width - byte_size(value))
end
