defmodule Sprout.Runtime do
  def value, do: Sprout.Pure.value()

  def asset,
    do: :sprout |> :code.priv_dir() |> to_string() |> Path.join("theme.txt") |> File.read!()
end
