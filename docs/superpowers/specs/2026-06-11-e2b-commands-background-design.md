# E2bEx Commands — Phase 2: Background execution, handle & control RPCs (Design)

**Date:** 2026-06-11
**Status:** Approved (pending implementation plan)

## Context

**Phase 2 of 3** in bringing `E2bEx.Commands` to feature parity with the E2B JS
and Python SDKs. Phase 1 (shipped) added the incremental Connect frame decoder
and `on_stdout`/`on_stderr` streaming callbacks on the blocking `run/4`. Phase 2
adds **background execution**: starting a command, streaming its output as
messages, waiting for the result, and controlling a running process (kill, stdin,
reconnect, list). Phase 3 (later) is PTY.

Reference SDKs (read for behavior, not for structure — see "Idiom" below):
JS `packages/js-sdk/src/sandbox/commands/{index.ts,commandHandle.ts}`, Python
`packages/python-sdk/e2b/sandbox_sync/commands/{command.py,command_handle.py}`,
proto `spec/envd/process/process.proto` (all under `/Users/col/Projects/E2B`).

### Idiom: message-first, not a transliterated SDK object

The JS/Python `CommandHandle` is a mutable object you poll (`handle.stdout`,
`handle.exitCode`) with output delivered via callbacks. Transliterating that to
Elixir would be unidiomatic: polling a process for accumulated state is an
anti-pattern, and running user callbacks **inside** the streaming process risks
stalling/crashing it. This design instead follows Elixir conventions (Ports,
active-mode sockets, `Task`): a process owns the stream and **pushes output as
messages** to a subscriber; the result comes from a terminal message or `wait/1`.
There are **no live pull-getters**.

A stream-owning **process** is still the right primitive (not a bare `Task`):
the envd process `pid` only arrives in the first `start` event, so something must
hold it mid-run to support `kill`/`send_stdin`. The control RPCs themselves are
independent unary calls keyed by pid, so they do **not** run through the stream
process.

### Decisions carried from brainstorming

| Decision | Choice |
|---|---|
| Background entry point | A distinct `start/4` returning `{:ok, %CommandHandle{}}`; `run/4` stays blocking. (No return type that varies by option.) |
| `run/4` internals | Keep `run/4`'s standalone synchronous `into: fun` path; extract the shared event-folding into one module both paths use. (No process spawned for a simple blocking command.) |
| Output delivery & handle | Messages to a subscriber pid + `wait/1`. No callbacks inside the handle process, no live getters. |
| Exit handling | `wait/1` / terminal message returns `{:ok, %CommandResult{}}` for any exit code; `{:error, %E2bEx.Error{}}` only for transport/protocol failures. (Consistent with Phase 1.) |

## Protocol note: streaming vs unary

In the Connect protocol only **`Start`** and **`Connect`** are server-streaming —
enveloped `application/connect+json` frames with the end-of-stream trailer, as in
Phase 1. The control RPCs — **`List`, `SendSignal` (kill), `SendInput` (stdin),
`CloseStdin`** — are **unary**: a plain `application/json` POST with a bare JSON
body and a bare JSON response; errors are HTTP non-2xx with a Connect error body
`{"code","message"}`. Unary calls therefore use ordinary Req JSON
encoding/decoding (no envelope, no `decode_body: false`), against the same envd
host with the same envd auth headers.

Request bodies (proto3 JSON; `ProcessSelector` oneof serialises as the field name,
`bytes` as base64, the `Signal` enum as its value name):

- `POST /process.Process/List` — `{}` → `{"processes": [{"config": {...}, "pid": N, "tag": "..."}]}`
- `POST /process.Process/SendSignal` — `{"process": {"pid": N}, "signal": "SIGNAL_SIGKILL"}` → `{}`
- `POST /process.Process/SendInput` — `{"process": {"pid": N}, "input": {"stdin": "<base64>"}}` → `{}`
- `POST /process.Process/CloseStdin` — `{"process": {"pid": N}}` → `{}`
- `POST /process.Process/Connect` (streaming) — `{"process": {"pid": N}}` → frame stream (like `Start`)

