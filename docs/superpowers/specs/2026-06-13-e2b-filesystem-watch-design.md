# E2bEx Filesystem watch — design (Phase 2)

**Status:** approved
**Date:** 2026-06-13
**Branch:** `feat/filesystem-watch` (off `feat/filesystem` / PR #2; depends on the
Phase 1 `E2bEx.Filesystem` + `E2bEx.EntryInfo`).

## Goal

Add live filesystem **watching** to `E2bEx.Filesystem`: stream filesystem change
events (create/write/remove/rename/chmod) from a sandbox directory to a subscriber
process, message-first, via the envd `WatchDir` server-streaming RPC.

## Background & decision

envd exposes watch two ways: the streaming `WatchDir` RPC, and a polling trio
(`CreateWatcher`/`GetWatcherEvents`/`RemoveWatcher`). Decision (from
brainstorming): **streaming `WatchDir`** for real-time events, modeled on the
library's existing message-first streaming design (`Commands.start`/PTY).

### Proto reference (`filesystem.proto`)

- `WatchDir(WatchDirRequest{path, recursive, include_entry})` →
  `stream WatchDirResponse`.
- `WatchDirResponse` is a **bare oneof** (no wrapping `event` field, unlike the
  Process API's `StartResponse{event: ...}`): each frame's JSON is exactly one of
  `{"start": {}}`, `{"filesystem": {…}}`, or `{"keepalive": {}}`.
- `FilesystemEvent{name, type: EventType, entry?: EntryInfo}`.
- `EventType`: `EVENT_TYPE_CREATE`, `_WRITE`, `_REMOVE`, `_RENAME`, `_CHMOD`.

proto3 JSON: enum `type` is a string; `include_entry → includeEntry`; an absent
`entry` (e.g. remove/rename-away events) is omitted.

## Architecture

Mirrors `Commands.start`/PTY: a GenServer owns the stream and pushes messages to a
subscriber, fronted by a thin handle struct.

```
E2bEx.FilesystemEvent          (lib/e2b_ex/filesystem_event.ex)
    — struct {name, type, entry} + from_api/1 (EventType decode; nested EntryInfo)

E2bEx.Filesystem.WatchServer   (lib/e2b_ex/filesystem/watch_server.ex)
    — GenServer (internal). Owns one WatchDir server-stream via Req `into: :self`,
      decodes Connect frames with Envd.Connect.Decoder, dispatches each
      WatchDirResponse, pushes {ref, {:fs_event, %FilesystemEvent{}}}. Modeled on
      Commands.HandleServer (see "Relationship to HandleServer").

E2bEx.Filesystem.WatchHandle   (lib/e2b_ex/filesystem/watch_handle.ex)
    — struct %{server, ref} + stop/1.

E2bEx.Filesystem.watch_dir/4   (added to lib/e2b_ex/filesystem.ex)
    — public entry point: builds ctx, spawns WatchServer, awaits the StartEvent,
      returns {:ok, %WatchHandle{}}.
```

## Component: `E2bEx.FilesystemEvent`

```elixir
@type t :: %__MODULE__{
        name: String.t() | nil,
        type: :create | :write | :remove | :rename | :chmod | nil,
        entry: E2bEx.EntryInfo.t() | nil
      }
defstruct [:name, :type, :entry]
```
`from_api/1`: `name ← m["name"]`; `type ← decode_type(m["type"])`
(`"EVENT_TYPE_CREATE" → :create`, etc., unknown → `nil`); `entry ←
EntryInfo.from_api(m["entry"])` when present, else `nil`.

## Component: `E2bEx.Filesystem.watch_dir/4`

```elixir
Filesystem.watch_dir(client, sandbox, path, opts \\ [])
  # → {:ok, %WatchHandle{}} | {:error, %E2bEx.Error{}}
```
- opts: `:recursive` (default `false`), `:include_entry` (default `false`),
  `:subscriber` (pid, default the caller), plus `:user`, `:timeout_ms`, `:domain`,
  `:port`, `:base_url` (as for `Commands`). The sandbox needs an
  `:envd_access_token` (same caveat as the rest of `Filesystem`).
- Request: `%{path: path, recursive: recursive, includeEntry: include_entry}` to
  `/filesystem.Filesystem/WatchDir` (streaming, `application/connect+json`).
- Builds the ctx (`Rpc.context/3`), spawns a `WatchServer`, and waits for the
  stream's `StartEvent` (confirms watching is active and surfaces a pre-start
  failure such as a bad path) before returning the handle — the same
  spawn-and-await shape as `Commands.spawn_handle`/`Pty` (a small watch-specific
  copy; see the deferred-unification note).

### Message model

The subscriber receives, tagged with the handle's `ref`:
```
{ref, {:fs_event, %E2bEx.FilesystemEvent{}}}   # each change, live
{ref, {:error, %E2bEx.Error{}}}                # the stream failed or closed
```
`KeepAlive` frames produce no message. Watch has **no result** and no `{:exit}`
terminal — it runs until the stream ends (→ `{:error, …}`) or you `stop/1` it.
`stop/1` sends **no** terminal message (like `CommandHandle.disconnect/1`).

## Component: `E2bEx.Filesystem.WatchHandle`

```elixir
@enforce_keys [:server, :ref]
defstruct [:server, :ref]

stop(%WatchHandle{}) :: :ok    # if alive, GenServer.stop(server); cancels the stream
```
No control ops (streaming watch has no per-watch RPCs); `stop/1` is the only
lifecycle call. (The polling `RemoveWatcher` RPC is not used — that's the polling
model, which is out of scope.)

