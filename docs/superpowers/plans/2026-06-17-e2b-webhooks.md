# E2bEx Webhooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add E2B lifecycle-event webhook support to `E2bEx` — outbound CRUD management of `/events/webhooks`, plus inbound signature verification and event-payload decoding.

**Architecture:** The management API reuses the existing central-API transport (`E2bEx.Request.request/4`, `x-api-key`) and mirrors `E2bEx.Volumes` (a `Webhook` struct + a `Webhooks` resource module). The inbound side is a pure, HTTP-free module `E2bEx.WebhookEvent` that decodes the snake_case delivery payload and verifies its signature (plain SHA256 of `secret <> raw_body`, base64, trailing `=` stripped).

**Tech Stack:** Elixir ~> 1.18, `Req ~> 0.5` (brings `Jason`), `:crypto`/`Base` from OTP, `Req.Test` for tests.

## Global Constraints

- `mix compile --warnings-as-errors` must stay clean.
- Read calls return `{:ok, struct | [struct]}`; void/lifecycle calls return `:ok`; central-API failures return `{:error, %E2bEx.Error{}}`.
- Central-API resources are tested with `Req.Test` (`req_options: [plug: {Req.Test, Mod}]`). The inbound module is pure — no HTTP harness.
- Webhook endpoints are NOT in `openapi.yml`; the source of truth is https://e2b.dev/docs/sandbox/lifecycle-events-webhooks.
- Spec: `docs/superpowers/specs/2026-06-17-e2b-webhooks-design.md`.
- Each struct decodes via a `@doc false` `from_api/1`. Timestamps stay strings (no `DateTime` parsing). Nested objects stay raw maps.

---

### Task 1: `E2bEx.Webhook` struct

**Files:**
- Create: `lib/e2b_ex/webhook.ex`
- Test: `test/e2b_ex/webhook_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `E2bEx.Webhook` struct with keys `:id, :team_id, :name, :created_at, :enabled, :url, :events`; `E2bEx.Webhook.from_api(map()) :: t()` decoding camelCase API keys (`id`, `teamId`, `name`, `createdAt`, `enabled`, `url`, `events`). `signatureSecret` is never decoded.

- [ ] **Step 1: Write the failing test**

```elixir
# test/e2b_ex/webhook_test.exs
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/webhook_test.exs`
Expected: FAIL — `E2bEx.Webhook.__struct__/0 is undefined` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/e2b_ex/webhook.ex
defmodule E2bEx.Webhook do
  @moduledoc "A registered webhook, decoded from create/get/list/update responses."

  @type t :: %__MODULE__{
          id: String.t() | nil,
          team_id: String.t() | nil,
          name: String.t() | nil,
          created_at: String.t() | nil,
          enabled: boolean() | nil,
          url: String.t() | nil,
          events: [String.t()] | nil
        }

  defstruct [:id, :team_id, :name, :created_at, :enabled, :url, :events]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      id: m["id"],
      team_id: m["teamId"],
      name: m["name"],
      created_at: m["createdAt"],
      enabled: m["enabled"],
      url: m["url"],
      events: m["events"]
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/webhook_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/webhook.ex test/e2b_ex/webhook_test.exs
git commit -m "feat(webhooks): add E2bEx.Webhook struct"
```

---

### Task 2: `E2bEx.Webhooks` CRUD resource

**Files:**
- Create: `lib/e2b_ex/webhooks.ex`
- Test: `test/e2b_ex/webhooks_test.exs`

