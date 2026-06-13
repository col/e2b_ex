defmodule E2bEx.CommandsJoinTest do
  use ExUnit.Case, async: true
  alias E2bEx.Commands

  test "join/1 leaves safe args unquoted and space-joins them" do
    assert Commands.join(["echo", "hello"]) == "echo hello"
    assert Commands.join(["ls", "-la", "/tmp/dir-1"]) == "ls -la /tmp/dir-1"
  end

  test "join/1 single-quotes args with spaces or shell metacharacters" do
    assert Commands.join(["echo", "hello world"]) == "echo 'hello world'"
    assert Commands.join(["grep", "a|b", "f"]) == "grep 'a|b' f"
    assert Commands.join(["echo", "$HOME"]) == "echo '$HOME'"
  end

  test "join/1 escapes embedded single quotes" do
    assert Commands.join(["echo", "it's"]) == "echo 'it'\\''s'"
  end

  test "join/1 quotes an empty argument" do
    assert Commands.join(["printf", "%s", ""]) == "printf %s ''"
  end

  test "join/1 returns an empty string for an empty list" do
    assert Commands.join([]) == ""
  end
end
