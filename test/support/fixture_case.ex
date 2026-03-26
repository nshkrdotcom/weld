defmodule Weld.FixtureCase do
  @moduledoc false

  def fixture_path(name) do
    Path.expand(Path.join(["..", "fixtures", name]), __DIR__)
  end

  def manifest_path(fixture, name) do
    Path.join([fixture_path(fixture), "packaging", "hex_projections", "#{name}.exs"])
  end

  def unique_tmp_dir(prefix) do
    tmp_root = System.tmp_dir!()
    dir = Path.join(tmp_root, "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
