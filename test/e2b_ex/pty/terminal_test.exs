defmodule E2bEx.Pty.TerminalTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Rpc
  alias E2bEx.Pty.{Handle, Terminal}

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  setup do
    bypass = Bypass.open()
    {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
    server = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    handle = %Handle{server: server, ref: make_ref(), pid: 7, context: ctx}
    {:ok, bypass: bypass, handle: handle, server: server}
  end

  # Spawn run/2 in its own process (it is the PTY subscriber + blocks in a loop),
  # returning {runner_pid, ref}. The runner reports run/2's return as {:result, _}.
  defp start_runner(handle, opts) do
    test = self()
    pid = spawn(fn -> send(test, {:result, Terminal.run(handle, opts)}) end)
    {pid, handle.ref}
  end

  test "writes pty output to the writer in order and returns on exit", %{handle: handle} do
    test = self()

    {runner, ref} =
      start_runner(handle,
        write: fn bytes -> send(test, {:wrote, bytes}) end,
        read_byte: fn -> :eof end,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 10_000
      )

    send(runner, {ref, {:pty, "ab"}})
    send(runner, {ref, {:pty, "cd"}})
    assert_receive {:wrote, "ab"}
    assert_receive {:wrote, "cd"}

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, %CommandResult{exit_code: 0}}}
  end

  test "batches typed bytes into a single SendInput (input.pty)", %{bypass: bypass, handle: handle} do
    test = self()

    Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, Jason.decode!(raw)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    {:ok, agent} = Agent.start_link(fn -> ["l", "s", "\r"] end)
    read_byte = fn -> Agent.get_and_update(agent, fn [] -> {:eof, []}; [h | t] -> {h, t} end) end

    {runner, ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: read_byte,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 25
      )

    assert_receive {:sent, %{"process" => %{"pid" => 7}, "input" => %{"pty" => pty}}}, 500
    assert pty == Base.encode64("ls\r")

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, _}}
  end

  test "resizes when the polled terminal size changes", %{bypass: bypass, handle: handle} do
    test = self()

    Bypass.expect_once(bypass, "POST", "/process.Process/Update", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:resized, Jason.decode!(raw)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    # First call (baseline) => {80, 24}; subsequent calls => {100, 30} (a change).
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    size = fn ->
      n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
      if n == 0, do: {80, 24}, else: {100, 30}
    end

    {runner, ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: fn -> :eof end,
        size: size,
        poll_ms: 20,
        flush_ms: 10_000
      )

    assert_receive {:resized, %{"pty" => %{"size" => %{"cols" => 100, "rows" => 30}}}}, 500

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, _}}
  end

  test "returns {:error, _} if the handle server crashes", %{handle: handle, server: server} do
    {_runner, _ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: fn -> :eof end,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 10_000
      )

    Process.exit(server, :kill)
    assert_receive {:result, {:error, %Error{message: "terminal session terminated"}}}, 500
  end
end
