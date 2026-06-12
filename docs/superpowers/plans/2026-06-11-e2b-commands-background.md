# E2bEx Commands — Phase 2: Background execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add background command execution to `E2bEx.Commands` — `start/4` returns a process-backed `%CommandHandle{}` that streams output as `{ref, …}` messages, plus `wait`, `kill`, `send_stdin`, `close_stdin`, `disconnect`, `list`, and `connect` (reconnect).

**Architecture:** A `HandleServer` GenServer owns one `Start`/`Connect` server-stream via Req `into: :self`, folds events through a shared pure `Commands.Fold`, and pushes `{ref, {:stdout|:stderr, _}}` / terminal `{ref, {:exit|:error, _}}` messages to a subscriber. The control RPCs (`List`/`SendSignal`/`SendInput`/`CloseStdin`) are independent **unary** JSON calls via a new `Envd.Rpc` layer, keyed by pid, run in the caller's process. `run/4` is refactored onto `Fold` + `Rpc` with unchanged behavior.

**Tech Stack:** Elixir, `Req` 0.6.1 (`into: :self`, `parse_message/2`, `cancel_async_response/1`, unary JSON), `Jason`, `Bypass` (test), ExUnit, GenServer.

**Spec:** `docs/superpowers/specs/2026-06-11-e2b-commands-background-design.md`

---

## File Structure

- **Create** `lib/e2b_ex/commands/fold.ex` — `E2bEx.Commands.Fold`: pure, delivery-agnostic event folding into a `%CommandResult{}` (+ `ended?`).
- **Create** `lib/e2b_ex/envd/rpc.ex` — `E2bEx.Envd.Rpc`: envd connection-context builder, unary Connect call, and control wrappers (`kill`/`send_stdin`/`close_stdin`/`list`).
- **Create** `lib/e2b_ex/process_info.ex` — `E2bEx.ProcessInfo` struct + `from_api/1`.
- **Create** `lib/e2b_ex/commands/handle_server.ex` — `E2bEx.Commands.HandleServer`: GenServer owning one stream.
- **Create** `lib/e2b_ex/command_handle.ex` — `E2bEx.CommandHandle` struct + `wait`/`kill`/`send_stdin`/`close_stdin`/`disconnect`/`pid`.
- **Modify** `lib/e2b_ex/envd/connect.ex` — add `trailer_error/1`.
- **Modify** `lib/e2b_ex/commands.ex` — refactor `run/4` onto `Fold`/`Rpc`/`Connect.trailer_error`; add `start/4`, `connect/4`, `list/2`, `kill/4`, `send_stdin/5`, `close_stdin/4`.
- **Create** tests: `test/e2b_ex/commands/fold_test.exs`, `test/e2b_ex/envd/rpc_test.exs`, `test/e2b_ex/process_info_test.exs`, `test/e2b_ex/commands_control_test.exs`, `test/e2b_ex/commands_background_test.exs`, `test/e2b_ex/command_handle_test.exs`.
- **Modify** `README.md`.

Existing Phase 1 tests (`test/e2b_ex/commands_test.exs`, 87 total) are the regression guard for the `run/4` refactor and must stay green throughout.

---

## Task 1: `E2bEx.Commands.Fold` (pure event folding)

**Files:**
- Create: `lib/e2b_ex/commands/fold.ex`
- Test: `test/e2b_ex/commands/fold_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/commands/fold_test.exs`:

```elixir
defmodule E2bEx.Commands.FoldTest do
  use ExUnit.Case, async: true
  alias E2bEx.Commands.Fold
  alias E2bEx.CommandResult

  test "folds a stdout data event, returning the decoded output" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => Base.encode64("hi")}})
    assert outputs == [{:stdout, "hi"}]
    assert Fold.result(acc) == %CommandResult{stdout: "hi"}
  end

  test "folds a stderr data event" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"data" => %{"stderr" => Base.encode64("oops")}})
    assert outputs == [{:stderr, "oops"}]
    assert Fold.result(acc).stderr == "oops"
  end

  test "accumulates across events and marks ended on the end event" do
    {:ok, acc, _} = Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => Base.encode64("a")}})
    {:ok, acc, _} = Fold.apply_event(acc, %{"data" => %{"stdout" => Base.encode64("b")}})
    refute Fold.ended?(acc)
    {:ok, acc, outputs} = Fold.apply_event(acc, %{"end" => %{"exitCode" => 3, "error" => "boom"}})
    assert outputs == []
    assert Fold.ended?(acc)
    assert Fold.result(acc) == %CommandResult{stdout: "ab", exit_code: 3, error: "boom"}
  end

  test "defaults exit_code to 0 when the end event omits it" do
    {:ok, acc, _} = Fold.apply_event(Fold.new(), %{"end" => %{"exited" => true}})
    assert Fold.result(acc).exit_code == 0
    assert Fold.result(acc).error == nil
  end

  test "ignores start and keepalive events with no output" do
    {:ok, acc, outputs} = Fold.apply_event(Fold.new(), %{"start" => %{"pid" => 7}})
    assert outputs == []
    assert Fold.result(acc) == %CommandResult{}
    {:ok, _acc, outputs} = Fold.apply_event(acc, %{"keepalive" => %{}})
    assert outputs == []
  end

  test "returns an error on an invalid base64 chunk" do
    assert {:error, :invalid_base64} =
             Fold.apply_event(Fold.new(), %{"data" => %{"stdout" => "!!! not base64 !!!"}})
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/commands/fold_test.exs`
Expected: FAIL — `E2bEx.Commands.Fold` is not available.

- [ ] **Step 3: Implement `Fold`**

Create `lib/e2b_ex/commands/fold.ex`:

