# E2bEx Filesystem Watch (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live filesystem watching to `E2bEx.Filesystem` via the streaming `WatchDir` RPC — `watch_dir/4` returns a `%WatchHandle{}` and pushes `{ref, {:fs_event, %FilesystemEvent{}}}` messages.

**Architecture:** Message-first streaming, like `Commands.start`/PTY: a `WatchServer` GenServer (modeled on `Commands.HandleServer`) owns the `WatchDir` server-stream via `Req` `into: :self`, decodes Connect frames with `Envd.Connect.Decoder`, and pushes events to a subscriber. A thin `WatchHandle` struct fronts it with `stop/1`. `watch_dir/4` spawns the server and awaits the stream's `StartEvent` before returning.

**Tech Stack:** Elixir ~> 1.18, `Req` (streaming `into: :self`), the existing `Envd.Connect`/`Envd.Rpc`, `Bypass` for tests.

**Reference spec:** `docs/superpowers/specs/2026-06-13-e2b-filesystem-watch-design.md`. Depends on Phase 1 (`E2bEx.Filesystem`, `E2bEx.EntryInfo`) already on this branch.

---

## File Structure

- **Create** `lib/e2b_ex/filesystem_event.ex` — `E2bEx.FilesystemEvent` struct + `from_api/1`.
- **Create** `lib/e2b_ex/filesystem/watch_handle.ex` — `E2bEx.Filesystem.WatchHandle` struct + `stop/1`.
- **Create** `lib/e2b_ex/filesystem/watch_server.ex` — `E2bEx.Filesystem.WatchServer` (internal GenServer).
- **Modify** `lib/e2b_ex/filesystem.ex` — add `watch_dir/4` + the private `spawn_watch/3` helper.
- **Modify** `README.md` — extend the `## Filesystem` section with a watch example.
- **Test** `test/e2b_ex/filesystem_event_test.exs`, `test/e2b_ex/filesystem/watch_handle_test.exs`, `test/e2b_ex/filesystem/watch_test.exs`.

### Conventions an implementer must know (verified against the codebase)

- `WatchServer` mirrors `lib/e2b_ex/commands/handle_server.ex` — read it. Key reused pieces: `Req.new(into: :self, compressed: false, decode_body: false, retry: false, receive_timeout: …)`, `Req.parse_message/2`, `Envd.Connect.Decoder.push/2` (→ `{:ok, messages, trailer, decoder}`), `Envd.Connect.encode_frame/1`, `Envd.Connect.trailer_error/1`, and `terminate/2` → `Req.cancel_async_response/1`.
- **Critical difference from HandleServer:** the Process stream wraps each frame as `%{"event" => …}`; the **WatchDir stream does NOT** — each decoded frame is a bare `WatchDirResponse`, i.e. exactly one of `%{"start" => …}`, `%{"filesystem" => …}`, `%{"keepalive" => …}`. Dispatch on those top-level keys directly.
- Watch has **no result** and **no pid**: `await_start` replies `:ok` (not `{:ok, pid}`); a closed stream is terminal `{:error, …}`, never an `{:exit, …}`.
- Streaming envd is tested with **Bypass** + `Plug.Conn.send_chunked/2`/`chunk/2` (or whole-body `Plug.Conn.resp/3`), pointing at it via `:base_url`. See `test/e2b_ex/commands_background_test.exs` for the `frame/1`/`trailer/1`/`chunk_bytes/2` helpers and the `trap_exit` disconnect-test pattern.
- This repo is **hand-formatted**; do NOT run `mix format`. Use the code below verbatim.

---

## Task 1: `E2bEx.FilesystemEvent` struct

**Files:**
- Create: `lib/e2b_ex/filesystem_event.ex`
- Test: `test/e2b_ex/filesystem_event_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/filesystem_event_test.exs`:

