defmodule E2bEx.SandboxTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Sandbox, SandboxMetric, SandboxLog, Snapshot}

  test "Sandbox.from_api/1 maps camelCase keys to struct fields" do
    api = %{
      "templateID" => "tmpl_1",
      "sandboxID" => "sb_1",
      "alias" => "base",
      "startedAt" => "2026-06-10T00:00:00Z",
      "endAt" => "2026-06-10T01:00:00Z",
      "state" => "running",
      "cpuCount" => 2,
      "memoryMB" => 512,
      "diskSizeMB" => 1024,
      "envdVersion" => "0.1.0",
      "metadata" => %{"user" => "abc"}
    }

    sb = Sandbox.from_api(api)
    assert sb.template_id == "tmpl_1"
    assert sb.sandbox_id == "sb_1"
    assert sb.state == "running"
    assert sb.cpu_count == 2
    assert sb.metadata == %{"user" => "abc"}
  end

  test "SandboxMetric.from_api/1 maps fields" do
    m = SandboxMetric.from_api(%{"timestampUnix" => 100, "cpuCount" => 2, "cpuUsedPct" => 1.5, "memUsed" => 10, "memTotal" => 20, "memCache" => 1, "diskUsed" => 5, "diskTotal" => 50})
    assert m.timestamp_unix == 100
    assert m.cpu_used_pct == 1.5
    assert m.disk_total == 50
  end

  test "SandboxLog.from_api/1 maps fields" do
    log = SandboxLog.from_api(%{"timestamp" => "2026-06-10T00:00:00Z", "message" => "hi", "level" => "info", "fields" => %{"k" => "v"}})
    assert log.message == "hi"
    assert log.level == "info"
    assert log.fields == %{"k" => "v"}
  end

  test "Snapshot.from_api/1 maps fields" do
    snap = Snapshot.from_api(%{"snapshotID" => "snap_1", "names" => ["team/snap:default"]})
    assert snap.snapshot_id == "snap_1"
    assert snap.names == ["team/snap:default"]
  end
end
