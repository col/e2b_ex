defmodule E2bEx.CommandHandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandHandle, Commands, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Connect

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp respond(bypass, body) do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  test "wait/1 drains output and returns the result", %{bypass: bypass, base_url: base_url} do
    respond(bypass,
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("hello")}}}) <>
        frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 2}}}) <>
        trailer("{}")
    )

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:ok, %CommandResult{stdout: "hello", exit_code: 2}} = CommandHandle.wait(handle)
  end

  test "wait/1 returns {:error, _} on a Connect trailer error", %{bypass: bypass, base_url: base_url} do
    respond(bypass,
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        trailer(~s({"error":{"code":"unavailable","message":"gone"}}))
    )

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:error, %Error{message: "gone", reason: "unavailable"}} = CommandHandle.wait(handle)
  end

  test "wait/1 returns {:error, _} when the stream ends with no end event",
       %{bypass: bypass, base_url: base_url} do
    respond(bypass, frame(%{"event" => %{"start" => %{"pid" => 1}}}) <> trailer("{}"))

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:error, %Error{message: "command ended without a result"}} = CommandHandle.wait(handle)
  end

  test "handle kill/1 delegates to the SendSignal RPC",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200,
        frame(%{"event" => %{"start" => %{"pid" => 77}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["process"] == %{"pid" => 77}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert CommandHandle.pid(handle) == 77
    assert {:ok, true} = CommandHandle.kill(handle)
  end
end
