defmodule E2bExTest do
  use ExUnit.Case, async: true

  test "client/1 builds an E2bEx.Client" do
    assert %E2bEx.Client{api_key: "k"} = E2bEx.client(api_key: "k")
  end
end
