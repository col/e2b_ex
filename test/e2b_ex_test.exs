defmodule E2bExTest do
  use ExUnit.Case
  doctest E2bEx

  test "greets the world" do
    assert E2bEx.hello() == :world
  end
end
