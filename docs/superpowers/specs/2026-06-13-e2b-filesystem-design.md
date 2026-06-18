# E2bEx Filesystem — Phase 1 design (file operations + content)

**Status:** approved
**Date:** 2026-06-13
**Branch:** `feat/filesystem` (off `main`; independent of the PTY work).

## Goal

Add sandbox **Filesystem** support to `E2bEx`: read/write file content and the
core metadata operations (list, stat, exists, make_dir, rename, remove). This is
**Phase 1**; **watch** (live filesystem events) is **Phase 2** with its own spec.

## Background & scope

Like `E2bEx.Commands`, Filesystem is served by the sandbox's **`envd` daemon**
(not the central API), so it reuses the existing envd connection layer
(`E2bEx.Envd.Rpc.context/3`, `x-access-token` auth). It has **two transports**:

1. **Connect unary RPCs** (`filesystem.Filesystem/{Stat,ListDir,MakeDir,Move,Remove}`)
   — metadata ops. These reuse the existing `E2bEx.Envd.Rpc.unary/4` (bare JSON
   POST to a Connect path) unchanged.
2. **Plain HTTP `/files`** — `GET` reads file content (raw bytes), `POST` writes
   it. This is the one new transport piece (raw-body HTTP, not Connect).

Decisions (from brainstorming): Phase 1 = ops + basic single-file content; Phase 2
= watch. `read/4` returns `{:ok, binary}` (an Elixir binary serves as both text
and bytes). `write/5` uses `application/octet-stream` and returns
`{:ok, %EntryInfo{}}`.

### Proto reference (Phase 1 RPCs, from `filesystem.proto`)

- `Stat(StatRequest{path})` → `StatResponse{entry: EntryInfo}`
- `ListDir(ListDirRequest{path, depth})` → `ListDirResponse{entries: [EntryInfo]}`
- `MakeDir(MakeDirRequest{path})` → `MakeDirResponse{entry: EntryInfo}`
- `Move(MoveRequest{source, destination})` → `MoveResponse{entry: EntryInfo}`
- `Remove(RemoveRequest{path})` → `RemoveResponse{}` (empty)
- `EntryInfo{name, type: FileType, path, size, mode, permissions, owner, group,
  modified_time: Timestamp, symlink_target?, metadata: map}`
- `FileType`: `FILE_TYPE_FILE`, `FILE_TYPE_DIRECTORY`.

proto3 JSON: enums serialize as their string name (`"FILE_TYPE_FILE"`); a
`Timestamp` serializes as an RFC3339 string; field names are camelCased
(`modified_time → modifiedTime`, `symlink_target → symlinkTarget`); zero values
are omitted.

## Architecture

```
E2bEx.Filesystem  (lib/e2b_ex/filesystem.ex)  — public surface; builds ctx via
                   Rpc.context, calls Rpc.unary for metadata ops and the new
                   Rpc file-content helpers for read/write, decodes EntryInfo.
E2bEx.EntryInfo   (lib/e2b_ex/entry_info.ex)   — typed struct + from_api/1.
E2bEx.Envd.Rpc    (lib/e2b_ex/envd/rpc.ex)     — ADD get_file/3 + put_file/4
                   (raw HTTP GET/POST /files). The 5 metadata RPCs reuse the
                   existing unary/4 unchanged.
```

No central-API/auth changes; no new dependencies.

## Component: `E2bEx.EntryInfo`

```elixir
defmodule E2bEx.EntryInfo do
  @moduledoc "A filesystem entry (file or directory), decoded from envd responses."

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: :file | :dir | nil,
          path: String.t() | nil,
          size: non_neg_integer() | nil,
          mode: non_neg_integer() | nil,
          permissions: String.t() | nil,
          owner: String.t() | nil,
          group: String.t() | nil,
          modified_time: String.t() | nil,
          symlink_target: String.t() | nil,
          metadata: map() | nil
        }

  defstruct [:name, :type, :path, :size, :mode, :permissions, :owner, :group,
             :modified_time, :symlink_target, :metadata]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      name: m["name"],
      type: decode_type(m["type"]),
      path: m["path"],
      size: m["size"],
      mode: m["mode"],
      permissions: m["permissions"],
      owner: m["owner"],
      group: m["group"],
      modified_time: m["modifiedTime"],
      symlink_target: m["symlinkTarget"],
      metadata: m["metadata"]
    }
  end

  defp decode_type("FILE_TYPE_FILE"), do: :file
  defp decode_type("FILE_TYPE_DIRECTORY"), do: :dir
  defp decode_type(_), do: nil
end
```

