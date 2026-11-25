defmodule Weld.Git do
  @moduledoc """
  Thin Git CLI wrapper used for affected-file resolution and release metadata.
  """

  alias Weld.Error

  @spec changed_files(Path.t(), String.t(), String.t()) :: [String.t()]
  def changed_files(repo_root, base, head) do
    args = ["diff", "--name-only", "--no-renames", "-z", "#{base}..#{head}", "--"]

    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> output |> String.split(<<0>>, trim: true) |> Enum.sort()
      {output, _status} -> raise Error, "git diff failed: #{String.trim(output)}"
    end
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

  @spec root(Path.t()) :: String.t() | nil
  def root(path) do
    path
    |> run(["rev-parse", "--show-toplevel"])
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

  @spec dirty?(Path.t()) :: boolean()
  def dirty?(repo_root) do
    case run(repo_root, ["status", "--short"]) do
      {:ok, ""} -> false
      {:ok, _output} -> true
      {:error, _reason} -> false
    end
  end

  @spec commit_message(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit_message(repo_root, ref) do
    run(repo_root, ["show", "-s", "--format=%B", ref])
  end

  @spec rev_parse(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def rev_parse(repo_root, ref) do
    run(repo_root, ["rev-parse", "--verify", ref])
  end

  @spec tag_exists?(Path.t(), String.t()) :: boolean()
  def tag_exists?(repo_root, tag) do
    match?({:ok, _}, run(repo_root, ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"]))
  end

  @spec tag_info(Path.t(), String.t()) ::
          {:ok,
           %{type: :annotated | :lightweight, target_sha: String.t(), message: String.t() | nil}}
          | :missing
  def tag_info(repo_root, tag) do
    ref = "refs/tags/#{tag}"

    with {:ok, obj_type} <- run(repo_root, ["cat-file", "-t", ref]),
         {:ok, target_sha} <- run(repo_root, ["rev-parse", "--verify", "#{ref}^{commit}"]) do
      {:ok, build_tag_info(repo_root, ref, obj_type, target_sha)}
    else
      _ -> :missing
    end
  end

  defp build_tag_info(repo_root, ref, "tag", target_sha) do
    message =
      case run(repo_root, ["for-each-ref", "--format=%(contents)", ref]) do
        {:ok, contents} -> contents
        {:error, _} -> nil
      end

    %{type: :annotated, target_sha: target_sha, message: message}
  end

  defp build_tag_info(_repo_root, _ref, _other, target_sha) do
    %{type: :lightweight, target_sha: target_sha, message: nil}
  end

  @spec ensure_clean_repo!(Path.t()) :: :ok
  def ensure_clean_repo!(repo_root) do
    case run(repo_root, ["status", "--short"]) do
      {:ok, ""} -> :ok
      {:ok, output} -> raise Error, "repo is dirty:\n#{output}"
      {:error, reason} -> raise Error, "git status failed: #{reason}"
    end
  end

  @spec branch_exists?(Path.t(), String.t()) :: boolean()
  def branch_exists?(repo_root, branch) do
    match?({:ok, _}, run(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  @spec remote_branch_exists?(Path.t(), String.t(), String.t()) :: boolean()
  def remote_branch_exists?(repo_root, remote, branch) do
    match?({:ok, _}, run(repo_root, ["ls-remote", "--exit-code", "--heads", remote, branch]))
  end

  @spec fetch_branch!(Path.t(), String.t(), String.t()) :: :ok
  def fetch_branch!(repo_root, remote, branch) do
    run!(repo_root, ["fetch", remote, "#{branch}:refs/heads/#{branch}"])
    :ok
  end

  @spec worktree_add!(Path.t(), Path.t(), String.t()) :: :ok
  def worktree_add!(repo_root, worktree_path, branch) do
    run!(repo_root, ["worktree", "add", worktree_path, branch])
    :ok
  end

  @spec worktree_add_detached!(Path.t(), Path.t()) :: :ok
  def worktree_add_detached!(repo_root, worktree_path) do
    run!(repo_root, ["worktree", "add", "--detach", worktree_path, "HEAD"])
    :ok
  end

  @spec worktree_remove!(Path.t(), Path.t()) :: :ok
  def worktree_remove!(repo_root, worktree_path) do
    run!(repo_root, ["worktree", "remove", "--force", worktree_path])
    :ok
  end

  @spec switch_orphan!(Path.t(), String.t()) :: :ok
  def switch_orphan!(repo_root, branch) do
    run!(repo_root, ["switch", "--orphan", branch])
    :ok
  end

  @spec stage_all!(Path.t()) :: :ok
  def stage_all!(repo_root) do
    run!(repo_root, ["add", "-A"])
    :ok
  end

  @spec staged_changes?(Path.t()) :: boolean()
  def staged_changes?(repo_root) do
    case System.cmd("git", ["diff", "--cached", "--quiet", "--exit-code"],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> false
      {_output, 1} -> true
      {output, _status} -> raise Error, "git diff --cached failed: #{String.trim(output)}"
    end
  end

  @spec commit_all!(Path.t(), String.t(), keyword()) :: :ok
  def commit_all!(repo_root, message, opts \\ []) do
    args =
      if Keyword.get(opts, :allow_empty, false),
        do: ["commit", "--allow-empty", "-m", message],
        else: ["commit", "-m", message]

    run!(repo_root, args)
    :ok
  end

  @spec create_tag!(Path.t(), String.t(), String.t() | nil) :: :ok
  def create_tag!(repo_root, tag, message \\ nil)

  def create_tag!(repo_root, tag, nil) do
    run!(repo_root, ["tag", tag])
    :ok
  end

  def create_tag!(repo_root, tag, message) when is_binary(message) do
    run!(repo_root, ["tag", "-a", tag, "-m", message])
    :ok
  end

  @spec push_branch!(Path.t(), String.t(), String.t()) :: :ok
  def push_branch!(repo_root, remote, branch) do
    run!(repo_root, ["push", "--set-upstream", remote, branch])
    :ok
  end

  @spec push_tag!(Path.t(), String.t(), String.t()) :: :ok
  def push_tag!(repo_root, remote, tag) do
    run!(repo_root, ["push", remote, tag])
    :ok
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
