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

  describe "control wrappers (via Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, ctx: ctx}
    end

    test "kill/2 sends SIGKILL and returns {:ok, true} on success", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}, "signal" => "SIGNAL_SIGKILL"}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, true} = Rpc.kill(ctx, 7)
    end

    test "kill/2 returns {:ok, false} on a not_found Connect error", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"gone"}))
      end)

      assert {:ok, false} = Rpc.kill(ctx, 7)
    end

    test "send_stdin/3 base64-encodes the data into input.stdin", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) ==
                 %{"process" => %{"pid" => 7}, "input" => %{"stdin" => Base.encode64("y\n")}}

        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.send_stdin(ctx, 7, "y\n")
    end

    test "close_stdin/2 posts the selector and returns :ok", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/CloseStdin", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.close_stdin(ctx, 7)
    end

    test "list/1 returns the raw process maps", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
        body = ~s({"processes":[{"pid":7,"config":{"cmd":"sleep"}}]})
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, [%{"pid" => 7, "config" => %{"cmd" => "sleep"}}]} = Rpc.list(ctx)
    end

    test "kill/2 surfaces other failures as {:error, %Error{}}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(503, ~s({"code":"unavailable","message":"down"}))
      end)

      assert {:error, %E2bEx.Error{status: 503}} = Rpc.kill(ctx, 7)
    end

    test "send_pty_input/3 base64-encodes the data into input.pty", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) ==
                 %{"process" => %{"pid" => 7}, "input" => %{"pty" => Base.encode64("ls\r")}}

        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.send_pty_input(ctx, 7, "ls\r")
    end

    test "resize/3 posts the Update body with the pty size", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/Update", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) ==
                 %{"process" => %{"pid" => 7}, "pty" => %{"size" => %{"cols" => 120, "rows" => 40}}}

        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.resize(ctx, 7, %{cols: 120, rows: 40})
    end

    test "resize/3 surfaces a non-2xx error as {:error, %Error{}}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/Update", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"gone"}))
      end)

      assert {:error, %Error{status: 404, code: "not_found"}} = Rpc.resize(ctx, 7, %{cols: 80, rows: 24})
    end
  end
end
