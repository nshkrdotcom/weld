defmodule WeldSmoke do
  def verify! do
    42 = WeldNativeProbe.value()
    "relocated-native-bootstrap" = WeldNativeProbe.bootstrap()
    :ok
  end
end
