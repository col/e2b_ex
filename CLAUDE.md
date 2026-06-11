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
- `e2b_ex/commands.ex` — `E2bEx.Commands`. Public surface over the envd Process API:
  `run/4` (blocking, `{:ok, %CommandResult{}}`, optional `:on_stdout`/`:on_stderr`
  callbacks), `start/4` (background → `%CommandHandle{}`), `connect/4` (reconnect to a
  pid), `list/2`, and by-pid `kill/4`/`send_stdin/5`/`close_stdin/4`. `run/4` uses a
  buffered `into: fun` reducer; `start/4`/`connect/4` spawn a `HandleServer`.
- `e2b_ex/command_handle.ex` — `E2bEx.CommandHandle`: `%{server, ref, pid, context}` +
  `wait/1` (draining receive + crash monitor), `kill/1`, `send_stdin/2`, `close_stdin/1`,
  `disconnect/1`, `pid/1`. Control ops delegate to `Envd.Rpc` (caller's process); `wait`
  /`disconnect` talk to the server. **No live getters** — output is push (messages).
- `e2b_ex/pty.ex` — `E2bEx.Pty`. PTY surface over the envd Process API: `create/3`
  (launches `/bin/bash -i -l` on a PTY of `:cols`×`:rows`, → `%Pty.Handle{}`),
  `connect/4` (reconnect by pid), and by-pid `send_input/5`/`resize/5`/`kill/4`.
  Reuses `Commands.HandleServer` for streaming; output is the merged `{:pty, _}`
  channel, not stdout/stderr. No `Pty.list` (listing stays on `Commands`).
- `e2b_ex/pty/handle.ex` — `E2bEx.Pty.Handle`: `%{server, ref, pid, context}` +
  `send_input/2`, `resize/2`, `kill/1`, `disconnect/1`, `wait/1` (drains `{:pty, _}`,
  returns exit-code-only `%CommandResult{}`), `pid/1`. No `close_stdin` (not in the
  PTY surface). Same message-first model as `CommandHandle`.
- `e2b_ex/commands/handle_server.ex` — `E2bEx.Commands.HandleServer` (GenServer, internal):
  owns one `Start`/`Connect` server-stream via Req `into: :self`, folds via `Fold`,
  pushes `{ref, {:stdout|:stderr, _}}` then terminal `{ref, {:exit|:error, _}}` to a
  subscriber. Replies to `:await_start` with the envd pid on the first `start` event.
  `terminate/2` cancels the async response so `disconnect` closes the connection.
- `e2b_ex/commands/fold.ex` — `E2bEx.Commands.Fold`: pure, delivery-agnostic folding of
  decoded events into `%CommandResult{}` (returns output events; `ended?/1`). Shared by
  `run/4` (→ callbacks) and `HandleServer` (→ messages). Also emits `{:pty, _}` for
  `data.pty` events (emit-only — PTY output is never accumulated into the result).
- `e2b_ex/envd/rpc.ex` — `E2bEx.Envd.Rpc` (internal): builds the envd connection context
  (`context/3`: base_url + headers), issues **unary** Connect calls (`unary/4`, bare
  JSON), and the control wrappers `kill/2`/`send_stdin/3`/`close_stdin/2`/`list/1`.
  Adds `send_pty_input/3` (the `pty` input channel) and `resize/3` (the `Update` RPC)
  for PTY.
- `e2b_ex/process_info.ex` — `E2bEx.ProcessInfo` struct (`pid`, `tag`, `cmd`, `args`,
  `envs`, `cwd`) + `from_api/1`; returned by `list/2`.
- `e2b_ex/envd/connect.ex` — Connect-protocol framing (whole-body `decode_frames/1`,
  `encode_frame/1`, `trailer_error/1`).
- `e2b_ex/envd/connect/decoder.ex` — `E2bEx.Envd.Connect.Decoder`: pure **incremental**
  frame decoder (`new/0`, `push/2`) that buffers partial frames across network chunks.
  `decode_frames/1` is implemented on top of it.

## Conventions

- **Return shapes:** read calls return `{:ok, struct | [struct]}`; void/lifecycle calls
  return `:ok`; everything fails with `{:error, %E2bEx.Error{}}`.
- **Commands never raise on non-zero exit.** `run/4` (and `wait/1`) return
  `{:ok, %CommandResult{}}` for *any* exit code (check `exit_code`); this diverges
  intentionally from the JS/Python SDKs, whose `wait()` raises `CommandExitError`.
  `{:error, …}` is reserved for transport/non-2xx/trailer/malformed-framing failures.
  (Elixir idiom, like `System.cmd/3`.)
- **Background is message-first, not a transliterated SDK object.** `start/4` returns a
  handle and pushes output as `{ref, {:stdout|:stderr, _}}` / terminal
  `{ref, {:exit|:error, _}}` messages to a subscriber (Port / active-socket style).
  Consume the message stream **or** call `wait/1` (which drains it), not both. There are
  no polling getters and no callbacks running inside the handle process — `start/4`'s
  output is async, so it uses messages; `run/4`'s `:on_stdout`/`:on_stderr` are
  synchronous (run in the caller). One deliberate divergence: a 2xx stream that closes
  with **no `end` event** is `{:ok, exit_code: 0}` for `run/4` (Phase 1 contract
  preserved) but `{:error, "command ended without a result"}` for `wait/1`.
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
- Streaming uses `Req`'s `into: fun` reducer (blocking `run/4`) or `into: :self` (the
  background `HandleServer`, which then parses messages with `Req.parse_message/2`), both
  with `compressed: false` (with `into:` Req does not run its body-decompression step, so
  the client must not advertise gzip).