```elixir
defmodule E2bEx.FilesystemEventTest do
  use ExUnit.Case, async: true
  alias E2bEx.{EntryInfo, FilesystemEvent}

  test "from_api/1 decodes the event type and nested entry" do
    event =
      FilesystemEvent.from_api(%{
        "name" => "/d/a.txt",
        "type" => "EVENT_TYPE_CREATE",
        "entry" => %{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt"}
      })

    assert %FilesystemEvent{
             name: "/d/a.txt",
             type: :create,
             entry: %EntryInfo{name: "a.txt", type: :file, path: "/d/a.txt"}
           } = event
  end

  test "from_api/1 leaves entry nil when absent and maps all event types" do
    assert %FilesystemEvent{type: :write, entry: nil} =
             FilesystemEvent.from_api(%{"name" => "x", "type" => "EVENT_TYPE_WRITE"})

    for {str, atom} <- [
          {"EVENT_TYPE_CREATE", :create},
          {"EVENT_TYPE_WRITE", :write},
          {"EVENT_TYPE_REMOVE", :remove},
          {"EVENT_TYPE_RENAME", :rename},
          {"EVENT_TYPE_CHMOD", :chmod}
        ] do
      assert %FilesystemEvent{type: ^atom} = FilesystemEvent.from_api(%{"type" => str})
    end
  end

  test "from_api/1 maps an unknown type to nil" do
    assert %FilesystemEvent{type: nil} = FilesystemEvent.from_api(%{"type" => "EVENT_TYPE_UNSPECIFIED"})
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/filesystem_event_test.exs`
Expected: FAIL to compile — `E2bEx.FilesystemEvent.__struct__/1 is undefined`.

- [ ] **Step 3: Create the struct**

Create `lib/e2b_ex/filesystem_event.ex`:

```elixir
defmodule E2bEx.FilesystemEvent do
  @moduledoc "A filesystem change event from `E2bEx.Filesystem.watch_dir/4`."

  alias E2bEx.EntryInfo

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: :create | :write | :remove | :rename | :chmod | nil,
          entry: EntryInfo.t() | nil
        }

  defstruct [:name, :type, :entry]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      name: m["name"],
      type: decode_type(m["type"]),
      entry: decode_entry(m["entry"])
    }
  end

  defp decode_type("EVENT_TYPE_CREATE"), do: :create
  defp decode_type("EVENT_TYPE_WRITE"), do: :write
  defp decode_type("EVENT_TYPE_REMOVE"), do: :remove
  defp decode_type("EVENT_TYPE_RENAME"), do: :rename
  defp decode_type("EVENT_TYPE_CHMOD"), do: :chmod
  defp decode_type(_), do: nil

  defp decode_entry(m) when is_map(m), do: EntryInfo.from_api(m)
  defp decode_entry(_), do: nil
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/filesystem_event_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/filesystem_event.ex test/e2b_ex/filesystem_event_test.exs
git commit -m "feat(fs-watch): add E2bEx.FilesystemEvent struct"
```

---

## Task 2: `E2bEx.Filesystem.WatchHandle` struct + `stop/1`

**Files:**
- Create: `lib/e2b_ex/filesystem/watch_handle.ex`
- Test: `test/e2b_ex/filesystem/watch_handle_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/filesystem/watch_handle_test.exs` (uses a plain `Agent` — itself a GenServer — as a stand-in server, so `stop/1` is testable without the full streaming stack):

```elixir
defmodule E2bEx.Filesystem.WatchHandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.Filesystem.WatchHandle

  test "stop/1 stops a live server and returns :ok" do
    {:ok, server} = Agent.start(fn -> 0 end)
    handle = %WatchHandle{server: server, ref: make_ref()}

    assert :ok = WatchHandle.stop(handle)
    refute Process.alive?(server)
  end

  test "stop/1 is a no-op (still :ok) when the server is already dead" do
    {:ok, server} = Agent.start(fn -> 0 end)
    :ok = Agent.stop(server)

    assert :ok = WatchHandle.stop(%WatchHandle{server: server, ref: make_ref()})
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/filesystem/watch_handle_test.exs`
Expected: FAIL to compile — `E2bEx.Filesystem.WatchHandle.__struct__/1 is undefined`.

- [ ] **Step 3: Create the handle**

Create `lib/e2b_ex/filesystem/watch_handle.ex`:

```elixir
defmodule E2bEx.Filesystem.WatchHandle do
  @moduledoc """
  A handle to a directory watch started with `E2bEx.Filesystem.watch_dir/4`.

  Change events are delivered to the subscriber process as messages tagged with
  the handle's `ref`:

      {ref, {:fs_event, %E2bEx.FilesystemEvent{}}}   # each change, live
      {ref, {:error, %E2bEx.Error{}}}                # the stream failed or closed

  `KeepAlive` frames produce no message. `stop/1` ends the watch (no terminal
  message is sent).
  """

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: pid(), ref: reference()}

  @doc "Stop the watch and close the stream. Always returns `:ok`."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{server: server}) do
    if Process.alive?(server), do: GenServer.stop(server)
    :ok
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/filesystem/watch_handle_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/filesystem/watch_handle.ex test/e2b_ex/filesystem/watch_handle_test.exs
git commit -m "feat(fs-watch): add Filesystem.WatchHandle struct + stop/1"
```

---

## Task 3: `WatchServer` + `Filesystem.watch_dir/4`

The streaming core. `WatchServer` is modeled on `Commands.HandleServer`, dispatching the bare `WatchDirResponse` frames; `watch_dir/4` spawns it and awaits the `StartEvent`. Tested end-to-end via Bypass.

**Files:**
- Create: `lib/e2b_ex/filesystem/watch_server.ex`
- Modify: `lib/e2b_ex/filesystem.ex`
- Test: `test/e2b_ex/filesystem/watch_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/filesystem/watch_test.exs`:

```elixir
defmodule E2bEx.Filesystem.WatchTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, EntryInfo, Error, Filesystem, FilesystemEvent, Sandbox}
  alias E2bEx.Envd.Connect

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp chunk_bytes(bin, n) when byte_size(bin) > n do
    <<part::binary-size(n), rest::binary>> = bin
    [part | chunk_bytes(rest, n)]
  end

  defp chunk_bytes(bin, _n), do: [bin]

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "watch_dir/4 sends the request, returns a handle on start, and streams events",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"path" => "/d", "recursive" => true, "includeEntry" => true}

      body =
        frame(%{"start" => %{}}) <>
          frame(%{
            "filesystem" => %{
              "name" => "/d/a.txt",
              "type" => "EVENT_TYPE_CREATE",
              "entry" => %{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt"}
            }
          }) <>
          frame(%{"keepalive" => %{}}) <>
          frame(%{"filesystem" => %{"name" => "/d/a.txt", "type" => "EVENT_TYPE_WRITE"}}) <>
          trailer("{}")

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunk_bytes(body, 7), conn, fn part, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, part)
        conn
      end)
    end)

    {:ok, handle} =
      Filesystem.watch_dir(client(), sandbox(), "/d",
        recursive: true,
        include_entry: true,
        base_url: base_url
      )

    ref = handle.ref

    assert_receive {^ref,
                    {:fs_event,
                     %FilesystemEvent{
                       name: "/d/a.txt",
                       type: :create,
                       entry: %EntryInfo{name: "a.txt", type: :file}
                     }}}

    refute_receive {^ref, {:fs_event, %FilesystemEvent{type: nil}}}, 0
    assert_receive {^ref, {:fs_event, %FilesystemEvent{name: "/d/a.txt", type: :write, entry: nil}}}
    # a clean close ends the watch with a terminal error (watch has no result)
    assert_receive {^ref, {:error, %Error{message: "watch stream closed"}}}
  end

  test "watch_dir/4 defaults recursive/include_entry to false", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"path" => "/d", "recursive" => false, "includeEntry" => false}
      Plug.Conn.resp(conn, 200, frame(%{"start" => %{}}) <> trailer("{}"))
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    assert_receive {_ref, {:error, %Error{message: "watch stream closed"}}}
    assert is_reference(handle.ref)
  end

  test "watch_dir/4 returns {:error, _} on a non-2xx before the start event",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"code":"unauthenticated","message":"no token"}))
    end)

    assert {:error, %Error{}} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
  end

  test "a Connect trailer error mid-stream is delivered as a terminal {:error}",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      body =
        frame(%{"start" => %{}}) <>
          trailer(~s({"error":{"code":"unavailable","message":"gone"}}))

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    ref = handle.ref
    assert_receive {^ref, {:error, %Error{message: "gone", reason: "unavailable"}}}
  end

  test "stop/1 ends the watch and sends no terminal message", %{bypass: bypass, base_url: base_url} do
    Bypass.expect(bypass, "POST", "/filesystem.Filesystem/WatchDir", fn conn ->
      # Stream only a start event, then keepalives, so the watch stays open. Trap
      # exits so cancelling the request (cowboy :shutdown EXIT) is caught and the
      # handler exits cleanly — same pattern as the commands disconnect test.
      Process.flag(:trap_exit, true)
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(%{"start" => %{}}))

      Enum.reduce_while(1..200, conn, fn _, conn ->
        receive do
          {:EXIT, _, _} -> {:halt, conn}
        after
          10 ->
            case Plug.Conn.chunk(conn, frame(%{"keepalive" => %{}})) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
        end
      end)
    end)

    {:ok, handle} = Filesystem.watch_dir(client(), sandbox(), "/d", base_url: base_url)
    ref = handle.ref
    server = handle.server
    assert :ok = E2bEx.Filesystem.WatchHandle.stop(handle)
    refute Process.alive?(server)
    refute_receive {^ref, {:error, _}}, 50
    refute_receive {^ref, {:fs_event, _}}, 50
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/filesystem/watch_test.exs`
Expected: FAIL — `E2bEx.Filesystem.watch_dir/4 is undefined`.

