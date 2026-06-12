# E2bEx Volumes — design

**Status:** approved
**Date:** 2026-06-12
**Branch:** `feat/volumes` (off `main`; independent of the PTY work).

## Goal

Add team **Volumes** support to `E2bEx`: list/create/get/delete persistent volumes
via the central API, plus document mounting a volume into a sandbox at create time.

## Background & scope

Volumes are one of three previously-excluded API groups (Teams, Filesystem,
Volumes) now being added, each as its own spec. Volumes is the smallest: four
central-API REST endpoints, all callable with the standard `X-API-Key`, fitting
the existing `E2bEx.Request` chokepoint with no transport or auth changes.

Endpoints (`openapi.yml`, tag `volumes`, no deprecations):

| Method | Path | Body | Success → |
| --- | --- | --- | --- |
| `GET` | `/volumes` | — | `200` `Volume[]` |
| `POST` | `/volumes` | `NewVolume{name}` | `201` `VolumeAndToken` |
| `GET` | `/volumes/{volumeID}` | — | `200` `VolumeAndToken` |
| `DELETE` | `/volumes/{volumeID}` | — | `204` no content |

Schemas:
- `Volume` — `{volumeID, name}`
- `VolumeAndToken` — `{volumeID, name, token}` (the `token` is for interacting
  with volume content; in practice it is consumed by mounting the volume into a
  sandbox)
- `NewVolume` — `{name}` (server-side pattern `^[a-zA-Z0-9_-]+$`)
- `SandboxVolumeMount` — `{name, path}` (used in the sandbox-create body)

## Architecture

A standard central-API resource, mirroring `E2bEx.Tags` / `E2bEx.Sandboxes`:
all requests funnel through `E2bEx.Request.request/4` (which sets `x-api-key` and
normalizes results). Two new files:

```
E2bEx.Volume    (lib/e2b_ex/volume.ex)    — typed struct + from_api/1 decoder
E2bEx.Volumes   (lib/e2b_ex/volumes.ex)   — list/create/get/delete resource fns
```

No changes to `E2bEx.Request`, `E2bEx.Client`, or auth. No new dependencies.

## Component: `E2bEx.Volume` struct

A **single** struct covers both API shapes (`Volume` without a token, and
`VolumeAndToken` with one) — the same approach `E2bEx.Sandbox` uses for
`envd_access_token` (present from create/get, absent from list → `nil`).

```elixir
defmodule E2bEx.Volume do
  @moduledoc "A team volume, decoded from create/get/list responses."

  @type t :: %__MODULE__{
          volume_id: String.t() | nil,
          name: String.t() | nil,
          token: String.t() | nil
        }

  defstruct [:volume_id, :name, :token]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{volume_id: m["volumeID"], name: m["name"], token: m["token"]}
  end
end
```

`token` is `nil` for `list`-derived volumes (the `Volume` schema omits it) and
populated for `create`/`get` (the `VolumeAndToken` schema).

## Component: `E2bEx.Volumes` resource

```elixir
defmodule E2bEx.Volumes do
  @moduledoc """
  Team volume operations (`/volumes`). Every function takes an `E2bEx.Client`.

  A volume can be mounted into a sandbox at create time via `volumeMounts`:

      E2bEx.Sandboxes.create(client, %{templateID: "base",
        volumeMounts: [%{name: "my-vol", path: "/data"}]})
  """

  alias E2bEx.{Request, Volume}

  @doc "List all team volumes (`GET /volumes`)."
  @spec list(E2bEx.Client.t()) :: {:ok, [Volume.t()]} | {:error, E2bEx.Error.t()}
  def list(client) do
    with {:ok, list} <- Request.request(client, :get, "/volumes") do
      {:ok, Enum.map(list, &Volume.from_api/1)}
    end
  end

  @doc "Create a team volume (`POST /volumes`). Returns the volume with its token."
  @spec create(E2bEx.Client.t(), String.t()) :: {:ok, Volume.t()} | {:error, E2bEx.Error.t()}
  def create(client, name) when is_binary(name) do
    with {:ok, volume} <- Request.request(client, :post, "/volumes", json: %{name: name}) do
      {:ok, Volume.from_api(volume)}
    end
  end

  @doc "Get a team volume by id (`GET /volumes/:id`). Returns the volume with its token."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Volume.t()} | {:error, E2bEx.Error.t()}
  def get(client, volume_id) when is_binary(volume_id) do
    with {:ok, volume} <- Request.request(client, :get, "/volumes/#{volume_id}") do
      {:ok, Volume.from_api(volume)}
    end
  end

  @doc "Delete a team volume by id (`DELETE /volumes/:id`)."
  @spec delete(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, volume_id) when is_binary(volume_id) do
    case Request.request(client, :delete, "/volumes/#{volume_id}") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
```