- **Streaming vs unary.** Only `Start` and `Connect` are server-streaming (enveloped
  `application/connect+json` frames). The control RPCs — `List`, `SendSignal` (kill),
  `SendInput` (stdin), `CloseStdin` — are **unary**: plain `application/json` POSTs with a
  bare JSON body, errors as HTTP non-2xx with a `{"code","message"}` body. `Envd.Rpc.unary/4`
  handles these (Req JSON-encodes/decodes them); `kill`'s `not_found`/404 → `{:ok, false}`.
  proto3 JSON: the `ProcessSelector` oneof serializes as `{"pid": N}`, `bytes` (stdin) as
  base64, the `Signal` enum as `"SIGNAL_SIGKILL"`.

## Testing

- `mix test` (121 tests as of Phase 2). `mix compile --warnings-as-errors` must stay clean.
- Central-API resources are tested with **`Req.Test`** (Plug-based stubs via
  `req_options: [plug: {Req.Test, Mod}]`).
- **`E2bEx.Commands` is tested with `Bypass`** (a real loopback HTTP server), NOT
  `Req.Test`. Reason: Req's plug adapter runs `Plug.Parsers` (JSON, `pass: ["*/*"]`)
  before the stub, and `application/connect+json` ends in `+json`, so it tries to
  JSON-decode the framed binary body and raises. Bypass avoids this and exercises the
  real wire. Commands tests use the `:base_url` opt to point at Bypass (also a legit
  self-hosted/proxy escape hatch). Streaming tests use `Plug.Conn.send_chunked/2` +
  `chunk/2` to split framed bytes across network chunks and prove incremental decoding.
- **The `disconnect/1` test** keeps the stream open with a keepalive-writing Bypass
  handler that uses `Process.flag(:trap_exit, true)` + an `{:EXIT, _, _}` arm: cancelling
  the client request closes the socket, and cowboy delivers the hangup to its handler as a
  `:shutdown` EXIT — the handler must catch it (not just a `chunk/2` `{:error, _}`) to exit
  cleanly so Bypass's `on_exit` doesn't re-raise.

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
- **`disconnect/1` must cancel the async response.** `HandleServer.terminate/2` calls
  `Req.cancel_async_response/1`. Finch's HTTP1 async streamer is `spawn_link`ed to the
  owner *and* monitors it, but a `:normal` owner exit does NOT kill it (link rule) — it
  only tears down on the next chunk or the receive timeout. So without the explicit
  cancel, `disconnect` would leave the envd connection lingering. Don't remove it.
- **`Error.code` is a string for envd Connect errors** (`"not_found"`, `"unavailable"`)
  but an integer for central-API errors (`404`). `@type code :: integer() | String.t() | nil`.
  `Rpc.kill/2` pattern-matches `%Error{code: "not_found"}`.

## Development workflow

This project is developed with the **superpowers** skills (brainstorming → writing-plans
→ subagent-driven-development → finishing-a-development-branch). Specs live in
`docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Work happens on feature
branches, reviewed in two stages (spec compliance, then code quality) per task.

## Roadmap — Commands feature parity (phased)

Bringing `E2bEx.Commands` to parity with the JS/Python SDKs, in sequence:

- **Phase 1 — DONE:** streaming foundation (incremental decoder + `on_stdout`/`on_stderr`).
  Spec: `docs/superpowers/specs/2026-06-11-e2b-commands-streaming-design.md`.
- **Phase 2 — DONE:** background execution — `start/4` → message-streaming
  `CommandHandle` (`wait`/`kill`/`disconnect`/`send_stdin`/`close_stdin`/`pid`), plus
  `connect/4` reconnect, `list/2`, and by-pid control. Added `HandleServer`, `Fold`,
  `Envd.Rpc`, `ProcessInfo` and the unary `SendSignal`/`SendInput`/`CloseStdin`/`List` +
  streaming `Connect` RPCs. (Message-first, not the SDKs' polling-object model.)
  Spec: `docs/superpowers/specs/2026-06-11-e2b-commands-background-design.md`.
- **Phase 3 — DONE:** PTY — `E2bEx.Pty` (`create`/`connect`/`send_input`/`resize`/
  `kill`) + `E2bEx.Pty.Handle`. Background-only (no blocking `run` analog); reuses
  `HandleServer` untouched. Added the `Update` (resize) RPC, the `SendInput` pty
  channel, and a `pty` (emit-only) branch in `Fold`. Note: there is **no** `Pty.list`
  (neither SDK has one; listing stays on `Commands`). Spec:
  `docs/superpowers/specs/2026-06-11-e2b-pty-design.md`; plan:
  `docs/superpowers/plans/2026-06-11-e2b-pty.md`. The two flagged refactors (shared
  `receive_timeout` constant; collapsing streaming-request construction into `Rpc`)
  remain deferred.
