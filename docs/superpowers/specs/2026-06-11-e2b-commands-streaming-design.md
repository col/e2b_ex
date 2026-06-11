# E2bEx Commands — Phase 1: Streaming foundation + output callbacks (Design)

**Date:** 2026-06-11
**Status:** Approved (pending implementation plan)

## Context

This is **Phase 1 of 3** in bringing `E2bEx.Commands` to feature parity with the
E2B JS and Python SDKs. The full parity surface (mapped from
`packages/js-sdk/src/sandbox/commands/` and
`packages/python-sdk/e2b/sandbox_sync/commands/`) is:

- **`Commands`**: `run` (blocking; `background: true` → handle), `list`, `kill`,
  `send_stdin`, `close_stdin`, `connect` (reconnect).
- **`CommandHandle`**: `wait`, `disconnect`, `kill`, `send_stdin`, `close_stdin`,
  live `stdout`/`stderr`/`exit_code`/`error`/`pid` getters, iterable output.
- **`Pty`**: `create`, `connect`, `send_stdin`, `resize`, `kill`, `list`.

Decomposed into three sequential, independently-shippable phases:

1. **Phase 1 (this spec):** Streaming foundation — an incremental Connect frame
   decoder plus `on_stdout`/`on_stderr` callbacks on the existing blocking
   `run/4`. Refactors today's buffer-then-parse path onto the streaming path that
   later phases reuse.
2. **Phase 2:** Background handle + control RPCs — a GenServer-backed
   `CommandHandle` (`wait`/`kill`/`disconnect`/`send_stdin`/`close_stdin`/
   getters), `run(background: true)`, plus `list`/`connect`.
3. **Phase 3:** PTY.

Dependency chain: 1 → 2 → 3.

### Decisions carried from brainstorming

| Decision | Choice |
|---|---|
| Effort structure | Three phases; design Phase 1 now |
| Non-zero exit handling | Keep `{:ok, %CommandResult{}}` for any exit code (Elixir idiom, like `System.cmd/3`); caller checks `exit_code`. `{:error, …}` stays reserved for transport/protocol failures. No `CommandExitError`. |
| Streaming mechanism | `Req` `into: fun` (synchronous reducer in the calling process). Verified supported by Req 0.6.1. (Phase 2 will use `into: :self`.) |

## Goal

Deliver command output **incrementally** via optional `on_stdout`/`on_stderr`
callbacks as chunks arrive, while `run/4` continues to return the same
`{:ok, %CommandResult{}}`. Internally, replace the buffer-whole-body-then-parse
implementation with an incremental decoder fed by Req's streaming reducer.

Omitting the callbacks yields exactly today's behavior.

## Public API

```elixir
{:ok, result} =
  E2bEx.Commands.run(client, sandbox, "for i in 1 2 3; do echo $i; sleep 1; done",
    on_stdout: fn chunk -> IO.write(chunk) end,
    on_stderr: fn chunk -> IO.write([:stderr, chunk]) end)

result.stdout    # => "1\n2\n3\n" (still fully accumulated)
result.exit_code # => 0
```

- `run(client, sandbox, command, opts \\ [])` — unchanged signature and return
  type: `{:ok, %E2bEx.CommandResult{}}` | `{:error, %E2bEx.Error{}}`.
- **New opts:**
  - `:on_stdout` — `(String.t() -> any())`, invoked with each decoded UTF-8
    stdout chunk as it arrives. Default `nil`.
  - `:on_stderr` — `(String.t() -> any())`, same for stderr. Default `nil`.
- **Existing opts unchanged:** `:cwd`, `:envs`, `:user`, `:timeout_ms`,
  `:domain`, `:port`, `:base_url`.
- Callbacks are invoked synchronously, in arrival order, from the calling
  process (the reducer runs inline in `run/4`). A callback that raises
  propagates the exception to the caller — matching the JS/Python SDKs, which do
  not trap callback errors.

## Architecture / modules

### `E2bEx.Envd.Connect.Decoder` (new, `lib/e2b_ex/envd/connect/decoder.ex`, pure)

Incremental Connect-frame parsing. Streaming hands us arbitrary byte chunks: a
single frame may be split across chunks, and one chunk may contain several
frames plus a partial one. The decoder buffers leftover bytes between pushes.

