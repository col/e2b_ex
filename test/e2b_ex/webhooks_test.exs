defmodule E2bEx.WebhooksTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Webhook, Webhooks}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  defp webhook_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "wh_1",
        "teamId" => "team_1",
        "name" => "my-hook",
        "createdAt" => "2026-06-17T00:00:00Z",
        "enabled" => true,
        "url" => "https://example.com/hook",
        "events" => ["sandbox.lifecycle.created"]
      },
      overrides
    )
  end

  test "list/1 GETs /events/webhooks and decodes webhooks" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/events/webhooks"
      Req.Test.json(conn, [webhook_json()])
    end)

    assert {:ok, [%Webhook{id: "wh_1", name: "my-hook"}]} = Webhooks.list(client())
  end

  test "create/2 POSTs the attrs map and decodes the returned webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/events/webhooks"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "name" => "my-hook",
               "url" => "https://example.com/hook",
               "enabled" => true,
               "events" => ["sandbox.lifecycle.created"],
               "signatureSecret" => "whsec_x"
             }

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(webhook_json())
    end)

    attrs = %{
      name: "my-hook",
      url: "https://example.com/hook",
      enabled: true,
      events: ["sandbox.lifecycle.created"],
      signatureSecret: "whsec_x"
    }

    assert {:ok, %Webhook{id: "wh_1", enabled: true}} = Webhooks.create(client(), attrs)
  end

  test "get/2 GETs /events/webhooks/:id and decodes the webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/events/webhooks/wh_1"
      Req.Test.json(conn, webhook_json())
    end)

    assert {:ok, %Webhook{id: "wh_1", team_id: "team_1"}} = Webhooks.get(client(), "wh_1")
  end

  test "update/3 PATCHes the partial attrs map and decodes the returned webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PATCH" and conn.request_path == "/events/webhooks/wh_1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"enabled" => false}

      Req.Test.json(conn, webhook_json(%{"enabled" => false}))
    end)

    assert {:ok, %Webhook{id: "wh_1", enabled: false}} =
             Webhooks.update(client(), "wh_1", %{enabled: false})
  end

  test "delete/2 DELETEs /events/webhooks/:id and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/events/webhooks/wh_1"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = Webhooks.delete(client(), "wh_1")
  end

  test "surfaces a non-2xx response as {:error, %Error{}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "not found"})
    end)

    assert {:error, %E2bEx.Error{status: 404}} = Webhooks.get(client(), "missing")
  end
end
