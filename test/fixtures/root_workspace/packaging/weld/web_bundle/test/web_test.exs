defmodule RootWebBundle.WebTest do
  use ExUnit.Case, async: true

  test "the projected web bundle exposes its runtime dependency" do
    assert RootWorkspace.Web.page_title() == "core web"
  end
end
