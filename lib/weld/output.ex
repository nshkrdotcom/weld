defmodule Weld.Output do
  @moduledoc """
  Owns generated paths, checkout-wide serialization and safe activation.
  A stopped writer can leave a mutation lock. Inspect its owner before clearing it.
  """

  alias Weld.{Error, Git}

  @owner "weld-output/v1\n"
  @ignore_rules [".weld", "/.weld", ".weld/", "/.weld/"]
  @forbidden ~w(.git .weld _build deps)

  def checkout(root), do: Git.root(root) || Path.expand(root)

  def path(root, parts) do
    base = Path.join(checkout(root), ".weld")

    reject_link!(base)

    Enum.reduce(parts, base, fn part, parent ->
      unless is_binary(part) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, part) and
               part not in [".", ".."] do
        raise Error, "invalid Weld output path segment: #{inspect(part)}"
      end

      target = Path.join(parent, part)
      reject_link!(target)
      target
    end)
  end

  def with_lock(root, fun) do
    checkout = checkout(root)
    key = {__MODULE__, :mutation, checkout}

    if Process.get(key) do
      fun.()
    else
      with_checkout_lock(checkout, key, fun)
    end
  end

  defp with_checkout_lock(checkout, key, fun) do
    base = Path.join(checkout, ".weld")
    ensure_untracked!(checkout)
    reject_link!(base)
    mkdir!(base)
    lock = Path.join(base, ".lock")
    acquire!(lock, System.monotonic_time(:millisecond) + 120_000)

    try do
      File.write!(Path.join(lock, "owner"), "pid=#{System.pid()} node=#{node()}\n")
      own_root!(base)
      ensure_ignore!(checkout, base)
      Process.put(key, true)
      fun.()
    after
      Process.delete(key)
      File.rm_rf!(lock)
    end
  end

  defp ensure_untracked!(checkout) do
    if Git.root(checkout) && Git.run!(checkout, ["ls-files", "--", ".weld"]) != "" do
      raise Error, "tracked .weld output at #{checkout}; resolve the index before projecting"
    end
  end

  defp own_root!(base) do
    owner = Path.join(base, ".owner")
    reject_link!(owner)

    case File.read(owner) do
      {:ok, @owner} ->
        :ok

      {:error, :enoent} ->
        unless File.ls!(base) == [".lock"], do: raise(Error, "unmanaged Weld output: #{base}")
        File.write!(owner, @owner, [:exclusive])

      _ ->
        raise Error, "unmanaged Weld output: #{base}"
    end
  end

  defp mkdir!(path) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        unless File.dir?(path), do: raise(Error, "Weld output is not a directory: #{path}")

      {:error, reason} ->
        raise Error, "cannot create #{path}: #{reason}"
    end
  end

  defp acquire!(lock, deadline) do
    case File.mkdir(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(lock) do
          {:ok, %{type: :directory}} ->
            if System.monotonic_time(:millisecond) >= deadline do
              raise Error, "Weld lock busy at #{lock}; inspect its owner"
            end

            Process.sleep(40)
            acquire!(lock, deadline)

          {:error, :enoent} ->
            acquire!(lock, deadline)

          _ ->
            raise Error, "unmanaged mutation lock: #{lock}"
        end

      {:error, reason} ->
        raise Error, "cannot acquire #{lock}: #{reason}"
    end
  end

  defp ensure_ignore!(checkout, base) do
    target = Path.join(checkout, ".gitignore")
    before = read_regular!(target)
    old = if before, do: elem(before, 0), else: ""
    newline = if String.contains?(old, "\r\n"), do: "\r\n", else: "\n"
    lines = String.split(old, ~r/(?<=\n)/, trim: true)

    check_negations!(lines, base)

    {lines, found?} =
      Enum.map_reduce(lines, false, fn line, found? ->
        raw = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
        rule = Regex.replace(~r/\\(.)/, String.trim_trailing(raw, " "), fn _, char -> char end)

        cond do
          rule not in @ignore_rules -> {line, found?}
          found? -> {"", true}
          true -> {".weld/" <> String.replace_prefix(line, raw, ""), true}
        end
      end)

    contents = IO.iodata_to_binary(lines)

    updated =
      cond do
        found? -> contents
        contents == "" or String.ends_with?(contents, "\n") -> contents <> ".weld/" <> newline
        true -> contents <> newline <> ".weld/" <> newline
      end

    if updated != old do
      temp = Path.join(base, "ignore-" <> nonce())

      try do
        File.write!(temp, updated, [:exclusive])
        if before, do: File.chmod!(temp, elem(before, 1))
        if read_regular!(target) != before, do: raise(Error, ".gitignore changed during setup")
        File.rename!(temp, target)
      after
        File.rm(temp)
      end
    end

    if Git.root(checkout) do
      for path <- ~w(.weld/live/probe .weld/full/probe/project .weld/cache/probe) do
        Git.run!(checkout, ["check-ignore", "--quiet", "--no-index", "--", path])
      end
    end
  end

  # Ask Git to match the first rooted component. This handles wildcards,
  # bracket expressions, escapes and trailing spaces using its own grammar.
  # Explicit child exceptions are conflicts even if a later rule masks them.
  defp check_negations!(lines, base) do
    candidates =
      for "!" <> pattern <- lines,
          first = first_component(pattern),
          first != "",
          do: "/" <> first <> "/"

    unless candidates == [] do
      scratch = Path.join(base, "ignore-check-" <> nonce())
      File.mkdir!(scratch)

      try do
        Git.run!(scratch, ["-c", "init.templateDir=", "init", "--quiet"])
        File.write!(Path.join(scratch, ".gitignore"), Enum.join(candidates, "\n") <> "\n")

        args = [
          "-c",
          "core.excludesFile=/dev/null",
          "check-ignore",
          "--no-index",
          "--",
          ".weld/probe"
        ]

        case System.cmd("git", args, cd: scratch, stderr_to_stdout: true) do
          {_path, 0} -> raise Error, "conflicting .gitignore negation for .weld/"
          {_output, 1} -> :ok
          {output, _status} -> raise Error, "unable to check .gitignore exceptions: #{output}"
        end
      after
        File.rm_rf!(scratch)
      end
    end
  end

  defp first_component(pattern) do
    pattern
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
    |> String.trim_trailing(" ")
    |> String.trim_leading("/")
    |> String.replace(~r/^(?:\*\*\/)+/, "")
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp read_regular!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> {File.read!(path), Bitwise.band(mode, 0o7777)}
      {:error, :enoent} -> nil
      _ -> raise Error, "expected a regular file: #{path}"
    end
  end

  def reject_link!(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> raise Error, "symlink is not permitted: #{path}"
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise Error, "cannot inspect #{path}: #{reason}"
    end
  end

  def source!(root, relative) do
    parts = String.split(relative, "/")

    if Path.type(relative) != :relative or String.contains?(relative, ["\\", <<0>>]) or
         Enum.any?(parts, &(&1 in ["", ".", ".." | @forbidden])) do
      raise Error, "unsafe source path: #{inspect(relative)}"
    end

    Enum.reduce(parts, root, fn part, parent ->
      path = Path.join(parent, part)
      reject_link!(path)
      path
    end)
  end

  def cache!(root, key, toolchain) do
    dir = path(root, ["cache", key, toolchain])
    owner = Path.join(dir, ".owner")
    reject_link!(owner)

    if File.exists?(dir) do
      unless File.read(owner) == {:ok, @owner}, do: raise(Error, "unmanaged cache: #{dir}")
    else
      File.mkdir_p!(dir)
      File.write!(owner, @owner, [:exclusive])
    end

    for child <- ["build", "deps"], do: reject_link!(Path.join(dir, child))
    dir
  end

  def temporary!(root, category) do
    dir = path(root, [category, nonce()])
    File.mkdir_p!(Path.dirname(dir))
    File.mkdir!(dir)
    dir
  end

  def activate!(stage, target, valid_existing?) do
    File.mkdir_p!(Path.dirname(target))
    reject_link!(target)

    if File.exists?(target) do
      unless valid_existing?.(target), do: raise(Error, "unmanaged output: #{target}")
      previous = stage <> "-previous"
      File.rename!(target, previous)

      try do
        File.rename!(stage, target)
      rescue
        error ->
          File.rename!(previous, target)
          reraise error, __STACKTRACE__
      end

      File.rm_rf!(previous)
    else
      File.rename!(stage, target)
    end
  end

  def reject_tree_links!(root) do
    reject_link!(root)

    if File.dir?(root) do
      for entry <- File.ls!(root), do: reject_tree_links!(Path.join(root, entry))
    end

    :ok
  end

  def nonce, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