## Public API

### `E2bEx.Commands` (additions; `run/4` unchanged)

```elixir
start(client, sandbox, command, opts \\ []) :: {:ok, CommandHandle.t()} | {:error, Error.t()}
connect(client, sandbox, pid, opts \\ []) :: {:ok, CommandHandle.t()} | {:error, Error.t()}
list(client, sandbox, opts \\ []) :: {:ok, [ProcessInfo.t()]} | {:error, Error.t()}
kill(client, sandbox, pid, opts \\ []) :: {:ok, boolean()} | {:error, Error.t()}
send_stdin(client, sandbox, pid, data, opts \\ []) :: :ok | {:error, Error.t()}
close_stdin(client, sandbox, pid, opts \\ []) :: :ok | {:error, Error.t()}
```

`start/4` opts: `:subscriber` (pid to receive output messages; default the calling
process), `:stdin` (bool, default `false`), `:cwd`, `:envs`, `:user`,
`:timeout_ms`, `:domain`, `:port`, `:base_url`. (No `:on_stdout`/`:on_stderr` —
those belong to the synchronous `run/4`.) `connect/4` opts: `:subscriber`,
`:timeout_ms`, `:domain`, `:port`, `:base_url`. The by-pid opts on
`list`/`kill`/`send_stdin`/`close_stdin` are the connection passthroughs
(`:domain`, `:port`, `:base_url`).

`kill` returns `{:ok, false}` specifically on the Connect `not_found` code (the
process is already gone), `{:ok, true}` on success, matching the SDKs' boolean.

### `E2bEx.CommandHandle`

```elixir
%E2bEx.CommandHandle{server: pid(), ref: reference(), pid: integer(), context: map()}

wait(handle) :: {:ok, CommandResult.t()} | {:error, Error.t()}
kill(handle) :: {:ok, boolean()} | {:error, Error.t()}
send_stdin(handle, data) :: :ok | {:error, Error.t()}
close_stdin(handle) :: :ok | {:error, Error.t()}
disconnect(handle) :: :ok
pid(handle) :: integer()
```

`kill/1`, `send_stdin/2`, `close_stdin/1` run in the **caller's** process via the
stored `context` + `pid` (delegating to the matching `Commands` by-pid function) —
they never touch the stream process. `wait/1` and `disconnect/1` talk to
`handle.server`. `pid/1` reads the struct.

### Output messages (to the subscriber)

Tagged with the handle's unique `ref` (mirrors `{port, _}` / `{task_ref, result}`):

```elixir
{ref, {:stdout, binary}}
{ref, {:stderr, binary}}
{ref, {:exit, %E2bEx.CommandResult{}}}   # terminal — success path, any exit code
{ref, {:error, %E2bEx.Error{}}}          # terminal — failure path
```

After the terminal message the stream process stops normally.

### `E2bEx.ProcessInfo`

```elixir
%E2bEx.ProcessInfo{
  pid: integer(),
  tag: String.t() | nil,
  cmd: String.t(),
  args: [String.t()],
  envs: %{String.t() => String.t()},
  cwd: String.t() | nil
}
```

`from_api/1` maps a `ListResponse` process entry (`config.cmd`, `config.args`,
`config.envs`, `config.cwd`, top-level `pid`, optional `tag`).

## Consuming a background command — use one, not both

- **Stream:** `receive`-loop the `{ref, …}` messages until `{:exit, _}`/`{:error, _}`.
- **`wait/1`:** convenience receive-loop in the subscriber that **drains** the
  intermediate `{ref, {:stdout|:stderr, _}}` messages (so they don't pile up in the
  mailbox) and returns on the terminal message, returning `{:ok, result}` /
  `{:error, error}`. It also monitors `handle.server` and returns `{:error,
  %Error{}}` if the server goes `:DOWN` without a terminal message. `wait/1` must be
  called from the subscriber process (the one holding the messages).

## Architecture / modules