**Interfaces:**
- Consumes: `E2bEx.Webhook.from_api/1` (Task 1); `E2bEx.Request.request/4`; `E2bEx.Client.new/1`.
- Produces: `E2bEx.Webhooks.list(client) :: {:ok, [Webhook.t()]} | {:error, Error.t()}`; `create(client, map) :: {:ok, Webhook.t()} | {:error, Error.t()}`; `get(client, id) :: {:ok, Webhook.t()} | {:error, Error.t()}`; `update(client, id, map) :: {:ok, Webhook.t()} | {:error, Error.t()}`; `delete(client, id) :: :ok | {:error, Error.t()}`. Base path `/events/webhooks`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/e2b_ex/webhooks_test.exs
defmodule E2bEx.WebhooksTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Webhook, Webhooks}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  defp webhook_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "wh_1",
        "teamId" => "team_1",
        "name" => "my-hook",
        "createdAt" => "2026-06-17T00:00:00Z",
        "enabled" => true,
        "url" => "https://example.com/hook",
        "events" => ["sandbox.lifecycle.created"]
      },
      overrides
    )
  end

  test "list/1 GETs /events/webhooks and decodes webhooks" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/events/webhooks"
      Req.Test.json(conn, [webhook_json()])
    end)

    assert {:ok, [%Webhook{id: "wh_1", name: "my-hook"}]} = Webhooks.list(client())
  end

  test "create/2 POSTs the attrs map and decodes the returned webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/events/webhooks"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "name" => "my-hook",
               "url" => "https://example.com/hook",
               "enabled" => true,
               "events" => ["sandbox.lifecycle.created"],
               "signatureSecret" => "whsec_x"
             }

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(webhook_json())
    end)

    attrs = %{
      name: "my-hook",
      url: "https://example.com/hook",
      enabled: true,
      events: ["sandbox.lifecycle.created"],
      signatureSecret: "whsec_x"
    }

    assert {:ok, %Webhook{id: "wh_1", enabled: true}} = Webhooks.create(client(), attrs)
  end

  test "get/2 GETs /events/webhooks/:id and decodes the webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/events/webhooks/wh_1"
      Req.Test.json(conn, webhook_json())
    end)

    assert {:ok, %Webhook{id: "wh_1", team_id: "team_1"}} = Webhooks.get(client(), "wh_1")
  end

  test "update/3 PATCHes the partial attrs map and decodes the returned webhook" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PATCH" and conn.request_path == "/events/webhooks/wh_1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"enabled" => false}

      Req.Test.json(conn, webhook_json(%{"enabled" => false}))
    end)

    assert {:ok, %Webhook{id: "wh_1", enabled: false}} =
             Webhooks.update(client(), "wh_1", %{enabled: false})
  end

  test "delete/2 DELETEs /events/webhooks/:id and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/events/webhooks/wh_1"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = Webhooks.delete(client(), "wh_1")
  end

  test "surfaces a non-2xx response as {:error, %Error{}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "not found"})
    end)

    assert {:error, %E2bEx.Error{status: 404}} = Webhooks.get(client(), "missing")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/webhooks_test.exs`
Expected: FAIL — `E2bEx.Webhooks.list/1 is undefined` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/e2b_ex/webhooks.ex
defmodule E2bEx.Webhooks do
  @moduledoc """
  Webhook management (`/events/webhooks`). Every function takes an `E2bEx.Client`.

  Webhooks deliver sandbox lifecycle events. Register one with a `signatureSecret`,
  then verify and decode deliveries with `E2bEx.WebhookEvent`.

      {:ok, wh} =
        E2bEx.Webhooks.create(client, %{
          name: "my-hook",
          url: "https://example.com/hook",
          enabled: true,
          events: ["sandbox.lifecycle.created"],
          signatureSecret: "whsec_..."
        })

  These endpoints are not in `openapi.yml`; the source of truth is
  https://e2b.dev/docs/sandbox/lifecycle-events-webhooks.
  """

  alias E2bEx.{Request, Webhook}

  @doc "List all webhooks (`GET /events/webhooks`)."
  @spec list(E2bEx.Client.t()) :: {:ok, [Webhook.t()]} | {:error, E2bEx.Error.t()}
  def list(client) do
    with {:ok, list} <- Request.request(client, :get, "/events/webhooks") do
      {:ok, Enum.map(list, &Webhook.from_api/1)}
    end
  end

  @doc """
  Create a webhook (`POST /events/webhooks`). `attrs` is a map in API shape
  (camelCase): `name`, `url`, `enabled`, `events`, `signatureSecret`.
  """
  @spec create(E2bEx.Client.t(), map()) :: {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def create(client, attrs) when is_map(attrs) do
    with {:ok, wh} <- Request.request(client, :post, "/events/webhooks", json: attrs) do
      {:ok, Webhook.from_api(wh)}
    end
  end

  @doc "Get a webhook by id (`GET /events/webhooks/:id`)."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def get(client, webhook_id) when is_binary(webhook_id) do
    with {:ok, wh} <- Request.request(client, :get, "/events/webhooks/#{webhook_id}") do
      {:ok, Webhook.from_api(wh)}
    end
  end

  @doc """
  Update a webhook (`PATCH /events/webhooks/:id`). `attrs` is a partial map in API
  shape: any of `url`, `enabled`, `events`.
  """
  @spec update(E2bEx.Client.t(), String.t(), map()) ::
          {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def update(client, webhook_id, attrs) when is_binary(webhook_id) and is_map(attrs) do
    with {:ok, wh} <- Request.request(client, :patch, "/events/webhooks/#{webhook_id}", json: attrs) do
      {:ok, Webhook.from_api(wh)}
    end
  end

  @doc "Delete a webhook by id (`DELETE /events/webhooks/:id`)."
  @spec delete(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, webhook_id) when is_binary(webhook_id) do
    case Request.request(client, :delete, "/events/webhooks/#{webhook_id}") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/webhooks_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/webhooks.ex test/e2b_ex/webhooks_test.exs
git commit -m "feat(webhooks): add E2bEx.Webhooks CRUD resource"
```

