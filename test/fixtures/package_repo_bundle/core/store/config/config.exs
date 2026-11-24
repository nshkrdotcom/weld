import Config

config :fixture_store, Fixture.Store.Repo,
  database: "fixture_store_test",
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1"
