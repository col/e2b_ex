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

  @secret "whsec_test"
  @raw_body ~s({"id":"evt_1","type":"sandbox.lifecycle.created"})
  # base64(sha256(@secret <> @raw_body)) with trailing "=" stripped
  @valid_sig "27bqPwMn89eQHee+y+wgyqHiUT+q2+gwTpYEwPvUetc"

  test "verify_signature/3 returns true for a correct signature" do
    assert WebhookEvent.verify_signature(@raw_body, @valid_sig, @secret)
  end

  test "verify_signature/3 returns false for a tampered body" do
    refute WebhookEvent.verify_signature(@raw_body <> " ", @valid_sig, @secret)
  end

  test "verify_signature/3 returns false for the wrong secret" do
    refute WebhookEvent.verify_signature(@raw_body, @valid_sig, "whsec_wrong")
  end

  test "verify_signature/3 returns false for a length-mismatched signature" do
    refute WebhookEvent.verify_signature(@raw_body, "short", @secret)
  end

  test "parse/3 returns {:ok, event} for a valid signature and JSON body" do
    assert {:ok, %WebhookEvent{id: "evt_1", type: "sandbox.lifecycle.created"}} =
             WebhookEvent.parse(@raw_body, @valid_sig, @secret)
  end

  test "parse/3 returns {:error, :invalid_signature} for a bad signature" do
    assert {:error, :invalid_signature} = WebhookEvent.parse(@raw_body, "bad", @secret)
  end

  test "parse/3 returns {:error, :invalid_payload} for a valid signature over non-JSON" do
    body = "not json"
    sig = :crypto.hash(:sha256, @secret <> body) |> Base.encode64() |> String.trim_trailing("=")
    assert {:error, :invalid_payload} = WebhookEvent.parse(body, sig, @secret)
  end
end