---

### Task 3: `E2bEx.WebhookEvent` struct + `from_api/1`

**Files:**
- Create: `lib/e2b_ex/webhook_event.ex`
- Test: `test/e2b_ex/webhook_event_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `E2bEx.WebhookEvent` struct with keys `:id, :version, :type, :timestamp, :event_category, :event_label, :event_data, :sandbox_id, :sandbox_execution_id, :sandbox_template_id, :sandbox_build_id, :sandbox_team_id`; `E2bEx.WebhookEvent.from_api(map()) :: t()` reading snake_case keys directly. `event_data` stays a raw map.

- [ ] **Step 1: Write the failing test**

```elixir
# test/e2b_ex/webhook_event_test.exs
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/webhook_event_test.exs`
Expected: FAIL — `E2bEx.WebhookEvent.__struct__/0 is undefined` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/e2b_ex/webhook_event.ex
defmodule E2bEx.WebhookEvent do
  @moduledoc """
  A sandbox lifecycle event delivered to your webhook endpoint.

  Hand the raw request body and the `e2b-signature` header to `parse/3`:

      case E2bEx.WebhookEvent.parse(raw_body, signature, secret) do
        {:ok, %E2bEx.WebhookEvent{} = event} -> handle(event)
        {:error, :invalid_signature} -> send_resp(conn, 401, "")
        {:error, :invalid_payload} -> send_resp(conn, 400, "")
      end

  The delivered payload is already snake_case, so `from_api/1` reads its keys directly
  (unlike the central-API decoders, which convert from camelCase). `event_data` is kept
  as a raw map.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          version: String.t() | nil,
          type: String.t() | nil,
          timestamp: String.t() | nil,
          event_category: String.t() | nil,
          event_label: String.t() | nil,
          event_data: map() | nil,
          sandbox_id: String.t() | nil,
          sandbox_execution_id: String.t() | nil,
          sandbox_template_id: String.t() | nil,
          sandbox_build_id: String.t() | nil,
          sandbox_team_id: String.t() | nil
        }

  defstruct [
    :id,
    :version,
    :type,
    :timestamp,
    :event_category,
    :event_label,
    :event_data,
    :sandbox_id,
    :sandbox_execution_id,
    :sandbox_template_id,
    :sandbox_build_id,
    :sandbox_team_id
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      id: m["id"],
      version: m["version"],
      type: m["type"],
      timestamp: m["timestamp"],
      event_category: m["event_category"],
      event_label: m["event_label"],
      event_data: m["event_data"],
      sandbox_id: m["sandbox_id"],
      sandbox_execution_id: m["sandbox_execution_id"],
      sandbox_template_id: m["sandbox_template_id"],
      sandbox_build_id: m["sandbox_build_id"],
      sandbox_team_id: m["sandbox_team_id"]
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/webhook_event_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/webhook_event.ex test/e2b_ex/webhook_event_test.exs
git commit -m "feat(webhooks): add E2bEx.WebhookEvent struct"
```