## Component: `E2bEx.Filesystem.WatchServer` (behavior)

A GenServer closely modeled on `E2bEx.Commands.HandleServer`, with watch-specific
event handling:

- `init/1` → `{:ok, state, {:continue, :request}}`; state mirrors HandleServer's
  (ctx, path, request, subscriber, ref, timeout_ms, resp, status, decoder,
  trailer, error_body, await_from, start_error) **minus** `fold`/`pid` (watch has
  no result and no pid), **plus** a `started?` flag.
- `handle_continue(:request)` → issues the `WatchDir` stream exactly like
  HandleServer (`Req.request(into: :self, compressed: false, decode_body: false,
  retry: false, receive_timeout: …)` over the `Connect.encode_frame`'d request).
- `handle_call(:await_start, …)` → reply `:ok` once `started?`, or the stashed
  `start_error`, else stash the caller (same shape as HandleServer's
  `:await_start`).
- `handle_info/2` → `Req.parse_message` → process parts (non-2xx: accumulate the
  error body, fail on `:done`; 2xx: `Decoder.push` then dispatch).
- **Dispatch** (the key difference from HandleServer — frames are bare
  `WatchDirResponse`, not `%{"event" => …}`):
  - `%{"start" => _}` → mark `started?`, reply `:await_start` with `:ok`.
  - `%{"filesystem" => fs}` → `send(subscriber, {ref, {:fs_event,
    FilesystemEvent.from_api(fs)}})`.
  - `%{"keepalive" => _}` (or anything else) → ignore.
- `:done` / trailer: a `Connect.trailer_error/1` error, a non-empty decoder buffer
  (`malformed`), or a clean close all resolve to a terminal `{ref, {:error,
  %Error{}}}` to the subscriber (a closed watch stream is an end-of-watch, not a
  success — there is no result to deliver). A pre-start failure routes to the
  `await_start` caller / `start_error` stash exactly as HandleServer does.
- `terminate/2` → `Req.cancel_async_response(state.resp)` so `stop/1` promptly
  closes the envd connection (the same rationale and code as HandleServer).

### Relationship to `HandleServer` (and the duplication)

`WatchServer` duplicates HandleServer's streaming skeleton (request construction,
`parse_message` loop, decoder/trailer handling, `terminate` cancel, the
await/stash failure routing). This is deliberate: generalizing `HandleServer`
would touch the shipped Commands/PTY path. The duplication is a **known cost** and
the natural future unification point (a shared streaming core parameterized by an
event handler). Not done here, to keep this change isolated.

## Error handling

- Pre-start (bad path, transport, non-2xx before `StartEvent`) → `watch_dir/4`
  returns `{:error, %E2bEx.Error{}}`.
- Mid-stream failure / unexpected close / malformed framing / Connect trailer
  error → terminal `{ref, {:error, %E2bEx.Error{}}}` to the subscriber.
- `stop/1` → `:ok`, no terminal message.
- If the WatchServer crashes, a `wait`-style monitor is **not** provided (watch is
  push-only, consumed live); a crashed server simply stops delivering events.

## Testing

Tested with **Bypass** + `Plug.Conn.send_chunked/2` + `chunk/2`, like the
Commands/PTY streaming tests (point at Bypass via `:base_url`). Helpers `frame/1`
(`Connect.encode_frame(Jason.encode!(...))`) and `trailer/1` are copied as in
those test modules.

- `watch_dir/4` returns a handle once the `start` frame arrives; then a
  `filesystem` frame (with and without `entry`) is delivered as
  `{ref, {:fs_event, %FilesystemEvent{type: :create, …}}}`; a `keepalive` frame
  produces no message; chunked-across-network-boundaries framing is decoded
  incrementally.
- request body asserts `%{"path" => …, "recursive" => …, "includeEntry" => …}`.
- a non-2xx before start → `watch_dir/4` returns `{:error, %Error{}}`.
- a Connect trailer error mid-stream → terminal `{ref, {:error, %Error{}}}`.
- `stop/1` stops the server, cancels the stream (the `trap_exit` Bypass handler
  pattern from the disconnect tests), and sends no terminal message.
- `E2bEx.FilesystemEvent.from_api/1` unit test: EventType decode for all five
  types + unknown → nil; nested `entry` decoded / absent → nil.

`mix test` stays green; `mix compile --warnings-as-errors` stays clean.

## Out of scope

- The polling watcher RPCs (`CreateWatcher`/`GetWatcherEvents`/`RemoveWatcher`).
- Unifying `WatchServer` and `HandleServer` into one shared streaming core.
- Any `wait`-style draining API for watch (it is push-only).

## Files

- Create: `lib/e2b_ex/filesystem_event.ex`,
  `lib/e2b_ex/filesystem/watch_server.ex`,
  `lib/e2b_ex/filesystem/watch_handle.ex`
- Modify: `lib/e2b_ex/filesystem.ex` (add `watch_dir/4` + its spawn/await helper)
- Test: `test/e2b_ex/filesystem_event_test.exs`,
  `test/e2b_ex/filesystem/watch_test.exs` (the streaming integration, via Bypass)
- Docs: extend the README `## Filesystem` section with a watch example
  (`stop/1`; the `{:fs_event, _}` message).