Frame format (unchanged): `<<flags::8, length::unsigned-big-32,
data::binary-size(length)>>`. The trailer frame is the one whose
`flags &&& 0x02 != 0`; its `data` is JSON (`{}` on success, or
`{"error": {"code", "message"}}`).

- `@type t` — opaque struct holding the leftover-bytes buffer
  (`%Decoder{buffer: binary()}`, `defstruct buffer: ""`).
- `new() :: t` — empty decoder.
- `push(t, bytes :: binary()) :: {:ok, [map()], trailer, t} | {:error, reason}`
  where `trailer` is `map() | nil` and `reason` is `{:invalid_json, term()}`.
  (An incomplete frame is never an error — it is buffered for the next push; only
  invalid JSON in a *complete* frame fails. `:malformed_frame` is a
  `decode_frames/1`-level concern, derived from leftover buffer bytes, not a
  `push/2` return.)
  - Append `bytes` to the buffer, then repeatedly extract complete frames:
    - A frame needs ≥ 5 header bytes, then ≥ `length` data bytes. If the buffer
      holds fewer, stop and keep the remainder in the returned decoder's buffer.
    - Non-trailer frame (`flags &&& 0x02 == 0`): JSON-decode `data` to a map and
      append to the messages list. A non-map JSON value is accepted as-is and
      folded later by the caller (matches current `decode_frames/1` tolerance).
    - Trailer frame (`flags &&& 0x02 != 0`): JSON-decode `data`
      (empty `data` → `%{}`); return it as `trailer`. Stop extracting after the
      trailer (it is the end of stream).
    - JSON decode failure on any frame → `{:error, {:invalid_json, reason}}`.
  - Returns the decoded non-trailer messages **from this push only**, the trailer
    if its complete frame arrived in this push (else `nil`), and the updated
    decoder. (Callers accumulate across pushes themselves.)

### `E2bEx.Envd.Connect` (modify, `lib/e2b_ex/envd/connect.ex`)

- `encode_frame/1` — unchanged.
- `decode_frames/1` — reimplemented on top of `Decoder` so there is a single
  framing implementation: `new()` → one `push(decoder, body)` → return
  `{:ok, messages, trailer}` where `trailer` is `nil` when no trailer frame was
  present (preserving current behavior — `decode_trailer([])` returns `nil`
  today). A success trailer with empty `data` still decodes to `%{}`. Truncated
  framing must still surface as `{:error, :malformed_frame}`, so the
  reimplementation checks that the single push leaves **no leftover bytes** in
  the decoder buffer (a non-empty remainder means a partial/truncated frame →
  `{:error, :malformed_frame}`). Decoder JSON errors map to the existing
  `{:error, {:invalid_json, reason}}` shape. Public contract and return shape are
  preserved (existing `connect_test.exs` cases must still pass unchanged).

### `E2bEx.Commands` (modify, `lib/e2b_ex/commands.ex`)

`run/4` swaps the buffered `Req.request` + post-hoc `parse_result` for a
streaming reducer:

- Reducer accumulator: a small internal struct, e.g.
  `%{decoder: Decoder.t(), result: CommandResult.t(), on_stdout: fun | nil,
  on_stderr: fun | nil, trailer: map() | nil, error: term() | nil}`.
- `Req.new(..., into: fn {:data, chunk}, {req, resp} -> … end)`:
  - `Decoder.push(acc.decoder, chunk)`:
    - `{:ok, messages, trailer, decoder}` → fold each message into `acc.result`
      using the **existing** `apply_event/2` logic (base64-decode stdout/stderr,
      capture `exit_code`/`error` from the `end` event); as each stdout/stderr
      chunk is decoded, invoke `on_stdout`/`on_stderr` with it; store `trailer`
      when present; keep the updated decoder. Continue (`{:cont, …}`).
    - `{:error, reason}` → store the error and halt (`{:halt, …}`).
  - A `apply_event/2` base64 failure stores the error and halts (same
    "malformed envd response" mapping as today).
- After `Req.request` returns:
  - transport exception → `{:error, Error.from_exception(exception)}`.
  - non-2xx status → `{:error, Error.from_response(resp)}`.
  - decoder/fold error recorded in the accumulator →
    `{:error, %Error{message: "malformed envd response", reason: reason, body: …}}`.
  - trailer carries a Connect error → `{:error, %Error{}}` (existing
    `trailer_error/1`).
  - otherwise → `{:ok, acc.result}`.

