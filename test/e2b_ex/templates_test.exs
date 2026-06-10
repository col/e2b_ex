defmodule E2bEx.TemplatesTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Template, TemplateAlias, Templates}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /templates with optional team filter and decodes a list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates"
      assert conn.query_string =~ "teamID=team_1"
      Req.Test.json(conn, [%{"templateID" => "tmpl_1"}])
    end)

    assert {:ok, [%Template{template_id: "tmpl_1"}]} = Templates.list(client(), team_id: "team_1")
  end

  test "create/2 POSTs /v3/templates and returns the raw response map" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/v3/templates"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "my-tmpl"}
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"templateID" => "tmpl_1", "buildID" => "b1"})
    end)

    assert {:ok, %{"templateID" => "tmpl_1", "buildID" => "b1"}} =
             Templates.create(client(), %{name: "my-tmpl"})
  end

  test "get/2 GETs /templates/:id and decodes with builds" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1"
      Req.Test.json(conn, %{"templateID" => "tmpl_1", "builds" => [%{"buildID" => "b1", "status" => "ready"}]})
    end)

    assert {:ok, %Template{template_id: "tmpl_1", builds: [%{build_id: "b1"}]}} =
             Templates.get(client(), "tmpl_1")
  end

  test "delete/2 DELETEs /templates/:id and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/templates/tmpl_1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Templates.delete(client(), "tmpl_1")
  end

  test "update/3 PATCHes /v2/templates/:id with the body" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PATCH" and conn.request_path == "/v2/templates/tmpl_1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"public" => true}
      Req.Test.json(conn, %{"names" => ["team/base"]})
    end)

    assert {:ok, %{"names" => ["team/base"]}} = Templates.update(client(), "tmpl_1", %{public: true})
  end

  test "get_by_alias/2 GETs /templates/aliases/:alias and decodes" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/aliases/base"
      Req.Test.json(conn, %{"templateID" => "tmpl_1", "public" => true})
    end)

    assert {:ok, %TemplateAlias{template_id: "tmpl_1", public: true}} =
             Templates.get_by_alias(client(), "base")
  end

  test "file_exists?/3 returns {:ok, true} on 2xx" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/files/abc123"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, true} = Templates.file_exists?(client(), "tmpl_1", "abc123")
  end

  test "file_exists?/3 returns {:ok, false} on 404" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "no"})
    end)

    assert {:ok, false} = Templates.file_exists?(client(), "tmpl_1", "missing")
  end
end