---

### Task 4: `verify_signature/3` and `parse/3`

**Files:**
- Modify: `lib/e2b_ex/webhook_event.ex` (add functions to the module from Task 3)
- Test: `test/e2b_ex/webhook_event_test.exs` (add tests)

**Interfaces:**
- Consumes: `E2bEx.WebhookEvent.from_api/1` (Task 3).
- Produces: `E2bEx.WebhookEvent.verify_signature(raw_body, signature, secret) :: boolean()`; `E2bEx.WebhookEvent.parse(raw_body, signature, secret) :: {:ok, t()} | {:error, :invalid_signature | :invalid_payload}`.
- Signature algorithm (verbatim from docs): `:crypto.hash(:sha256, secret <> raw_body) |> Base.encode64() |> String.trim_trailing("=")`, compared to the `e2b-signature` header (plain SHA256, NOT HMAC).
- Test fixture: `secret = "whsec_test"`, `raw_body = ~s({"id":"evt_1","type":"sandbox.lifecycle.created"})` → signature `27bqPwMn89eQHee+y+wgyqHiUT+q2+gwTpYEwPvUetc` (precomputed with the formula above; reproduce it in-test via `@valid_sig`).

- [ ] **Step 1: Write the failing test**

Add these to `test/e2b_ex/webhook_event_test.exs` (inside the existing `describe`-less module, after the Task 3 test):

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/webhook_event_test.exs`
Expected: FAIL — `E2bEx.WebhookEvent.verify_signature/3 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/e2b_ex/webhook_event.ex`, after `from_api/1`:

```elixir
  @doc """
  Verify a delivery's `e2b-signature` header against the raw request body.

  Computes `base64(sha256(secret <> raw_body))` with trailing `=` stripped (plain
  SHA256, not HMAC — per the E2B docs) and compares it to `signature` in constant time.
  The raw body must be the exact bytes received; re-encoding a parsed map would change
  them and fail verification.
  """
  @spec verify_signature(binary(), binary(), binary()) :: boolean()
  def verify_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    expected =
      :crypto.hash(:sha256, secret <> raw_body)
      |> Base.encode64()
      |> String.trim_trailing("=")

    secure_compare(expected, signature)
  end

  @doc """
  Verify and decode a delivery in one step.

  Returns `{:ok, %E2bEx.WebhookEvent{}}` when the signature is valid and the body is
  JSON, `{:error, :invalid_signature}` when the signature does not match, or
  `{:error, :invalid_payload}` when the body is not valid JSON. These atom reasons are
  intentional: signature/JSON checks are local, not HTTP failures, so they do not use
  `%E2bEx.Error{}`.
  """
  @spec parse(binary(), binary(), binary()) ::
          {:ok, t()} | {:error, :invalid_signature | :invalid_payload}
  def parse(raw_body, signature, secret) do
    if verify_signature(raw_body, signature, secret) do
      case Jason.decode(raw_body) do
        {:ok, map} -> {:ok, from_api(map)}
        {:error, _} -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_signature}
    end
  end

  # Constant-time comparison. Byte-wise XOR fold avoids depending on
  # `:crypto.hash_equals/2` (OTP 25+).
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.exor(a, b) == :binary.copy(<<0>>, byte_size(a))
  end

  defp secure_compare(_, _), do: false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/webhook_event_test.exs`
Expected: PASS (8 tests total in the file).

- [ ] **Step 5: Run the full suite and warnings check**

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass; compile clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/webhook_event.ex test/e2b_ex/webhook_event_test.exs
git commit -m "feat(webhooks): add WebhookEvent signature verification and parse/3"
```

---

### Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md` (scope, module map, conventions, gotchas)
- Modify: `README.md` (add a Webhooks section after the Volumes section, ~line 130)

**Interfaces:**
- Consumes: the public API from Tasks 1–4. No code changes.
- Produces: documentation only.

- [ ] **Step 1: Update `README.md`**

