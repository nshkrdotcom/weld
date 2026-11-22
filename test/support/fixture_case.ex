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
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(tmp_root, "#{prefix}_#{suffix}")
    File.mkdir!(dir)
    dir
  end

  def copy_fixture(name) do
    parent = unique_tmp_dir("weld_fixture_parent")
    target = Path.join(parent, name)
    File.cp_r!(fixture_path(name), target)
    target
  end

  def write_tracking_fixture!(repo_root, manifest_path) do
    bundle = Weld.release_bundle_path!(manifest_path)
    project = Path.join(bundle, "project")
    File.mkdir_p!(project)
    File.cp!(Path.join(repo_root, "README.md"), Path.join(project, "README.md"))
    revision = git_output!(repo_root, ["rev-parse", "HEAD"])
    File.write!(Path.join(bundle, "release.json"), Jason.encode!(%{source_revision: revision}))
  end

  def init_git!(repo_root) do
    run!(repo_root, ["init"])

    File.write!(
      Path.join(repo_root, ".git/info/exclude"),
      "\n**/_build/\n**/deps/\n**/mix.lock\n/dist/\n/tmp/\n",
      [:append]
    )

    run!(repo_root, ["config", "user.name", "Weld Test"])
    run!(repo_root, ["config", "user.email", "weld@example.test"])
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", "initial"])
  end

  def init_bare_git!(repo_root) do
    File.rm_rf!(repo_root)
    File.mkdir_p!(repo_root)

    {output, status} =
      System.cmd("git", ["init", "--bare", repo_root], stderr_to_stdout: true)

    if status != 0 do
      raise "git init --bare failed:\n#{output}"
    end
  end

  def commit_all!(repo_root, message) do
    run!(repo_root, ["add", "."])
    run!(repo_root, ["commit", "-m", message])
  end

  def git_output!(repo_root, args) do
    {output, status} = git(repo_root, args)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end

    String.trim(output)
  end

  def branch_exists?(repo_root, branch) do
    {_output, status} =
      git(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"])

    status == 0
  end

  def remote_branch_exists?(repo_root, remote, branch) do
    {_output, status} = git(repo_root, ["ls-remote", "--exit-code", "--heads", remote, branch])
    status == 0
  end

  def tag_exists?(repo_root, tag) do
    {_output, status} = git(repo_root, ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"])
    status == 0
  end

  def git(repo_root, args) do
    System.cmd("git", args, cd: repo_root, stderr_to_stdout: true)
  end

  defp run!(repo_root, args) do
    {output, status} = git(repo_root, args)

    if status != 0 do
      raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end
  end
end
