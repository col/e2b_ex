defmodule E2bEx.CommandsTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandResult, Commands, Error, Sandbox}
  alias E2bEx.Envd.Connect

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "run/4 posts a wrapped command and folds stdout/exit code", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-access-token") == ["tok_1"]
      assert Plug.Conn.get_req_header(conn, "connect-protocol-version") == ["1"]
      assert Plug.Conn.get_req_header(conn, "e2b-sandbox-id") == ["sb_1"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/connect+json"]

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) ==
               %{"process" => %{"cmd" => "/bin/bash", "args" => ["-l", "-c", "echo hi"]}, "stdin" => false}

      body =
        frame(%{"event" => %{"start" => %{"pid" => 7}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("hi\n")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, %CommandResult{stdout: "hi\n", stderr: "", exit_code: 0, error: nil}} =
             Commands.run(client(), sandbox(), "echo hi", base_url: base_url)
  end

  test "run/4 sends cwd, envs, and a Basic auth header for :user", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("root:")]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw

      assert Jason.decode!(json) == %{
               "process" => %{
                 "cmd" => "/bin/bash",
                 "args" => ["-l", "-c", "ls"],
                 "cwd" => "/tmp",
                 "envs" => %{"FOO" => "bar"}
               },
               "stdin" => false
             }

      Plug.Conn.resp(conn, 200, frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    assert {:ok, %CommandResult{}} =
             Commands.run(client(), sandbox(), "ls",
               cwd: "/tmp",
               envs: %{"FOO" => "bar"},
               user: "root",
               base_url: base_url
             )
  end

  test "run/4 returns a non-zero exit code with stderr (still {:ok, _})", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      body =
        frame(%{"event" => %{"data" => %{"stderr" => Base.encode64("boom\n")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 2}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, %CommandResult{exit_code: 2, stderr: "boom\n"}} =
             Commands.run(client(), sandbox(), "false", base_url: base_url)
  end

  test "run/4 maps a Connect error trailer to {:error, %Error{}}", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200, trailer(~s({"error":{"code":"unavailable","message":"sandbox gone"}})))
    end)

    assert {:error, %Error{message: "sandbox gone", reason: "unavailable"}} =
             Commands.run(client(), sandbox(), "echo hi", base_url: base_url)
  end

  test "run/4 maps a transport error to {:error, %Error{}}", %{bypass: bypass, base_url: base_url} do
    Bypass.down(bypass)
    assert {:error, %Error{} = error} = Commands.run(client(), sandbox(), "echo hi", base_url: base_url)
    assert error.reason != nil
  end

  test "run/4 omits x-access-token when the sandbox has none", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-access-token") == []
      Plug.Conn.resp(conn, 200, frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    sb = %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: nil}
    assert {:ok, %CommandResult{}} = Commands.run(client(), sb, "echo hi", base_url: base_url)
  end

  test "run/4 errors when the sandbox is missing its id" do
    assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
             Commands.run(client(), %Sandbox{sandbox_id: nil}, "echo hi")
  end

  test "run/4 returns an error when a data chunk is not valid base64", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      body = frame(%{"event" => %{"data" => %{"stdout" => "!!! not base64 !!!"}}}) <> trailer("{}")
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:error, %Error{message: "malformed envd response"}} =
             Commands.run(client(), sandbox(), "echo hi", base_url: base_url)
  end

  test "run/4 maps a non-2xx envd response to {:error, %Error{}}", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 503, "unavailable")
    end)

    assert {:error, %Error{status: 503}} = Commands.run(client(), sandbox(), "echo hi", base_url: base_url)
  end
end
