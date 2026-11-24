defmodule Sprout.Consumer.MixProject do
  use Mix.Project
  def project, do: [app: :sprout_consumer, version: "0.1.0", deps: deps()]

  defp deps do
    {deps, []} = Code.eval_file("dependencies.exs", __DIR__)
    deps
  end
end
