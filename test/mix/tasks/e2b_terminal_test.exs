defmodule Mix.Tasks.E2b.TerminalTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.E2b.Terminal

  test "parses a sandbox id target with an explicit --api-key" do
    assert {"k", {:id, "sb_1"}} = Terminal.parse!(["--api-key", "k", "sb_1"])
  end

  test "parses a --template target" do
    assert {"k", {:template, "base"}} = Terminal.parse!(["--api-key", "k", "--template", "base"])
  end

  test "falls back to the E2B_API_KEY env var" do
    System.put_env("E2B_API_KEY", "envk")
    on_exit(fn -> System.delete_env("E2B_API_KEY") end)
    assert {"envk", {:id, "sb_1"}} = Terminal.parse!(["sb_1"])
  end

  test "raises Mix.Error when neither an id nor --template is given" do
    assert_raise Mix.Error, fn -> Terminal.parse!(["--api-key", "k"]) end
  end
end
