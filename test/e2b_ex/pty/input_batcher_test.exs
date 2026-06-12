defmodule E2bEx.Pty.InputBatcherTest do
  use ExUnit.Case, async: true
  alias E2bEx.Pty.InputBatcher

  test "flushes accumulated bytes once per interval, concatenated" do
    test = self()
    {:ok, b} = InputBatcher.start_link(flush_ms: 20, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    InputBatcher.push(b, "a")
    InputBatcher.push(b, "b")
    InputBatcher.push(b, "c")
    assert_receive {:flush, "abc"}, 200
  end

  test "does not invoke on_flush for an empty interval" do
    test = self()
    {:ok, _b} = InputBatcher.start_link(flush_ms: 20, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    refute_receive {:flush, _}, 80
  end

  test "stop/1 flushes the remaining buffer" do
    test = self()
    {:ok, b} = InputBatcher.start_link(flush_ms: 10_000, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    InputBatcher.push(b, "x")
    :ok = InputBatcher.stop(b)
    assert_receive {:flush, "x"}, 200
  end
end
