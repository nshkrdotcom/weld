defmodule Fixture.Store.Repo.Migrations.CreateFixtureTable do
  use Ecto.Migration

  def change do
    create table(:fixture_records) do
      add(:name, :text)
    end
  end
end