- [ ] **Step 3: Create the `WatchServer`**

Create `lib/e2b_ex/filesystem/watch_server.ex`:

```elixir
defmodule E2bEx.Filesystem.WatchServer do
  @moduledoc false
  # GenServer owning one WatchDir server-stream (Req `into: :self`). Decodes
  # Connect frames and pushes `{ref, {:fs_event, %FilesystemEvent{}}}` to a
  # subscriber, then a terminal `{ref, {:error, %Error{}}}` when the stream fails
  # or closes (watch has no result). Replies to `:await_start` with `:ok` on the
  # first `start` frame. Modeled on `E2bEx.Commands.HandleServer`; the key
  # difference is that WatchDir frames are bare `WatchDirResponse` (no `event`
  # wrapper).

  use GenServer

  alias E2bEx.{Error, FilesystemEvent}
  alias E2bEx.Envd.Connect

  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(arg) when is_map(arg), do: GenServer.start(__MODULE__, arg)

  @impl true
  def init(arg) do
    state = %{
      ctx: arg.ctx,
      path: arg.path,
      request: arg.request,
      subscriber: arg.subscriber,
      ref: arg.ref,
      timeout_ms: arg.timeout_ms,
      resp: nil,
      status: nil,
      decoder: Connect.Decoder.new(),
      trailer: nil,
      error_body: "",
      started?: false,
      await_from: nil,
      start_error: nil
    }

    {:ok, state, {:continue, :request}}
  end

  @impl true
  def handle_continue(:request, state) do
    body = Connect.encode_frame(Jason.encode!(state.request))

    req =
      Req.new(
        method: :post,
        base_url: state.ctx.base_url,
        url: state.path,
        headers: state.ctx.headers,
        body: body,
        retry: false,
        decode_body: false,
        compressed: false,
        into: :self,
        receive_timeout: receive_timeout(state.timeout_ms)
      )
      |> Req.merge(state.ctx.req_options)

    case Req.request(req) do
      {:ok, resp} ->
        {:noreply, %{state | resp: resp, status: resp.status}}

      {:error, exception} ->
        continue_after(failure(state, Error.from_exception(exception)))
    end
  end

  @impl true
  def handle_call(:await_start, from, state) do
    cond do
      state.started? -> {:reply, :ok, state}
      state.start_error != nil -> {:stop, :normal, {:error, state.start_error}, state}
      true -> {:noreply, %{state | await_from: from}}
    end
  end

  @impl true
  def handle_info(message, %{resp: resp} = state) when not is_nil(resp) do
    case Req.parse_message(resp, message) do
      {:ok, parts} -> process_parts(parts, state)
      {:error, reason} -> continue_after(failure(state, %Error{message: "envd stream error", reason: reason}))
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.resp, do: Req.cancel_async_response(state.resp)
    :ok
  end

  # ---- streamed parts ----

  defp process_parts(parts, state) do
    parts
    |> Enum.reduce_while({:cont, state}, fn part, {:cont, state} ->
      case process_part(part, state) do
        {:cont, _} = ok -> {:cont, ok}
        {:stop, _} = stop -> {:halt, stop}
      end
    end)
    |> continue_after()
  end

  defp process_part({:data, chunk}, %{status: status} = state) when status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp process_part(:done, %{status: status} = state) when status not in 200..299 do
    failure(state, Error.from_response(%Req.Response{status: status, body: state.error_body}))
  end

  defp process_part({:data, chunk}, state) do
    case Connect.Decoder.push(state.decoder, chunk) do
      {:ok, messages, trailer, decoder} ->
        apply_messages(messages, %{state | decoder: decoder, trailer: trailer || state.trailer})

      {:error, reason} ->
        failure(state, malformed(reason))
    end
  end

  defp process_part(:done, state) do
    trailer_error = Connect.trailer_error(state.trailer)

    cond do
      state.decoder.buffer != "" -> failure(state, malformed(:malformed_frame))
      match?(%Error{}, trailer_error) -> failure(state, trailer_error)
      not state.started? -> failure(state, %Error{message: "watch failed to start"})
      true -> failure(state, %Error{message: "watch stream closed"})
    end
  end

  defp process_part({:trailers, _}, state), do: {:cont, state}

  # WatchDir frames are bare WatchDirResponse: %{"start"|"filesystem"|"keepalive" => _}.
  defp apply_messages(messages, state) do
    {:cont, Enum.reduce(messages, state, &dispatch/2)}
  end

  defp dispatch(%{"start" => _}, state), do: mark_started(state)

  defp dispatch(%{"filesystem" => fs}, state) do
    send_msg(state, {:fs_event, FilesystemEvent.from_api(fs)})
    state
  end

  defp dispatch(_other, state), do: state

  defp mark_started(%{started?: true} = state), do: state

  defp mark_started(state) do
    state = %{state | started?: true}

    if state.await_from do
      GenServer.reply(state.await_from, :ok)
      %{state | await_from: nil}
    else
      state
    end
  end

  # Deliver an error: to the subscriber if watching is active, else to the
  # await_start caller, else stash until await_start arrives.
  defp failure(state, error) do
    cond do
      state.started? ->
        send_msg(state, {:error, error})
        {:stop, state}

      state.await_from != nil ->
        GenServer.reply(state.await_from, {:error, error})
        {:stop, %{state | await_from: nil}}

      true ->
        {:cont, %{state | start_error: state.start_error || error}}
    end
  end

  defp continue_after({:cont, state}), do: {:noreply, state}
  defp continue_after({:stop, state}), do: {:stop, :normal, state}

  defp send_msg(state, payload), do: send(state.subscriber, {state.ref, payload})

  defp malformed(reason), do: %Error{message: "malformed envd response", reason: reason}

  defp receive_timeout(0), do: :infinity
  defp receive_timeout(ms), do: ms + 5_000
end
```