`size`/`mode` stay `nil` when proto3 omits the zero value (callers treat
`nil`/`0` equivalently); we do not coerce.

## Component: `E2bEx.Envd.Rpc` additions (file content over HTTP)

Two helpers that build a `Req` request to `ctx.base_url <> "/files"`, reusing the
ctx headers but **stripping the Connect-only headers** (the same set `unary/4`
strips: `content-type`, `keepalive-ping-interval`, `connect-timeout-ms`) so the
`x-access-token` (and optional `:user` Basic auth, already in the ctx headers)
carry the auth.

```elixir
@doc "Download file content over HTTP (`GET /files`). Returns the raw body bytes."
@spec get_file(ctx(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
def get_file(ctx, path, opts \\ []) do
  req =
    Req.new(
      method: :get,
      base_url: ctx.base_url,
      url: "/files",
      headers: file_headers(ctx),
      params: file_params(path, opts),
      decode_body: false,
      retry: false
    )
    |> Req.merge(ctx.req_options)

  case Req.request(req) do
    {:ok, %Req.Response{status: s, body: body}} when s in 200..299 -> {:ok, body || ""}
    {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
    {:error, exception} -> {:error, Error.from_exception(exception)}
  end
end

@doc "Upload file content over HTTP (`POST /files`, octet-stream). Returns the WriteInfo list."
@spec put_file(ctx(), String.t(), binary(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
def put_file(ctx, path, data, opts \\ []) when is_binary(data) do
  req =
    Req.new(
      method: :post,
      base_url: ctx.base_url,
      url: "/files",
      headers: Map.put(file_headers(ctx), "content-type", "application/octet-stream"),
      params: file_params(path, opts),
      body: data,
      retry: false
    )
    |> Req.merge(ctx.req_options)

  case Req.request(req) do
    {:ok, %Req.Response{status: s, body: body}} when s in 200..299 -> {:ok, body}
    {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
    {:error, exception} -> {:error, Error.from_exception(exception)}
  end
end
```

Helpers (private to `Rpc`):
- `file_headers(ctx)` — `ctx.headers |> Map.delete("content-type") |>
  Map.delete("keepalive-ping-interval") |> Map.delete("connect-timeout-ms")`.
- `file_params(path, opts)` — `[path: path]`, plus `username: opts[:user]` only
  when `:user` is present.

`get_file` sets `decode_body: false` so Req returns the raw bytes (not parsed).
`put_file` lets Req parse the JSON `WriteInfo` array response by default.

## Component: `E2bEx.Filesystem` (public surface)

Every function builds the ctx (`Rpc.context(client, sandbox, opts)`) and dispatches
to a unary RPC or a content helper.

```elixir
Filesystem.read(client, sandbox, path, opts \\ [])
  # → {:ok, binary} | {:error, Error.t()}   (Rpc.get_file)

Filesystem.write(client, sandbox, path, data, opts \\ [])
  # → {:ok, EntryInfo.t()} | {:error, Error.t()}
  # Rpc.put_file → first WriteInfo entry → EntryInfo.from_api/1

Filesystem.list(client, sandbox, path, opts \\ [])
  # → {:ok, [EntryInfo.t()]} | {:error, Error.t()}
  # unary "/filesystem.Filesystem/ListDir" %{path: path, depth: opts[:depth] || 1}
  #   → %{"entries" => entries} → Enum.map(&EntryInfo.from_api/1)

Filesystem.get_info(client, sandbox, path, opts \\ [])
  # → {:ok, EntryInfo.t()} | {:error, Error.t()}
  # unary "/filesystem.Filesystem/Stat" %{path: path} → %{"entry" => entry}

Filesystem.exists(client, sandbox, path, opts \\ [])
  # → {:ok, boolean} | {:error, Error.t()}
  # Stat → {:ok, true}; not_found → {:ok, false}

Filesystem.make_dir(client, sandbox, path, opts \\ [])
  # → {:ok, boolean} | {:error, Error.t()}
  # MakeDir → {:ok, true}; already_exists → {:ok, false}

Filesystem.rename(client, sandbox, old_path, new_path, opts \\ [])
  # → {:ok, EntryInfo.t()} | {:error, Error.t()}
  # unary "/filesystem.Filesystem/Move" %{source: old_path, destination: new_path}
  #   → %{"entry" => entry}

Filesystem.remove(client, sandbox, path, opts \\ [])
  # → :ok | {:error, Error.t()}
  # unary "/filesystem.Filesystem/Remove" %{path: path} → {:ok, _} → :ok
```

