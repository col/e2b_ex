defmodule E2bEx.TemplatesBuildTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Templates}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "trigger_build/4 POSTs /v2/templates/:id/builds/:build with the body and returns :ok on 202" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/v2/templates/tmpl_1/builds/b1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"fromImage" => "ubuntu:22.04"}
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = Templates.trigger_build(client(), "tmpl_1", "b1", %{fromImage: "ubuntu:22.04"})
  end

  test "build_status/4 GETs the status endpoint and forwards options under the correct keys" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/builds/b1/status"
      assert conn.query_string =~ "logsOffset=10"
      assert conn.query_string =~ "limit=5"
      assert conn.query_string =~ "level=error"
      Req.Test.json(conn, %{"status" => "building", "logs" => ["a"]})
    end)

    assert {:ok, %{"status" => "building", "logs" => ["a"]}} =
             Templates.build_status(client(), "tmpl_1", "b1", logs_offset: 10, logs_limit: 5, level: "error")
  end

  test "build_logs/4 GETs the logs endpoint, forwards options, and returns the logs list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/builds/b1/logs"
      assert conn.query_string =~ "cursor=100"
      assert conn.query_string =~ "limit=5"
      assert conn.query_string =~ "direction=backward"
      Req.Test.json(conn, %{"logs" => [%{"timestamp" => "t", "message" => "m", "level" => "info"}]})
    end)

    assert {:ok, [%{"message" => "m"}]} =
             Templates.build_logs(client(), "tmpl_1", "b1", cursor: 100, limit: 5, direction: "backward")
  end
end
