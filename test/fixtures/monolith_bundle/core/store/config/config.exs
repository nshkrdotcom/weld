import Config

config :fixture_store, :source, :store

if config_env() == :test do
  config :fixture_store, :mode, :test
end
