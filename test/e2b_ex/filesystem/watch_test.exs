defmodule E2bEx.Filesystem.WatchTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, EntryInfo, Error, Filesystem, FilesystemEvent, Sandbox}
  alias E2bEx.Envd.Connect

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp chunk_bytes(bin, n) when byte_size(bin) > n do
    <<part::binary-size(n), rest::binary>> = bin
    [part | chunk_bytes(rest, n)]
  end

  defp chunk_bytes(bin, _n), do: [bin]

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "watch_dir/4 sends the request, returns a handle on start, and streams events",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"path" => "/d", "recursive" => true, "includeEntry" => true}

      body =
        frame(%{"start" => %{}}) <>
          frame(%{
            "filesystem" => %{
              "name" => "/d/a.txt",
              "type" => "EVENT_TYPE_CREATE",
              "entry" => %{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt"}
            }
          }) <>
          frame(%{"keepalive" => %{}}) <>
          frame(%{"filesystem" => %{"name" => "/d/a.txt", "type" => "EVENT_TYPE_WRITE"}}) <>
          trailer("{}")

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunk_bytes(body, 7), conn, fn part, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, part)
        conn
      end)
    end)

    {:ok, handle} =
      Filesystem.watch_dir(client(), sandbox(), "/d",
        recursive: true,
        include_entry: true,
        base_url: base_url
      )

    ref = handle.ref

    assert_receive {^ref,
                    {:fs_event,
                     %FilesystemEvent{
                       name: "/d/a.txt",
                       type: :create,
                       entry: %EntryInfo{name: "a.txt", type: :file}
                     }}}

    refute_receive {^ref, {:fs_event, %FilesystemEvent{type: nil}}}, 0
    assert_receive {^ref, {:fs_event, %FilesystemEvent{name: "/d/a.txt", type: :write, entry: nil}}}
    # a clean close ends the watch with a terminal error (watch has no result)
    assert_receive {^ref, {:error, %Error{message: "watch stream closed"}}}
  end

  test "watch_dir/4 defaults recursive/include_entry to false", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"path" => "/d", "recursive" => false, "includeEntry" => false}
      Plug.Conn.resp(conn, 200, frame(%{"start" => %{}}) <> trailer("{}"))
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    assert_receive {_ref, {:error, %Error{message: "watch stream closed"}}}
    assert is_reference(handle.ref)
  end

  test "watch_dir/4 returns {:error, _} on a non-2xx before the start event",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"code":"unauthenticated","message":"no token"}))
    end)

    assert {:error, %Error{}} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
  end

  test "a Connect trailer error mid-stream is delivered as a terminal {:error}",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      body =
        frame(%{"start" => %{}}) <>
          trailer(~s({"error":{"code":"unavailable","message":"gone"}}))

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    ref = handle.ref
    assert_receive {^ref, {:error, %Error{message: "gone", reason: "unavailable"}}}
  end

  test "stop/1 ends the watch and sends no terminal message", %{bypass: bypass, base_url: base_url} do
    Bypass.expect(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      # Stream only a start event, then keepalives, so the watch stays open. Trap
      # exits so cancelling the request (cowboy :shutdown EXIT) is caught and the
      # handler exits cleanly — same pattern as the commands disconnect test.
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(%{"start" => %{}}))

      Enum.reduce_while(1..200, conn, fn _, conn ->
        receive do
          {:EXIT, _, _} -> {:halt, conn}
        after
          10 ->
            case Plug.Conn.chunk(conn, frame(%{"keepalive" => %{}})) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
        end
      end)
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    ref = handle.ref
    server = handle.server
    assert :ok = E2bEx.Filesystem.WatchHandle.stop(handle)
    refute Process.alive?(server)
    refute_receive {^ref, {:error, _}}, 50
    refute_receive {^ref, {:fs_event, _}}, 50
  end
end
