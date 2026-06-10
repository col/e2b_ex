defmodule E2bEx.SandboxesReadTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox, SandboxMetric, SandboxLog, Sandboxes}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /v2/sandboxes and decodes a list, passing filters" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/sandboxes"
      assert conn.query_string =~ "metadata=user%3Dabc"
      Req.Test.json(conn, [%{"sandboxID" => "sb_1"}, %{"sandboxID" => "sb_2"}])
    end)

    assert {:ok, [%Sandbox{sandbox_id: "sb_1"}, %Sandbox{sandbox_id: "sb_2"}]} =
             Sandboxes.list(client(), metadata: "user=abc")
  end

  test "list/2 encodes list-valued :state as a comma-joined query param" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string =~ "state=running%2Cpaused"
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Sandboxes.list(client(), state: ["running", "paused"])
  end

  test "get/2 GETs /sandboxes/:id and decodes one sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1"
      Req.Test.json(conn, %{"sandboxID" => "sb_1", "state" => "running"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1", state: "running"}} = Sandboxes.get(client(), "sb_1")
  end

  test "metrics/3 GETs /sandboxes/:id/metrics and decodes a metric list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/metrics"
      Req.Test.json(conn, [%{"timestampUnix" => 100, "cpuCount" => 2, "cpuUsedPct" => 1.0, "memUsed" => 1, "memTotal" => 2, "memCache" => 0, "diskUsed" => 1, "diskTotal" => 2}])
    end)

    assert {:ok, [%SandboxMetric{timestamp_unix: 100}]} = Sandboxes.metrics(client(), "sb_1")
  end

  test "list_metrics/2 GETs /sandboxes/metrics and decodes the sandboxes map" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/metrics"
      assert conn.query_string =~ "sandbox_ids=sb_1"
      Req.Test.json(conn, %{"sandboxes" => %{"sb_1" => %{"timestampUnix" => 1, "cpuCount" => 1, "cpuUsedPct" => 0.0, "memUsed" => 0, "memTotal" => 0, "memCache" => 0, "diskUsed" => 0, "diskTotal" => 0}}})
    end)

    assert {:ok, %{"sb_1" => %SandboxMetric{timestamp_unix: 1}}} =
             Sandboxes.list_metrics(client(), ["sb_1"])
  end

  test "logs/3 GETs /v2/sandboxes/:id/logs and decodes log entries" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/sandboxes/sb_1/logs"
      Req.Test.json(conn, %{"logs" => [%{"timestamp" => "t", "message" => "hi", "level" => "info", "fields" => %{}}]})
    end)

    assert {:ok, [%SandboxLog{message: "hi"}]} = Sandboxes.logs(client(), "sb_1")
  end

  test "list_snapshots/2 GETs /snapshots and decodes SnapshotInfo" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/snapshots"
      Req.Test.json(conn, [%{"snapshotID" => "snap_1", "names" => ["team/snap:default"]}])
    end)

    assert {:ok, [%E2bEx.Snapshot{snapshot_id: "snap_1"}]} = Sandboxes.list_snapshots(client())
  end
end