- **`E2bEx.Commands.Fold`** (`lib/e2b_ex/commands/fold.ex`, pure) — the
  event-folding logic, extracted from Phase 1's inline `apply_event`/`decode_chunk`.
  Delivery-agnostic: folds a decoded `StartResponse`/`ConnectResponse` event into a
  `%CommandResult{}` accumulator and returns the produced output events so the caller
  delivers them however it likes.
  - `new() :: acc` — initial accumulator wrapping `%CommandResult{}`.
  - `apply_event(acc, event_map) :: {:ok, acc, [output]} | {:error, reason}` where
    `output` is `{:stdout, binary} | {:stderr, binary}` and `reason` is
    `:invalid_base64`. `data` events base64-decode and emit an output; the `end`
    event sets `exit_code` (default `0`) and `error`; other events (e.g. `start`,
    `keepalive`) are ignored and emit no output.
  - `result(acc) :: CommandResult.t()`.
  - `run/4` calls `apply_event` and turns each `output` into an `on_stdout`/
    `on_stderr` callback; `HandleServer` turns each into a `{ref, …}` message.
  - The **trailer** is not a `Fold` concern: it comes from `Decoder.push/2`, and both
    callers map it with `Connect.trailer_error/1` (see below).

- **`E2bEx.Envd.Rpc`** (`lib/e2b_ex/envd/rpc.ex`, internal) — the envd request layer.
  - `context(client, sandbox, opts) :: {:ok, ctx} | {:error, Error.t()}` — validates
    `sandbox.sandbox_id`, resolves `domain`/`port`/`base_url`, and builds the shared
    envd headers (`e2b-sandbox-id`, `e2b-sandbox-port`, `connect-protocol-version`,
    `keepalive-ping-interval`, conditional `x-access-token` from
    `envd_access_token`, conditional `connect-timeout-ms`, conditional
    `authorization: Basic` from `:user`). `ctx` carries `base_url`, `headers`,
    `sandbox_id`, `port`, `timeout_ms`, and `req_options` (from the client). This
    replaces the header/URL building currently inline in `Commands`.
  - `unary(ctx, path, request_map, opts) :: {:ok, map()} | {:error, Error.t()}` —
    `POST` bare JSON (`content-type: application/json`) to the envd `path`, merging
    `ctx.req_options`, `retry: false`. On 2xx returns the decoded body map; on
    non-2xx returns `Error.from_response/1` (whose `code`/`message` come from the
    Connect error body).
  - Context-based control wrappers built on `unary/4`, so both the `Commands`
    by-pid functions and `CommandHandle` can call them without depending on each
    other:
    - `kill(ctx, pid) :: {:ok, boolean()} | {:error, Error.t()}` — `SendSignal`
      SIGKILL; maps a `not_found` Connect error to `{:ok, false}`, 2xx to `{:ok, true}`.
    - `send_stdin(ctx, pid, data) :: :ok | {:error, Error.t()}` — `SendInput` with
      `input.stdin` base64-encoded.
    - `close_stdin(ctx, pid) :: :ok | {:error, Error.t()}` — `CloseStdin`.
    - `list(ctx) :: {:ok, [map()]} | {:error, Error.t()}` — `List`; returns the raw
      `processes` maps (the caller maps them through `ProcessInfo.from_api/1`).

