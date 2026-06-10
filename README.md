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

Configuration can also come from application config:

```elixir
config :e2b_ex, api_key: "e2b_..."
```
