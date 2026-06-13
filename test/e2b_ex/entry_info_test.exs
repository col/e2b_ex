defmodule E2bEx.EntryInfoTest do
  use ExUnit.Case, async: true
  alias E2bEx.EntryInfo

  test "from_api/1 decodes a file entry (type, camelCase fields)" do
    entry =
      EntryInfo.from_api(%{
        "name" => "a.txt",
        "type" => "FILE_TYPE_FILE",
        "path" => "/d/a.txt",
        "size" => 3,
        "mode" => 420,
        "permissions" => "rw-r--r--",
        "owner" => "user",
        "group" => "user",
        "modifiedTime" => "2024-01-02T03:04:05Z",
        "symlinkTarget" => "/d/target",
        "metadata" => %{"k" => "v"}
      })

    assert %EntryInfo{
             name: "a.txt",
             type: :file,
             path: "/d/a.txt",
             size: 3,
             mode: 420,
             permissions: "rw-r--r--",
             owner: "user",
             group: "user",
             modified_time: "2024-01-02T03:04:05Z",
             symlink_target: "/d/target",
             metadata: %{"k" => "v"}
           } = entry
  end

  test "from_api/1 maps the directory type" do
    assert %EntryInfo{type: :dir} = EntryInfo.from_api(%{"type" => "FILE_TYPE_DIRECTORY"})
  end

  test "from_api/1 leaves omitted fields nil and unknown type nil" do
    assert %EntryInfo{name: "x", type: nil, size: nil, symlink_target: nil} =
             EntryInfo.from_api(%{"name" => "x"})
  end
end
