defmodule E2bEx.Envd.RpcTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Error, Sandbox}
  alias E2bEx.Envd.Rpc

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  describe "context/3" do
    test "builds base_url, headers and timeout from client/sandbox/opts" do
      {:ok, ctx} = Rpc.context(client(), sandbox(), [])
      assert ctx.base_url == "https://49983-sb_1.e2b.app"
      assert ctx.sandbox_id == "sb_1"
      assert ctx.headers["e2b-sandbox-id"] == "sb_1"
      assert ctx.headers["x-access-token"] == "tok_1"
      assert ctx.timeout_ms == 60_000
    end

    test "honours :base_url, :port and :domain overrides" do
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:1234")
      assert ctx.base_url == "http://localhost:1234"
      {:ok, ctx} = Rpc.context(client(), %Sandbox{sandbox_id: "s", domain: nil}, port: 9, domain: "x.io")
      assert ctx.base_url == "https://9-s.x.io"
    end

    test "errors when the sandbox is missing its id" do
      assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
               Rpc.context(client(), %Sandbox{sandbox_id: nil}, [])
    end
  end

  describe "unary/4 (via Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, ctx: ctx}
    end

    test "posts bare JSON with envd headers and returns the decoded body", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-access-token") == ["tok_1"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, ~s({"processes":[]}))
      end)

      assert {:ok, %{"processes" => []}} = Rpc.unary(ctx, "/process.Process/List", %{})
    end

    test "does not leak streaming-only headers onto a unary call", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
        assert Plug.Conn.get_req_header(conn, "keepalive-ping-interval") == []
        assert Plug.Conn.get_req_header(conn, "connect-timeout-ms") == []
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, %{}} = Rpc.unary(ctx, "/process.Process/List", %{})
    end

    test "maps a non-2xx Connect error body to %Error{}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"no such process"}))
      end)

      assert {:error, %Error{status: 404, code: "not_found", message: "no such process"}} =
               Rpc.unary(ctx, "/process.Process/SendSignal", %{process: %{pid: 9}})
    end
  end
end
