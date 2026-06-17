# E2bEx Webhooks — design

Add support for the E2B **lifecycle-event webhooks** API to `E2bEx`: both the
outbound management API (register/list/get/update/delete webhooks) and the inbound
side (verify a delivery's signature and decode its event payload).

## Source of truth

These endpoints are **not** in `openapi.yml` — confirmed absent from both this repo's
copy and the upstream E2B spec (`/Users/col/Projects/E2B/spec/openapi.yml`, same
version `0.1.0`, same 44 paths). The JS/Python SDKs do **not** implement webhook
management either, so there is no parity reference. The authority for this feature is
the docs page:

> https://e2b.dev/docs/sandbox/lifecycle-events-webhooks

This will be recorded as a gotcha in `CLAUDE.md` so a future spec regeneration does not
make the code look wrong.

## Scope

In scope:

- Management CRUD on `/events/webhooks` (central API host, `x-api-key` auth).
- Inbound signature verification + event-payload decoding.

Out of scope (YAGNI): retries/redelivery, the dashboard, anything not on the docs page.

## Architecture

Two independent concerns, each following existing project patterns.

### 1. Outbound management API

Central API (`https://api.e2b.app`), plain JSON over `Req`, funnelled through
`E2bEx.Request.request/4` — identical transport to `E2bEx.Volumes`/`Tags`. Errors are
already normalised to `{:error, %E2bEx.Error{}}` by `Request`.

#### `lib/e2b_ex/webhook.ex` — `E2bEx.Webhook` struct

Decoded representation of a webhook returned by get/list (and create/update). camelCase →
snake_case via `from_api/1`, exactly like every other struct. Timestamps stay strings
(project convention — no `DateTime` parsing). `signatureSecret` is write-only and is
never decoded back.

Fields:

| struct key   | API key      | type             |
|--------------|--------------|------------------|
| `id`         | `id`         | `String.t()`     |
| `team_id`    | `teamId`     | `String.t()`     |
| `name`       | `name`       | `String.t()`     |
| `created_at` | `createdAt`  | `String.t()`     |
| `enabled`    | `enabled`    | `boolean()`      |
| `url`        | `url`        | `String.t()`     |
| `events`     | `events`     | `[String.t()]`   |

```elixir
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
```

#### `lib/e2b_ex/webhooks.ex` — `E2bEx.Webhooks` resource

Every function takes an `E2bEx.Client`. Mirrors `E2bEx.Volumes` structure.

| function       | HTTP                            | returns                    |
|----------------|---------------------------------|----------------------------|
| `list/1`       | `GET /events/webhooks`          | `{:ok, [%Webhook{}]}`      |
| `create/2`     | `POST /events/webhooks`         | `{:ok, %Webhook{}}`        |
| `get/2`        | `GET /events/webhooks/:id`      | `{:ok, %Webhook{}}`        |
| `update/3`     | `PATCH /events/webhooks/:id`    | `{:ok, %Webhook{}}`        |
| `delete/2`     | `DELETE /events/webhooks/:id`   | `:ok`                      |

- `create(client, attrs)` — `attrs` is a map in **API shape** (camelCase), passed
  straight to `json:`, consistent with `Sandboxes.create/2`. Documented keys:
  `%{name:, url:, enabled:, events:, signatureSecret:}`. Decodes the returned webhook.
- `update(client, webhook_id, attrs)` — partial map (`url`, `enabled`, `events`).
  Decodes the returned webhook.
- `delete/2` — follows `Volumes.delete/2`: `{:ok, _} -> :ok`.
- All failures surface as `{:error, %E2bEx.Error{}}` (no change to `Request`).

```elixir
def list(client) do
  with {:ok, list} <- Request.request(client, :get, "/events/webhooks") do
    {:ok, Enum.map(list, &Webhook.from_api/1)}
  end
end

def create(client, attrs) when is_map(attrs) do
  with {:ok, wh} <- Request.request(client, :post, "/events/webhooks", json: attrs) do
    {:ok, Webhook.from_api(wh)}
  end
end

def get(client, id) when is_binary(id) do
  with {:ok, wh} <- Request.request(client, :get, "/events/webhooks/#{id}") do
    {:ok, Webhook.from_api(wh)}
  end
end

def update(client, id, attrs) when is_binary(id) and is_map(attrs) do
  with {:ok, wh} <- Request.request(client, :patch, "/events/webhooks/#{id}", json: attrs) do
    {:ok, Webhook.from_api(wh)}
  end
end

def delete(client, id) when is_binary(id) do
  case Request.request(client, :delete, "/events/webhooks/#{id}") do
    {:ok, _} -> :ok
    {:error, error} -> {:error, error}
  end
end
```

**Assumption to confirm during implementation:** the docs state create/update return
`201`/`200` but do not show a response body. This design decodes the returned webhook
object (REST norm, and what `get` clearly returns); tests stub the full-object response.
If the live API returns an empty body on create/update, adapt then (e.g. fall back to
`get/2`, or return `:ok`).

### 2. Inbound delivery — `lib/e2b_ex/webhook_event.ex`

Pure, local, no HTTP. The user receives the raw POST body + the `e2b-signature` header
at their own web endpoint and hands them to this module.

#### `E2bEx.WebhookEvent` struct

The delivered payload is already **snake_case**, so `from_api/1` reads snake_case keys
directly rather than converting — a deliberate divergence from the central-API decoders,
which convert from camelCase. `event_data` stays a raw `map()` (nested
`sandbox_metadata`/`execution`), consistent with how `metadata`/`lifecycle` are left as
raw maps elsewhere.

Fields (all `String.t() | nil` except `event_data` which is `map() | nil`):
`id`, `version`, `type`, `timestamp`, `event_category`, `event_label`, `event_data`,
`sandbox_id`, `sandbox_execution_id`, `sandbox_template_id`, `sandbox_build_id`,
`sandbox_team_id`.

```elixir
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
```

Documented event types (`type`): `sandbox.lifecycle.created`,
`sandbox.lifecycle.killed`, `sandbox.lifecycle.updated`, `sandbox.lifecycle.paused`,
`sandbox.lifecycle.resumed`, `sandbox.lifecycle.checkpointed`. (The struct does not
restrict `type` — it stores whatever string is delivered.)

#### `verify_signature/3`

```elixir
@spec verify_signature(binary(), binary(), binary()) :: boolean()
def verify_signature(raw_body, signature, secret)
    when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
  expected =
    :crypto.hash(:sha256, secret <> raw_body)
    |> Base.encode64()
    |> String.trim_trailing("=")

  secure_compare(expected, signature)
end
```

Algorithm verbatim from the docs (plain SHA256, **not** HMAC): hash `secret <> raw_body`,
standard base64, strip trailing `=`. Compare to the `e2b-signature` header value.

`secure_compare/2` is a private constant-time comparison implemented with a byte-wise
XOR fold (avoids depending on `:crypto.hash_equals/2`, which is OTP-25+):

```elixir
defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
  :crypto.exor(a, b) == :binary.copy(<<0>>, byte_size(a))
end

defp secure_compare(_, _), do: false
```

#### `parse/3`

```elixir
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
```

**Deliberate divergence:** `parse/3` returns **atom** error reasons, not
`%E2bEx.Error{}`. `%E2bEx.Error{}` models HTTP/transport failures (`status`, `body`,
`code`); signature/JSON validation is purely local, so atoms (`:invalid_signature`,
`:invalid_payload`) are clearer and carry no spurious HTTP fields. This mirrors how
`Commands` intentionally diverges from the uniform error shape. Documented in
`CLAUDE.md` conventions.

The `e2b-signature-version` header is currently always `v1`; `parse/3`/`verify_signature/3`
do not consume it (YAGNI — single version).

## Testing

Follows project conventions: central-API CRUD with **`Req.Test`**; the inbound module is
pure so it needs no HTTP harness (no Bypass).

- `test/e2b_ex/webhooks_test.exs` — mirrors `volumes_test.exs`: stub each of
  list/create/get/update/delete (assert method + path + request body) and one non-2xx
  case asserting `{:error, %E2bEx.Error{status: ...}}`.
- `test/e2b_ex/webhook_test.exs` — `Webhook.from_api/1` decoding (camelCase → snake_case,
  `signatureSecret` ignored).
- `test/e2b_ex/webhook_event_test.exs`:
  - `from_api/1` decodes a full snake_case payload, `event_data` kept as a raw map.
  - `verify_signature/3`: a known `secret`/`raw_body` produces the known base64 signature
    (compute the expected value with the documented formula in the test); a tampered body
    or wrong secret → `false`; length-mismatched signature → `false`.
  - `parse/3`: valid → `{:ok, %WebhookEvent{}}`; bad signature → `{:error,
    :invalid_signature}`; valid signature over non-JSON body → `{:error,
    :invalid_payload}`.

`mix compile --warnings-as-errors` must stay clean.

## Documentation

- `CLAUDE.md`:
  - Scope: add Webhooks (management) and lifecycle-event webhooks (inbound) to the
    in-scope list.
  - Module map: `webhook.ex`, `webhooks.ex`, `webhook_event.ex`.
  - Conventions: note the inbound divergences (snake_case `from_api`, atom error reasons
    from `parse/3`).
  - Gotchas: webhook endpoints are not in `openapi.yml` — source of truth is the docs
    page.
- README / moduledocs: a short usage example (register a webhook; verify + parse a
  delivery).

## Module map summary (new files)

- `lib/e2b_ex/webhook.ex` — `E2bEx.Webhook` struct + `from_api/1`.
- `lib/e2b_ex/webhooks.ex` — `E2bEx.Webhooks` CRUD resource over `/events/webhooks`.
- `lib/e2b_ex/webhook_event.ex` — `E2bEx.WebhookEvent` struct + `from_api/1` +
  `verify_signature/3` + `parse/3`.
- `test/e2b_ex/webhooks_test.exs`, `test/e2b_ex/webhook_test.exs`,
  `test/e2b_ex/webhook_event_test.exs`.
