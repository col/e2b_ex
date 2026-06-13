defmodule E2bEx.Filesystem.WatchHandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.Filesystem.WatchHandle

  test "stop/1 stops a live server and returns :ok" do
    {:ok, server} = Agent.start(fn -> 0 end)
    handle = %WatchHandle{server: server, ref: make_ref()}

    assert :ok = WatchHandle.stop(handle)
    refute Process.alive?(server)
  end

  test "stop/1 is a no-op (still :ok) when the server is already dead" do
    {:ok, server} = Agent.start(fn -> 0 end)
    :ok = Agent.stop(server)

    assert :ok = WatchHandle.stop(%WatchHandle{server: server, ref: make_ref()})
  end
end
