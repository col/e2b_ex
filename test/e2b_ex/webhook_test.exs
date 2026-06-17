defmodule E2bEx.WebhookTest do
  use ExUnit.Case, async: true
  alias E2bEx.Webhook

  test "from_api/1 decodes camelCase keys and ignores signatureSecret" do
    api = %{
      "id" => "wh_1",
      "teamId" => "team_1",
      "name" => "my-hook",
      "createdAt" => "2026-06-17T00:00:00Z",
      "enabled" => true,
      "url" => "https://example.com/hook",
      "events" => ["sandbox.lifecycle.created"],
      "signatureSecret" => "whsec_should_be_ignored"
    }

    assert %Webhook{
             id: "wh_1",
             team_id: "team_1",
             name: "my-hook",
             created_at: "2026-06-17T00:00:00Z",
             enabled: true,
             url: "https://example.com/hook",
             events: ["sandbox.lifecycle.created"]
           } = Webhook.from_api(api)

    refute Map.has_key?(Webhook.from_api(api), :signature_secret)
  end
end
