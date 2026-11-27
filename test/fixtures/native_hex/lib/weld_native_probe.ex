defmodule WeldNativeProbe do
  @moduledoc "A real compiled NIF and relocated priv bootstrap payload."
  @on_load :load_native
  def load_native do
    :code.priv_dir(:weld_native_probe)
    |> :filename.join(~c"weld_native_probe")
    |> :erlang.load_nif(0)
  end

  def value, do: :erlang.nif_error(:not_loaded)

  def bootstrap,
    do:
      Application.app_dir(:weld_native_probe, "priv/bootstrap.txt")
      |> File.read!()
      |> String.trim()
end