`exists`/`make_dir` follow the existing `Rpc.kill/2` idiom for turning a specific
envd error code into a boolean:
```elixir
case Rpc.unary(ctx, "/filesystem.Filesystem/Stat", %{path: path}) do
  {:ok, _} -> {:ok, true}
  {:error, %Error{code: "not_found"}} -> {:ok, false}
  {:error, %Error{status: 404}} -> {:ok, false}
  {:error, _} = error -> error
end
```
(`make_dir` matches `%Error{code: "already_exists"}` instead.)

## Behavior & options

- `opts` recognised by all functions: `:user` (Linux user → `Authorization: Basic`
  header, already handled by `Rpc.context` headers + the `username` query param on
  content calls), `:timeout_ms`, `:domain`, `:port`, `:base_url`. Same as
  `E2bEx.Commands`.
- The sandbox must carry an `:envd_access_token` (from `create`/`connect`/`get`);
  a `list`-derived sandbox gets `401` from envd — same caveat as Commands.
- `read` of an empty file returns `{:ok, ""}`.
- `write` overwrites an existing file and creates parent-less files per envd
  semantics (no client-side check). Uses `application/octet-stream` (requires
  envd ≥ 0.5.7; all current E2B sandboxes satisfy this).

## Error handling

Uniform with the rest of the envd surface: transport/non-2xx/Connect-trailer
errors → `{:error, %E2bEx.Error{}}` via `Rpc`/`Error`. `exists`/`make_dir`
translate one specific error code to a boolean; everything else propagates.

## Testing

Tested with **Bypass** (a real loopback HTTP server), like the `Rpc`/Commands
tests — point at it with the `:base_url` opt. Two surfaces:

- **Metadata ops** (`test/e2b_ex/filesystem_test.exs`): each asserts the POST path
  (`/filesystem.Filesystem/Stat` etc.) and the decoded JSON request body, and
  stubs `{"entry": …}` / `{"entries": […]}`; assert the decoded `%EntryInfo{}`
  (incl. `type: :file`/`:dir`, `modified_time`, `symlink_target`). Cover
  `exists` true/false (200 vs `not_found`), `make_dir` true/false (200 vs
  `already_exists`), `remove` → `:ok`, and an error path.
- **Content ops**: `read` asserts `GET /files?path=…` (+ `username` when `:user`)
  and that no Connect-only headers leak; stubs raw bytes → `{:ok, binary}` (and a
  `204`/empty → `{:ok, ""}`). `write` asserts `POST /files` with
  `content-type: application/octet-stream` and the raw body, stubs a `WriteInfo`
  JSON array → `{:ok, %EntryInfo{}}`.
- **`E2bEx.EntryInfo.from_api/1`** unit test (`test/e2b_ex/entry_info_test.exs`):
  type-enum decode, `modifiedTime`/`symlinkTarget` mapping, missing fields → nil.

`mix test` stays green; `mix compile --warnings-as-errors` stays clean.

## Out of scope (Phase 1)

- **Watch** (`WatchDir` streaming and the `CreateWatcher`/`GetWatcherEvents`/
  `RemoveWatcher` poll loop) — Phase 2.
- gzip up/download, file metadata/xattr write headers (`X-Metadata-*`), batch
  `write_files` (multipart upload), signed-URL generation, and streaming reads —
  later phases.
- The central-API and PTY surfaces — unrelated.

## Files

- Create: `lib/e2b_ex/filesystem.ex`, `lib/e2b_ex/entry_info.ex`
- Modify: `lib/e2b_ex/envd/rpc.ex` (add `get_file/3`, `put_file/4`, file helpers)
- Test: `test/e2b_ex/filesystem_test.exs`, `test/e2b_ex/entry_info_test.exs`,
  plus `get_file`/`put_file` cases in `test/e2b_ex/envd/rpc_test.exs`
- Docs: a `## Filesystem` README section (decide details at plan time).
