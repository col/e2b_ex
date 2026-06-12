# E2bEx

An Elixir client for the [E2B](https://e2b.dev) API, covering Sandboxes,
Templates, and Tags. Built on [`Req`](https://hex.pm/packages/req).

## Installation

Add `e2b_ex` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:e2b_ex, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
client = E2bEx.client(api_key: "e2b_...")

{:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})
{:ok, sandboxes} = E2bEx.Sandboxes.list(client)
:ok = E2bEx.Sandboxes.kill(client, sandbox.sandbox_id)
```

## Running commands in a sandbox

Commands run directly against the sandbox's `envd` daemon (not the central API).
This requires a `%E2bEx.Sandbox{}` carrying an `:envd_access_token` — which means
one returned by `create/2`, `connect/3`, or `get/2`. The `list/2` endpoint does
**not** return the access token (the API omits it from listed sandboxes), so a
sandbox from `list/2` will get a `401` from envd; call `connect/3` or `get/2`
first to obtain a token-bearing sandbox:

```elixir
client = E2bEx.client(api_key: "e2b_...")
{:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})

# Or, from an existing sandbox id (e.g. one found via list/2):
{:ok, sandbox} = E2bEx.Sandboxes.connect(client, sandbox_id, 60)

{:ok, result} =
  E2bEx.Commands.run(client, sandbox,
    ~s(codex exec --full-auto --skip-git-repo-check "Create a hello world HTTP server in Go"))

result.exit_code  # 0
result.stdout     # "..."
```

`run/4` returns `{:ok, %E2bEx.CommandResult{}}` whenever the command runs (check
`exit_code` for success); `{:error, %E2bEx.Error{}}` signals it could not be run.
Options: `:on_stdout`, `:on_stderr`, `:cwd`, `:envs`, `:user`, `:timeout_ms`.

### Streaming output

Pass `:on_stdout` / `:on_stderr` to receive output incrementally as the command
runs. `run/4` still blocks and returns the fully accumulated
`%E2bEx.CommandResult{}`:

```elixir
{:ok, result} =
  E2bEx.Commands.run(client, sandbox, "for i in 1 2 3; do echo $i; sleep 1; done",
    on_stdout: &IO.write/1,
    on_stderr: fn chunk -> IO.write(:stderr, chunk) end)

result.stdout # => "1\n2\n3\n"
```

Background execution (`start/4`), reconnecting (`connect/4`), and interactive
PTY sessions (`E2bEx.Pty`) are covered below.

### Background commands

`start/4` runs a command without blocking and returns a `%E2bEx.CommandHandle{}`.
Output is delivered to the subscriber (the caller by default) as messages tagged
with the handle's `ref`; `E2bEx.CommandHandle.wait/1` blocks for the result:

```elixir
{:ok, h} = E2bEx.Commands.start(client, sandbox, ~s(codex exec --full-auto --skip-git-repo-check "Create a hello world HTTP server in Go"))

receive do
  {ref, {:stdout, data}} when ref == h.ref -> IO.write(data)
  other -> IO.inspect(other, label: "Other event")
end

{:ok, result} = E2bEx.CommandHandle.wait(h)  # {:ok, %E2bEx.CommandResult{}}
```

Control a running command:

```elixir
{:ok, procs}   = E2bEx.Commands.list(client, sandbox)          # [%E2bEx.ProcessInfo{}]
{:ok, h2}      = E2bEx.Commands.connect(client, sandbox, pid)  # reconnect
{:ok, killed?} = E2bEx.CommandHandle.kill(h)
:ok            = E2bEx.CommandHandle.send_stdin(h, "y\n")      # start(stdin: true)
:ok            = E2bEx.CommandHandle.disconnect(h)             # stop streaming, keep running
```

### Interactive PTY sessions

`E2bEx.Pty.create/3` launches an interactive login shell (`/bin/bash -i -l`)
attached to a pseudo-terminal of the given size, returning a
`%E2bEx.Pty.Handle{}`. Unlike a command, you drive a PTY by *sending input*
(typing) rather than passing a command string, and its output is a single merged
terminal stream delivered as `{ref, {:pty, bytes}}` messages (not split into
stdout/stderr). `:cols` and `:rows` are required:

```elixir
{:ok, pty} = E2bEx.Pty.create(client, sandbox, cols: 80, rows: 24)

receive do
  {ref, {:pty, data}} when ref == pty.ref -> IO.binwrite(data)
end

:ok = E2bEx.Pty.Handle.send_input(pty, "ls -la\r")          # drive it by typing
:ok = E2bEx.Pty.Handle.resize(pty, %{cols: 120, rows: 40})  # resize the terminal
```

Output is delivered to the subscriber (the caller by default) until a terminal
`{ref, {:exit, %E2bEx.CommandResult{}}}` (any exit code) or
`{ref, {:error, %E2bEx.Error{}}}`. `wait/1` drains the stream and returns the
result — exit code only, since PTY output is streamed live rather than buffered:

```elixir
{:ok, result} = E2bEx.Pty.Handle.wait(pty)   # {:ok, %E2bEx.CommandResult{exit_code: ...}}
```

Control a running PTY, or reconnect to one by pid:

```elixir
{:ok, pty2}    = E2bEx.Pty.connect(client, sandbox, pid)             # reconnect, stream its output
{:ok, killed?} = E2bEx.Pty.Handle.kill(pty)                          # SIGKILL
:ok            = E2bEx.Pty.Handle.disconnect(pty)                    # stop streaming, keep running
:ok            = E2bEx.Pty.send_input(client, sandbox, pid, "exit\r") # by-pid variants also exist
```

PTY default envs (`TERM=xterm-256color`, `LANG`/`LC_ALL=C.UTF-8`) are merged
under any `:envs` you pass; `:cwd`, `:user`, `:timeout_ms`, and `:subscriber`
work as for `E2bEx.Commands`.

Configuration can also come from application config:

```elixir
config :e2b_ex, api_key: "e2b_..."
```
