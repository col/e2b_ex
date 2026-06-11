defmodule E2bEx.Pty.HandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.{Connect, Rpc}
  alias E2bEx.Pty
  alias E2bEx.Pty.Handle

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

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

  test "wait/1 drains pty output and returns an exit-code-only result", %{bypass: bypass} do
    base_url = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200,
        frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
          frame(%{"event" => %{"data" => %{"pty" => Base.encode64("noise")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 7}}}) <>
          trailer("{}"))
    end)

    {:ok, handle} = Pty.create(client(), sandbox(), cols: 80, rows: 24, base_url: base_url)
    assert {:ok, %CommandResult{exit_code: 7, stdout: "", stderr: ""}} = Handle.wait(handle)
  end

  test "wait/1 returns {:error, _} if the handle server crashes", %{bypass: bypass} do
    base_url = "http://localhost:#{bypass.port}"

    # Hang the stream (only a start event, then keepalives) so the server never
    # sends a terminal message — otherwise wait/1 would race the {:exit, _} it
    # emits on normal completion. Same trap_exit teardown as the disconnect test.
    Bypass.expect(bypass, "POST", "/process.Process/Start", fn conn ->
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(%{"event" => %{"start" => %{"pid" => 1}}}))

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

    {:ok, handle} = Pty.create(client(), sandbox(), cols: 80, rows: 24, base_url: base_url)
    # Brutally kill the server; wait/1 monitors it and returns on the :DOWN.
    Process.exit(handle.server, :kill)
    assert {:error, %Error{message: "command handle terminated"}} = Handle.wait(handle)
  end

  test "disconnect/1 stops the server and sends no terminal message", %{bypass: bypass} do
    base_url = "http://localhost:#{bypass.port}"

    Bypass.expect(bypass, "POST", "/process.Process/Start", fn conn ->
      # Same trap_exit pattern as the commands disconnect test: cancelling the
      # request closes the socket; cowboy delivers a linked :shutdown EXIT here.
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

    {:ok, handle} = Pty.create(client(), sandbox(), cols: 80, rows: 24, base_url: base_url)
    ref = handle.ref
    server = handle.server
    assert :ok = Handle.disconnect(handle)
    refute Process.alive?(server)
    refute_receive {^ref, {:exit, _}}, 50
    refute_receive {^ref, {:error, _}}, 50
  end
end
