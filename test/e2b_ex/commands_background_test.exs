defmodule E2bEx.CommandsBackgroundTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandHandle, Commands, Sandbox}
  alias E2bEx.Envd.Connect

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp chunk_bytes(bin, n) when byte_size(bin) > n do
    <<part::binary-size(n), rest::binary>> = bin
    [part | chunk_bytes(rest, n)]
  end

  defp chunk_bytes(bin, _n), do: [bin]

  defp start_body do
    frame(%{"event" => %{"start" => %{"pid" => 99}}}) <>
      frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("foo")}}}) <>
      frame(%{"event" => %{"data" => %{"stderr" => Base.encode64("bar")}}}) <>
      frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 0}}}) <>
      trailer("{}")
  end

  test "start/4 returns a handle with the pid and streams output then a terminal exit",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunk_bytes(start_body(), 9), conn, fn part, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, part)
        conn
      end)
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "echo hi", base_url: base_url)
    assert CommandHandle.pid(handle) == 99
    ref = handle.ref

    assert_receive {^ref, {:stdout, "foo"}}
    assert_receive {^ref, {:stderr, "bar"}}
    assert_receive {^ref, {:exit, %E2bEx.CommandResult{stdout: "foo", stderr: "bar", exit_code: 0}}}
  end

  test "start/4 errors when the stream returns non-2xx before a start event",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"code":"unauthenticated","message":"no token"}))
    end)

    assert {:error, %E2bEx.Error{}} = Commands.start(client(), sandbox(), "echo", base_url: base_url)
  end

  test "disconnect/1 stops the handle server and sends no terminal message",
       %{bypass: bypass, base_url: base_url} do
    # Stream only a start event, then hang (no end / trailer), so the command stays "running".
    Bypass.expect(bypass, "POST", "/process.Process/Start", fn conn ->
      # Trap exits: when `disconnect/1` cancels the request, the socket closes and
      # cowboy's connection process sends this handler a linked `:shutdown` EXIT.
      # Catch it (and the chunk/2 {:error, _} fallback) and return the conn so the
      # handler exits cleanly — otherwise Bypass re-raises the abrupt shutdown in
      # on_exit. Keepalive events are ignored by Fold, so no subscriber messages.
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(%{"event" => %{"start" => %{"pid" => 5}}}))

      Enum.reduce_while(1..200, conn, fn _, conn ->
        receive do
          {:EXIT, _, _} -> {:halt, conn}
        after
          10 ->
            case Plug.Conn.chunk(conn, frame(%{"event" => %{"keepalive" => %{}}})) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
        end
      end)
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "sleep 100", base_url: base_url)
    ref = handle.ref
    server = handle.server
    assert :ok = CommandHandle.disconnect(handle)
    refute Process.alive?(server)
    refute_receive {^ref, {:exit, _}}, 50
    refute_receive {^ref, {:error, _}}, 50
  end

  test "a malformed chunk after the start event sends a terminal error to the subscriber",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      body =
        frame(%{"event" => %{"start" => %{"pid" => 3}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => "!!! not base64 !!!"}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    ref = handle.ref
    assert CommandHandle.pid(handle) == 3
    assert_receive {^ref, {:error, %E2bEx.Error{message: "malformed envd response"}}}
  end

  test "connect/4 reconnects to a running pid and yields the result", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Connect", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"process" => %{"pid" => 42}}

      body =
        frame(%{"event" => %{"start" => %{"pid" => 42}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("back")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Commands.connect(client(), sandbox(), 42, base_url: base_url)
    assert E2bEx.CommandHandle.pid(handle) == 42
    assert {:ok, %E2bEx.CommandResult{stdout: "back"}} = E2bEx.CommandHandle.wait(handle)
  end
end