- **`E2bEx.Commands.HandleServer`** (`lib/e2b_ex/commands/handle_server.ex`,
  GenServer, internal) — owns exactly one `Start`/`Connect` stream.
  - Started by `Commands.start/4` / `connect/4` with
    `{ctx, path, request_frame, subscriber, ref, timeout_ms}`. Unlinked
    (`GenServer.start`).
  - `init/1` returns fast and issues the Req request in a `handle_continue` (so
    starting doesn't block the caller): `into: :self`, `content-type:
    application/connect+json`, `compressed: false`, `retry: false`, and the receive
    timeout derived from `timeout_ms` (as in Phase 1).
  - `handle_info` consumes Req's streamed messages via `Req.parse_message/2`,
    feeding the incremental `Connect.Decoder` and `Fold`. The first `start` event
    captures the envd pid and replies to a stashed `:await_start` caller. Each
    output event is sent to the subscriber as `{ref, {:stdout|:stderr, _}}`. On the
    `end` event + end-of-stream (or a trailer/transport/malformed error) it sends
    the terminal `{ref, {:exit, result}}` / `{ref, {:error, error}}` and stops
    normally.
  - `handle_call(:await_start, ...)` replies with `{:ok, pid}` once the start event
    arrives, or `{:error, %Error{}}` if the stream errors/closes first.
  - `disconnect` is `GenServer.stop/1` — terminating the process closes the Req
    connection without sending SIGKILL; no terminal message is emitted.
  - Holds no control logic (kill/stdin are independent unary calls).

- **`E2bEx.CommandHandle`** (`lib/e2b_ex/command_handle.ex`) — the struct and the
  user-facing functions. `wait/1` is the draining receive-loop described above;
  `kill/1`/`send_stdin/2`/`close_stdin/1` delegate to `Rpc.kill/2`/`send_stdin/3`/
  `close_stdin/2` using `handle.context` and `handle.pid` (so `CommandHandle`
  depends on `Rpc`, not on `Commands`); `disconnect/1` stops the server; `pid/1`
  reads the struct.

- **`E2bEx.ProcessInfo`** (`lib/e2b_ex/process_info.ex`) — struct + `from_api/1`.

- **`E2bEx.Envd.Connect`** (`lib/e2b_ex/envd/connect.ex`) — gains
  `trailer_error/1` (moved from `Commands`, since it is Connect-protocol logic):
  `%{"error" => err} -> %Error{}`, else `nil`. Shared by `run/4` and `HandleServer`.

- **`E2bEx.Commands`** (`lib/e2b_ex/commands.ex`) — gains `start/4`, `connect/4`,
  `list/2`, `kill/4`, `send_stdin/5`, `close_stdin/4`. Refactored so `run/4` uses
  `Rpc.context/3` + `Fold` + `Connect.trailer_error/1` (behaviour unchanged).
  `start/4`/`connect/4` build the context, start a `HandleServer`, and
  `GenServer.call(server, :await_start, _)` before returning the handle. The by-pid
  control functions build the context with `Rpc.context/3` and delegate to the
  matching `Rpc` control wrapper (`list/2` maps the result via
  `ProcessInfo.from_api/1`).

## Data flow

**`start/4`:** `Rpc.context` → `GenServer.start(HandleServer, {...})` →
`GenServer.call(server, :await_start, await_timeout)` where `await_timeout` is
`timeout_ms` (or `:infinity` when `timeout_ms == 0`) — if the command never starts
within that window the call times out and `start/4` returns `{:error, %Error{}}`.
The server issues the `Start` stream, awaits the `start` event, replies with the
pid (or an error). `start/4` returns
`{:ok, %CommandHandle{server, ref, pid, context}}`.

**streaming:** Req `into: :self` → `handle_info` → `Req.parse_message` →
`Decoder.push` → `Fold.apply_event` per message → subscriber messages → terminal
message → `:stop`.

**`wait/1`:** receive-loop in the subscriber draining `{ref, {:stdout|:stderr, _}}`,
returning on `{ref, {:exit, result}}` / `{ref, {:error, error}}`, with a
`Process.monitor(server)` guard for `:DOWN`.

**control (`kill`/`send_stdin`/`close_stdin`):** build/stored ctx → the matching
`Rpc` control wrapper (which calls `Rpc.unary`). `Rpc.kill/2` inspects the error
for the `not_found` code.

**`list/2`:** `Rpc.context` → `Rpc.list(ctx)` (`/process.Process/List`, `{}`) → map
each process entry through `ProcessInfo.from_api/1`.

**`connect/4`:** like `start/4` but the `Connect` stream; the `start` event's pid
equals the requested pid.

## Error handling

| Situation | Result |
|---|---|
| `start`/`connect` stream errors or closes before the `start` event | `start/4`/`connect/4` → `{:error, %Error{}}` |
| Command ran (any exit code) | terminal `{ref, {:exit, %CommandResult{}}}`; `wait/1` → `{:ok, …}` |
| Transport drop / non-2xx / trailer Connect error / malformed framing mid-stream | terminal `{ref, {:error, %Error{}}}`; `wait/1` → `{:error, …}` |
| Stream closed with no `end` event | terminal `{ref, {:error, %Error{message: "command ended without a result"}}}` |
| `HandleServer` crashes before terminal | `wait/1` `:DOWN` guard → `{:error, %Error{}}` |
| `kill` on an already-gone pid | `{:ok, false}` (Connect `not_found`) |
| `kill`/`send_stdin`/`close_stdin`/`list` other failure | `{:error, %Error{}}` |
| `send_stdin`/`close_stdin` without `start(stdin: true)` | envd rejects → `{:error, %Error{}}` surfaced as-is |

`%E2bEx.Error{}` and `%E2bEx.CommandResult{}` gain no new fields.

## Testing

- **`E2bEx.Commands.Fold`** (pure): a `data`/stdout event base64-decodes and emits
  `{:stdout, bytes}`; stderr likewise; the `end` event sets `exit_code` (and
  defaults it to `0` when omitted) and `error`; an invalid-base64 chunk →
  `{:error, :invalid_base64}`; `result/1`/`trailer/1` return the folded state.
- **`E2bEx.Envd.Rpc.unary`** (Bypass): the right path receives a bare-JSON body with
  the envd headers (`x-access-token`, `e2b-sandbox-id`, …) and `content-type:
  application/json`; a 2xx JSON body is returned decoded; a non-2xx Connect error
  body becomes `%Error{code, message, status}`.
- **`E2bEx.ProcessInfo.from_api/1`**: maps a `ListResponse` entry (nested `config`)
  to the struct, including a missing `cwd`/`tag`.
- **control RPCs** (Bypass): `Commands.kill/4` → `{:ok, true}` on 2xx and
  `{:ok, false}` on a `not_found` error; `send_stdin/5` base64-encodes the data into
  `input.stdin` and returns `:ok`; `close_stdin/4` posts the selector and returns
  `:ok`; `list/2` returns `[%ProcessInfo{}]`.
- **`start/4` + streaming + `wait/1`** (Bypass, **chunked**): the request hits
  `/process.Process/Start`; `start/4` returns a handle whose `pid` came from the
  `start` event; output arrives as `{ref, {:stdout, _}}` / `{ref, {:stderr, _}}`
  messages **in order** across network chunks; the terminal `{ref, {:exit, result}}`
  carries the accumulated stdout/stderr and exit code; `wait/1` drains and returns
  `{:ok, %CommandResult{}}`; a non-zero exit still yields `{:ok, exit_code: n}`.
- **error paths** (Bypass): a trailer Connect error and a non-2xx status each yield a
  terminal `{ref, {:error, %Error{}}}` and `wait/1` → `{:error, _}`; a 2xx stream that
  ends with no `end` event → `wait/1` → `{:error, %Error{message: "command ended
  without a result"}}`.
- **`disconnect/1`** (Bypass): after `disconnect/1` the server process is down and no
  terminal message is delivered to the subscriber.
- **`connect/4`** (Bypass): hits `/process.Process/Connect` and returns a handle whose
  `wait/1` yields the result.
- **`run/4` regression**: all Phase 1 command tests stay green after the `Fold` /
  `Rpc` extraction (behaviour unchanged).

Bypass remains the tool (real loopback HTTP; `Req.Test` can't carry
`application/connect+json`). Streaming tests use `Plug.Conn.send_chunked/2` +
`chunk/2`; the `:base_url` opt points the envd request at Bypass.

## Dependencies

No new dependencies. Runtime uses `Req` (`into: :self` for streaming,
`Req.parse_message/2`, ordinary JSON for unary) and `Jason`; tests use `Bypass`.

## Out of scope (Phase 3)

PTY (`create`/`connect`/`send_stdin`/`resize`/`kill`/`list`) and the `Update`
(resize) RPC. The client-streaming `StreamInput` RPC and process `tag` selectors
are not needed for Phase 2 and are deferred.
