# E2bEx Commands — blocking command execution (Design)

**Date:** 2026-06-11
**Status:** Approved (pending implementation plan)

## Overview

Add the ability to run shell commands inside a running E2B sandbox, equivalent
to the JS SDK's `sandbox.commands.run("...")`. v1 covers **blocking** execution
only: run a command, wait for it to finish, and return stdout/stderr/exit code.

Unlike every existing `E2bEx` function, command execution does **not** go through
the central API (`api.e2b.app`). It talks directly to the sandbox's embedded
`envd` daemon using the **Connect protocol** (ConnectRPC) — a server-streaming
RPC `POST /process.Process/Start`. For a blocking run we let `Req` buffer the
entire response and parse the length-prefixed frames afterward, so no
incremental streaming or long-lived connection handling is needed, and using the
Connect **+JSON** codec means **no protobuf dependency**.

Reference: the JS SDK (`packages/js-sdk/src/sandbox/commands/`) and the proto at
`spec/envd/process/process.proto` in the E2B repo.

## Design decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | Blocking `run` only (defer background/streaming/stdin/kill/PTY) |
| Exit handling | A command that ran returns `{:ok, %CommandResult{}}` regardless of exit code; `{:error, %E2bEx.Error{}}` only for transport/connection/protocol failures |
| Entry point | Client-first: `E2bEx.Commands.run(client, sandbox, command, opts)` |
| Wire codec | Connect **+JSON** (`application/connect+json`), buffered then parsed — no protobuf, no incremental streaming |

## Out of scope for v1 (future work)

Background processes / handles (PID), live output streaming to a callback,
stdin, kill/signals, reconnect, PTY, and the `List` RPC. These require
incremental frame streaming over a kept-alive connection (Finch streaming) and
are deliberately deferred.

## Public API

```elixir
{:ok, result} =
  E2bEx.Commands.run(client, sandbox,
    ~s(codex exec --full-auto --skip-git-repo-check "Create a hello world HTTP server in Go"))

result.exit_code  # 0
result.stdout     # "..."
result.stderr     # "..."
result.error      # nil, or a command-level error string from the end event
```

- `run(client, sandbox, command, opts \\ [])` →
  `{:ok, %E2bEx.CommandResult{}}` | `{:error, %E2bEx.Error{}}`.
- `client` is an `%E2bEx.Client{}` (supplies shared Req config via `req_options`
  and a fallback domain). Its API key and base URL are not used for the envd
  request.
- `sandbox` is an `%E2bEx.Sandbox{}` (from `create/2`, `connect/3`, or `get/2`),
  supplying `sandbox_id`, `domain`, and `envd_access_token`.
- **opts:**
  - `:cwd` — working directory (string).
  - `:envs` — environment variables (map of string => string).
  - `:user` — Linux user; when set, sends `Authorization: Basic base64("#{user}:")`.
  - `:timeout_ms` — total command/stream timeout; default `60_000`; `0` disables.
  - `:domain` — override the sandbox domain.
  - `:port` — envd port; default `49983`.
  - `:base_url` — override the full envd base URL (advanced; self-hosted/proxy/testing).

### `E2bEx.CommandResult`

```elixir
%E2bEx.CommandResult{
  stdout: String.t(),     # accumulated, default ""
  stderr: String.t(),     # accumulated, default ""
  exit_code: integer(),   # from end event; default 0 (proto3 JSON omits zero)
  error: String.t() | nil # command-level error string from end event, if any
}
```

## Architecture / modules

- **`E2bEx.Commands`** (`lib/e2b_ex/commands.ex`) — public. Resolves connection
  info, builds the envd Req request, issues the `POST`, and folds the response
  frames into a `CommandResult`. The only place that builds the envd HTTP call.
- **`E2bEx.Envd.Connect`** (`lib/e2b_ex/envd/connect.ex`, internal, pure) — the
  Connect-protocol framing. No HTTP. Unit-testable in isolation.
  - `encode_frame(binary) :: binary` — wrap a payload in one Connect envelope:
    `<<0::8, byte_size(payload)::unsigned-big-32, payload::binary>>`.
  - `decode_frames(binary) :: {:ok, [map()], trailer} | {:error, term()}` where
    `trailer` is the decoded end-of-stream frame (`flags &&& 0x02 != 0`). Each
    non-trailer message is the JSON-decoded `StartResponse` map. Returns
    `{:error, reason}` on malformed framing.
- **`E2bEx.CommandResult`** (`lib/e2b_ex/command_result.ex`) — the struct +
  `@type t`.

Command execution deliberately does **not** reuse `E2bEx.Request` or
`E2bEx.Client.base_req/1` (those target `api.e2b.app`, send `x-api-key`, and
JSON-decode responses). `Commands` builds its own `Req` request against the envd
URL, merging `client.req_options` (so the `Req.Test` plug and any user Req config
flow through), with `retry: false` and `decode_body: false` (frames are parsed
manually, not decoded as JSON).

## Connect protocol details (the wire)

### Request

- **Method/path:** `POST /process.Process/Start`.
- **Headers:**
  - `content-type: application/connect+json`
  - `connect-protocol-version: 1`
  - `x-access-token: <envd_access_token>` (omitted if the sandbox has none)
  - `e2b-sandbox-id: <sandbox_id>`
  - `e2b-sandbox-port: <port>`
  - `keepalive-ping-interval: 50`
  - `connect-timeout-ms: <timeout_ms>` (omitted when `timeout_ms == 0`)
  - `authorization: Basic base64("#{user}:")` (only when `:user` is set)
