defmodule E2bEx.FilesystemTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, EntryInfo, Error, Filesystem, Sandbox}

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp respond_json(conn, status, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(map))
  end

  test "list/4 ListDir sends path+depth and decodes entries", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d", "depth" => 1}

      respond_json(conn, 200, %{
        "entries" => [%{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt", "size" => 3}]
      })
    end)

    assert {:ok, [%EntryInfo{name: "a.txt", type: :file, path: "/d/a.txt", size: 3}]} =
             Filesystem.list(client(), sandbox(), "/d", base_url: base_url)
  end

  test "list/4 returns [] for an empty dir (no entries key)", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      respond_json(conn, 200, %{})
    end)

    assert {:ok, []} = Filesystem.list(client(), sandbox(), "/empty", base_url: base_url)
  end

  test "list/4 honours an explicit :depth", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d", "depth" => 3}
      respond_json(conn, 200, %{"entries" => []})
    end)

    assert {:ok, []} = Filesystem.list(client(), sandbox(), "/d", depth: 3, base_url: base_url)
  end

  test "get_info/4 Stat decodes a directory entry incl. timestamp + symlink",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d"}

      respond_json(conn, 200, %{
        "entry" => %{
          "name" => "d",
          "type" => "FILE_TYPE_DIRECTORY",
          "path" => "/d",
          "modifiedTime" => "2024-01-02T03:04:05Z",
          "symlinkTarget" => "/x"
        }
      })
    end)

    assert {:ok, %EntryInfo{type: :dir, modified_time: "2024-01-02T03:04:05Z", symlink_target: "/x"}} =
             Filesystem.get_info(client(), sandbox(), "/d", base_url: base_url)
  end

  test "exists/4 is true when Stat succeeds", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 200, %{"entry" => %{"name" => "a", "type" => "FILE_TYPE_FILE", "path" => "/a"}})
    end)

    assert {:ok, true} = Filesystem.exists(client(), sandbox(), "/a", base_url: base_url)
  end

  test "exists/4 is false on a not_found error", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 404, %{"code" => "not_found", "message" => "missing"})
    end)

    assert {:ok, false} = Filesystem.exists(client(), sandbox(), "/missing", base_url: base_url)
  end

  test "make_dir/4 is true on success", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/MakeDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d/new"}
      respond_json(conn, 200, %{"entry" => %{"name" => "new", "type" => "FILE_TYPE_DIRECTORY", "path" => "/d/new"}})
    end)

    assert {:ok, true} = Filesystem.make_dir(client(), sandbox(), "/d/new", base_url: base_url)
  end

  test "make_dir/4 is false when the directory already exists", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/MakeDir", fn conn ->
      respond_json(conn, 409, %{"code" => "already_exists", "message" => "exists"})
    end)

    assert {:ok, false} = Filesystem.make_dir(client(), sandbox(), "/d/old", base_url: base_url)
  end

  test "rename/5 Move sends source+destination and decodes the entry",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Move", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"source" => "/a.txt", "destination" => "/b.txt"}
      respond_json(conn, 200, %{"entry" => %{"name" => "b.txt", "type" => "FILE_TYPE_FILE", "path" => "/b.txt"}})
    end)

    assert {:ok, %EntryInfo{name: "b.txt", path: "/b.txt"}} =
             Filesystem.rename(client(), sandbox(), "/a.txt", "/b.txt", base_url: base_url)
  end

  test "remove/4 Remove returns :ok", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Remove", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/a.txt"}
      respond_json(conn, 200, %{})
    end)

    assert :ok = Filesystem.remove(client(), sandbox(), "/a.txt", base_url: base_url)
  end

  test "get_info/4 propagates a non-2xx as {:error, %Error{}}", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 500, %{"code" => "internal", "message" => "boom"})
    end)

    assert {:error, %Error{status: 500}} = Filesystem.get_info(client(), sandbox(), "/x", base_url: base_url)
  end
end
