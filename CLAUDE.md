# E2bEx — project guide for Claude

An Elixir API client for the [E2B](https://e2b.dev) sandbox platform, built on the
`Req` HTTP library. Mix app `:e2b_ex`, Elixir `~> 1.18`.

## Scope

Deliberately scoped to **Sandboxes, Templates, and Tags**, plus **running commands
inside a sandbox**. Intentionally **excluded**: Teams, Filesystem, Volumes, and any
API marked deprecated in the OpenAPI spec. (The envd Process API is in scope only via
`E2bEx.Commands` — see below.)

## Two transport surfaces

The library talks to **two different hosts**, and this distinction matters:

1. **Central API** (`https://api.e2b.app`) — Sandboxes/Templates/Tags. Plain JSON over
   `Req`. All requests funnel through `E2bEx.Request.request/4` (the single HTTP
   chokepoint), which sets the `x-api-key` header and normalizes results.
2. **Sandbox `envd` daemon** (`https://<port>-<sandbox_id>.<domain>`) — command
   execution. Uses the **Connect protocol (ConnectRPC)** with the JSON codec
   (`application/connect+json`), NOT the central API. `E2bEx.Commands` builds its own
   `Req` request for this (it does not go through `E2bEx.Request`), because the host,
   auth, content-type, and response framing are all different.

## Module map (`lib/`)

- `e2b_ex.ex` — top-level convenience: `E2bEx.client/1` delegates to `Client.new/1`.
- `e2b_ex/client.ex` — `%Client{api_key, base_url, req_options}`; `new/1` (raises without
  `:api_key`, default base_url `https://api.e2b.app`), `base_req/1` (sets `x-api-key`,
  `retry: false`).
- `e2b_ex/request.ex` — `request/4` + `build_options/3`. **Single HTTP chokepoint** for
  the central API. Note: write methods with no JSON body get `body: ""` so Finch emits
  `Content-Length: 0` (E2B's GCP frontend returns `411 Length Required` for bodyless
  POSTs — see "Gotchas").
- `e2b_ex/error.ex` — uniform `%E2bEx.Error{status, code, message, reason, body}`.
  `from_response/1` (API errors), `from_exception/1` (transport).
- `e2b_ex/sandbox.ex`, `template.ex`, `command_result.ex` — typed structs with
  `from_api/1` camelCase→snake_case decoders.
- `e2b_ex/sandboxes.ex` — list/create/get/kill/pause/connect/set_timeout/set_network/
  refresh/snapshot/list_snapshots/metrics/list_metrics/logs.
- `e2b_ex/templates.ex`, `e2b_ex/tags.ex` — Templates and Tags resources.
- `e2b_ex/commands.ex` — `E2bEx.Commands.run/4`: blocking command execution over envd
  Connect, with optional `:on_stdout`/`:on_stderr` streaming callbacks.
- `e2b_ex/envd/connect.ex` — Connect-protocol framing (whole-body `decode_frames/1`,
  `encode_frame/1`).
- `e2b_ex/envd/connect/decoder.ex` — `E2bEx.Envd.Connect.Decoder`: pure **incremental**
  frame decoder (`new/0`, `push/2`) that buffers partial frames across network chunks.
  `decode_frames/1` is implemented on top of it.

## Conventions

- **Return shapes:** read calls return `{:ok, struct | [struct]}`; void/lifecycle calls
  return `:ok`; everything fails with `{:error, %E2bEx.Error{}}`.
- **Commands never raise on non-zero exit.** `run/4` returns `{:ok, %CommandResult{}}`
  for *any* exit code (check `exit_code`); this diverges intentionally from the JS/Python
  SDKs, whose `wait()` raises `CommandExitError`. `{:error, …}` is reserved for
  transport/non-2xx/trailer/malformed-framing failures. (Elixir idiom, like
  `System.cmd/3`.)
- Each `lib` file has one focused responsibility; tests mirror the structure under
  `test/e2b_ex/`.

## Connect protocol notes (envd command execution)

- Server-streaming RPC `POST /process.Process/Start`. Command is always wrapped as
  `/bin/bash -l -c "<command>"`.
- Frame format: `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  The end-of-stream **trailer** sets bit `0x02`; its JSON is `{}` on success or
  `{"error": {"code","message"}}` on a Connect-level error.
- Events (proto3 JSON, zero values omitted): `start` (pid), `data` (base64 stdout/stderr),
  `end` (`exitCode` **omitted when 0** → default to 0; optional `error`), `keepalive`.
- **Auth:** the `x-access-token` header carries the sandbox's `envd_access_token`. This
  token is returned by `create`/`connect`/`get` but **NOT** by `list` (the API omits it
  from `ListedSandbox`). A `list`-derived sandbox will get `401` from envd — call
  `connect/3` or `get/2` first to obtain a token-bearing sandbox. `:user` adds an
  `Authorization: Basic base64("user:")` header.
- Streaming uses `Req`'s `into: fun` reducer with `compressed: false` (with `into: fun`
  Req does not run its body-decompression step, so the client must not advertise gzip).

## Testing

- `mix test` (87 tests as of Phase 1). `mix compile --warnings-as-errors` must stay clean.
- Central-API resources are tested with **`Req.Test`** (Plug-based stubs via
  `req_options: [plug: {Req.Test, Mod}]`).
- **`E2bEx.Commands` is tested with `Bypass`** (a real loopback HTTP server), NOT
  `Req.Test`. Reason: Req's plug adapter runs `Plug.Parsers` (JSON, `pass: ["*/*"]`)
  before the stub, and `application/connect+json` ends in `+json`, so it tries to
  JSON-decode the framed binary body and raises. Bypass avoids this and exercises the
  real wire. Commands tests use the `:base_url` opt to point at Bypass (also a legit
  self-hosted/proxy escape hatch). Streaming tests use `Plug.Conn.send_chunked/2` +
  `chunk/2` to split framed bytes across network chunks and prove incremental decoding.

## Reference material

- **OpenAPI spec:** `openapi.yml` (in this repo) — source of truth for the central API.
- **Official E2B SDKs** (read these for parity/behavior when extending Commands):
  - JS SDK: `/Users/col/Projects/E2B/packages/js-sdk` — commands at
    `src/sandbox/commands/{index.ts,commandHandle.ts,pty.ts}`; sandbox/auth at
    `src/sandbox/{index.ts,sandboxApi.ts,signature.ts}`.
  - Python SDK: `/Users/col/Projects/E2B/packages/python-sdk` — sync commands at
    `e2b/sandbox_sync/commands/{command.py,command_handle.py,pty.py}` (closest analog to
    Elixir's synchronous-but-process-based model); async variants under
    `e2b/sandbox_async/`; shared types in `e2b/sandbox/commands/`.
  - envd Process proto: `/Users/col/Projects/E2B/spec/envd/process/process.proto` —
    the full RPC surface (`Start`, `Connect`, `List`, `SendInput`, `SendSignal`,
    `CloseStdin`, `Update`) and message shapes.

## Gotchas (learned the hard way)

- **`411 Length Required` on bodyless POSTs** (e.g. `pause`): E2B's GCP frontend rejects
  POSTs without a Content-Length. Finch only emits it for a binary (non-nil) body, so
  `Request.build_options/3` sets `body: ""` for bodyless write methods. Don't remove this.
- **`401` running commands on a `list`-derived sandbox:** missing `envd_access_token` — see
  Connect auth note above.
- **Truncated 2xx command streams:** `Commands.finalize/1` treats a non-empty decoder
  buffer at end-of-response as `{:error, "malformed envd response"}` — a partial frame
  means the stream was cut short. Keep that check.

## Development workflow

This project is developed with the **superpowers** skills (brainstorming → writing-plans
→ subagent-driven-development → finishing-a-development-branch). Specs live in
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Work happens on feature
branches, reviewed in two stages (spec compliance, then code quality) per task.

## Roadmap — Commands feature parity (phased)

Bringing `E2bEx.Commands` to parity with the JS/Python SDKs, in sequence:

- **Phase 1 — DONE:** streaming foundation (incremental decoder + `on_stdout`/`on_stderr`).
  Spec: `docs/superpowers/specs/2026-06-11-e2b-commands-streaming-design.md`.
- **Phase 2 — planned:** background execution + a GenServer-backed `CommandHandle`
  (`wait`/`kill`/`disconnect`/`send_stdin`/`close_stdin`/live getters), plus `list` and
  `connect`/reconnect. These add the unary Connect RPCs `SendSignal`, `SendInput`,
  `CloseStdin`, `List`, and the streaming `Connect` RPC.
- **Phase 3 — planned:** PTY (`create`/`connect`/`send_stdin`/`resize`/`kill`/`list`).
