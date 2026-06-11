# E2bEx PTY support — design (Phase 3)

**Status:** approved
**Date:** 2026-06-11
**Scope:** Add pseudo-terminal (PTY) support to `E2bEx`, reaching feature parity
with the JS/Python SDKs' `pty` namespace. PTY-only — no refactors folded in.

## Background

`E2bEx.Commands` runs commands as plain processes: stdout and stderr come back
as separate byte streams over pipes, with no terminal attached. A class of use
cases only works when the process has a **PTY** (pseudo-terminal): interactive
REPLs/shells (`bash -i`, `python`, `psql`), readline/curses/TUI apps (`vim`,
`htop`), and anything that switches behaviour on `isatty` or emits ANSI escape
codes. PTYs also have a settable size (rows/cols), which full-screen apps need.

The official SDKs expose a separate `pty` namespace. This phase adds the Elixir
equivalent, reusing the streaming machinery built in Phase 2.

### Key facts from the SDKs and the envd proto

- **`create` takes no command** — it always launches `/bin/bash -i -l` (an
  interactive login shell). You drive it by *sending input* (typing), not by
  passing a command string.
- **Output is one merged byte stream** — `ProcessEvent.DataEvent.pty` (raw
  `bytes`), separate from `stdout`/`stderr`, not split by channel.
- **Input uses a distinct field** — `ProcessInput.pty` (base64 bytes), not
  `stdin`.
- **Resize is the `Update` RPC** — `UpdateRequest{process: selector, pty: PTY}`,
  returns an empty `UpdateResponse`.
- **`PTY.Size`** is `{cols: uint32, rows: uint32}`. Set on `StartRequest.pty.size`
  at create and `UpdateRequest.pty.size` on resize.