- **Body:** one Connect frame (`encode_frame/1`) wrapping the JSON of:

  ```json
  {
    "process": {
      "cmd": "/bin/bash",
      "args": ["-l", "-c", "<command>"],
      "cwd": "<cwd>",
      "envs": {"KEY": "value"}
    },
    "stdin": false
  }
  ```

  `cwd` and `envs` are omitted when not provided. The command string is always
  wrapped as `/bin/bash -l -c "<command>"` — never sent raw.

  The body is passed to Req as a raw `:body` binary (not `:json`), with
  `content-type` set manually, so Req does not re-encode it.

### Response

HTTP 200 with `content-type: application/connect+json` and a body that is a
sequence of Connect frames. Each frame: `<<flags::8, len::unsigned-big-32,
data::binary-size(len)>>`.

- Non-trailer frames (`flags == 0`): `data` is the JSON of a `StartResponse`,
  shaped `{"event": {<oneof>}}` where `<oneof>` is one of:
  - `{"start": {"pid": 123}}` — first frame; pid ignored for blocking run.
  - `{"data": {"stdout": "<base64>"}}` or `{"data": {"stderr": "<base64>"}}` —
    output chunk; base64-decode the value and accumulate.
  - `{"end": {"exitCode": 1, "exited": true, "status": "...", "error": "..."}}`
    — final event. `exitCode` is **omitted when 0** (proto3 JSON), so default to
    `0`. `error` is optional.
  - `{"keepalive": {}}` — heartbeat; ignore.
- Trailer frame (`flags &&& 0x02 != 0`): `data` is JSON `{}` on success, or
  `{"error": {"code": "...", "message": "..."}}` on a Connect-level error.

## Data flow (`run/4`)

1. Validate `sandbox.sandbox_id` is present (else `{:error, %Error{}}` describing
   the missing field).
2. Resolve `domain = sandbox.domain || opts[:domain] || domain_from(client) || "e2b.app"`
   where `domain_from/1` strips a leading `"api."` from the host of
   `client.base_url`.
3. Resolve `token = sandbox.envd_access_token` (may be nil).
4. Build URL `https://#{port}-#{sandbox_id}.#{domain}` and the headers above.
5. Build the request body via `Connect.encode_frame(Jason.encode!(start_request))`.
6. Issue `POST /process.Process/Start` (buffered, `decode_body: false`,
   `retry: false`, `receive_timeout` derived from `timeout_ms`).
7. On a 2xx response, `Connect.decode_frames/1` the body, then fold the messages:
   accumulate stdout/stderr (base64-decoded), capture `exit_code`/`error` from
   the `end` event. If the trailer carries a Connect error → `{:error, %Error{}}`.
   Otherwise `{:ok, %CommandResult{}}`.
8. On a non-2xx response → `{:error, Error.from_response/1}` (the Connect unary
   error body, e.g. auth failure). On a transport exception →
   `{:error, Error.from_exception/1}`.

## Error handling

| Situation | Result |
|---|---|
| Command ran (any exit code, including non-zero) | `{:ok, %CommandResult{exit_code, stdout, stderr, error}}` |
| Connection/transport failure (DNS, refused, timeout) | `{:error, %E2bEx.Error{reason: ...}}` |
| Non-200 response (e.g. bad/missing access token) | `{:error, %E2bEx.Error{status, ...}}` |
| End-of-stream trailer Connect error | `{:error, %E2bEx.Error{}}` |
| Malformed framing in the response body | `{:error, %E2bEx.Error{}}` |

`%E2bEx.Error{}` is the existing uniform error type; it gains no new fields.

## Testing

- **`E2bEx.Envd.Connect`** (pure, no HTTP):
  - `encode_frame/1` produces the correct `<<0, len::32, payload>>` bytes.
  - `decode_frames/1` round-trips a single data frame, multiple frames, an `end`
    event with an explicit `exitCode`, an `end` event with `exitCode` omitted
    (defaults handled by the caller), a success trailer (`{}`), an error trailer,
    and returns `{:error, _}` on truncated/garbage framing.
- **`E2bEx.Commands`** (via a **Bypass** local HTTP server — see note):
  - Stubs the envd endpoint; asserts method `POST`, path `/process.Process/Start`,
    the `x-access-token` / `content-type` / `e2b-sandbox-id` headers, and the
    decoded `StartRequest` body (cmd `/bin/bash`, args `["-l","-c", command]`,
    `cwd`, `envs`). Responds with hand-framed connect+json bytes and asserts the
    returned `%CommandResult{}` (stdout/stderr/exit_code).
  - A non-zero exit returns `{:ok, %CommandResult{exit_code: n}}`.
  - A trailer error frame returns `{:error, %E2bEx.Error{}}`.
  - A non-2xx envd response returns `{:error, %E2bEx.Error{status: n}}`.
  - A transport error (`Bypass.down/1`) returns `{:error, %E2bEx.Error{reason: ...}}`.
  - A malformed base64 chunk returns `{:error, %E2bEx.Error{}}`.
  - `:user` opt adds the `Authorization: Basic` header; `:cwd`/`:envs` reach the
    request body.

Note: `Req.Test` **cannot** test this — its plug adapter runs `Plug.Parsers`
(JSON, `pass: ["*/*"]`) on the request body before the stub, and the
`application/connect+json` content-type makes it try to JSON-decode the framed
binary body, raising before the stub runs. Tests therefore use **Bypass** (a real
loopback HTTP server, no `Plug.Parsers`), pointed at via the `:base_url` opt. This
also yields genuine on-the-wire transport coverage. Fixtures are hand-built framed
bytes (helpers in the test module) since these payloads are not in `openapi.yml`.

## Dependencies

One new **test-only** dependency: `{:bypass, "~> 2.1", only: :test}` (real local
HTTP server for the command tests). Runtime uses `Req` (already present) and
`Jason` (transitive via Req); base64 via the standard `Base` module; framing via
binary pattern matching.