Insert after the Volumes section (after the closing ```` ``` ```` of the Volumes example, before `## ` that follows, i.e. around line 131):

````markdown
## Webhooks

Register webhooks for sandbox lifecycle events, then verify and decode deliveries:

```elixir
{:ok, wh} =
  E2bEx.Webhooks.create(client, %{
    name: "my-hook",
    url: "https://example.com/hook",
    enabled: true,
    events: ["sandbox.lifecycle.created", "sandbox.lifecycle.killed"],
    signatureSecret: "whsec_..."
  })

{:ok, hooks} = E2bEx.Webhooks.list(client)
{:ok, wh}    = E2bEx.Webhooks.get(client, wh.id)
{:ok, wh}    = E2bEx.Webhooks.update(client, wh.id, %{enabled: false})
:ok          = E2bEx.Webhooks.delete(client, wh.id)

# In your webhook endpoint, verify + decode a delivery from the raw body and the
# "e2b-signature" header:
case E2bEx.WebhookEvent.parse(raw_body, signature, "whsec_...") do
  {:ok, %E2bEx.WebhookEvent{type: type, sandbox_id: id}} -> handle(type, id)
  {:error, :invalid_signature} -> :unauthorized
  {:error, :invalid_payload} -> :bad_request
end
```
````

- [ ] **Step 2: Update `CLAUDE.md`**

Make these edits:

1. In the **Scope** section, add Webhooks to the in-scope list — change the opening sentence to include Webhooks and lifecycle-event webhooks:

   > Deliberately scoped to **Sandboxes, Templates, Tags, Volumes, and Webhooks**, plus **running commands inside a sandbox** and **inbound lifecycle-event webhooks** (verify + decode).

2. In the **Module map (`lib/`)** section, add three entries:

   ```markdown
   - `e2b_ex/webhook.ex`, `e2b_ex/webhooks.ex` — `E2bEx.Webhook` struct and the
     `E2bEx.Webhooks` CRUD resource over `/events/webhooks` (list/create/get/update/delete).
   - `e2b_ex/webhook_event.ex` — `E2bEx.WebhookEvent`: inbound delivery. `from_api/1`
     decodes the **snake_case** payload directly; `verify_signature/3` (plain SHA256 of
     `secret <> raw_body`, base64, trailing `=` stripped, constant-time compared);
     `parse/3` (verify + decode → `{:ok, event} | {:error, :invalid_signature | :invalid_payload}`).
   ```

3. In the **Conventions** section, add a bullet:

   ```markdown
   - **Inbound webhook errors are atoms, not `%E2bEx.Error{}`.** `WebhookEvent.parse/3`
     returns `{:error, :invalid_signature | :invalid_payload}` — signature/JSON checks
     are local, not HTTP failures. (Deliberate divergence, like `Commands`.)
   ```

4. In the **Gotchas** section, add a bullet:

   ```markdown
   - **Webhook endpoints are not in `openapi.yml`.** `/events/webhooks` is absent from
     both this repo's spec and upstream E2B's. Source of truth is the docs page:
     https://e2b.dev/docs/sandbox/lifecycle-events-webhooks. Don't expect a spec regen to
     surface them.
   ```

- [ ] **Step 3: Verify the suite still passes**

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass; compile clean.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(webhooks): document Webhooks and WebhookEvent"
```

---

## Self-Review

**Spec coverage:**
- Management `Webhook` struct → Task 1. ✓
- `Webhooks` CRUD (list/create/get/update/delete, `/events/webhooks`) → Task 2. ✓
- `WebhookEvent` struct + snake_case `from_api/1` → Task 3. ✓
- `verify_signature/3` (plain SHA256, base64, strip `=`, constant-time) + `parse/3` (atom errors) → Task 4. ✓
- Tests (Req.Test for CRUD, pure for inbound) → Tasks 1–4. ✓
- Docs (CLAUDE.md scope/module map/conventions/gotchas + README) → Task 5. ✓

**Placeholder scan:** No TBD/TODO; every code/test step shows full content. ✓

**Type consistency:** `Webhook.from_api/1`, `Webhooks.{list,create,get,update,delete}`, `WebhookEvent.{from_api,verify_signature,parse}` names/arities match across tasks and the spec. Signature fixture value is precomputed and consistent. ✓