`headers/5`, `start_request/2`, `with_timeout/2`, `fetch_sandbox_id/1`,
`domain_from/1`, and the `apply_event/2` / `decode_chunk/1` folding helpers are
reused. `decode_body: false` is retained (harmless; `into: fun` already bypasses
body decoding) and `retry: false` stays.

## Data flow (`run/4`)

1. Validate `sandbox.sandbox_id` (else `{:error, %Error{}}`) — unchanged.
2. Resolve `domain`/`port`/`timeout_ms`/`base_url` and build the start-request
   body frame — unchanged.
3. Build the `Req` request with the envd headers and `into:` reducer, merge
   `client.req_options`, apply the receive timeout — as today, but streaming.
4. Issue the `POST /process.Process/Start`. The reducer runs inline, feeding the
   decoder, folding events, and firing callbacks as chunks arrive.
5. Resolve the final result from the accumulator + HTTP status per the rules
   above.

## Error handling

| Situation | Result |
|---|---|
| Command ran (any exit code) | `{:ok, %CommandResult{exit_code, stdout, stderr, error}}` |
| Connection/transport failure | `{:error, %E2bEx.Error{reason: …}}` |
| Non-2xx response (e.g. bad/missing access token) | `{:error, %E2bEx.Error{status: …}}` |
| End-of-stream trailer Connect error | `{:error, %E2bEx.Error{}}` |
| Malformed framing / JSON / base64 in the response | `{:error, %E2bEx.Error{message: "malformed envd response"}}` |
| `on_stdout`/`on_stderr` callback raises | exception propagates to the caller |

`%E2bEx.CommandResult{}` and `%E2bEx.Error{}` are unchanged (no new fields).

## Testing

### `E2bEx.Envd.Connect.Decoder` (pure unit tests)

- A single frame delivered across two `push/2` calls (split mid-header and
  mid-data) is emitted once the final byte arrives, with the right leftover
  buffer in between.
- Multiple complete frames in one `push/2` are all returned.
- A `push/2` that ends on a partial header (< 5 bytes) and on a partial body
  (header complete, body short) returns no message and buffers the remainder.
- The trailer frame is returned as `trailer`; a success trailer with empty
  `data` decodes to `%{}`; an error trailer decodes to its map.
- Malformed JSON in a frame → `{:error, {:invalid_json, _}}`.

### `E2bEx.Envd.Connect` (existing `decode_frames/1` tests)

- All current `connect_test.exs` cases still pass unchanged (round-trip a data
  frame, multiple frames, `end` with/without `exitCode`, success/error trailer,
  `{:error, _}` on truncated/garbage framing) — proving the reimplementation is
  behavior-preserving.

### `E2bEx.Commands` (Bypass, including chunked responses)

Bypass can send a **chunked** HTTP response (`Plug.Conn.send_chunked/2` +
`chunk/2`), letting us split the framed connect+json bytes across multiple
network chunks and assert true incremental delivery:

- With `on_stdout`/`on_stderr` set and the framed response split across chunks,
  the callbacks receive the expected stdout/stderr pieces **in order**, and the
  returned `%CommandResult{}` still has the fully accumulated
  stdout/stderr/exit_code.
- A frame split so one stdout payload spans two network chunks still yields one
  correct decoded chunk to the callback (decoder reassembly).
- Without callbacks, the result matches today's behavior (regression guard).
- A non-zero exit still returns `{:ok, %CommandResult{exit_code: n}}`.
- A trailer error frame returns `{:error, %E2bEx.Error{}}`.
- A non-2xx envd response returns `{:error, %E2bEx.Error{status: n}}`.
- A malformed base64 chunk returns `{:error, %E2bEx.Error{}}`.
- The `:cwd`/`:envs`/`:user` request-shaping assertions from the existing tests
  continue to hold.

Fixtures remain hand-built framed bytes (helpers in the test module), since these
payloads are not in `openapi.yml`.

## Dependencies

No new dependencies. Runtime uses `Req` (`into: fun` streaming) and `Jason`;
test uses `Bypass` (already present).

## Out of scope (later phases)

Background execution / `CommandHandle`, `kill`, `send_stdin`/`close_stdin`,
`list`, `connect`/reconnect (Phase 2), and PTY (Phase 3). An Elixir `Stream`
interface over output is not part of parity and is not planned; callbacks are the
streaming-consumption mechanism.
