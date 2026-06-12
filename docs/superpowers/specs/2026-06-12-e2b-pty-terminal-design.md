# E2bEx PTY interactive terminal — design

**Status:** approved
**Date:** 2026-06-12
**Depends on:** the PTY feature (`E2bEx.Pty` / `E2bEx.Pty.Handle`), currently on
branch `feat/pty` (PR #1). This work branches from `feat/pty` as
`feat/pty-terminal`.

## Goal

A `mix e2b.terminal` task that opens a **real interactive terminal** into a
sandbox PTY from a normal shell (run *outside* `iex`): local keystrokes are
forwarded raw to the remote shell, and the remote terminal output is written
straight to the local terminal — arrow keys, tab-completion, `vim`/`htop`, and
Ctrl-C all work.

## Background & constraint

The earlier ergonomics ask was "run a PTY in an IEx session, auto-print output
and auto-forward keystrokes." Inside `iex` that is only achievable in a
line-buffered form, because the BEAM's tty driver owns stdin. A *full* terminal
(char-by-char, escape sequences, TUI apps) requires putting the terminal into
**raw mode**, which can't be done cleanly from within `iex`. So this is a
standalone CLI (a Mix task) that runs outside `iex` and owns the terminal.

Reference: the E2B CLI's `packages/cli/src/terminal.ts`
(`spawnConnectedTerminal`), which does: `stdin.setRawMode(true)` →
`pty.create({onData → stdout, cols, rows, timeoutMs: 0})` → batch stdin (10ms) →
`pty.sendInput` → `stdout 'resize'` → `pty.resize` → `wait()` → restore raw mode
in `finally`. This design ports that, accommodating two BEAM differences:

- **No `setRawMode`** — shell out to `stty` on the controlling terminal.
- **No `SIGWINCH`** — OTP's `:os.set_signal/2` does not support `SIGWINCH`, so
  live resize is driven by **polling** `stty size` (~500ms) instead of a signal.

## Architecture

Three units with clean boundaries:

```
Mix.Tasks.E2b.Terminal   — CLI: args, api-key, sandbox resolve/create, raw-tty
  (lib/mix/tasks/         setup+restore, kill-on-exit. Owns ALL real side effects.
   e2b.terminal.ex)       Thin wrapper; delegates the session to Terminal.

E2bEx.Pty.Terminal        — session orchestrator (the spawnConnectedTerminal
  (lib/e2b_ex/pty/         analog). Given a %Pty.Handle{} + injectable IO hooks,
   terminal.ex)           runs output-loop + reader + size-poller + batcher,
                          returns {:ok, %CommandResult{}} | {:error, %Error{}}.

E2bEx.Pty.InputBatcher    — GenServer: accumulate bytes, flush every N ms via a
  (lib/e2b_ex/pty/         callback. The reference's BatchedQueue. Knows nothing
   input_batcher.ex)      about PTYs (bytes + flush fun only).
```

`InputBatcher` knows nothing about PTYs; `Terminal` knows nothing about
`stty`/Mix; the Mix task owns every real-world side effect. The BEAM-specific tty
wrinkles are quarantined in one thin, manually-verified file.

## Component: `E2bEx.Pty.InputBatcher`

A GenServer that coalesces rapid keystrokes (and multi-byte escape sequences like
the 3-byte arrow keys) into a single `send_input`, reducing one-HTTP-call-per-byte.

- `start_link(opts)` — `:flush_ms` (default 10), `:on_flush` (`(binary -> any)`).
- `push(server, bytes)` — append `bytes` (binary) to the buffer (a cast).
- On a `:flush_ms` timer: if the buffer is non-empty, call `on_flush.(buffer)` and
  clear it. (Empty intervals do nothing.)
- `stop(server)` — flush any remainder, then stop.

State: `%{buffer: iodata/binary, flush_ms, on_flush}`. The timer reschedules
itself (`Process.send_after`).

## Component: `E2bEx.Pty.Terminal`

`run(handle, opts) :: {:ok, CommandResult.t()} | {:error, Error.t()}`

Runs in the process that owns the PTY subscription (so it receives
`{ref, {:pty, _}}`). `opts` carries injectable hooks so the logic is testable
without a real terminal:

- `:write` — `(binary -> any)`, default `&IO.binwrite(:stdio, &1)`.
- `:read_byte` — `(-> binary | :eof)`, default `fn -> IO.binread(:stdio, 1) end`.
  Called in a tight loop by the reader process.
- `:size` — `(-> {cols, rows} | :error)`, default reads `stty size </dev/tty`.
- `:poll_ms` — size-poll interval, default 500.
- `:flush_ms` — batcher flush interval, default 10.

Flow:
1. Start an `InputBatcher` whose `on_flush` calls
   `E2bEx.Pty.Handle.send_input(handle, bytes)`.
2. Spawn a **linked reader** process: loop `read_byte.()`, `InputBatcher.push/2`
   each byte; exit the loop on `:eof`. (In raw mode local Ctrl-D is just a byte
   forwarded to the remote, so `:eof` is not the normal exit — the remote shell
   ending is.)
3. Spawn a **linked size poller**: every `poll_ms`, call `size.()`; if it changed
   since last, `E2bEx.Pty.Handle.resize(handle, %{cols: c, rows: r})`.
4. **Output loop** (in the calling process): `Process.monitor` the handle server,
   then `receive`:
   - `{ref, {:pty, bytes}}` → `write.(bytes)`, recurse.
   - `{ref, {:exit, %CommandResult{} = r}}` → `{:ok, r}`.
   - `{ref, {:error, %Error{} = e}}` → `{:error, e}`.
   - `{:DOWN, mon, :process, _, reason}` →
     `{:error, %Error{message: "terminal session terminated", reason: reason}}`.
5. **Always** (an `after`/cleanup around the loop): stop the poller and reader
   (link + `Process.exit(pid, :kill)` — they may be blocked in `read_byte`),
   `InputBatcher.stop/1` (final flush), `Process.demonitor(mon, [:flush])`.

`Terminal.run/2` does **not** touch the tty or `stty` — that is the Mix task's
job. It is pure orchestration over its hooks + the handle.

## Component: `Mix.Tasks.E2b.Terminal`

`mix e2b.terminal SANDBOX_ID` or `mix e2b.terminal --template <tmpl>`.

```
run(argv):
  {opts, args} = OptionParser.parse(argv,
    strict: [template: :string, api_key: :string],
    aliases: [t: :template])
  api_key = opts[:api_key] || System.get_env("E2B_API_KEY")
            || Application.get_env(:e2b_ex, :api_key) || raise (usage)
  Application.ensure_all_started(:e2b_ex)   # Req/Finch etc.
  client = E2bEx.client(api_key: api_key)

  {sandbox, created?} =
    cond do
      args != []        -> {connect(client, hd(args)), false}
      opts[:template]   -> {create(client, opts[:template]), true}
      true              -> halt with usage
    end

  {cols, rows} = terminal_size()            # stty size </dev/tty
  orig = save_tty()                         # stty -g </dev/tty
  try do
    raw_tty()                               # stty raw -echo </dev/tty
    {:ok, handle} =
      E2bEx.Pty.create(client, sandbox, cols: cols, rows: rows, timeout_ms: 0)
    _result = E2bEx.Pty.Terminal.run(handle, [])
    IO.binwrite(:stdio, "\n")
  after
    restore_tty(orig)                       # stty <orig> </dev/tty
    if created?, do: E2bEx.Sandboxes.kill(client, sandbox.sandbox_id)
  end
```

- `connect/2` → `E2bEx.Sandboxes.connect(client, id, 60)` (token-bearing).
- `create/2` → `E2bEx.Sandboxes.create(client, %{templateID: tmpl})` then ensure
  it is token-bearing (create returns the token).
- tty helpers use `:os.cmd(~c"stty ... </dev/tty")` so they act on the controlling
  terminal regardless of how the BEAM set up stdio. `terminal_size/0` parses
  `"rows cols\n"`.

`@shortdoc` / `@moduledoc` document usage, the "exit by ending the remote shell
(`exit` / Ctrl-D)" behavior, and that an abrupt `kill -9` may leave the terminal
raw (run `reset`).

## Exit, cleanup & error handling

- **No local detach key** (matches the reference). Leave by ending the remote
  shell; that ends the PTY, `run/2` returns, the task unwinds.
- The session is wrapped in `try/after` so the tty is restored on normal exit and
  on a crash. `kill -9` can still leave it raw — documented, unavoidable.
- A non-zero remote exit is **not** an error: `run/2` returns `{:ok,
  %CommandResult{exit_code: n}}` (consistent with the rest of `E2bEx.Pty`).
- A failed sandbox connect/create surfaces as a printed error + non-zero task
  exit (`Mix.raise/1`), before any tty change.

## Testing

- **`InputBatcher`** (unit): push bytes → after one interval, `on_flush` fires
  once with the concatenated batch; an empty interval fires nothing; multiple
  pushes within an interval coalesce; `stop/1` flushes the remainder and stops.
- **`E2bEx.Pty.Terminal.run/2`** (Bypass-backed handle + injected hooks):
  - output: feeding `{ref, {:pty, "a"}}`/`{:pty, "b"}` messages writes `"a"`,
    `"b"` in order to the injected writer; a `{ref, {:exit, result}}` returns
    `{:ok, result}`.
  - input: bytes from the fake `read_byte` are batched and POST to envd
    `SendInput` with `input.pty` (asserted on Bypass), concatenated within a
    flush window.
  - resize: a `size` fun returning a changed `{cols, rows}` triggers a POST to
    envd `Update` (asserted on Bypass); an unchanged size does not.
  - crash: killing the handle server makes `run/2` return `{:error, %Error{}}`.
  Use short `:flush_ms`/`:poll_ms` and a controllable fake handle (its `context`
  pointed at Bypass; a dummy `server` pid we can kill).
- **Mix task**: a thin wrapper over real `stty`/stdio/sandbox lifecycle, verified
  manually (documented smoke test: `mix e2b.terminal --template base`). Only its
  pure arg/api-key/sandbox-resolution helper, if cleanly factored, gets a unit
  test (e.g. missing api key → raises; id vs `--template` selection). No automated
  test drives a real raw terminal.

## Out of scope

- A line-mode in-`iex` console (the rejected option 1).
- A local detach/prefix key (`tmux`-style) — exit via the remote shell.
- Trapping `SIGWINCH` (unsupported by OTP) — superseded by size polling.
- Windows/non-POSIX `stty` handling — POSIX (`stty`, `/dev/tty`) only.
- `--keep` (don't kill a `--template`-created sandbox) — created sandboxes are
  always killed on exit in v1.

## Files

- Create: `lib/e2b_ex/pty/input_batcher.ex`, `lib/e2b_ex/pty/terminal.ex`,
  `lib/mix/tasks/e2b.terminal.ex`
- Test: `test/e2b_ex/pty/input_batcher_test.exs`,
  `test/e2b_ex/pty/terminal_test.exs`
- Docs: update `README.md` (a `mix e2b.terminal` section).
