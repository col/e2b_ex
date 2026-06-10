defmodule E2bEx.RequestTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Error, Request}

  defp client do
    Client.new(api_key: "key_123", req_options: [plug: {Req.Test, __MODULE__}])
  end

  test "request/4 returns {:ok, body} on 2xx and sends the api key + path" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["key_123"]
      Req.Test.json(conn, %{"sandboxID" => "sb_1"})
    end)

    assert {:ok, %{"sandboxID" => "sb_1"}} = Request.request(client(), :get, "/sandboxes/sb_1")
  end

  test "request/4 sends query params and json body" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "metadata=user%3Dabc"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"templateID" => "tmpl_1"}
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, _} =
             Request.request(client(), :post, "/sandboxes",
               params: [metadata: "user=abc"],
               json: %{templateID: "tmpl_1"}
             )
  end

  test "request/4 returns :ok-shaped nil body for empty 204" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert {:ok, nil} = Request.request(client(), :delete, "/sandboxes/sb_1")
  end

  test "request/4 maps non-2xx to %Error{}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "nope"})
    end)

    assert {:error, %Error{status: 404, code: 404, message: "nope"}} =
             Request.request(client(), :get, "/sandboxes/missing")
  end

  test "request/4 maps transport errors to %Error{}" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Error{reason: :timeout}} = Request.request(client(), :get, "/sandboxes")
  end
end
