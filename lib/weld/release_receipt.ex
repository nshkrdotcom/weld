defmodule Weld.ReleaseReceipt do
  @moduledoc """
  One canonical `weld.receipt/2` value encoded as unpadded base64url in a
  single `Weld-Receipt` trailer. Commits and annotated tags carry identical
  values; a receipt does not claim publication or local archive availability.
  """

  alias Weld.Core.Identity
  alias Weld.{Error, Git}

  @schema "weld.receipt/2"
  @keys ~w(schema artifact package version bundle_id qualification_id project_id archive_sha256 docs_id docs_archive_sha256 source compiler_id)
  @source_keys ~w(git_algorithm commit manifest_path manifest_sha256)

  def schema, do: @schema

  def from_bundle(metadata) do
    record = metadata |> Map.take(@keys -- ["schema"]) |> Map.put("schema", @schema)
    validate!(record)
  end

  def format_commit_message(_selection, metadata) do
    "Track projection for #{metadata["package"]} #{metadata["version"]}\n\n" <>
      format_trailers(nil, metadata) <> "\n"
  end

  def format_tag_message(_selection, metadata, tag) do
    "Weld prepared release #{metadata["package"]} #{metadata["version"]} (#{tag})\n\n" <>
      format_trailers(nil, metadata) <> "\n"
  end

  def format_trailers(_selection, metadata) do
    "Weld-Receipt: " <>
      (metadata |> from_bundle() |> Identity.canonical() |> Base.url_encode64(padding: false))
  end

  def parse(nil), do: :none

  def parse(message) when is_binary(message) do
    lines = String.split(message, "\n", trim: false)
    weld_lines = Enum.filter(lines, &String.starts_with?(&1, "Weld-"))

    case weld_lines do
      [] -> :none
      ["Weld-Receipt: " <> encoded] -> decode(encoded, lines)
      _ -> {:error, "exactly one canonical Weld-Receipt trailer is required"}
    end
  end

  defp decode(encoded, lines) do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, encoded),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded,
         {:ok, record} <- Jason.decode(bytes),
         true <- Identity.canonical(record) == bytes,
         true <- trailer_last?(lines, "Weld-Receipt: " <> encoded) do
      {:ok, validate!(record)}
    else
      _ -> {:error, "malformed or noncanonical Weld receipt"}
    end
  rescue
    _ -> {:error, "invalid or unsupported Weld receipt"}
  end

  defp trailer_last?(lines, trailer) do
    stripped = Enum.reverse(lines) |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

    List.last(stripped) == trailer and
      (length(stripped) == 1 or Enum.at(stripped, -2) == "")
  end

  def validate!(record) do
    unless is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@keys) and
             record["schema"] == @schema and valid_name?(record["artifact"]) and
             valid_package?(record["package"]) and is_binary(record["version"]) and
             match?({:ok, _}, Version.parse(record["version"])) and
             Enum.all?(
               ~w(bundle_id qualification_id project_id docs_id compiler_id),
               &Identity.valid?(record[&1])
             ) and
             Enum.all?(
               ~w(archive_sha256 docs_archive_sha256),
               &(is_nil(record[&1]) or Identity.valid?(record[&1]))
             ) and
             is_nil(record["archive_sha256"]) == is_nil(record["docs_archive_sha256"]) do
      raise Error, "invalid Weld receipt schema"
    end

    validate_source!(record["source"])
    record
  end

  def validate_source!(source) do
    unless is_map(source) and Enum.sort(Map.keys(source)) == Enum.sort(@source_keys) and
             Identity.valid?(source["manifest_sha256"]) and
             source["git_algorithm"] in ["sha1", "sha256"] and
             is_binary(source["commit"]) and
             Regex.match?(
               if(source["git_algorithm"] == "sha1",
                 do: ~r/\A[0-9a-f]{40}\z/,
                 else: ~r/\A[0-9a-f]{64}\z/
               ),
               source["commit"]
             ) do
      raise Error, "invalid source provenance"
    end

    Weld.Core.Inventory.validate_path!(source["manifest_path"])
    source
  end

  defp valid_name?(value) when is_binary(value),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, value)

  defp valid_name?(_), do: false

  defp valid_package?(value) when is_binary(value),
    do: Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, value)

  defp valid_package?(_), do: false

  def from_commit(root, ref) do
    case Git.commit_message(root, ref) do
      {:ok, message} ->
        case parse(message) do
          :none -> {:error, "commit has no Weld receipt"}
          result -> result
        end

      _ ->
        :missing
    end
  end

  def from_tag(root, tag) do
    case Git.tag_info(root, tag) do
      :missing ->
        :missing

      {:ok, %{type: :lightweight}} ->
        {:error, "only annotated weld.receipt/2 tags are supported"}

      {:ok, %{type: :annotated, target_sha: sha, message: message}} ->
        case parse(message) do
          {:ok, record} -> {:ok, %{type: :annotated, target_sha: sha, receipt: record}}
          :none -> {:error, "annotated tag has no Weld receipt"}
          error -> error
        end
    end
  end
end
