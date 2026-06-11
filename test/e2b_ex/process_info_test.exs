defmodule E2bEx.ProcessInfoTest do
  use ExUnit.Case, async: true
  alias E2bEx.ProcessInfo

  test "from_api/1 maps a ListResponse entry with full config" do
    entry = %{
      "pid" => 42,
      "tag" => "build",
      "config" => %{
        "cmd" => "/bin/bash",
        "args" => ["-l", "-c", "make"],
        "envs" => %{"FOO" => "bar"},
        "cwd" => "/work"
      }
    }

    assert ProcessInfo.from_api(entry) == %ProcessInfo{
             pid: 42,
             tag: "build",
             cmd: "/bin/bash",
             args: ["-l", "-c", "make"],
             envs: %{"FOO" => "bar"},
             cwd: "/work"
           }
  end

  test "from_api/1 tolerates a missing tag, cwd, args and envs" do
    entry = %{"pid" => 7, "config" => %{"cmd" => "sleep"}}

    assert ProcessInfo.from_api(entry) == %ProcessInfo{
             pid: 7,
             tag: nil,
             cmd: "sleep",
             args: [],
             envs: %{},
             cwd: nil
           }
  end
end
