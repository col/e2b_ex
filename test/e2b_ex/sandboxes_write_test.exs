defmodule E2bEx.SandboxesWriteTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox, Snapshot, Sandboxes}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "create/2 POSTs /sandboxes with the body and decodes the sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/sandboxes"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"templateID" => "tmpl_1", "timeout" => 30}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sandboxID" => "sb_1", "templateID" => "tmpl_1"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1"}} =
             Sandboxes.create(client(), %{templateID: "tmpl_1", timeout: 30})
  end

  test "kill/2 DELETEs /sandboxes/:id and returns :ok on 204" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/sandboxes/sb_1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.kill(client(), "sb_1")
  end

  test "pause/2 POSTs /sandboxes/:id/pause and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/pause"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.pause(client(), "sb_1")
  end

  test "connect/3 POSTs /sandboxes/:id/connect with timeout and decodes the sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/connect"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"timeout" => 60}
      Req.Test.json(conn, %{"sandboxID" => "sb_1"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1"}} = Sandboxes.connect(client(), "sb_1", 60)
  end

  test "set_timeout/3 POSTs /sandboxes/:id/timeout with the timeout" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/timeout"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"timeout" => 120}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.set_timeout(client(), "sb_1", 120)
  end

  test "set_network/3 PUTs /sandboxes/:id/network with the config" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT" and conn.request_path == "/sandboxes/sb_1/network"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"allowOut" => ["8.8.8.8/32"]}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.set_network(client(), "sb_1", %{allowOut: ["8.8.8.8/32"]})
  end

  test "refresh/3 POSTs /sandboxes/:id/refreshes with optional duration" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/refreshes"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"duration" => 30}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.refresh(client(), "sb_1", duration: 30)
  end

  test "snapshot/3 POSTs /sandboxes/:id/snapshots and decodes the snapshot" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/snapshots"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"snapshotID" => "snap_1", "names" => ["n"]})
    end)

    assert {:ok, %Snapshot{snapshot_id: "snap_1"}} = Sandboxes.snapshot(client(), "sb_1", name: "n")
  end
end
