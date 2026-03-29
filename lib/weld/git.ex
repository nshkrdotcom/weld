defmodule Weld.Git do
  @moduledoc """
  Thin Git CLI wrapper used for affected-file resolution and release metadata.
  """

  alias Weld.Error

  @spec changed_files(Path.t(), String.t(), String.t()) :: [String.t()]
  def changed_files(repo_root, base, head) do
    output = run!(repo_root, ["diff", "--name-only", "#{base}..#{head}"])

    output
    |> String.split("\n", trim: true)
    |> Enum.sort()
  end

  @spec revision(Path.t()) :: String.t() | nil
  def revision(repo_root) do
    repo_root
    |> run(["rev-parse", "HEAD"])
    |> case do
      {:ok, output} -> String.trim(output)
      {:error, _reason} -> nil
    end
  end

  @spec remote_url(Path.t()) :: String.t() | nil
  def remote_url(repo_root) do
    repo_root
    |> run(["config", "--get", "remote.origin.url"])
    |> case do
      {:ok, output} ->
        output
        |> String.trim()
        |> normalize_remote()

      {:error, _reason} ->
        nil
    end
  end

  @spec ensure_clean_repo!(Path.t()) :: :ok
  def ensure_clean_repo!(repo_root) do
    case run(repo_root, ["status", "--short"]) do
      {:ok, ""} -> :ok
      {:ok, output} -> raise Error, "repo is dirty:\n#{output}"
      {:error, reason} -> raise Error, "git status failed: #{reason}"
    end
  end

  @spec run(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  @spec run!(Path.t(), [String.t()]) :: String.t()
  def run!(repo_root, args) do
    case run(repo_root, args) do
      {:ok, output} -> output
      {:error, reason} -> raise Error, "git #{Enum.join(args, " ")} failed: #{reason}"
    end
  end

  defp normalize_remote(""), do: nil

  defp normalize_remote("git@github.com:" <> rest) do
    "https://github.com/" <> String.trim_trailing(rest, ".git")
  end

  defp normalize_remote(url), do: String.trim_trailing(url, ".git")
end