```elixir
defmodule E2bEx.Commands.Fold do
  @moduledoc false
  # Pure, delivery-agnostic folding of decoded Connect process events into a
  # CommandResult. `apply_event/2` returns the produced output events so callers
  # deliver them however they like: run/4 turns them into on_stdout/on_stderr
  # callbacks, HandleServer into `{ref, _}` messages.

  alias E2bEx.CommandResult

  @type output :: {:stdout, binary()} | {:stderr, binary()}
  @type t :: %{result: CommandResult.t(), ended: boolean()}

  @spec new() :: t()
  def new, do: %{result: %CommandResult{}, ended: false}

  @spec apply_event(t(), map()) :: {:ok, t(), [output()]} | {:error, :invalid_base64}
  def apply_event(acc, %{"data" => %{"stdout" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      {:ok, %{acc | result: %{acc.result | stdout: acc.result.stdout <> bytes}}, [{:stdout, bytes}]}
    end
  end

  def apply_event(acc, %{"data" => %{"stderr" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      {:ok, %{acc | result: %{acc.result | stderr: acc.result.stderr <> bytes}}, [{:stderr, bytes}]}
    end
  end

  def apply_event(acc, %{"end" => end_event}) do
    result = %{
      acc.result
      | exit_code: Map.get(end_event, "exitCode", 0),
        error: Map.get(end_event, "error")
    }

    {:ok, %{acc | result: result, ended: true}, []}
  end

  def apply_event(acc, _other), do: {:ok, acc, []}

  @spec result(t()) :: CommandResult.t()
  def result(%{result: result}), do: result

  @spec ended?(t()) :: boolean()
  def ended?(%{ended: ended}), do: ended

  defp decode_chunk(chunk) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/commands/fold_test.exs`
