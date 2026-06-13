defmodule E2bEx.FilesystemEventTest do
  use ExUnit.Case, async: true
  alias E2bEx.{EntryInfo, FilesystemEvent}

  test "from_api/1 decodes the event type and nested entry" do
    event =
      FilesystemEvent.from_api(%{
        "name" => "/d/a.txt",
        "type" => "EVENT_TYPE_CREATE",
        "entry" => %{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt"}
      })

    assert %FilesystemEvent{
             name: "/d/a.txt",
             type: :create,
             entry: %EntryInfo{name: "a.txt", type: :file, path: "/d/a.txt"}
           } = event
  end

  test "from_api/1 leaves entry nil when absent and maps all event types" do
    assert %FilesystemEvent{type: :write, entry: nil} =
             FilesystemEvent.from_api(%{"name" => "x", "type" => "EVENT_TYPE_WRITE"})

    for {str, atom} <- [
          {"EVENT_TYPE_CREATE", :create},
          {"EVENT_TYPE_WRITE", :write},
          {"EVENT_TYPE_REMOVE", :remove},
          {"EVENT_TYPE_RENAME", :rename},
          {"EVENT_TYPE_CHMOD", :chmod}
        ] do
      assert %FilesystemEvent{type: ^atom} = FilesystemEvent.from_api(%{"type" => str})
    end
  end

  test "from_api/1 maps an unknown type to nil" do
    assert %FilesystemEvent{type: nil} = FilesystemEvent.from_api(%{"type" => "EVENT_TYPE_UNSPECIFIED"})
  end
end
