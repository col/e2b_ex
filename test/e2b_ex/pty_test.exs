defmodule E2bEx.PtyTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox}
  alias E2bEx.Envd.Connect
  alias E2bEx.Pty

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "create/3 launches bash -i -l, streams pty output, then a terminal exit",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      req = Jason.decode!(json)
      assert req["process"]["cmd"] == "/bin/bash"
      assert req["process"]["args"] == ["-i", "-l"]
      assert req["pty"]["size"] == %{"cols" => 100, "rows" => 30}
      # default terminal envs merged in
      assert req["process"]["envs"]["TERM"] == "xterm-256color"
      assert req["process"]["envs"]["LANG"] == "C.UTF-8"
      assert req["process"]["envs"]["LC_ALL"] == "C.UTF-8"

      body =
        frame(%{"event" => %{"start" => %{"pid" => 11}}}) <>
          frame(%{"event" => %{"data" => %{"pty" => Base.encode64("$ ")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 0}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Pty.create(client(), sandbox(), cols: 100, rows: 30, base_url: base_url)
    assert Pty.Handle.pid(handle) == 11
    ref = handle.ref
    assert_receive {^ref, {:pty, "$ "}}
    assert_receive {^ref, {:exit, %E2bEx.CommandResult{exit_code: 0}}}
  end

  test "create/3 lets caller envs override the terminal defaults",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      req = Jason.decode!(json)
      assert req["process"]["envs"]["TERM"] == "dumb"
      assert req["process"]["envs"]["FOO"] == "bar"

      Plug.Conn.resp(conn, 200,
        frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    {:ok, _handle} =
      Pty.create(client(), sandbox(),
        cols: 80, rows: 24, envs: %{"TERM" => "dumb", "FOO" => "bar"}, base_url: base_url)
  end

  test "create/3 raises ArgumentError without :cols/:rows" do
    assert_raise ArgumentError, fn -> Pty.create(client(), sandbox(), rows: 24) end
    assert_raise ArgumentError, fn -> Pty.create(client(), sandbox(), cols: 80) end
  end

  test "connect/4 reattaches to a running pid and streams pty output",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Connect", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"process" => %{"pid" => 42}}

      body =
        frame(%{"event" => %{"start" => %{"pid" => 42}}}) <>
          frame(%{"event" => %{"data" => %{"pty" => Base.encode64("back")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Pty.connect(client(), sandbox(), 42, base_url: base_url)
    assert Pty.Handle.pid(handle) == 42
    ref = handle.ref
    assert_receive {^ref, {:pty, "back"}}
  end
end
