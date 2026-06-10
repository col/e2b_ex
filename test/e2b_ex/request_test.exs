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

  describe "build_options/3 (Content-Length for bodyless writes)" do
    # E2B runs behind a GCP frontend that rejects bodyless POSTs with
    # `411 Length Required`. Finch only emits a Content-Length header when the
    # request body is a binary (not nil), so write requests with no JSON body
    # must carry an empty-string body to force `Content-Length: 0`.
    # (Req.Test bypasses Finch's transport layer, so this is verified at the
    # options-construction layer rather than via a stubbed request.)

    test "POST without a json body gets an empty-string body" do
      opts = Request.build_options(:post, "/sandboxes/sb_1/pause", [])
      assert Keyword.get(opts, :body) == ""
    end

    test "PUT and PATCH without a json body get an empty-string body" do
      assert Request.build_options(:put, "/x", []) |> Keyword.get(:body) == ""
      assert Request.build_options(:patch, "/x", []) |> Keyword.get(:body) == ""
    end

    test "a write request with a json body does not also set :body" do
      opts = Request.build_options(:post, "/sandboxes", json: %{templateID: "t"})
      assert Keyword.get(opts, :body) == nil
      assert Keyword.get(opts, :json) == %{templateID: "t"}
    end

    test "GET and DELETE without a body do not set :body" do
      assert Request.build_options(:get, "/sandboxes", []) |> Keyword.get(:body) == nil
      assert Request.build_options(:delete, "/sandboxes/sb_1", []) |> Keyword.get(:body) == nil
    end
  end
end
