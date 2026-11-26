defmodule Workshop.PaletteTest do
  use ExUnit.Case, async: true

  test "the extension uses its external base and owns its private assets" do
    expected = File.read!(Path.join(__DIR__, "shade.txt"))
    assert {"jade", ^expected} = Workshop.Palette.color()
    assert Application.get_application(Workshop) == :workshop
    assert Application.get_application(Workshop.Palette) == :workshop_palette
  end
end
