defmodule E2bEx.VolumeTest do
  use ExUnit.Case, async: true
  alias E2bEx.Volume

  test "from_api/1 maps volumeID -> volume_id and keeps name + token" do
    assert %Volume{volume_id: "v1", name: "data", token: "tok"} =
             Volume.from_api(%{"volumeID" => "v1", "name" => "data", "token" => "tok"})
  end

  test "from_api/1 leaves token nil when absent (the list shape omits it)" do
    assert %Volume{volume_id: "v1", name: "data", token: nil} =
             Volume.from_api(%{"volumeID" => "v1", "name" => "data"})
  end
end