Expected: PASS (6 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/commands/fold.ex test/e2b_ex/commands/fold_test.exs
git commit -m "feat: add pure Commands.Fold event folding"
```

---

## Task 2: Move `trailer_error/1` to `Connect`; refactor `run/4` onto `Fold`

**Files:**
- Modify: `lib/e2b_ex/envd/connect.ex`, `lib/e2b_ex/commands.ex`
- Test (guard, unchanged): `test/e2b_ex/commands_test.exs`, `test/e2b_ex/envd/connect_test.exs`

This is a behavior-preserving refactor. The Phase 1 command tests are the guard.

- [ ] **Step 1: Confirm the guard tests pass first**

Run: `mix test`
Expected: PASS (87 tests, 0 failures).

- [ ] **Step 2: Add `trailer_error/1` to `Connect`**

In `lib/e2b_ex/envd/connect.ex`, add `alias E2bEx.Error` near the top (after the `import Bitwise` line is gone — the module currently has `alias E2bEx.Envd.Connect.Decoder`; add `alias E2bEx.Error`), and add this function (e.g. after `decode_frames/1`):

```elixir
  @doc """
  Map an end-of-stream trailer to an `%E2bEx.Error{}` when it carries a Connect
  error, or `nil` for a success/`nil` trailer.
  """
  @spec trailer_error(map() | nil) :: E2bEx.Error.t() | nil
  def trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  def trailer_error(_), do: nil
```

- [ ] **Step 3: Refactor `commands.ex` `run/4` internals onto `Fold` + `Connect.trailer_error`**

In `lib/e2b_ex/commands.ex`: add `alias E2bEx.Commands.Fold` to the existing alias block. Replace the streaming-collection section (the private functions `new_state/1`, `consume/2`, `apply_messages/2`, `apply_event/2` clauses, `invoke/2`, `finalize/1`, `trailer_error/1`, `decode_chunk/1`) with the versions below. Keep `run/4`, `collector/1`, the request-building helpers (`fetch_sandbox_id/1`, `domain_from/1`, `start_request/2`, `headers/5`, `with_timeout/2`, `put_present/3`, `put_when/3`) unchanged for now (Task 3 handles the `Rpc` extraction).

Replace from `defp new_state(opts) do` through the end of `defp decode_chunk(chunk) do ... end` with:

```elixir
  defp new_state(opts) do
    %{
      decoder: Connect.Decoder.new(),
      fold: Fold.new(),
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
      case Fold.apply_event(state.fold, message["event"]) do
        {:ok, fold, outputs} ->
          Enum.each(outputs, fn
            {:stdout, bytes} -> invoke(state.on_stdout, bytes)
            {:stderr, bytes} -> invoke(state.on_stderr, bytes)
          end)

          {:cont, {:ok, %{state | fold: fold}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

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

      state.decoder.buffer != "" ->
        {:error, %Error{message: "malformed envd response", reason: :malformed_frame, body: resp.body}}

      true ->
        case Connect.trailer_error(state.trailer) do
          %Error{} = error -> {:error, error}
          nil -> {:ok, Fold.result(state.fold)}
        end
    end
  end
```

(The old `apply_event/2` clauses, `trailer_error/1`, and `decode_chunk/1` in `commands.ex` are deleted — that logic now lives in `Fold` and `Connect`.)

- [ ] **Step 4: Run the full suite + strict compile**

Run: `mix test && mix compile --warnings-as-errors`
Expected: PASS (87 tests, 0 failures); clean compile (no unused-function warnings).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/envd/connect.ex lib/e2b_ex/commands.ex
git commit -m "refactor: run/4 folds via Commands.Fold; trailer_error moves to Connect"
```

---

## Task 3: `E2bEx.Envd.Rpc` context + unary; refactor `run/4` onto `Rpc.context`

**Files:**
- Create: `lib/e2b_ex/envd/rpc.ex`
- Modify: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/envd/rpc_test.exs`; guard: `test/e2b_ex/commands_test.exs`

- [ ] **Step 1: Write the failing `Rpc` tests**

Create `test/e2b_ex/envd/rpc_test.exs`:

```elixir
defmodule E2bEx.Envd.RpcTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Error, Sandbox}
  alias E2bEx.Envd.Rpc

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  describe "context/3" do
    test "builds base_url, headers and timeout from client/sandbox/opts" do
      {:ok, ctx} = Rpc.context(client(), sandbox(), [])
      assert ctx.base_url == "https://49983-sb_1.e2b.app"
      assert ctx.sandbox_id == "sb_1"
      assert ctx.headers["e2b-sandbox-id"] == "sb_1"
      assert ctx.headers["x-access-token"] == "tok_1"
      assert ctx.timeout_ms == 60_000
    end

    test "honours :base_url, :port and :domain overrides" do
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:1234")
      assert ctx.base_url == "http://localhost:1234"
      {:ok, ctx} = Rpc.context(client(), %Sandbox{sandbox_id: "s", domain: nil}, port: 9, domain: "x.io")
      assert ctx.base_url == "https://9-s.x.io"
    end

    test "errors when the sandbox is missing its id" do
      assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
               Rpc.context(client(), %Sandbox{sandbox_id: nil}, [])
    end
  end

  describe "unary/4 (via Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, ctx: ctx}
    end

    test "posts bare JSON with envd headers and returns the decoded body", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-access-token") == ["tok_1"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, ~s({"processes":[]}))
      end)

      assert {:ok, %{"processes" => []}} = Rpc.unary(ctx, "/process.Process/List", %{})
    end

    test "maps a non-2xx Connect error body to %Error{}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"no such process"}))
      end)

      assert {:error, %Error{status: 404, code: "not_found", message: "no such process"}} =
               Rpc.unary(ctx, "/process.Process/SendSignal", %{process: %{pid: 9}})
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/envd/rpc_test.exs`
Expected: FAIL — `E2bEx.Envd.Rpc` is not available.

- [ ] **Step 3: Implement `Rpc` context + unary**

Create `lib/e2b_ex/envd/rpc.ex`:

```elixir
defmodule E2bEx.Envd.Rpc do
  @moduledoc false
  # The envd request layer: builds the per-sandbox connection context (base_url +
  # headers) shared by the streaming and unary paths, and issues unary Connect
  # calls (bare JSON). Control wrappers (kill/send_stdin/close_stdin/list) are
  # added in a later task.

  alias E2bEx.{Client, Error, Sandbox}

  @default_port 49_983
  @default_domain "e2b.app"
  @default_timeout_ms 60_000

  @type ctx :: %{
          base_url: String.t(),
          headers: map(),
          sandbox_id: String.t(),
          port: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          req_options: keyword()
        }

  @doc "Build the envd connection context, or `{:error, %Error{}}` if the sandbox has no id."
  @spec context(Client.t(), Sandbox.t(), keyword()) :: {:ok, ctx()} | {:error, Error.t()}
  def context(%Client{} = client, %Sandbox{} = sandbox, opts) do
    with {:ok, sandbox_id} <- fetch_sandbox_id(sandbox) do
      domain = sandbox.domain || opts[:domain] || domain_from(client)
      port = opts[:port] || @default_port
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      base_url = opts[:base_url] || "https://#{port}-#{sandbox_id}.#{domain}"

      ctx = %{
        base_url: base_url,
        headers: headers(sandbox, sandbox_id, port, timeout_ms, opts),
        sandbox_id: sandbox_id,
        port: port,
        timeout_ms: timeout_ms,
        req_options: client.req_options
      }

      {:ok, ctx}
    end
  end

  @doc "Issue a unary Connect call (bare JSON) to the envd `path`."
  @spec unary(ctx(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def unary(ctx, path, request_map, opts \\ []) do
    req =
      Req.new(
        method: :post,
        base_url: ctx.base_url,
        url: path,
        headers: Map.delete(ctx.headers, "content-type"),
        json: request_map,
        retry: false
      )
      |> Req.merge(ctx.req_options)
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
      {:error, exception} -> {:error, Error.from_exception(exception)}
    end
  end

  defp fetch_sandbox_id(%Sandbox{sandbox_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_sandbox_id(_), do: {:error, %Error{message: "sandbox is missing :sandbox_id"}}

  defp domain_from(%Client{base_url: base_url}) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "api.", "")
      _ -> @default_domain
    end
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

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 4: Refactor `run/4` to build its request from `Rpc.context`**

In `lib/e2b_ex/commands.ex`: add `alias E2bEx.Envd.Rpc` to the alias block, then rewrite `run/4` to obtain the context from `Rpc` and use `ctx.headers`/`ctx.base_url`/`ctx.timeout_ms`/`ctx.req_options`. Replace the `run/4` body with:

```elixir
  def run(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      body = Connect.encode_frame(Jason.encode!(start_request(command, opts)))

      req =
        Req.new(
          method: :post,
          base_url: ctx.base_url,
          url: @start_path,
          headers: ctx.headers,
          body: body,
          retry: false,
          decode_body: false,
          compressed: false,
          into: collector(opts)
        )
        |> Req.merge(ctx.req_options)
        |> with_timeout(ctx.timeout_ms)

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
```

Then delete the now-unused private helpers from `commands.ex`: `fetch_sandbox_id/1`, `domain_from/1`, `headers/5`, `put_when/3` (all now live in `Rpc`). Keep `@start_path`, `start_request/2`, `with_timeout/2`, `put_present/3`, `collector/1`, and the streaming helpers from Task 2.

**Important — the module attributes are referenced by `run/4`'s `@doc`.** The `run/4` docstring interpolates `#{@default_timeout_ms}` and `#{@default_port}`, so deleting those attributes would break compilation. Before deleting them, edit the `run/4` `@doc` to use literals instead:
- change `` default `#{@default_timeout_ms}`, `0` disables. `` to `` default `60000`, `0` disables. ``
- change `` envd port; default `#{@default_port}`. `` to `` envd port; default `49983`. ``

Then delete all three attributes `@default_port`, `@default_domain`, `@default_timeout_ms` from `commands.ex` (they now live only in `Rpc`).

- [ ] **Step 5: Run the suite + strict compile**

Run: `mix test && mix compile --warnings-as-errors`
Expected: PASS (87 + 5 Rpc = 92 tests, 0 failures); clean compile (no unused-function/attribute warnings — verify the deleted helpers/attributes are truly unused in `commands.ex`).

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/envd/rpc.ex lib/e2b_ex/commands.ex test/e2b_ex/envd/rpc_test.exs
git commit -m "feat: add Envd.Rpc context/unary; run/4 builds its request from it"
```

---

## Task 4: `E2bEx.ProcessInfo`

**Files:**
- Create: `lib/e2b_ex/process_info.ex`
- Test: `test/e2b_ex/process_info_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/process_info_test.exs`:

```elixir
defmodule E2bEx.ProcessInfoTest do
  use ExUnit.Case, async: true
  alias E2bEx.ProcessInfo

  test "from_api/1 maps a ListResponse entry with full config" do
    entry = %{
      "pid" => 42,
      "tag" => "build",
      "config" => %{
        "cmd" => "/bin/bash",
        "args" => ["-l", "-c", "make"],
        "envs" => %{"FOO" => "bar"},
        "cwd" => "/work"
      }
    }

    assert ProcessInfo.from_api(entry) == %ProcessInfo{
             pid: 42,
             tag: "build",
             cmd: "/bin/bash",
             args: ["-l", "-c", "make"],
             envs: %{"FOO" => "bar"},
             cwd: "/work"
           }
  end

  test "from_api/1 tolerates a missing tag, cwd, args and envs" do
    entry = %{"pid" => 7, "config" => %{"cmd" => "sleep"}}

    assert ProcessInfo.from_api(entry) == %ProcessInfo{
             pid: 7,
             tag: nil,
             cmd: "sleep",
             args: [],
             envs: %{},
             cwd: nil
           }
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/process_info_test.exs`
Expected: FAIL — `E2bEx.ProcessInfo` is not available.

- [ ] **Step 3: Implement `ProcessInfo`**

Create `lib/e2b_ex/process_info.ex`:

```elixir
defmodule E2bEx.ProcessInfo do
  @moduledoc """
  A running command or PTY session, as returned by `E2bEx.Commands.list/2`.
  """

  @type t :: %__MODULE__{
          pid: non_neg_integer(),
          tag: String.t() | nil,
          cmd: String.t(),
          args: [String.t()],
          envs: %{String.t() => String.t()},
          cwd: String.t() | nil
        }

  defstruct [:pid, :tag, :cmd, :args, :envs, :cwd]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(%{"config" => config} = entry) do
    %__MODULE__{
      pid: entry["pid"],
      tag: entry["tag"],
      cmd: config["cmd"],
      args: config["args"] || [],
      envs: config["envs"] || %{},
      cwd: config["cwd"]
    }
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/process_info_test.exs`
Expected: PASS (2 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/process_info.ex test/e2b_ex/process_info_test.exs
git commit -m "feat: add E2bEx.ProcessInfo struct"
```

---

## Task 5: `Rpc` control wrappers (`kill`/`send_stdin`/`close_stdin`/`list`)

**Files:**
- Modify: `lib/e2b_ex/envd/rpc.ex`
- Test: `test/e2b_ex/envd/rpc_test.exs`

- [ ] **Step 1: Write the failing tests**

Append these to `test/e2b_ex/envd/rpc_test.exs` inside the module (after the `unary/4` describe block):

```elixir
  describe "control wrappers (via Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, ctx: ctx}
    end

    test "kill/2 sends SIGKILL and returns {:ok, true} on success", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}, "signal" => "SIGNAL_SIGKILL"}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, true} = Rpc.kill(ctx, 7)
    end

    test "kill/2 returns {:ok, false} on a not_found Connect error", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"gone"}))
      end)

      assert {:ok, false} = Rpc.kill(ctx, 7)
    end

    test "send_stdin/3 base64-encodes the data into input.stdin", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) ==
                 %{"process" => %{"pid" => 7}, "input" => %{"stdin" => Base.encode64("y\n")}}

        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.send_stdin(ctx, 7, "y\n")
    end

    test "close_stdin/2 posts the selector and returns :ok", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/CloseStdin", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"process" => %{"pid" => 7}}
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Rpc.close_stdin(ctx, 7)
    end

    test "list/1 returns the raw process maps", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
        body = ~s({"processes":[{"pid":7,"config":{"cmd":"sleep"}}]})
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, [%{"pid" => 7, "config" => %{"cmd" => "sleep"}}]} = Rpc.list(ctx)
    end

    test "kill/2 surfaces other failures as {:error, %Error{}}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(503, ~s({"code":"unavailable","message":"down"}))
      end)

      assert {:error, %E2bEx.Error{status: 503}} = Rpc.kill(ctx, 7)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/envd/rpc_test.exs`
Expected: FAIL — `Rpc.kill/2` etc. are undefined.

- [ ] **Step 3: Implement the control wrappers in `Rpc`**

In `lib/e2b_ex/envd/rpc.ex`, add these public functions (after `unary/4`):

```elixir
  @doc "Kill a process by pid (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(ctx(), non_neg_integer()) :: {:ok, boolean()} | {:error, Error.t()}
  def kill(ctx, pid) do
    case unary(ctx, "/process.Process/SendSignal", %{process: %{pid: pid}, signal: "SIGNAL_SIGKILL"}) do
      {:ok, _} -> {:ok, true}
      {:error, %Error{code: "not_found"}} -> {:ok, false}
      {:error, %Error{status: 404}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc "Send data to a process's stdin by pid."
  @spec send_stdin(ctx(), non_neg_integer(), binary()) :: :ok | {:error, Error.t()}
  def send_stdin(ctx, pid, data) when is_binary(data) do
    body = %{process: %{pid: pid}, input: %{stdin: Base.encode64(data)}}

    case unary(ctx, "/process.Process/SendInput", body) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Close a process's stdin (EOF) by pid."
  @spec close_stdin(ctx(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def close_stdin(ctx, pid) do
    case unary(ctx, "/process.Process/CloseStdin", %{process: %{pid: pid}}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "List running processes; returns the raw `processes` maps."
  @spec list(ctx()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(ctx) do
    case unary(ctx, "/process.Process/List", %{}) do
      {:ok, %{"processes" => procs}} when is_list(procs) -> {:ok, procs}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/envd/rpc_test.exs`
Expected: PASS (5 + 6 = 11 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/envd/rpc.ex test/e2b_ex/envd/rpc_test.exs
git commit -m "feat: add Rpc control wrappers (kill/send_stdin/close_stdin/list)"
```

---

## Task 6: `Commands` by-pid functions (`list/2`, `kill/4`, `send_stdin/5`, `close_stdin/4`)

**Files:**
- Modify: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/commands_control_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/commands_control_test.exs`:

```elixir
defmodule E2bEx.CommandsControlTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Commands, Error, ProcessInfo, Sandbox}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  test "list/2 returns ProcessInfo structs", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/List", fn conn ->
      body = ~s({"processes":[{"pid":7,"tag":"t","config":{"cmd":"sleep","args":["1"],"envs":{},"cwd":"/"}}]})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, [%ProcessInfo{pid: 7, tag: "t", cmd: "sleep", args: ["1"], cwd: "/"}]} =
             Commands.list(client(), sandbox(), base_url: base_url)
  end

  test "kill/4 returns {:ok, true} on success", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert {:ok, true} = Commands.kill(client(), sandbox(), 7, base_url: base_url)
  end

  test "send_stdin/5 and close_stdin/4 return :ok", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    assert :ok = Commands.send_stdin(client(), sandbox(), 7, "data", base_url: base_url)
  end

  test "kill/4 propagates a context error when the sandbox has no id" do
    assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
             Commands.kill(client(), %Sandbox{sandbox_id: nil}, 7)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/commands_control_test.exs`
Expected: FAIL — `Commands.list/3` etc. are undefined.

- [ ] **Step 3: Implement the by-pid functions**

In `lib/e2b_ex/commands.ex`, add `alias E2bEx.ProcessInfo` to the alias block, and add these public functions (after `run/4`):

```elixir
  @doc "List running commands/PTYs in `sandbox` (`/process.Process/List`)."
  @spec list(Client.t(), Sandbox.t(), keyword()) :: {:ok, [ProcessInfo.t()]} | {:error, Error.t()}
  def list(%Client{} = client, %Sandbox{} = sandbox, opts \\ []) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, procs} <- Rpc.list(ctx) do
      {:ok, Enum.map(procs, &ProcessInfo.from_api/1)}
    end
  end

  @doc "Kill a process by pid (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def kill(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.kill(ctx, pid)
  end

  @doc "Send `data` to a process's stdin by pid (requires the process was started with `stdin: true`)."
  @spec send_stdin(Client.t(), Sandbox.t(), non_neg_integer(), binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def send_stdin(%Client{} = client, %Sandbox{} = sandbox, pid, data, opts \\ [])
      when is_integer(pid) and is_binary(data) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.send_stdin(ctx, pid, data)
  end

  @doc "Close a process's stdin (EOF) by pid."
  @spec close_stdin(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, Error.t()}
  def close_stdin(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.close_stdin(ctx, pid)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/commands_control_test.exs && mix test`
Expected: PASS (4 new; full suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/commands.ex test/e2b_ex/commands_control_test.exs
git commit -m "feat: add Commands by-pid list/kill/send_stdin/close_stdin"
```

---

## Task 7: `HandleServer` + `Commands.start/4` + `CommandHandle` (stream, pid, disconnect)

**Files:**
- Create: `lib/e2b_ex/commands/handle_server.ex`, `lib/e2b_ex/command_handle.ex`
- Modify: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/commands_background_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/commands_background_test.exs`:

```elixir
defmodule E2bEx.CommandsBackgroundTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandHandle, Commands, Sandbox}
  alias E2bEx.Envd.Connect

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp chunk_bytes(bin, n) when byte_size(bin) > n do
    <<part::binary-size(n), rest::binary>> = bin
    [part | chunk_bytes(rest, n)]
  end

  defp chunk_bytes(bin, _n), do: [bin]

  defp start_body do
    frame(%{"event" => %{"start" => %{"pid" => 99}}}) <>
      frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("foo")}}}) <>
      frame(%{"event" => %{"data" => %{"stderr" => Base.encode64("bar")}}}) <>
      frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 0}}}) <>
      trailer("{}")
  end

  test "start/4 returns a handle with the pid and streams output then a terminal exit",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunk_bytes(start_body(), 9), conn, fn part, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, part)
        conn
      end)
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "echo hi", base_url: base_url)
    assert CommandHandle.pid(handle) == 99
    ref = handle.ref

    assert_receive {^ref, {:stdout, "foo"}}
    assert_receive {^ref, {:stderr, "bar"}}
    assert_receive {^ref, {:exit, %E2bEx.CommandResult{stdout: "foo", stderr: "bar", exit_code: 0}}}
  end

  test "start/4 errors when the stream returns non-2xx before a start event",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"code":"unauthenticated","message":"no token"}))
    end)

    assert {:error, %E2bEx.Error{}} = Commands.start(client(), sandbox(), "echo", base_url: base_url)
  end

  test "disconnect/1 stops the handle server and sends no terminal message",
       %{bypass: bypass, base_url: base_url} do
    # Stream only a start event, then hang (no end / trailer), so the command stays "running".
    Bypass.expect(bypass, "POST", "/process.Process/Start", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(%{"event" => %{"start" => %{"pid" => 5}}}))
      Process.sleep(200)
      conn
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "sleep 100", base_url: base_url)
    ref = handle.ref
    server = handle.server
    assert :ok = CommandHandle.disconnect(handle)
    refute Process.alive?(server)
    refute_receive {^ref, {:exit, _}}, 50
    refute_receive {^ref, {:error, _}}, 50
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/commands_background_test.exs`
Expected: FAIL — `Commands.start/4` / `E2bEx.CommandHandle` not available.

- [ ] **Step 3: Implement `HandleServer`**

Create `lib/e2b_ex/commands/handle_server.ex`:

```elixir
defmodule E2bEx.Commands.HandleServer do
  @moduledoc false
  # GenServer owning one envd Start/Connect server-stream (Req `into: :self`).
  # Folds events via `Commands.Fold` and pushes `{ref, _}` messages to the
  # subscriber: `{:stdout, bin}` / `{:stderr, bin}` while running, then a terminal
  # `{:exit, result}` or `{:error, error}`. Replies to `:await_start` with the
  # envd pid once the first `start` event arrives. Holds no control logic.

  use GenServer

  alias E2bEx.Error
  alias E2bEx.Commands.Fold
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
      fold: Fold.new(),
      trailer: nil,
      error_body: "",
      pid: nil,
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
      state.pid != nil -> {:reply, {:ok, state.pid}, state}
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

  # non-2xx: accumulate the raw error body, then fail on :done.
  defp process_part({:data, chunk}, %{status: status} = state) when status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp process_part(:done, %{status: status} = state) when status not in 200..299 do
    failure(state, Error.from_response(%Req.Response{status: status, body: state.error_body}))
  end

  # 2xx streaming
  defp process_part({:data, chunk}, state) do
    case Connect.Decoder.push(state.decoder, chunk) do
      {:ok, messages, trailer, decoder} ->
        apply_messages(messages, %{state | decoder: decoder, trailer: trailer || state.trailer})

      {:error, reason} ->
        failure(state, malformed(reason))
    end
  end

  defp process_part(:done, state) do
    cond do
      state.decoder.buffer != "" ->
        failure(state, malformed(:malformed_frame))

      match?(%Error{}, Connect.trailer_error(state.trailer)) ->
        failure(state, Connect.trailer_error(state.trailer))

      state.pid == nil ->
        failure(state, %Error{message: "command failed to start"})

      Fold.ended?(state.fold) ->
        send_msg(state, {:exit, Fold.result(state.fold)})
        {:stop, state}

      true ->
        failure(state, %Error{message: "command ended without a result"})
    end
  end

  defp apply_messages(messages, state) do
    Enum.reduce_while(messages, {:cont, state}, fn message, {:cont, state} ->
      event = message["event"]
      state = maybe_capture_pid(event, state)

      case Fold.apply_event(state.fold, event) do
        {:ok, fold, outputs} ->
          Enum.each(outputs, fn {kind, bytes} -> send_msg(state, {kind, bytes}) end)
          {:cont, {:cont, %{state | fold: fold}}}

        {:error, reason} ->
          {:halt, failure(state, malformed(reason))}
      end
    end)
  end

  defp maybe_capture_pid(%{"start" => %{"pid" => pid}}, %{pid: nil} = state) do
    state = %{state | pid: pid}

    if state.await_from do
      GenServer.reply(state.await_from, {:ok, pid})
      %{state | await_from: nil}
    else
      state
    end
  end

  defp maybe_capture_pid(_event, state), do: state

  # Deliver an error: to the start caller if not started yet, else to the
  # subscriber as a terminal message. Returns a {:cont | :stop, state} tuple.
  defp failure(state, error) do
    cond do
      state.pid != nil ->
        send_msg(state, {:error, error})
        {:stop, state}

      state.await_from != nil ->
        GenServer.reply(state.await_from, {:error, error})
        {:stop, %{state | await_from: nil}}

      true ->
        # Failed before start and before the await_start call arrived: stay alive
        # so handle_call(:await_start) can return the error, then stop.
        {:cont, %{state | start_error: error}}
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

- [ ] **Step 4: Implement `CommandHandle` (struct, `pid/1`, `disconnect/1`)**

Create `lib/e2b_ex/command_handle.ex`:

```elixir
defmodule E2bEx.CommandHandle do
  @moduledoc """
  A handle to a background command started with `E2bEx.Commands.start/4` (or
  reconnected via `E2bEx.Commands.connect/4`).

  Output is delivered to the subscriber process as messages tagged with the
  handle's `ref`:

      {ref, {:stdout, binary}}
      {ref, {:stderr, binary}}
      {ref, {:exit, %E2bEx.CommandResult{}}}   # terminal, any exit code
      {ref, {:error, %E2bEx.Error{}}}          # terminal, failure

  Consume the message stream **or** call `wait/1` (which drains the stream and
  returns the result) — not both from the same process.
  """

  alias E2bEx.Envd.Rpc

  @enforce_keys [:server, :ref, :pid, :context]
  defstruct [:server, :ref, :pid, :context]

  @type t :: %__MODULE__{
          server: pid(),
          ref: reference(),
          pid: non_neg_integer(),
          context: map()
        }

  @doc "The envd process id of the running command."
  @spec pid(t()) :: non_neg_integer()
  def pid(%__MODULE__{pid: pid}), do: pid

  @doc "Kill the command (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(t()) :: {:ok, boolean()} | {:error, E2bEx.Error.t()}
  def kill(%__MODULE__{context: ctx, pid: pid}), do: Rpc.kill(ctx, pid)

  @doc "Send `data` to the command's stdin (requires `start(stdin: true)`)."
  @spec send_stdin(t(), binary()) :: :ok | {:error, E2bEx.Error.t()}
  def send_stdin(%__MODULE__{context: ctx, pid: pid}, data) when is_binary(data),
    do: Rpc.send_stdin(ctx, pid, data)

  @doc "Close the command's stdin (EOF)."
  @spec close_stdin(t()) :: :ok | {:error, E2bEx.Error.t()}
  def close_stdin(%__MODULE__{context: ctx, pid: pid}), do: Rpc.close_stdin(ctx, pid)

  @doc """
  Stop streaming from the command without killing it. The envd process keeps
  running; reconnect with `E2bEx.Commands.connect/4`. No terminal message is sent.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{server: server}) do
    if Process.alive?(server), do: GenServer.stop(server)
    :ok
  end
end
```

- [ ] **Step 5: Implement `Commands.start/4`**

In `lib/e2b_ex/commands.ex`, add aliases `E2bEx.CommandHandle` and `E2bEx.Commands.HandleServer` to the alias block, add `@connect_path "/process.Process/Connect"` near `@start_path`, and add:

```elixir
  @doc """
  Start `command` in `sandbox` in the background and return a `CommandHandle`.

  Output is streamed to the subscriber (`opts[:subscriber]`, default the calling
  process) as `{handle.ref, {:stdout|:stderr, binary}}` messages, ending with a
  terminal `{handle.ref, {:exit, %E2bEx.CommandResult{}}}` (any exit code) or
  `{handle.ref, {:error, %E2bEx.Error{}}}`. Use the message stream or
  `E2bEx.CommandHandle.wait/1`.

  ## Options
    * `:subscriber` — pid to receive output messages (default the caller).
    * `:stdin` — open stdin so `send_stdin/2` works (default `false`).
    * `:cwd`, `:envs`, `:user`, `:timeout_ms`, `:domain`, `:port`, `:base_url` —
      as for `run/4`.
  """
  @spec start(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, CommandHandle.t()} | {:error, Error.t()}
  def start(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      spawn_handle(ctx, @start_path, start_request(command, opts), opts)
    end
  end

  defp spawn_handle(ctx, path, request, opts) do
    ref = make_ref()
    subscriber = opts[:subscriber] || self()

    arg = %{
      ctx: ctx,
      path: path,
      request: request,
      subscriber: subscriber,
      ref: ref,
      timeout_ms: ctx.timeout_ms
    }

    with {:ok, server} <- HandleServer.start(arg) do
      await = if ctx.timeout_ms == 0, do: :infinity, else: ctx.timeout_ms

      try do
        case GenServer.call(server, :await_start, await) do
          {:ok, pid} -> {:ok, %CommandHandle{server: server, ref: ref, pid: pid, context: ctx}}
          {:error, error} -> {:error, error}
        end
      catch
        :exit, _ -> {:error, %Error{message: "command failed to start"}}
      end
    end
  end
```

Also update `start_request/2` so it honours `:stdin` (it currently hardcodes `stdin: false`):

```elixir
  defp start_request(command, opts) do
    process =
      %{cmd: "/bin/bash", args: ["-l", "-c", command]}
      |> put_present(:cwd, opts[:cwd])
      |> put_present(:envs, opts[:envs])

    %{process: process, stdin: opts[:stdin] || false}
  end
```

(`run/4` passes no `:stdin`, so it still sends `stdin: false` — unchanged.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/commands_background_test.exs && mix test`
Expected: PASS (3 new background tests; full suite green).

- [ ] **Step 7: Commit**

```bash
git add lib/e2b_ex/commands/handle_server.ex lib/e2b_ex/command_handle.ex lib/e2b_ex/commands.ex test/e2b_ex/commands_background_test.exs
git commit -m "feat: background Commands.start/4 with streaming CommandHandle"
```

---

## Task 8: `CommandHandle.wait/1` (+ handle control delegation tests)

**Files:**
- Modify: `lib/e2b_ex/command_handle.ex`
- Test: `test/e2b_ex/command_handle_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/command_handle_test.exs`:

```elixir
defmodule E2bEx.CommandHandleTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandHandle, Commands, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Connect

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp respond(bypass, body) do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  test "wait/1 drains output and returns the result", %{bypass: bypass, base_url: base_url} do
    respond(bypass,
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("hello")}}}) <>
        frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 2}}}) <>
        trailer("{}")
    )

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:ok, %CommandResult{stdout: "hello", exit_code: 2}} = CommandHandle.wait(handle)
  end

  test "wait/1 returns {:error, _} on a Connect trailer error", %{bypass: bypass, base_url: base_url} do
    respond(bypass,
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        trailer(~s({"error":{"code":"unavailable","message":"gone"}}))
    )

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:error, %Error{message: "gone", reason: "unavailable"}} = CommandHandle.wait(handle)
  end

  test "wait/1 returns {:error, _} when the stream ends with no end event",
       %{bypass: bypass, base_url: base_url} do
    respond(bypass, frame(%{"event" => %{"start" => %{"pid" => 1}}}) <> trailer("{}"))

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert {:error, %Error{message: "command ended without a result"}} = CommandHandle.wait(handle)
  end

  test "handle kill/send_stdin/close_stdin delegate to the by-pid RPCs",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Start", fn conn ->
      Plug.Conn.resp(conn, 200,
        frame(%{"event" => %{"start" => %{"pid" => 77}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    Bypass.expect_once(bypass, "POST", "/process.Process/SendSignal", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["process"] == %{"pid" => 77}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    {:ok, handle} = Commands.start(client(), sandbox(), "x", base_url: base_url)
    assert CommandHandle.pid(handle) == 77
    assert {:ok, true} = CommandHandle.kill(handle)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/command_handle_test.exs`
Expected: FAIL — `CommandHandle.wait/1` is undefined.

- [ ] **Step 3: Implement `wait/1`**

In `lib/e2b_ex/command_handle.ex`, add `alias E2bEx.{CommandResult, Error}` to the alias block (alongside `Rpc`) and add:

```elixir
  @doc """
  Block until the command finishes and return its result.

  Drains the intermediate `{ref, {:stdout|:stderr, _}}` messages from the caller's
  mailbox and returns on the terminal message: `{:ok, %E2bEx.CommandResult{}}` for
  any exit code, or `{:error, %E2bEx.Error{}}`. Must be called from the subscriber
  process. Returns `{:error, %E2bEx.Error{}}` if the handle server crashes.
  """
  @spec wait(t()) :: {:ok, CommandResult.t()} | {:error, Error.t()}
  def wait(%__MODULE__{server: server, ref: ref}) do
    mon = Process.monitor(server)
    result = wait_loop(ref, mon)
    Process.demonitor(mon, [:flush])
    result
  end

  defp wait_loop(ref, mon) do
    receive do
      {^ref, {:exit, %CommandResult{} = result}} -> {:ok, result}
      {^ref, {:error, %Error{} = error}} -> {:error, error}
      {^ref, {:stdout, _}} -> wait_loop(ref, mon)
      {^ref, {:stderr, _}} -> wait_loop(ref, mon)
      {:DOWN, ^mon, :process, _pid, reason} -> {:error, %Error{message: "command handle terminated", reason: reason}}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/command_handle_test.exs && mix test`
Expected: PASS (4 new; full suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/command_handle.ex test/e2b_ex/command_handle_test.exs
git commit -m "feat: CommandHandle.wait/1 draining receive"
```

---

## Task 9: `Commands.connect/4` (reconnect to a running pid)

**Files:**
- Modify: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/commands_background_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/e2b_ex/commands_background_test.exs` (inside the module):

```elixir
  test "connect/4 reconnects to a running pid and yields the result", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/process.Process/Connect", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) == %{"process" => %{"pid" => 42}}

      body =
        frame(%{"event" => %{"start" => %{"pid" => 42}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("back")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true}}}) <>
          trailer("{}")

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, handle} = Commands.connect(client(), sandbox(), 42, base_url: base_url)
    assert E2bEx.CommandHandle.pid(handle) == 42
    assert {:ok, %E2bEx.CommandResult{stdout: "back"}} = E2bEx.CommandHandle.wait(handle)
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/e2b_ex/commands_background_test.exs`
Expected: FAIL — `Commands.connect/4` is undefined.

- [ ] **Step 3: Implement `connect/4`**

In `lib/e2b_ex/commands.ex`, add (after `start/4`):

```elixir
  @doc """
  Reconnect to a running command by `pid` and return a `CommandHandle` that streams
  its output (`/process.Process/Connect`). Options: `:subscriber`, `:timeout_ms`,
  `:domain`, `:port`, `:base_url`.
  """
  @spec connect(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          {:ok, CommandHandle.t()} | {:error, Error.t()}
  def connect(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      spawn_handle(ctx, @connect_path, %{process: %{pid: pid}}, opts)
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/e2b_ex/commands_background_test.exs && mix test`
Expected: PASS (1 new; full suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/commands.ex test/e2b_ex/commands_background_test.exs
git commit -m "feat: Commands.connect/4 reconnect to a running command"
```

---

## Task 10: Documentation

**Files:**
- Modify: `README.md`, `lib/e2b_ex/commands.ex` (moduledoc)

- [ ] **Step 1: Update the `Commands` moduledoc**

In `lib/e2b_ex/commands.ex`, extend the moduledoc (after the existing streaming-callbacks example, before the closing `"""`) with a background example:

```elixir
  ## Background execution

  Use `start/4` to run a command in the background; output arrives as messages and
  `E2bEx.CommandHandle.wait/1` returns the result:

      {:ok, h} = E2bEx.Commands.start(client, sandbox, "sleep 1; echo done")
      receive do
        {ref, {:stdout, data}} when ref == h.ref -> IO.write(data)
      end
      {:ok, result} = E2bEx.CommandHandle.wait(h)

  Control a running command with `E2bEx.CommandHandle.kill/1`, `send_stdin/2`,
  `close_stdin/1`, `disconnect/1`, or the by-pid `kill/4`, `send_stdin/5`,
  `close_stdin/4`, `list/2`, and `connect/4`.
```

- [ ] **Step 2: Update the README**

In `README.md`, after the "Streaming output" subsection added in Phase 1, add a "Background commands" subsection:

```markdown
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
```

Update the Phase 1 "later phases" note (the sentence ending "Background execution,
`kill`/stdin, reconnecting, and PTY are planned in later phases.") to:
"Background execution and reconnecting are available via `start/4`/`connect/4`; PTY
is planned for a later phase."

- [ ] **Step 3: Verify docs build and the suite is green**

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass; clean compile.

- [ ] **Step 4: Commit**

```bash
git add README.md lib/e2b_ex/commands.ex
git commit -m "docs: document background command execution"
```

---

## Final verification

- [ ] Run the whole suite and strict compile:

Run: `mix test && mix compile --warnings-as-errors`
Expected: all tests pass (Phase 1 regression + Fold + Rpc + ProcessInfo + control + background + handle + connect); clean compile.

- [ ] Confirm `run/4`'s public contract is unchanged after the `Fold`/`Rpc` refactor: `{:ok, %CommandResult{}}` for any exit code, `{:error, %E2bEx.Error{}}` for transport/non-2xx/trailer/malformed; the Phase 1 command tests still pass verbatim.
- [ ] Confirm `start/4` → handle → `{ref, …}` messages → `wait/1`, and the control RPCs, all behave per the spec's error table.
