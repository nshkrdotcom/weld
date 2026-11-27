defmodule Weld.Git do
  @moduledoc """
  Bounded Git observations and object/ref operations. Tree proof reads actual
  Git blobs and executable modes; tracking never checks out or changes main.
  """

  alias Weld.Core.{Identity, Inventory}
  alias Weld.Error
  alias Weld.Shell.Runner

  @git_overrides ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_CURL GIT_CURL_VERBOSE)

  def tracked_files(root), do: raw!(root, ["ls-files", "--full-name", "-z"]) |> String.split(<<0>>, trim: true) |> MapSet.new()

  def changed_files(root, base, head) do
    raw!(root, ["diff", "--name-only", "--no-renames", "-z", "#{base}..#{head}", "--"])
    |> String.split(<<0>>, trim: true) |> Enum.sort()
  end

  def changes(root, base, head) do
    raw!(root, ["diff", "--name-status", "--find-renames", "-z", "#{base}..#{head}", "--"])
    |> String.split(<<0>>, trim: true) |> parse_changes([])
  end

  defp parse_changes([], acc), do: Enum.reverse(acc)
  defp parse_changes([status, old, new | rest], acc) when binary_part(status, 0, 1) in ["R", "C"],
    do: parse_changes(rest, [%{status: status, old: old, new: new} | acc])
  defp parse_changes([status, path | rest], acc),
    do: parse_changes(rest, [%{status: status, old: path, new: path} | acc])
  defp parse_changes(_, _), do: raise(Error, "malformed Git name-status response")

  def with_tree!(root, ref, fun) do
    commit = run!(root, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"])
    validate_oid!(root, commit)
    directory = Path.join(System.tmp_dir!(), "weld-tree-" <> nonce())
    File.mkdir!(directory)
    try do
      for entry <- tree_entries(root, commit), entry.type == :file do
        target = Path.join(directory, entry.path)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, raw!(root, ["cat-file", "blob", entry.oid]), [:exclusive])
        File.chmod!(target, if(entry.executable, do: 0o755, else: 0o644))
      end
      fun.(directory, commit)
    after
      File.rm_rf!(directory)
    end
  end

  def revision(root), do: optional(root, ["rev-parse", "--verify", "HEAD"])
  def root(path), do: optional(path, ["rev-parse", "--show-toplevel"])
  def object_format(root), do: run!(root, ["rev-parse", "--show-object-format"])
  def remote_url(root), do: normalize_remote(optional(root, ["config", "--get", "remote.origin.url"]))

  def dirty?(root) do
    case run(root, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, ""} -> false
      {:ok, _} -> true
      {:error, reason} -> raise Error, "cannot establish source cleanliness: #{reason}"
    end
  end

  def ensure_clean_repo!(root) do
    unless is_binary(revision(root)), do: raise(Error, "release requires a committed Git revision")
    if dirty?(root), do: raise(Error, "repo is dirty; commit source changes before release preparation")
    :ok
  end

  def commit_message(root, ref), do: run(root, ["show", "-s", "--format=%B", "--end-of-options", ref])
  def branch_exists?(root, branch), do: ref_oid(root, "refs/heads/" <> branch) != nil
  def tag_exists?(root, tag), do: ref_oid(root, "refs/tags/" <> tag) != nil
  def ref_oid(root, ref), do: optional(root, ["show-ref", "--verify", "--hash", ref])

  def check_ref!(root, ref) do
    run!(root, ["check-ref-format", ref])
    ref
  end

  def tag_info(root, tag) do
    ref = check_ref!(root, "refs/tags/" <> tag)
    case {run(root, ["cat-file", "-t", ref]), run(root, ["rev-parse", "--verify", ref <> "^{commit}"])} do
      {{:ok, "tag"}, {:ok, target}} ->
        object = raw!(root, ["cat-file", "tag", ref])
        case String.split(object, "\n\n", parts: 2) do
          [header, message] ->
            unless String.contains?(header, "\ntype commit\n"), do: raise(Error, "tag must directly reference a commit")
            {:ok, %{type: :annotated, target_sha: target, message: message}}
          _ -> raise Error, "invalid annotated tag object"
        end
      {{:ok, _}, {:ok, target}} -> {:ok, %{type: :lightweight, target_sha: target, message: nil}}
      _ -> :missing
    end
  end

  @doc "Exact portable project inventory read from Git, including explicit empty trees."
  def project_observation(root, ref) do
    entries = tree_entries(root, ref)
    files = for %{type: :file} = entry <- entries do
      bytes = raw!(root, ["cat-file", "blob", entry.oid])
      %{"path" => entry.path, "sha256" => Identity.raw(bytes), "size" => byte_size(bytes), "executable" => entry.executable}
    end
    empty = for %{type: :directory, path: path} <- entries,
      not Enum.any?(entries, &String.starts_with?(&1.path, path <> "/")), do: path
    %{"entries" => Enum.sort_by(files, & &1["path"]), "empty_dirs" => Enum.sort(empty)}
  end

  def project_id(root, ref), do: Identity.digest("project", project_observation(root, ref))

  defp tree_entries(root, ref) do
    raw!(root, ["ls-tree", "-r", "-t", "-z", "--full-tree", ref])
    |> String.split(<<0>>, trim: true)
    |> Enum.map(fn item ->
      with [head, path] <- String.split(item, "\t", parts: 2),
           [mode, type, oid] <- String.split(head, " "),
           true <- {mode, type} in [{"100644", "blob"}, {"100755", "blob"}, {"040000", "tree"}] do
        Inventory.validate_path!(path)
        %{path: path, type: if(type == "blob", do: :file, else: :directory), oid: oid, executable: mode == "100755"}
      else
        _ -> raise Error, "unsupported or malformed Git tree entry"
      end
    end)
  end

  @doc "Write a tree directly from qualified files, preserving modes and empty directories."
  def write_project_tree!(root, project, scratch) do
    observation = project_files(project)
    tree = Enum.reduce(observation["entries"], %{}, fn entry, acc ->
      oid = run!(root, ["hash-object", "-w", "--no-filters", "--", Path.join(project, entry["path"])])
      leaf = {:blob, if(entry["executable"], do: "100755", else: "100644"), oid}
      put_tree(acc, String.split(entry["path"], "/"), leaf)
    end)
    tree = Enum.reduce(observation["empty_dirs"], tree, &put_tree(&2, String.split(&1, "/"), %{}))
    {write_tree_object!(root, tree, scratch), observation}
  end

  defp put_tree(tree, [name], leaf), do: Map.put(tree, name, leaf)
  defp put_tree(tree, [name | rest], leaf), do: Map.update(tree, name, put_tree(%{}, rest, leaf), &put_tree(&1, rest, leaf))

  defp write_tree_object!(root, tree, scratch) do
    bytes = tree
      |> Enum.sort_by(fn {name, node} -> name <> if(is_map(node), do: "/", else: "") end)
      |> Enum.map(fn
        {name, {:blob, mode, oid}} -> [mode, " ", name, <<0>>, Base.decode16!(oid, case: :lower)]
        {name, children} -> ["40000 ", name, <<0>>, Base.decode16!(write_tree_object!(root, children, scratch), case: :lower)]
      end) |> IO.iodata_to_binary()
    write_object!(root, "tree", bytes, scratch)
  end

  def write_commit!(root, tree, parent, message, scratch) do
    file = Path.join(scratch, "message-" <> nonce())
    File.write!(file, message, [:exclusive])
    try do
      args = ["commit-tree", tree] ++ if(parent, do: ["-p", parent], else: [])
      run!(root, args ++ ["-F", file])
    after
      File.rm(file)
    end
  end

  def write_tag!(root, tag, commit, message, scratch) do
    check_ref!(root, "refs/tags/" <> tag)
    tagger = run!(root, ["var", "GIT_COMMITTER_IDENT"])
    bytes = "object #{commit}\ntype commit\ntag #{tag}\ntagger #{tagger}\n\n#{message}"
    write_object!(root, "tag", bytes, scratch)
  end

  defp write_object!(root, type, bytes, scratch) do
    file = Path.join(scratch, "object-" <> nonce())
    File.write!(file, bytes, [:exclusive])
    try do
      run!(root, ["hash-object", "-w", "-t", type, "--no-filters", "--", file])
    after
      File.rm(file)
    end
  end

  @doc "Update refs together with expected old object IDs; never replace a conflicting tag."
  def transaction!(root, updates) do
    zeros = String.duplicate("0", if(object_format(root) == "sha256", do: 64, else: 40))
    commands = Enum.map(updates, fn {ref, new, old} ->
      check_ref!(root, ref)
      validate_oid!(root, new)
      if old, do: validate_oid!(root, old)
      "update #{ref} #{new} #{old || zeros}\n"
    end)
    executable = System.find_executable("git") || raise(Error, "Git executable unavailable")
    timeout = System.find_executable("timeout") || raise(Error, "bounded Git operations require timeout")
    port = Port.open({:spawn_executable, timeout}, [:binary, :exit_status, :stderr_to_stdout, :use_stdio,
      {:args, ["--signal=TERM", "--kill-after=2s", "10s", executable, "update-ref", "--stdin"]}, {:cd, root},
      {:env, Enum.map(git_env(), fn {name, value} -> {to_charlist(name), if(value, do: to_charlist(value), else: false)} end)}])
    try do
      Port.command(port, IO.iodata_to_binary(["start\n", commands, "prepare\ncommit\n"]))
      await_transaction!(port, "", System.monotonic_time(:millisecond) + 10_000)
    after
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          _ = System.cmd("kill", ["-TERM", "--", "-#{pid}"], stderr_to_stdout: true)
          Port.close(port)
        nil -> :ok
      end
    end
    unless Enum.all?(updates, fn {ref, oid, _} -> ref_oid(root, ref) == oid end),
      do: raise(Error, "Git ref transaction result is unknown; inspect refs before retry")
    :ok
  end

  defp await_transaction!(port, output, deadline) do
    receive do
      {^port, {:data, bytes}} ->
        output = output <> bytes
        cond do
          byte_size(output) > 64_000 -> raise Error, "Git ref transaction output exceeded limit"
          String.contains?(output, "commit: ok\n") -> :ok
          true -> await_transaction!(port, output, deadline)
        end
      {^port, {:exit_status, status}} -> raise Error, "Git ref transaction failed (#{status}): #{Runner.sanitize(output)}"
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise Error, "Git ref transaction outcome unknown; inspect refs before retry"
    end
  end

  def push_release!(root, remote, branch, tag \\ nil) do
    refs = ["refs/heads/" <> branch] ++ if(tag, do: ["refs/tags/" <> tag], else: [])
    expected = Map.new(refs, &{&1, ref_oid(root, &1)})
    case run(root, ["push", "--atomic", "--", remote | refs]) do
      {:ok, _} -> :ok
      {:error, reason} ->
        observed = remote_refs(root, remote, refs)
        if observed == {:ok, expected}, do: :ok,
          else: raise(Error, "atomic remote push failed or is unresolved; inspect refs before retry: #{reason}")
    end
  end

  def remote_refs(root, remote, refs) do
    case run(root, ["ls-remote", "--refs", "--", remote | refs]) do
      {:ok, output} ->
        pairs = for line <- String.split(output, "\n", trim: true), [oid, ref] <- [String.split(line, "\t", parts: 2)], do: {ref, oid}
        {:ok, Map.new(pairs)}
      error -> error
    end
  end

  @doc "Prove a remote tip is an ancestor of the local tip using available commit objects."
  def fast_forward_from?(root, remote_tip, local_tip) when is_binary(remote_tip) and is_binary(local_tip) do
    validate_oid!(root, remote_tip)
    validate_oid!(root, local_tip)
    match?({:ok, _}, run(root, ["merge-base", "--is-ancestor", remote_tip, local_tip]))
  end
  def fast_forward_from?(_root, _remote_tip, _local_tip), do: false

  def project_files(root), do: Weld.Hash.observation(root)

  defp validate_oid!(root, oid) do
    size = if object_format(root) == "sha256", do: 64, else: 40
    unless is_binary(oid) and byte_size(oid) == size and Regex.match?(~r/\A[0-9a-f]+\z/, oid), do: raise(Error, "invalid Git object ID")
    oid
  end
  defp optional(root, args) do
    case run(root, args) do
      {:ok, output} -> output
      _ -> nil
    end
  end

  defp git_env, do: Enum.map(@git_overrides, &{&1, nil}) ++ [{"GIT_TERMINAL_PROMPT", "0"}]

  def run(root, args) do
    case Runner.capture!("git", args, cd: root, seconds: 60, max_bytes: 64 * 1024 * 1024, env: git_env()) do
      {bytes, 0} -> {:ok, String.trim(bytes)}
      {bytes, _} -> {:error, Runner.sanitize(String.trim(bytes))}
    end
  end

  def run!(root, args) do
    case run(root, args) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise Error, "git operation failed: #{reason}"
    end
  end

  defp raw!(root, args) do
    case Runner.capture!("git", args, cd: root, seconds: 60, max_bytes: 256 * 1024 * 1024, env: git_env()) do
      {bytes, 0} -> bytes
      {bytes, _} -> raise Error, "git observation failed: #{Runner.sanitize(bytes)}"
    end
  end

  defp normalize_remote(nil), do: nil
  defp normalize_remote(""), do: nil
  defp normalize_remote("git@github.com:" <> path), do: "https://github.com/" <> String.trim_trailing(path, ".git")
  defp normalize_remote(url) do
    parsed = URI.parse(String.trim_trailing(url, ".git"))
    %{parsed | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()
  end
  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
