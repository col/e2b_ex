defmodule E2bEx.TagsTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, TemplateTag, Tags}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /templates/:id/tags and decodes tags" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/tags"
      Req.Test.json(conn, [%{"tag" => "v1", "buildID" => "b1", "createdAt" => "t"}])
    end)

    assert {:ok, [%TemplateTag{tag: "v1", build_id: "b1"}]} = Tags.list(client(), "tmpl_1")
  end

  test "add/3 POSTs /templates/tags with target + tags and returns the assigned tags" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/templates/tags"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"target" => "my-tmpl:latest", "tags" => ["v1", "v2"]}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"tags" => ["v1", "v2"], "buildID" => "b1"})
    end)

    assert {:ok, %{"tags" => ["v1", "v2"], "buildID" => "b1"}} =
             Tags.add(client(), "my-tmpl:latest", ["v1", "v2"])
  end

  test "delete/3 DELETEs /templates/tags with name + tags and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/templates/tags"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "my-tmpl", "tags" => ["v1"]}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Tags.delete(client(), "my-tmpl", ["v1"])
  end
end
