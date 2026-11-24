defmodule Sprout.Probe do
  @external_resource Path.expand("../priv/probe.txt", __DIR__)
  @fixture File.read!(@external_resource)

  def value, do: {String.trim(@fixture), :sprout_probe_native.value()}
end
