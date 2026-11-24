defmodule Sprout.Layout do
  def value, do: {:layout, Sprout.Runtime.value()}
end
