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

Background execution and reconnecting are available via `start/4`/`connect/4`;
PTY is planned for a later phase.

### Background commands

`start/4` runs a command without blocking and returns a `%E2bEx.CommandHandle{}`.
Output is delivered to the subscriber (the caller by default) as messages tagged
with the handle's `ref`; `E2bEx.CommandHandle.wait/1` blocks for the result:

```elixir
{:ok, h} = E2bEx.Commands.start(client, sandbox, "make")

receive do
  {ref, {:stdout, data}} when ref == h.ref -> IO.write(data)
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

PTY support is planned for a later phase.

## Volumes

Create and manage persistent team volumes, and mount them into sandboxes:

```elixir
{:ok, vol}  = E2bEx.Volumes.create(client, "my-vol")   # %E2bEx.Volume{volume_id, name, token}
{:ok, vols} = E2bEx.Volumes.list(client)
{:ok, vol}  = E2bEx.Volumes.get(client, vol.volume_id)
:ok         = E2bEx.Volumes.delete(client, vol.volume_id)

# Mount a volume when creating a sandbox:
{:ok, sandbox} =
  E2bEx.Sandboxes.create(client, %{templateID: "base",
    volumeMounts: [%{name: "my-vol", path: "/data"}]})
```

Configuration can also come from application config:

```elixir
config :e2b_ex, api_key: "e2b_..."
```
