defmodule LaevTest do
  use ExUnit.Case

  test "config lang defaults sensibly" do
    assert is_binary(Laev.Config.lang())
  end
end