- [ ] **Step 4: Add `watch_dir/4` to `E2bEx.Filesystem`**

In `lib/e2b_ex/filesystem.ex`, add `WatchHandle`/`WatchServer` to the aliases and a `@watch_path`, then add `watch_dir/4` and the `spawn_watch/3` helper.

Change the alias block near the top from:

```elixir
  alias E2bEx.{Client, EntryInfo, Error, Sandbox}
  alias E2bEx.Envd.Rpc
```

to:

```elixir
  alias E2bEx.{Client, EntryInfo, Error, Sandbox}
  alias E2bEx.Envd.Rpc
  alias E2bEx.Filesystem.{WatchHandle, WatchServer}
```

Add the path constant next to the other `@*_path` module attributes:

```elixir
  @watch_path "/filesystem.Filesystem/WatchDir"
```

Add these functions after `write/5` (before the private `write_info/1`):

```elixir
  @doc """
  Watch a directory for changes (`WatchDir`), returning a `%E2bEx.Filesystem.WatchHandle{}`.

  Change events are pushed to the subscriber (`opts[:subscriber]`, default the
  caller) as `{handle.ref, {:fs_event, %E2bEx.FilesystemEvent{}}}`, ending with a
  terminal `{handle.ref, {:error, %E2bEx.Error{}}}` if the stream fails or closes.
  Call `E2bEx.Filesystem.WatchHandle.stop/1` to end the watch.

  ## Options
    * `:recursive` — watch subdirectories too (default `false`).
    * `:include_entry` — include the `%EntryInfo{}` of the affected entry in each
      event when available (default `false`).
    * `:subscriber` — pid to receive event messages (default the caller).
    * `:user`, `:timeout_ms`, `:domain`, `:port`, `:base_url` — as for the other
      `E2bEx.Filesystem` functions.
  """
  @spec watch_dir(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, WatchHandle.t()} | {:error, Error.t()}
  def watch_dir(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      request = %{
        path: path,
        recursive: opts[:recursive] || false,
        includeEntry: opts[:include_entry] || false
      }

      spawn_watch(ctx, request, opts)
    end
  end

  defp spawn_watch(ctx, request, opts) do
    ref = make_ref()
    subscriber = opts[:subscriber] || self()

    arg = %{
      ctx: ctx,
      path: @watch_path,
      request: request,
      subscriber: subscriber,
      ref: ref,
      timeout_ms: ctx.timeout_ms
    }

    with {:ok, server} <- WatchServer.start(arg) do
      await = if ctx.timeout_ms == 0, do: :infinity, else: ctx.timeout_ms

      try do
        case GenServer.call(server, :await_start, await) do
          :ok -> {:ok, %WatchHandle{server: server, ref: ref}}
          {:error, error} -> {:error, error}
        end
      catch
        :exit, _ -> {:error, %Error{message: "watch failed to start"}}
      end
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/filesystem/watch_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Run the full suite + strict compile**

Run: `mix test`
Expected: all pass.

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/e2b_ex/filesystem/watch_server.ex lib/e2b_ex/filesystem.ex test/e2b_ex/filesystem/watch_test.exs
git commit -m "feat(fs-watch): add WatchServer + Filesystem.watch_dir/4"
```

