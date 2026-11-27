defmodule WeldNativeProbeTest do
  use ExUnit.Case
  test "loads actual compiled native code and relocated bootstrap" do
    assert WeldNativeProbe.value() == 42
    assert WeldNativeProbe.bootstrap() == "relocated-native-bootstrap"
  end
end
