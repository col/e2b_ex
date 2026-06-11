defmodule E2bEx.CommandsControlTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Commands, Error, ProcessInfo, Sandbox}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  test "list/2 returns ProcessInfo structs", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
      body = ~s({"processes":[{"pid":7,"tag":"t","config":{"cmd":"sleep","args":["1"],"envs":{},"cwd":"/"}}]})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, [%ProcessInfo{pid: 7, tag: "t", cmd: "sleep", args: ["1"], cwd: "/"}]} =
             Commands.list(client(), sandbox(), base_url: base_url)
  end

  test "kill/4 returns {:ok, true} on success", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert {:ok, true} = Commands.kill(client(), sandbox(), 7, base_url: base_url)
  end

  test "send_stdin/5 returns :ok", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert :ok = Commands.send_stdin(client(), sandbox(), 7, "data", base_url: base_url)
  end

  test "close_stdin/4 returns :ok", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/CloseStdin", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert :ok = Commands.close_stdin(client(), sandbox(), 7, base_url: base_url)
  end

  test "kill/4 propagates a context error when the sandbox has no id" do
    assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
             Commands.kill(client(), %Sandbox{sandbox_id: nil}, 7)
  end
end
