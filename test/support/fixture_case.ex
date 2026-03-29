defmodule Weld.FixtureCase do
  @moduledoc false

  def fixture_path(name) do
    Path.expand(Path.join(["..", "fixtures", name]), __DIR__)
  end

  def manifest_path(fixture, name) do
    Path.join([fixture_path(fixture), "packaging", "weld", "#{name}.exs"])
  end

  def copied_manifest_path(fixture, name) do
    copied_root = copy_fixture(fixture)
    Path.join([copied_root, "packaging", "weld", "#{name}.exs"])
  end

  def unique_tmp_dir(prefix) do
    tmp_root = System.tmp_dir!()
    dir = Path.join(tmp_root, "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  def copy_fixture(name) do
    parent = unique_tmp_dir("weld_fixture_parent")
    target = Path.join(parent, name)
    File.cp_r!(fixture_path(name), target)
    target
  end

  def init_git!(repo_root) do
    run!(repo_root, ["init"])
    run!(repo_root, ["config", "user.name", "Weld Test"])
    run!(repo_root, ["config", "user.email", "weld@example.test"])
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", "initial"])
  end

  def commit_all!(repo_root, message) do
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", message])
  end

  defp run!(repo_root, args) do
    {output, status} = System.cmd("git", args, cd: repo_root, stderr_to_stdout: true)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end
  end
end
