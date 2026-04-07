defmodule Fixture.Api do
  @moduledoc false

  def source do
    {Fixture.Store.source(), Application.get_env(:fixture_api, :source)}
  end
end