Return shapes follow house convention: read calls → `{:ok, struct | [struct]}`,
the void `delete` → `:ok`, everything fails with `{:error, %E2bEx.Error{}}`.
`create/2` passes `name` through unvalidated; the server enforces the
`^[a-zA-Z0-9_-]+$` pattern and returns a `4xx` (surfaced as `%E2bEx.Error{}`) on a
bad name — consistent with how other create calls defer validation to the API.

## Volume mounts (documentation only — no new code)

`E2bEx.Sandbox` already decodes a `volume_mounts` field, and
`E2bEx.Sandboxes.create/2` already forwards an arbitrary params map to the API.
So mounting a volume already works today:

```elixir
E2bEx.Sandboxes.create(client, %{templateID: "base",
  volumeMounts: [%{name: "my-vol", path: "/data"}]})
```

This spec adds **documentation only**: the `volumeMounts` example in
`E2bEx.Volumes`' moduledoc (above) and a one-line note + the same example in
`E2bEx.Sandboxes.create/2`'s `@doc`. No code change to `Sandboxes`/`Sandbox`.

## Error handling

Uniform with the rest of the central-API client: non-2xx and transport failures
return `{:error, %E2bEx.Error{}}` via `E2bEx.Request`/`E2bEx.Error`. No
Volumes-specific error handling.

## Testing

Central-API resources are tested with **`Req.Test`** (Plug stubs via
`req_options: [plug: {Req.Test, Mod}]`), mirroring `test/e2b_ex/tags_test.exs`.
A new `test/e2b_ex/volumes_test.exs` covers:

- `list/1` → decodes a `Volume[]` body into `[%Volume{token: nil}]` (list omits token).
- `create/2` → posts `%{"name" => name}` and decodes a `VolumeAndToken` body into
  `%Volume{token: "..."}`.
- `get/2` → decodes a `VolumeAndToken` body into `%Volume{token: "..."}`.
- `delete/2` → a `204`/empty response returns `:ok`.
- An error path (e.g. `404`/`409`) returns `{:error, %E2bEx.Error{}}`.
- `E2bEx.Volume.from_api/1` maps `volumeID → volume_id` and tolerates a missing
  `token` (→ `nil`).

`mix test` must stay green and `mix compile --warnings-as-errors` must stay clean.

## Out of scope

- Any volume-content read/write API — none exists in `openapi.yml`; content is
  reached by mounting the volume into a sandbox. The `VolumeToken` schema (a bare
  `{token}`) has no endpoint in the in-scope surface and is not modeled.
- Teams and Filesystem — their own specs.
- Adding a typed `%VolumeMount{}` struct or changing `Sandboxes.create/2` — the
  existing map passthrough already covers mounting; YAGNI.

## Files

- Create: `lib/e2b_ex/volume.ex`, `lib/e2b_ex/volumes.ex`
- Modify: `lib/e2b_ex/sandboxes.ex` (doc-only: `volumeMounts` note on `create/2`)
- Test: `test/e2b_ex/volumes_test.exs`
- Docs: optionally a short Volumes note in `README.md` (decide at plan time).
