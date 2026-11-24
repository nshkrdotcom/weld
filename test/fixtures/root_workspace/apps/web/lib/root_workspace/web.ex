defmodule RootWorkspace.Web do
  @moduledoc false

  alias RootWorkspace.Core

  def page_title, do: "#{Core.greet()} web"
end