- **Defaults** (both SDKs): envs `TERM=xterm-256color`, `LANG=C.UTF-8`,
  `LC_ALL=C.UTF-8` (only when the caller didn't supply them); connection timeout
  60s.
- **No `pty.list`** — neither SDK has one; PTY processes appear in the shared
  `Process/List` (via their `tag`), so listing stays on `E2bEx.Commands`.

PTY is **background-only** — there is no blocking `run`-style PTY call in the
SDKs — so it reuses `E2bEx.Commands.HandleServer` rather than the `run/4` path.

## Architecture

PTY maps cleanly onto the Phase 2 message-first design. `create`/`connect` hand
`HandleServer` a different request map (and the existing Start/Connect paths),
and the server streams the same way it does for commands. The only difference on
the wire is the data-event field (`pty` instead of `stdout`/`stderr`), which is
handled in the shared `Fold`. The handle is a distinct public struct so its API
is exactly what's valid for a PTY.

```
E2bEx.Pty            — public surface: create/connect/send_input/resize/kill
E2bEx.Pty.Handle     — %Pty.Handle{server, ref, pid, context}; send_input/resize/
                       kill/disconnect/wait/pid (backed by HandleServer)
E2bEx.Envd.Rpc       — + send_pty_input/3, resize/3, @update_path (kill/2 reused)
E2bEx.Commands.Fold  — + pty data-event branch (emit-only, no accumulation)
E2bEx.Commands.HandleServer — UNCHANGED (generic over Fold's emitted events)
```

## Public surface — `E2bEx.Pty`

Call shape mirrors `E2bEx.Commands` (`client, sandbox, …`):

```elixir
Pty.create(client, sandbox, opts \\ [])
  # → {:ok, %Pty.Handle{}} | {:error, %E2bEx.Error{}}
Pty.connect(client, sandbox, pid, opts \\ [])
  # → {:ok, %Pty.Handle{}} | {:error, %E2bEx.Error{}}
Pty.send_input(client, sandbox, pid, data, opts \\ [])
  # → :ok | {:error, %E2bEx.Error{}}
Pty.resize(client, sandbox, pid, %{cols: c, rows: r}, opts \\ [])
  # → :ok | {:error, %E2bEx.Error{}}
Pty.kill(client, sandbox, pid, opts \\ [])
  # → {:ok, boolean()} | {:error, %E2bEx.Error{}}
```

### `create` options

- **`:cols` (required), `:rows` (required)** — terminal size. If either is
  missing, raise `ArgumentError` (a programmer error, consistent with
  `Client.new/1` raising without `:api_key`). Not an `{:error, …}` runtime value.
- `:envs` — map merged over the PTY defaults. Defaults applied only when the key
  is absent: `TERM=xterm-256color`, `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`.
- `:cwd` — working directory; omitted from the request when nil.
- `:user` — same handling as the command path (Basic auth header).
- `:timeout_ms` — connection/stream timeout; same default as the command path.
- `:subscriber` — pid to receive messages; defaults to `self()`.

There is **no command argument** — `create` always runs `/bin/bash -i -l`.

## The handle — `E2bEx.Pty.Handle`

```elixir
defstruct [:server, :ref, :pid, :context]   # @enforce_keys all four
```

Same shape as `%E2bEx.CommandHandle{}` and backed by the same `HandleServer`,
but a distinct type exposing only PTY-valid operations:

```elixir
Pty.Handle.pid(h)            # → non_neg_integer()  (envd process id)
Pty.Handle.send_input(h, data)             # → Rpc.send_pty_input/3
Pty.Handle.resize(h, %{cols: c, rows: r})  # → Rpc.resize/3
Pty.Handle.kill(h)                         # → Rpc.kill/2 (reused)
Pty.Handle.disconnect(h)                   # → GenServer.stop(server) (reused pattern)
Pty.Handle.wait(h)
  # → {:ok, %CommandResult{}} | {:error, %E2bEx.Error{}}
```

No `close_stdin/1` — not part of the PTY surface.

`wait/1` drains the live `{ref, {:pty, _}}` messages from the caller's mailbox,
monitors the server, and returns on the terminal message:
`{:ok, %CommandResult{exit_code, error}}` for **any** exit code (stdout/stderr
empty — PTY output is not buffered), or `{:error, %Error{}}`. Returns
`{:error, %Error{message: "command handle terminated", reason: …}}` if the server
crashes. This is the same `wait_loop` as `CommandHandle.wait/1` with an added
arm draining `{:pty, _}` instead of `{:stdout|:stderr, _}`.

## Message model

The subscriber receives, tagged with the handle's `ref`:

```
{ref, {:pty, bytes}}                # merged terminal output, delivered live
{ref, {:exit, %E2bEx.CommandResult{}}}   # terminal, any exit code
{ref, {:error, %E2bEx.Error{}}}          # terminal, failure
```

Consume the message stream **or** call `wait/1` (which drains it) — not both
from the same process. Same contract as `CommandHandle`, with `:pty` replacing
`:stdout`/`:stderr`.

## Data flow

### create / connect

1. `Pty.create/3` validates `:cols`/`:rows`, merges default envs, builds the
   Start request map (below), and goes through the existing `spawn_handle`
   path with `@start_path` — returning a `%Pty.Handle{}` once the first `start`
   event yields the pid (or `{:error, …}` on a pre-start failure).
2. `Pty.connect/4` builds the Connect request map (`{process: {pid: pid}}`) and
   uses `@connect_path` the same way (identical to the command `connect`).
3. `HandleServer` owns the stream (`into: :self`), folds events via `Fold`, and
   pushes `{ref, {:pty, bytes}}` then the terminal message. No changes to
   `HandleServer`: it sends `{ref, {kind, bytes}}` for whatever `Fold` emits and
   captures the pid from the `start` event, so `:pty` events flow through with
   zero special-casing.

### Fold change (the only streaming-path change)

`Fold.apply_event/2` gains a branch for a `data` event carrying `pty`:

```elixir
# decoded event JSON: %{"data" => %{"pty" => "<base64>"}}
defp ... pty branch:
  case Base.decode64(b64) do
    {:ok, bytes} -> {:ok, t, [{:pty, bytes}]}   # emit only; accumulate nothing
    :error       -> {:error, :invalid_base64}
  end
```

It emits `{:pty, bytes}` and accumulates **nothing** into `%CommandResult{}`
(same `:invalid_base64` guard as the stdout/stderr branches). The existing
stdout/stderr branches, the `end`-event handling (sets `exit_code`, default 0),
and `%CommandResult{}` itself are unchanged.

### send_input / resize / kill (unary)

`E2bEx.Envd.Rpc` gains:

- `send_pty_input(ctx, pid, data)` — unary `SendInput`, body
  `%{"process" => %{"pid" => pid}, "input" => %{"pty" => Base.encode64(data)}}`.
  Mirrors the existing `send_stdin/3` but with the `pty` input field.
- `resize(ctx, pid, %{cols: c, rows: r})` — unary `Update` at the new
  `@update_path "/process.Process/Update"`, body
  `%{"process" => %{"pid" => pid}, "pty" => %{"size" => %{"cols" => c, "rows" => r}}}`.
  Empty `UpdateResponse` on success; non-2xx → `{:error, %Error{}}` like the
  other unary control RPCs.
- `kill/2` — reused unchanged (`SendSignal` SIGKILL; `not_found`/404 →
  `{:ok, false}`).

## Request shapes (proto3 JSON, following existing `start_request/2` conventions)

```elixir
# create (Start)
%{
  "process" => %{
    "cmd"  => "/bin/bash",
    "args" => ["-i", "-l"],
    "envs" => merged_envs,        # TERM/LANG/LC_ALL defaults + caller envs
    "cwd"  => cwd                 # omitted when nil
  },
  "pty" => %{"size" => %{"cols" => cols, "rows" => rows}}
}

# resize (Update)
%{"process" => %{"pid" => pid}, "pty" => %{"size" => %{"cols" => c, "rows" => r}}}

# send_input (SendInput)
%{"process" => %{"pid" => pid}, "input" => %{"pty" => Base.encode64(data)}}
```

`stdin` is **not** set on the create request — PTY input flows through the `pty`
channel, matching the SDKs.

## Error handling

- Missing `:cols`/`:rows` on `create` → raise `ArgumentError` (programmer error).
- Transport / non-2xx / trailer / malformed-framing failures →
  `{:error, %E2bEx.Error{}}`, exactly as the command path. The truncated-2xx,
  `command failed to start`, and `command ended without a result` paths in
  `HandleServer` apply unchanged.
- A PTY exiting with a non-zero code is **not** an error: `wait/1` returns
  `{:ok, %CommandResult{exit_code: n}}` (check `exit_code`), consistent with the
  rest of `E2bEx.Commands`.
- `send_input`/`resize`/`kill` on a dead process → the envd unary error surfaces
  as `{:error, %Error{}}` (or `{:ok, false}` for `kill`'s `not_found`).

## Files

- **Create:** `lib/e2b_ex/pty.ex` (`E2bEx.Pty`)
- **Create:** `lib/e2b_ex/pty/handle.ex` (`E2bEx.Pty.Handle`)
- **Modify:** `lib/e2b_ex/envd/rpc.ex` (`send_pty_input/3`, `resize/3`,
  `@update_path`)
- **Modify:** `lib/e2b_ex/commands/fold.ex` (pty data-event branch)
- **Unchanged:** `lib/e2b_ex/commands/handle_server.ex`,
  `lib/e2b_ex/command_result.ex`

## Testing

Same approach as `E2bEx.Commands`: **Bypass** (real loopback HTTP server), not
`Req.Test` — Req's plug adapter JSON-parses `application/connect+json` bodies and
raises on the framed binary. Point tests at Bypass via the `:base_url` opt.
Streaming tests use `Plug.Conn.send_chunked/2` + `chunk/2` to split framed bytes
across network chunks.

- `test/e2b_ex/commands/fold_test.exs` (additions): a `pty` data event emits
  `{:pty, bytes}` and accumulates nothing into the result; invalid base64 in a
  `pty` event → `{:error, :invalid_base64}`; an `end` event after pty data still
  sets `exit_code`.
- `test/e2b_ex/envd/rpc_test.exs` (additions): `send_pty_input/3` posts
  `input.pty` base64; `resize/3` posts the `Update` body shape to `@update_path`;
  non-2xx `Update`/`SendInput` → `{:error, %Error{}}`.
- `test/e2b_ex/pty_test.exs` (new): `create` streams `{:pty, _}` then `{:exit}`;
  `create` raises `ArgumentError` without `:cols`/`:rows`; default envs merged
  and caller envs win; `connect` reattaches by pid; `send_input`/`resize`/`kill`
  hit the right unary endpoints; `disconnect` cancels the async response (the
  same trap_exit Bypass handler pattern as the commands disconnect test).
- `test/e2b_ex/pty/handle_test.exs` (new): `wait/1` drains `{:pty, _}` and
  returns `{:ok, %CommandResult{exit_code}}`; `wait/1` returns `{:error, …}` on
  server crash; `send_input`/`resize`/`kill`/`pid` route through the context.

`mix test` must stay green and `mix compile --warnings-as-errors` must stay
clean.

## Out of scope

- The two previously-flagged refactors (sharing the
  `receive_timeout(ms) -> ms + 5_000` constant; collapsing the streaming-request
  construction from `Commands.run/4` and `HandleServer.handle_continue` into
  `Rpc`). Deferred to a separate cleanup pass to keep this diff PTY-only.
- Any blocking `run`-style PTY call (no SDK analog).
- `Pty.list` (no SDK analog; listing stays on `E2bEx.Commands`).
