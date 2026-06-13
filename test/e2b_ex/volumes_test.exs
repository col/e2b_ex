defmodule E2bEx.VolumesTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Volume, Volumes}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/1 GETs /volumes and decodes volumes (no token)" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/volumes"
      Req.Test.json(conn, [%{"volumeID" => "v1", "name" => "data"}])
    end)

    assert {:ok, [%Volume{volume_id: "v1", name: "data", token: nil}]} = Volumes.list(client())
  end

  test "create/2 POSTs /volumes with the name and decodes the returned token" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/volumes"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "data"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"volumeID" => "v1", "name" => "data", "token" => "tok"})
    end)

    assert {:ok, %Volume{volume_id: "v1", name: "data", token: "tok"}} = Volumes.create(client(), "data")
  end

  test "get/2 GETs /volumes/:id and decodes the token" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/volumes/v1"
      Req.Test.json(conn, %{"volumeID" => "v1", "name" => "data", "token" => "tok"})
    end)

    assert {:ok, %Volume{volume_id: "v1", token: "tok"}} = Volumes.get(client(), "v1")
  end

  test "delete/2 DELETEs /volumes/:id and returns :ok on 204" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/volumes/v1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Volumes.delete(client(), "v1")
  end

  test "surfaces a non-2xx response as {:error, %Error{}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "not found"})
    end)

    assert {:error, %E2bEx.Error{status: 404}} = Volumes.get(client(), "missing")
  end
end
