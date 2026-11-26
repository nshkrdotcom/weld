defmodule Weld.ReleaseReceipt do
  @moduledoc """
  Formats and parses versioned Git release receipts (`weld.receipt/v1`)
  embedded as structured trailers in `projection/*` commits and annotated tags.
  """

  alias Weld.{Git, Plan}

  @schema "weld.receipt/v1"

  @trailer_keys %{
    "Weld-Receipt-Schema" => :schema,
    "Weld-Package" => :package,
    "Weld-Version" => :version,
    "Weld-Artifact" => :artifact,
    "Weld-Identity" => :identity,
    "Weld-Source-Revision" => :source_revision,
    "Weld-Project-SHA256" => :project_sha256,
    "Weld-Docs-SHA256" => :docs_sha256,
    "Weld-Archive-SHA256" => :archive_sha256,
    "Weld-Tool-Version" => :tool_version
  }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec format_commit_message(Plan.t(), map()) :: String.t()
  def format_commit_message(%Plan{} = plan, metadata) when is_map(metadata) do
    subject =
      "Track projection for #{plan.artifact.package.name} #{plan.artifact.package.version}"

    subject <> "\n\n" <> format_trailers(plan, metadata) <> "\n"
  end

  @spec format_tag_message(Plan.t(), map(), String.t()) :: String.t()
  def format_tag_message(%Plan{} = plan, metadata, tag)
      when is_map(metadata) and is_binary(tag) do
    subject =
      "Weld prepared release #{plan.artifact.package.name} #{plan.artifact.package.version} (#{tag})"

    subject <> "\n\n" <> format_trailers(plan, metadata) <> "\n"
  end

  @spec format_trailers(Plan.t(), map()) :: String.t()
  def format_trailers(%Plan{} = plan, metadata) when is_map(metadata) do
    integrity = metadata["integrity"] || metadata["handoff"] || %{}
    package = metadata["package"] || %{}

    [
      {"Weld-Receipt-Schema", @schema},
      {"Weld-Package", package["name"] || plan.artifact.package.name},
      {"Weld-Version", package["version"] || plan.artifact.package.version},
      {"Weld-Artifact", metadata["artifact"] || plan.artifact.id},
      {"Weld-Identity", metadata["identity"]},
      {"Weld-Source-Revision", metadata["source_revision"]},
      {"Weld-Project-SHA256", integrity["project_sha256"]},
      {"Weld-Docs-SHA256", integrity["docs_sha256"]},
      {"Weld-Archive-SHA256", integrity["archive_sha256"]},
      {"Weld-Tool-Version", metadata["weld_version"] || Weld.version()}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)
  end

  @spec parse(String.t() | nil) :: {:ok, map()} | :none | {:error, String.t()}
  def parse(nil), do: :none

  def parse(message) when is_binary(message) do
    parsed =
      message
      |> String.split(~r/\r?\n/)
      |> Enum.reduce(%{}, &parse_trailer_line/2)

    cond do
      map_size(parsed) == 0 ->
        :none

      parsed[:schema] != @schema ->
        {:error, "unsupported receipt schema: #{inspect(parsed[:schema])}"}

      not valid_sha256?(parsed[:identity]) ->
        {:error, "invalid Weld-Identity in receipt"}

      true ->
        {:ok, parsed}
    end
  end

  @spec from_commit(Path.t(), String.t()) ::
          {:ok, map()} | :legacy | :missing | {:error, String.t()}
  def from_commit(repo_root, ref) do
    case Git.commit_message(repo_root, ref) do
      {:ok, message} ->
        case parse(message) do
          {:ok, receipt} -> {:ok, receipt}
          :none -> :legacy
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        :missing
    end
  end

  @spec from_tag(Path.t(), String.t()) ::
          {:ok, %{type: :annotated | :lightweight, target_sha: String.t(), receipt: map() | nil}}
          | :missing
          | {:error, String.t()}
  def from_tag(repo_root, tag) do
    case Git.tag_info(repo_root, tag) do
      :missing ->
        :missing

      {:ok, %{type: :lightweight, target_sha: target_sha}} ->
        {:ok, %{type: :lightweight, target_sha: target_sha, receipt: nil}}

      {:ok, %{type: :annotated, target_sha: target_sha, message: message}} ->
        case parse(message) do
          {:ok, receipt} ->
            {:ok, %{type: :annotated, target_sha: target_sha, receipt: receipt}}

          :none ->
            {:ok, %{type: :annotated, target_sha: target_sha, receipt: nil}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_trailer_line(line, acc) do
    with [key, value] <- String.split(line, ": ", parts: 2),
         {:ok, field} <- Map.fetch(@trailer_keys, String.trim(key)) do
      Map.put(acc, field, String.trim(value))
    else
      _ -> acc
    end
  end

  defp valid_sha256?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_sha256?(_), do: false
end
