defmodule Fixture.Store.Repo do
  use Ecto.Repo,
    otp_app: :fixture_store,
    adapter: Ecto.Adapters.Postgres
end
