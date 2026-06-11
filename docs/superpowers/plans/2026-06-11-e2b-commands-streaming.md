# E2bEx Commands — Phase 1: Streaming foundation + output callbacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add incremental output streaming to `E2bEx.Commands.run/4` via optional `on_stdout`/`on_stderr` callbacks, backed by a new incremental Connect-frame decoder, while keeping the same `{:ok, %CommandResult{}}` return.

**Architecture:** A pure incremental decoder (`E2bEx.Envd.Connect.Decoder`) parses Connect frames from arbitrary byte chunks, buffering partial frames. `Connect.decode_frames/1` is reimplemented on top of it (one framing implementation). `Commands.run/4` switches from buffer-then-parse to a `Req` `into: fun` streaming reducer that feeds the decoder, folds events into a `CommandResult`, and fires callbacks as chunks arrive.

**Tech Stack:** Elixir, `Req` 0.6.1 (`into: fun` streaming), `Jason`, `Bypass` (test), ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-11-e2b-commands-streaming-design.md`

---

## File Structure

- **Create** `lib/e2b_ex/envd/connect/decoder.ex` — `E2bEx.Envd.Connect.Decoder`: pure, stateful incremental frame parser (`new/0`, `push/2`). Owns the framing/Bitwise logic.
- **Modify** `lib/e2b_ex/envd/connect.ex` — reimplement `decode_frames/1` on the decoder; remove the now-unused private framing helpers and `import Bitwise`. `encode_frame/1` unchanged.
- **Modify** `lib/e2b_ex/commands.ex` — streaming `run/4` with `:on_stdout`/`:on_stderr`; replace the buffered `parse_result`/`fold_events` path with a `into: fun` reducer. Request-building helpers unchanged.
- **Create** `test/e2b_ex/envd/connect/decoder_test.exs` — decoder unit tests.
- **Modify** `test/e2b_ex/envd/connect_test.exs` — no edits expected; it is the behavior-preserving guard for `decode_frames/1`.
- **Modify** `test/e2b_ex/commands_test.exs` — add streaming/callback tests (Bypass chunked responses); existing tests must still pass.

---

## Task 1: Incremental frame decoder (`E2bEx.Envd.Connect.Decoder`)

**Files:**
- Create: `lib/e2b_ex/envd/connect/decoder.ex`
- Test: `test/e2b_ex/envd/connect/decoder_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/envd/connect/decoder_test.exs`:

```elixir
defmodule E2bEx.Envd.Connect.DecoderTest do
  use ExUnit.Case, async: true
  alias E2bEx.Envd.Connect.Decoder

  defp frame(map) do
    json = Jason.encode!(map)
    <<0::8, byte_size(json)::unsigned-big-32, json::binary>>
  end

  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "push/2 returns a complete frame and an empty buffer" do
    assert {:ok, [%{"a" => 1}], nil, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), frame(%{"a" => 1}))
  end

  test "push/2 reassembles a frame split across two pushes" do
    f = frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}})
    <<head::binary-size(4), tail::binary>> = f

    assert {:ok, [], nil, %Decoder{buffer: ^head} = d} = Decoder.push(Decoder.new(), head)

    assert {:ok, [%{"event" => %{"data" => %{"stdout" => "aGk="}}}], nil, %Decoder{buffer: ""}} =
             Decoder.push(d, tail)
  end

  test "push/2 returns multiple complete frames from one push" do
    body = frame(%{"n" => 1}) <> frame(%{"n" => 2})

    assert {:ok, [%{"n" => 1}, %{"n" => 2}], nil, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), body)
  end

  test "push/2 buffers a partial header (< 5 bytes)" do
    assert {:ok, [], nil, %Decoder{buffer: <<0, 0>>}} = Decoder.push(Decoder.new(), <<0, 0>>)
  end

  test "push/2 buffers a complete header with a partial body" do
    partial = <<0::8, 10::unsigned-big-32, "short">>
    assert {:ok, [], nil, %Decoder{buffer: ^partial}} = Decoder.push(Decoder.new(), partial)
  end

  test "push/2 returns a success trailer with empty data as an empty map" do
    assert {:ok, [], %{}, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), <<2::8, 0::unsigned-big-32>>)
  end

  test "push/2 returns an error trailer map" do
    assert {:ok, [], %{"error" => %{"code" => "x", "message" => "y"}}, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), trailer(~s({"error":{"code":"x","message":"y"}})))
  end

  test "push/2 returns messages preceding a trailer in one push" do
    body = frame(%{"n" => 1}) <> trailer("{}")
    assert {:ok, [%{"n" => 1}], %{}, %Decoder{buffer: ""}} = Decoder.push(Decoder.new(), body)
  end

  test "push/2 errors on invalid JSON in a complete frame" do
    bad = <<0::8, 3::unsigned-big-32, "{[}">>
    assert {:error, {:invalid_json, _}} = Decoder.push(Decoder.new(), bad)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/envd/connect/decoder_test.exs`
Expected: FAIL — `module E2bEx.Envd.Connect.Decoder is not available` / `Decoder.new/0 undefined`.

- [ ] **Step 3: Write the decoder implementation**

Create `lib/e2b_ex/envd/connect/decoder.ex`:

```elixir
defmodule E2bEx.Envd.Connect.Decoder do
  @moduledoc false
  # Incremental Connect-protocol frame decoder. Feed response-body byte chunks via
  # push/2; it extracts every complete frame and buffers any partial remainder for
  # the next push.
  #
  # A frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # The end-of-stream trailer sets bit 0x02 and ends the stream; its data is JSON
  # (`{}` on success, `{"error": {...}}` on a Connect-level error).

  import Bitwise

  @end_stream_flag 0x02

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "A fresh decoder with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append `bytes` and extract complete frames.

  Returns `{:ok, messages, trailer, decoder}` where `messages` are the
  JSON-decoded non-trailer frames completed by this push, `trailer` is the decoded
  end-of-stream frame if it arrived (else `nil`), and `decoder` carries any partial
  remainder. Returns `{:error, {:invalid_json, reason}}` if a *complete* frame's
  payload is not valid JSON. An incomplete frame is buffered, never an error.
  """
  @spec push(t(), binary()) ::
          {:ok, [map()], map() | nil, t()} | {:error, {:invalid_json, term()}}
  def push(%__MODULE__{buffer: buffer}, bytes) when is_binary(bytes) do
    extract(buffer <> bytes, [])
  end

  defp extract(<<flags::8, len::unsigned-big-32, data::binary-size(len), rest::binary>>, acc) do
    if trailer?(flags) do
      case decode_trailer(data) do
        {:ok, trailer} -> {:ok, Enum.reverse(acc), trailer, %__MODULE__{buffer: rest}}
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    else
      case Jason.decode(data) do
        {:ok, message} -> extract(rest, [message | acc])
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    end
  end

  defp extract(remainder, acc) do
    {:ok, Enum.reverse(acc), nil, %__MODULE__{buffer: remainder}}
  end

  defp trailer?(flags), do: (flags &&& @end_stream_flag) != 0

  defp decode_trailer(""), do: {:ok, %{}}
  defp decode_trailer(data), do: Jason.decode(data)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/envd/connect/decoder_test.exs`
Expected: PASS (9 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/envd/connect/decoder.ex test/e2b_ex/envd/connect/decoder_test.exs
git commit -m "feat: add incremental Connect frame decoder"
```

---

## Task 2: Reimplement `Connect.decode_frames/1` on the decoder

**Files:**
- Modify: `lib/e2b_ex/envd/connect.ex`
- Test (guard, unchanged): `test/e2b_ex/envd/connect_test.exs`

- [ ] **Step 1: Confirm the existing guard tests pass first**

Run: `mix test test/e2b_ex/envd/connect_test.exs`
Expected: PASS (7 tests, 0 failures) — this is the behavior we must preserve.

- [ ] **Step 2: Replace the body of `connect.ex` with the decoder-backed version**

Replace the entire contents of `lib/e2b_ex/envd/connect.ex` with:

```elixir
defmodule E2bEx.Envd.Connect do
  @moduledoc false
  # Connect-protocol (ConnectRPC) framing for the envd process API, JSON codec.
  #
  # Each frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # Normal messages use flags 0; the end-of-stream trailer sets bit 0x02.
  # Incremental decoding lives in `E2bEx.Envd.Connect.Decoder`; this module wraps it
  # for the whole-body (buffered) case.

  alias E2bEx.Envd.Connect.Decoder

  @doc "Wrap a payload in a single Connect frame (flags 0)."
  @spec encode_frame(binary()) :: binary()
  def encode_frame(payload) when is_binary(payload) do
    <<0::8, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  @doc """
  Split a buffered Connect response body into `{:ok, messages, trailer}`.

  `messages` is the list of JSON-decoded non-trailer frames; `trailer` is the
  JSON-decoded end-of-stream frame, or `nil` when none is present. Returns
  `{:error, :malformed_frame}` on truncated framing or `{:error, {:invalid_json,
  reason}}` when a frame's payload is not valid JSON.
  """
  @spec decode_frames(binary()) ::
          {:ok, [map()], map() | nil} | {:error, :malformed_frame | {:invalid_json, term()}}
  def decode_frames(body) when is_binary(body) do
    case Decoder.push(Decoder.new(), body) do
      {:ok, messages, trailer, %Decoder{buffer: ""}} -> {:ok, messages, trailer}
      {:ok, _messages, _trailer, %Decoder{}} -> {:error, :malformed_frame}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Note: a non-empty leftover buffer after a single whole-body push means a partial/truncated frame, which maps to `{:error, :malformed_frame}` — preserving the old behavior.

- [ ] **Step 3: Run the guard tests to verify they still pass**

Run: `mix test test/e2b_ex/envd/connect_test.exs`
Expected: PASS (7 tests, 0 failures) — unchanged.

- [ ] **Step 4: Run the full suite + strict compile**

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass; clean compile (no "unused function" warnings from the removed helpers, since the whole file was replaced).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/envd/connect.ex
git commit -m "refactor: reimplement decode_frames on the incremental decoder"
```

---

## Task 3: Streaming `run/4` with `on_stdout`/`on_stderr`

**Files:**
- Modify: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/commands_test.exs`

- [ ] **Step 1: Write the failing streaming tests**

Add these helpers and tests to `test/e2b_ex/commands_test.exs`.

First, add a chunk-splitting helper at the bottom of the module (before the final `end`):

```elixir
  # Split a binary into consecutive parts of at most `n` bytes (keeps the remainder).
  defp chunk_bytes(bin, n) when byte_size(bin) > n do
    <<part::binary-size(n), rest::binary>> = bin
    [part | chunk_bytes(rest, n)]
  end

  defp chunk_bytes(bin, _n), do: [bin]
```

Then add these tests:

```elixir
  test "run/4 streams stdout/stderr to callbacks in arrival order across network chunks",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      body =
        frame(%{"event" => %{"start" => %{"pid" => 7}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("foo")}}}) <>
          frame(%{"event" => %{"data" => %{"stderr" => Base.encode64("bar")}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("baz")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <>
          trailer("{}")

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunk_bytes(body, 7), conn, fn part, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, part)
        conn
      end)
    end)

    {:ok, sink} = Agent.start_link(fn -> [] end)
    record = fn tag -> fn data -> Agent.update(sink, &[{tag, data} | &1]) end end

    assert {:ok, %CommandResult{stdout: "foobaz", stderr: "bar", exit_code: 0}} =
             Commands.run(client(), sandbox(), "echo",
               base_url: base_url,
               on_stdout: record.(:out),
               on_stderr: record.(:err)
             )

    assert Enum.reverse(Agent.get(sink, & &1)) == [{:out, "foo"}, {:err, "bar"}, {:out, "baz"}]
  end

  test "run/4 reassembles a single output chunk whose frame spans two network chunks",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      body =
        frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("hello world")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <>
          trailer("{}")

      # Split mid-first-frame so the stdout payload arrives in two pieces.
      <<first::binary-size(6), second::binary>> = body
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, second)
      conn
    end)

    {:ok, sink} = Agent.start_link(fn -> [] end)

    assert {:ok, %CommandResult{stdout: "hello world"}} =
             Commands.run(client(), sandbox(), "echo",
               base_url: base_url,
               on_stdout: fn data -> Agent.update(sink, &[data | &1]) end
             )

    # Exactly one callback invocation with the whole reassembled payload.
    assert Agent.get(sink, & &1) == ["hello world"]
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/e2b_ex/commands_test.exs`
Expected: FAIL — `Commands.run/4` does not yet accept `:on_stdout`/`:on_stderr`, so the callbacks never fire and the `Agent` assertions fail (e.g. `[] == [{:out, "foo"}, ...]`).

- [ ] **Step 3: Rewrite `commands.ex` to stream via `into: fun`**

Replace the entire contents of `lib/e2b_ex/commands.ex` with:

```elixir
defmodule E2bEx.Commands do
  @moduledoc """
  Run shell commands inside a running sandbox.

  Unlike the rest of `E2bEx`, this talks directly to the sandbox's `envd` daemon
  (not `api.e2b.app`) over the Connect protocol. v1 supports blocking execution:
  the command runs to completion and the result is returned.

      {:ok, result} = E2bEx.Commands.run(client, sandbox, "echo hello")
      result.stdout    # => "hello\\n"
      result.exit_code # => 0

  Output can be streamed as it arrives by passing `:on_stdout` / `:on_stderr`
  callbacks; the fully accumulated result is still returned:

      {:ok, _result} =
        E2bEx.Commands.run(client, sandbox, "make",
          on_stdout: &IO.write/1,
          on_stderr: &IO.write/1)

  A command that runs returns `{:ok, %E2bEx.CommandResult{}}` regardless of its
  exit code; `{:error, %E2bEx.Error{}}` is reserved for transport, connection, or
  protocol failures.
  """

  alias E2bEx.{Client, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Connect

  @default_port 49_983
  @default_domain "e2b.app"
  @default_timeout_ms 60_000
  @start_path "/process.Process/Start"

  @doc """
  Run `command` in `sandbox` and wait for it to finish.

  `sandbox` is an `%E2bEx.Sandbox{}` and must carry a `:sandbox_id` and an
  `:envd_access_token`. Use a sandbox from `E2bEx.Sandboxes.create/2`,
  `connect/3`, or `get/2` — these return the access token. A sandbox from
  `list/2` does **not** carry the token (the API omits it from listed
  sandboxes), so envd will reject the request with `401`; call `connect/3` or
  `get/2` on its `sandbox_id` first. `client` supplies shared `Req` config via
  its `:req_options`.

  ## Options
    * `:on_stdout` — `(String.t() -> any())` invoked with each stdout chunk as it
      arrives.
    * `:on_stderr` — `(String.t() -> any())` invoked with each stderr chunk as it
      arrives.
    * `:cwd` — working directory.
    * `:envs` — environment variables (`%{String.t() => String.t()}`).
    * `:user` — Linux user to run as (adds an `Authorization: Basic` header).
    * `:timeout_ms` — total command timeout; default `#{@default_timeout_ms}`, `0` disables.
    * `:domain` — override the sandbox domain.
    * `:port` — envd port; default `#{@default_port}`.
    * `:base_url` — override the full envd base URL (advanced; self-hosted/testing).

  Callbacks run synchronously in arrival order from the calling process; a callback
  that raises propagates to the caller.
  """
  @spec run(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, sandbox_id} <- fetch_sandbox_id(sandbox) do
      domain = sandbox.domain || opts[:domain] || domain_from(client)
      port = opts[:port] || @default_port
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      base_url = opts[:base_url] || "https://#{port}-#{sandbox_id}.#{domain}"
      body = Connect.encode_frame(Jason.encode!(start_request(command, opts)))

      req =
        Req.new(
          method: :post,
          base_url: base_url,
          url: @start_path,
          headers: headers(sandbox, sandbox_id, port, timeout_ms, opts),
          body: body,
          retry: false,
          decode_body: false,
          compressed: false,
          into: collector(opts)
        )
        |> Req.merge(client.req_options)
        |> with_timeout(timeout_ms)

      case Req.request(req) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          finalize(resp)

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          {:error, Error.from_exception(exception)}
      end
    end
  end

  # ---- streaming collection ----

  # Req `into:` reducer. Accumulates raw bytes onto `resp.body` (so non-2xx error
  # bodies stay intact for `Error.from_response/1`) and, for 2xx responses, feeds
  # the incremental decoder, folding events and firing callbacks. Parse state lives
  # in `resp.private[:e2b_stream]`.
  defp collector(opts) do
    fn {:data, chunk}, {req, resp} ->
      resp = %{resp | body: (resp.body || "") <> chunk}

      if resp.status in 200..299 do
        state = Req.Response.get_private(resp, :e2b_stream, new_state(opts))
        {action, state} = consume(state, chunk)
        {action, {req, Req.Response.put_private(resp, :e2b_stream, state)}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  defp new_state(opts) do
    %{
      decoder: Connect.Decoder.new(),
      result: %CommandResult{},
      on_stdout: opts[:on_stdout],
      on_stderr: opts[:on_stderr],
      trailer: nil,
      error: nil
    }
  end

  defp consume(state, chunk) do
    case Connect.Decoder.push(state.decoder, chunk) do
      {:ok, messages, trailer, decoder} ->
        state = %{state | decoder: decoder, trailer: trailer || state.trailer}

        case apply_messages(state, messages) do
          {:ok, state} -> {:cont, state}
          {:error, reason} -> {:halt, %{state | error: reason}}
        end

      {:error, reason} ->
        {:halt, %{state | error: reason}}
    end
  end

  defp apply_messages(state, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn message, {:ok, state} ->
      case apply_event(state, message["event"]) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_event(state, %{"data" => %{"stdout" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      invoke(state.on_stdout, bytes)
      {:ok, %{state | result: %{state.result | stdout: state.result.stdout <> bytes}}}
    end
  end

  defp apply_event(state, %{"data" => %{"stderr" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      invoke(state.on_stderr, bytes)
      {:ok, %{state | result: %{state.result | stderr: state.result.stderr <> bytes}}}
    end
  end

  defp apply_event(state, %{"end" => end_event}) do
    result = %{
      state.result
      | exit_code: Map.get(end_event, "exitCode", 0),
        error: Map.get(end_event, "error")
    }

    {:ok, %{state | result: result}}
  end

  defp apply_event(state, _other), do: {:ok, state}

  defp invoke(nil, _chunk), do: :ok

  defp invoke(fun, chunk) when is_function(fun, 1) do
    fun.(chunk)
    :ok
  end

  defp finalize(resp) do
    state = Req.Response.get_private(resp, :e2b_stream, new_state([]))

    cond do
      state.error != nil ->
        {:error, %Error{message: "malformed envd response", reason: state.error, body: resp.body}}

      true ->
        case trailer_error(state.trailer) do
          %Error{} = error -> {:error, error}
          nil -> {:ok, state.result}
        end
    end
  end

  defp trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  defp trailer_error(_), do: nil

  defp decode_chunk(chunk) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  # ---- request building ----

  defp fetch_sandbox_id(%Sandbox{sandbox_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_sandbox_id(_), do: {:error, %Error{message: "sandbox is missing :sandbox_id"}}

  defp domain_from(%Client{base_url: base_url}) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "api.", "")
      _ -> @default_domain
    end
  end

  defp start_request(command, opts) do
    process =
      %{cmd: "/bin/bash", args: ["-l", "-c", command]}
      |> put_present(:cwd, opts[:cwd])
      |> put_present(:envs, opts[:envs])

    %{process: process, stdin: false}
  end

  defp headers(sandbox, sandbox_id, port, timeout_ms, opts) do
    %{
      "content-type" => "application/connect+json",
      "connect-protocol-version" => "1",
      "e2b-sandbox-id" => sandbox_id,
      "e2b-sandbox-port" => Integer.to_string(port),
      "keepalive-ping-interval" => "50"
    }
    |> put_when(sandbox.envd_access_token, "x-access-token", sandbox.envd_access_token)
    |> put_when(timeout_ms != 0, "connect-timeout-ms", Integer.to_string(timeout_ms))
    |> put_when(opts[:user], "authorization", "Basic " <> Base.encode64("#{opts[:user]}:"))
  end

  defp with_timeout(req, 0), do: Req.merge(req, receive_timeout: :infinity)
  defp with_timeout(req, ms), do: Req.merge(req, receive_timeout: ms + 5_000)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 4: Run the command tests to verify they pass**

Run: `mix test test/e2b_ex/commands_test.exs`
Expected: PASS — both new streaming tests plus all pre-existing command tests (folding, cwd/envs/user, non-zero exit, trailer error, transport error, missing token, missing id, malformed base64, non-2xx).

- [ ] **Step 5: Run the full suite + strict compile**

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass; clean compile.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/commands.ex test/e2b_ex/commands_test.exs
git commit -m "feat: stream command output via on_stdout/on_stderr callbacks"
```

---

## Task 4: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the streaming callbacks in the README**

In `README.md`, under the "Running commands in a sandbox" section, after the existing `run/4` paragraph that lists options, add:

```markdown
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

Background execution, `kill`/stdin, reconnecting, and PTY are planned in later
phases.
```

Also update the existing options line to mention the new callbacks: change
`Options: \`:cwd\`, \`:envs\`, \`:user\`, \`:timeout_ms\`.` to
`Options: \`:on_stdout\`, \`:on_stderr\`, \`:cwd\`, \`:envs\`, \`:user\`, \`:timeout_ms\`.`

- [ ] **Step 2: Verify docs build**

Run: `mix compile --warnings-as-errors`
Expected: clean compile (README is referenced by `ex_doc` extras; no doc errors).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document streaming command output callbacks"
```

---

## Final verification

- [ ] Run the whole suite and strict compile once more:

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass (existing + new decoder tests + new streaming tests); clean compile.

- [ ] Confirm no regressions in the public contract: `run/4` without callbacks behaves exactly as before (`{:ok, %CommandResult{}}` for any exit code; `{:error, %E2bEx.Error{}}` only for transport/non-2xx/trailer/malformed responses).