---

## Task 4: README documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a watch example to the Filesystem section**

In `README.md`, find the `## Filesystem` section. After its closing line (the one that mentions watching being planned — `Watching for live filesystem changes is planned for a later release.`), **replace that single line** with this watch subsection:

    Watch a directory for live changes; events are pushed to your process:

    ```elixir
    {:ok, watch} = E2bEx.Filesystem.watch_dir(client, sandbox, "/app", recursive: true)

    receive do
      {ref, {:fs_event, %E2bEx.FilesystemEvent{type: type, name: name}}} when ref == watch.ref ->
        IO.puts("#{type}: #{name}")
    end

    :ok = E2bEx.Filesystem.WatchHandle.stop(watch)
    ```

(The code block above must be a REAL fenced ```elixir block — it is indented here only to embed it in this plan.)

- [ ] **Step 2: Verify**

Run: `grep -n "watch_dir\|fs_event" README.md`
Expected: shows the new `watch_dir`/`fs_event` example.

Run: `grep -c "Watching for live filesystem changes is planned" README.md`
Expected: `0` (the old "planned" line is gone).

Re-read the section to confirm the ```elixir fence is well-formed.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(fs-watch): document Filesystem.watch_dir in README"
```

---

## Final Review

After all tasks, dispatch a final reviewer over the whole change, then use `superpowers:finishing-a-development-branch`.

Sanity checklist before merge:
- [ ] `mix test` green; `mix compile --warnings-as-errors` clean.
- [ ] `FilesystemEvent.from_api/1` decodes the EventType enum + nested entry.
- [ ] `watch_dir/4` returns a handle on the `start` frame; pushes `{:fs_event, _}` for `filesystem` frames (entry present and absent); ignores `keepalive`; a clean close → terminal `{:error, "watch stream closed"}`; a Connect trailer error → terminal `{:error, _}`; a pre-start non-2xx → `{:error, _}` from `watch_dir/4`.
- [ ] `WatchServer` dispatches **bare** `WatchDirResponse` frames (no `event` wrapper); `terminate/2` cancels the async response; `stop/1` sends no terminal message.
- [ ] No changes to `Commands.HandleServer`/`Commands`/`Rpc`/Phase-1 `Filesystem` behavior (only `watch_dir/4` added to `Filesystem`).
- [ ] README has a `watch_dir` example; the "planned" line is gone.
```
