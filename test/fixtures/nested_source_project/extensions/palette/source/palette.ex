defmodule Workshop.Palette do
  def color do
    filename = Application.app_dir(:workshop_palette, "priv/shade.txt")
    {Workshop.color(), File.read!(filename)}
  end
end
