defmodule E2bEx.Commands.FoldTest do
  use ExUnit.Case, async: true
  alias E2bEx.Commands.Fold
  alias E2bEx.CommandResult

  test "folds a stdout data event, returning the decoded output" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => Base.encode64("hi")}})
    assert outputs == [{:stdout, "hi"}]
    assert Fold.result(acc) == %CommandResult{stdout: "hi"}
  end

  test "folds a stderr data event" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"data" => %{"stderr" => Base.encode64("oops")}})
    assert outputs == [{:stderr, "oops"}]
    assert Fold.result(acc).stderr == "oops"
  end

  test "accumulates across events and marks ended on the end event" do
    {:ok, acc, _} = Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => Base.encode64("a")}})
    {:ok, acc, _} = Fold.apply_event(acc, %{"data" => %{"stdout" => Base.encode64("b")}})
    refute Fold.ended?(acc)
    {:ok, acc, outputs} = Fold.apply_event(acc, %{"end" => %{"exitCode" => 3, "error" => "boom"}})
    assert outputs == []
    assert Fold.ended?(acc)
    assert Fold.result(acc) == %CommandResult{stdout: "ab", exit_code: 3, error: "boom"}
  end

  test "defaults exit_code to 0 when the end event omits it" do
    {:ok, acc, _} = Fold.apply_event(Fold.new(), %{"end" => %{"exited" => true}})
    assert Fold.result(acc).exit_code == 0
    assert Fold.result(acc).error == nil
  end

  test "ignores start and keepalive events with no output" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"start" => %{"pid" => 7}})
    assert outputs == []
    assert Fold.result(acc) == %CommandResult{}
    {:ok, _acc, outputs} = Fold.apply_event(acc, %{"keepalive" => %{}})
    assert outputs == []
  end

  test "returns an error on an invalid base64 chunk" do
    assert {:error, :invalid_base64} =
             Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => "!!! not base64 !!!"}})
  end
end
