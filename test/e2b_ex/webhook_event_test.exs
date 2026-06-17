defmodule E2bEx.WebhookEventTest do
  use ExUnit.Case, async: true
  alias E2bEx.WebhookEvent

  test "from_api/1 decodes the snake_case payload and keeps event_data as a raw map" do
    payload = %{
      "id" => "evt_1",
      "version" => "v2",
      "type" => "sandbox.lifecycle.paused",
      "timestamp" => "2026-06-17T00:00:00Z",
      "event_category" => "lifecycle",
      "event_label" => "paused",
      "event_data" => %{
        "sandbox_metadata" => %{"custom" => "value"},
        "execution" => %{"vcpu_count" => 2, "memory_mb" => 512}
      },
      "sandbox_id" => "sb_1",
      "sandbox_execution_id" => "exec_1",
      "sandbox_template_id" => "tpl_1",
      "sandbox_build_id" => "build_1",
      "sandbox_team_id" => "team_1"
    }

    assert %WebhookEvent{
             id: "evt_1",
             version: "v2",
             type: "sandbox.lifecycle.paused",
             timestamp: "2026-06-17T00:00:00Z",
             event_category: "lifecycle",
             event_label: "paused",
             event_data: %{"execution" => %{"vcpu_count" => 2}},
             sandbox_id: "sb_1",
             sandbox_execution_id: "exec_1",
             sandbox_template_id: "tpl_1",
             sandbox_build_id: "build_1",
             sandbox_team_id: "team_1"
           } = WebhookEvent.from_api(payload)
  end
end
