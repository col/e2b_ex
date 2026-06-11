defmodule E2bEx.CommandResultTest do
  use ExUnit.Case, async: true
  alias E2bEx.CommandResult

  test "defaults to empty output and zero exit code" do
    assert %CommandResult{stdout: "", stderr: "", exit_code: 0, error: nil} = %CommandResult{}
  end

  test "holds populated fields" do
    r = %CommandResult{stdout: "hi", stderr: "err", exit_code: 1, error: "boom"}
    assert r.stdout == "hi"
    assert r.exit_code == 1
    assert r.error == "boom"
  end
end
