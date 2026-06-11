defmodule E2bEx.Pty.HandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox}
  alias E2bEx.Envd.Rpc
  alias E2bEx.Pty.Handle

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  setup do
    bypass = Bypass.open()
    {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
    # server is unused by the control delegations; self() satisfies @enforce_keys.
    handle = %Handle{server: self(), ref: make_ref(), pid: 7, context: ctx}
    {:ok, bypass: bypass, handle: handle}
  end

  test "pid/1 returns the envd pid", %{handle: handle} do
    assert Handle.pid(handle) == 7
  end

  test "send_input/2 routes to the SendInput RPC's pty field", %{bypass: bypass, handle: handle} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}, "input" => %{"pty" => Base.encode64("a")}}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert :ok = Handle.send_input(handle, "a")
  end

  test "resize/2 routes to the Update RPC", %{bypass: bypass, handle: handle} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Update", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}, "pty" => %{"size" => %{"cols" => 90, "rows" => 30}}}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert :ok = Handle.resize(handle, %{cols: 90, rows: 30})
  end

  test "kill/1 routes to the SendSignal RPC", %{bypass: bypass, handle: handle} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}, "signal" => "SIGNAL_SIGKILL"}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert {:ok, true} = Handle.kill(handle)
  end
end
