# E2bEx — Elixir API client for E2B (Design)

**Date:** 2026-06-10
**Status:** Approved (pending implementation plan)

## Overview

`E2bEx` is a hand-written, idiomatic Elixir client for a focused subset of the
E2B HTTP API, built on the [`req`](https://hex.pm/packages/req) HTTP client.

Scope for v1 is limited to three resource groups — **Sandboxes**, **Templates**,
and **Tags**. The following spec categories are explicitly **out of scope**:
Process, Teams, Filesystem, Envd, Volumes (plus `admin`, `auth`, `nodes`,
`access-tokens`, `api-keys`, `snapshots`-as-a-group, `health`). All endpoints
marked `deprecated: true` in `openapi.yml` are excluded; where the spec exposes
overlapping non-deprecated versions, only the **latest** version is wrapped.

The source of truth for shapes and paths is `openapi.yml` at the repo root
(E2B API `0.1.0`, base server `https://api.e2b.app`).

## Design decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Code production | Hand-written modules over `Req` (no codegen) |
| Success return shape | Typed structs (`%E2bEx.Sandbox{}`, etc.) |
| Config / credentials | Explicit `%E2bEx.Client{}` passed as first arg |
| Error return shape | Uniform `{:error, %E2bEx.Error{}}` |
| Auth | `X-API-Key` header only (`ApiKeyAuth`) for v1 |
| Borderline endpoints | Latest version only; include `GET /snapshots` and the template file-hash GET |

### Auth note

Every in-scope endpoint accepts `ApiKeyAuth` (`X-API-Key` header), so the client
authenticates uniformly with a single API key. Some template endpoints also
accept a bearer access token (`AccessTokenAuth`); since the API key covers all
of them, bearer/access-token support is deferred and can be added later without
breaking the public API.

## Endpoint surface (~27 functions)

All resource functions take a `%E2bEx.Client{}` as the first argument. The
trailing argument is an `opts` keyword list carrying query params and/or the
request body.

### `E2bEx.Sandboxes`

| Function | HTTP | Notes |
|---|---|---|
| `list/2` | GET `/v2/sandboxes` | latest list version (v1 dropped) |
| `create/2` | POST `/sandboxes` | body = `NewSandbox` |
| `get/2` | GET `/sandboxes/{id}` | → `SandboxDetail` |
| `kill/2` | DELETE `/sandboxes/{id}` | |
| `list_metrics/2` | GET `/sandboxes/metrics` | query: sandbox ids |
| `metrics/2` | GET `/sandboxes/{id}/metrics` | |
| `logs/2` | GET `/v2/sandboxes/{id}/logs` | latest logs version |
| `pause/2` | POST `/sandboxes/{id}/pause` | |
| `connect/2` | POST `/sandboxes/{id}/connect` | |
| `set_timeout/3` | POST `/sandboxes/{id}/timeout` | |
| `set_network/3` | PUT `/sandboxes/{id}/network` | |
| `refresh/2` | POST `/sandboxes/{id}/refreshes` | |
| `snapshot/2` | POST `/sandboxes/{id}/snapshots` | |
| `list_snapshots/2` | GET `/snapshots` | included per scope decision |

### `E2bEx.Templates`

| Function | HTTP | Notes |
|---|---|---|
| `list/2` | GET `/templates` | |
| `create/2` | POST `/v3/templates` | latest create version |
| `get/2` | GET `/templates/{id}` | → `TemplateWithBuilds` |
| `delete/2` | DELETE `/templates/{id}` | |
| `update/3` | PATCH `/v2/templates/{id}` | latest update version |
| `trigger_build/4` | POST `/v2/templates/{id}/builds/{buildID}` | latest build version |
| `build_status/4` | GET `/templates/{id}/builds/{buildID}/status` | |
| `build_logs/4` | GET `/templates/{id}/builds/{buildID}/logs` | |
| `get_by_alias/2` | GET `/templates/aliases/{alias}` | |
| `file_exists?/3` | GET `/templates/{id}/files/{hash}` | returns `{:ok, boolean}` |

### `E2bEx.Tags`

| Function | HTTP | Notes |
|---|---|---|
| `add/3` | POST `/templates/tags` | |
| `delete/2` | DELETE `/templates/tags` | |
| `list/2` | GET `/templates/{id}/tags` | → `[String.t()]` |

## Architecture

### Modules & responsibilities

- **`E2bEx`** — top-level convenience. `E2bEx.client/1` builds a `%Client{}`.
  Holds module-level docs and a usage example.
- **`E2bEx.Client`** — struct `%E2bEx.Client{api_key, base_url, req_options}`.
  - `new/1` (aliased as `E2bEx.client/1`) builds the struct, falling back to
    `Application` config for any opt not supplied. Default `base_url` is
    `https://api.e2b.app`.
  - Builds the base `Req` request: sets `base_url`, the `X-API-Key` header,
    JSON encoding/decoding, and merges any `req_options` (used in tests to
    inject the `Req.Test` adapter).
- **`E2bEx.Request`** (internal) — the single HTTP/error chokepoint.
  - `request(client, method, path, opts)` runs the `Req` call and normalises:
    - 2xx → `{:ok, body}` (decoded JSON map, or `:ok`-style body for empty 204s)
    - non-2xx → `{:error, %E2bEx.Error{}}` mapped from the response
    - transport failure (timeout, closed, etc.) → `{:error, %E2bEx.Error{}}`
      with `reason:` set and the exception in `body`
  - `opts` carries `:params` (query), `:json` (body), and `:path_params`.
- **`E2bEx.Sandboxes` / `.Templates` / `.Tags`** — pure mapping layer. Each
  function: build the path (interpolate path params), assemble query/body from
  `opts`, call `Request.request/4`, then decode the success body into the right
  struct via that struct's `from_api/1`.

### Entity structs

Typed structs with `@type t`, one per primary entity, each built from the
**superset** of its related response schemas in `openapi.yml`. Decoding is an
explicit `from_api/1` mapping from string-keyed JSON; unknown/absent fields are
dropped or `nil`.

- `E2bEx.Sandbox` — covers `NewSandbox` (create), `SandboxDetail` (get),
  `ListedSandbox` (list).
- `E2bEx.SandboxMetric` — `SandboxMetric`.
- `E2bEx.SandboxLog` — `SandboxLogEntry` / `SandboxLogsV2Response` entries.
- `E2bEx.Template` — `Template` / `TemplateWithBuilds`.
- `E2bEx.TemplateBuild` — `TemplateBuild` plus build-status fields.
- `E2bEx.Error` — `%E2bEx.Error{status, code, message, body, reason}`.

Tag listing returns `[String.t()]` (no struct).

### Data flow (example)

```
E2bEx.Sandboxes.get(client, id)
  └─ build path "/sandboxes/#{id}"
     └─ E2bEx.Request.request(client, :get, path, [])
        └─ Req call against base_url with X-API-Key
           ├─ 2xx → body map → E2bEx.Sandbox.from_api/1 → {:ok, %Sandbox{}}
           └─ non-2xx → {:error, %E2bEx.Error{status, code, message, body}}
```

## Error handling

A single error type, `%E2bEx.Error{}`:

- **API errors** (non-2xx): `status` (HTTP status), `code` and `message` from
  the spec's `Error` schema (`{code: integer, message: string}`), and the raw
  decoded `body`.
- **Transport failures**: `reason` (e.g. `:timeout`, `:closed`) with the
  underlying exception placed in `body`; `status` is `nil`.

Callers always pattern-match a single shape: `{:ok, value}` or
`{:error, %E2bEx.Error{}}`.

## Testing

Test-driven, using Req's built-in `Req.Test` stubbing — no live network calls.
The base request carries a `Req.Test` adapter via `req_options` in the test
client. Each resource function has tests asserting:

- HTTP method and interpolated path
- presence of the `X-API-Key` header
- query-param and JSON-body encoding from `opts`
- success decoding into the correct struct
- non-2xx → `%E2bEx.Error{}` mapping
- transport failure → `%E2bEx.Error{}` with `reason:`

Fixtures are drawn from the example payloads in `openapi.yml`.

## Dependencies

- `{:req, "~> 0.5"}` — HTTP client (Jason comes transitively).
- `{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}` — docs.

## Out of scope for v1 (future work)

- Bearer / access-token (`AccessTokenAuth`) authentication.
- Deprecated endpoint versions and the excluded resource groups.
- Streaming/long-poll helpers for build/sandbox logs (v1 returns the plain
  response).
- Automatic retries/backoff beyond Req defaults.
