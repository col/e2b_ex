# E2bEx PTY Interactive Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `mix e2b.terminal` task that opens a real raw interactive terminal into a sandbox PTY from a normal shell (run outside `iex`).

**Architecture:** A thin Mix task (`Mix.Tasks.E2b.Terminal`) owns all the real-world side effects — arg parsing, API-key resolution, sandbox resolve/create, `stty` raw-mode setup/restore, kill-on-exit. It delegates the live session to a pure-orchestration `E2bEx.Pty.Terminal.run/2`, which (via injectable IO hooks) streams PTY output to a writer, batches stdin bytes through `E2bEx.Pty.InputBatcher` into `Pty.send_input`, polls the terminal size to drive `Pty.resize`, and returns on the terminal exit. Ports the E2B CLI's `terminal.ts`, accommodating that the BEAM has no `setRawMode` (→ `stty`) and can't trap `SIGWINCH` (→ size polling).

**Tech Stack:** Elixir ~> 1.18, `Req`, the existing `E2bEx.Pty`/`E2bEx.Pty.Handle` (from branch `feat/pty`), `Bypass` for tests. POSIX `stty` + `/dev/tty`.

**Reference spec:** `docs/superpowers/specs/2026-06-12-e2b-pty-terminal-design.md`

---

## File Structure

- **Create** `lib/e2b_ex/pty/input_batcher.ex` — `E2bEx.Pty.InputBatcher`: a GenServer that accumulates bytes and flushes them every N ms via a callback. Knows nothing about PTYs (bytes + flush fun only).
- **Create** `lib/e2b_ex/pty/terminal.ex` — `E2bEx.Pty.Terminal`: `run/2`, the session orchestrator over injectable hooks + a `%Pty.Handle{}`. Knows nothing about `stty`/Mix.
- **Create** `lib/mix/tasks/e2b.terminal.ex` — `Mix.Tasks.E2b.Terminal`: the CLI. Owns args, api-key, sandbox lifecycle, and all `stty`/tty side effects.
- **Test** `test/e2b_ex/pty/input_batcher_test.exs`, `test/e2b_ex/pty/terminal_test.exs`, `test/mix/tasks/e2b_terminal_test.exs`.
- **Modify** `README.md` — add a `mix e2b.terminal` section.

### Conventions an implementer must know (verified against the codebase)

- `E2bEx.Pty.Handle.send_input(handle, data)` → `:ok | {:error, %E2bEx.Error{}}`; `Handle.resize(handle, %{cols: c, rows: r})` → `:ok | {:error}`. The struct is `%E2bEx.Pty.Handle{server, ref, pid, context}`.
- `E2bEx.Pty.create(client, sandbox, opts)` → `{:ok, %Pty.Handle{}}`; opts include `:cols`, `:rows`, `:timeout_ms`, `:subscriber` (defaults to the caller).
- `E2bEx.Sandboxes.connect(client, id, timeout)` → `{:ok, %Sandbox{}}` (token-bearing); `create(client, %{templateID: t})` → `{:ok, %Sandbox{}}`; `kill(client, id)` → `:ok | {:error}`.
- `E2bEx.client(api_key: key)` → `%E2bEx.Client{}`.
- `%E2bEx.CommandResult{stdout, stderr, exit_code, error}` and `%E2bEx.Error{message, ...}` already exist.
- Tests use **Bypass** (not `Req.Test`) for the envd surface, pointing at it via `Rpc.context(client, sandbox, base_url: "http://localhost:#{bypass.port}")` — see `test/e2b_ex/pty/handle_test.exs`.
- Mix tasks live under `lib/mix/tasks/` and are auto-discovered; no registration needed.

### Boundary note (intentional refinement of the spec)

The spec mentioned `Terminal`'s `:size` default reading `stty`. To keep `Terminal` free of any `stty` knowledge, **`:size` defaults to `fn -> :error end` (no resize)** and the Mix task injects the real `stty`-based size fun. `:write`/`:read_byte` default to plain `:stdio` IO (not `stty`), which is fine — the Mix task sets raw mode around the call.

---

## Task 1: `E2bEx.Pty.InputBatcher`

A GenServer that coalesces rapid stdin bytes (and multi-byte escape sequences) into one flush.

**Files:**
- Create: `lib/e2b_ex/pty/input_batcher.ex`
- Test: `test/e2b_ex/pty/input_batcher_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/pty/input_batcher_test.exs`:

```elixir
defmodule E2bEx.Pty.InputBatcherTest do
  use ExUnit.Case, async: true
  alias E2bEx.Pty.InputBatcher

  test "flushes accumulated bytes once per interval, concatenated" do
    test = self()
    {:ok, b} = InputBatcher.start_link(flush_ms: 20, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    InputBatcher.push(b, "a")
    InputBatcher.push(b, "b")
    InputBatcher.push(b, "c")
    assert_receive {:flush, "abc"}, 200
  end

  test "does not invoke on_flush for an empty interval" do
    test = self()
    {:ok, _b} = InputBatcher.start_link(flush_ms: 20, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    refute_receive {:flush, _}, 80
  end

  test "stop/1 flushes the remaining buffer" do
    test = self()
    {:ok, b} = InputBatcher.start_link(flush_ms: 10_000, on_flush: fn bytes -> send(test, {:flush, bytes}) end)
    InputBatcher.push(b, "x")
    :ok = InputBatcher.stop(b)
    assert_receive {:flush, "x"}, 200
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/pty/input_batcher_test.exs`
Expected: FAIL to compile — `E2bEx.Pty.InputBatcher.start_link/1 is undefined` (module does not exist).

- [ ] **Step 3: Implement the GenServer**

Create `lib/e2b_ex/pty/input_batcher.ex`:

```elixir
defmodule E2bEx.Pty.InputBatcher do
  @moduledoc false
  # Accumulates raw input bytes and flushes them in one batch every `:flush_ms`
  # via the `:on_flush` callback. Coalesces fast typing and multi-byte escape
  # sequences (e.g. arrow keys) so the terminal makes one `send_input` per window
  # instead of one per byte. Knows nothing about PTYs.

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Append `bytes` to the pending buffer."
  @spec push(GenServer.server(), binary()) :: :ok
  def push(server, bytes) when is_binary(bytes), do: GenServer.cast(server, {:push, bytes})

  @doc "Flush any remaining bytes and stop."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    flush_ms = Keyword.get(opts, :flush_ms, 10)
    on_flush = Keyword.fetch!(opts, :on_flush)
    schedule(flush_ms)
    {:ok, %{buffer: [], flush_ms: flush_ms, on_flush: on_flush}}
  end

  @impl true
  def handle_cast({:push, bytes}, state) do
    {:noreply, %{state | buffer: [state.buffer, bytes]}}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush(state)
    schedule(state.flush_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  defp flush(%{buffer: buffer, on_flush: on_flush} = state) do
    case IO.iodata_to_binary(buffer) do
      "" -> state
      bin -> on_flush.(bin); %{state | buffer: []}
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :flush, ms)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/pty/input_batcher_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/pty/input_batcher.ex test/e2b_ex/pty/input_batcher_test.exs
git commit -m "feat(terminal): add Pty.InputBatcher (timed input coalescing)"
```

---

## Task 2: `E2bEx.Pty.Terminal.run/2`

The session orchestrator: output loop + reader + size-poll, over injectable hooks.

**Files:**
- Create: `lib/e2b_ex/pty/terminal.ex`
- Test: `test/e2b_ex/pty/terminal_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/pty/terminal_test.exs`:

```elixir
defmodule E2bEx.Pty.TerminalTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Rpc
  alias E2bEx.Pty.{Handle, Terminal}

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  setup do
    bypass = Bypass.open()
    {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
    server = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    handle = %Handle{server: server, ref: make_ref(), pid: 7, context: ctx}
    {:ok, bypass: bypass, handle: handle, server: server}
  end

  # Spawn run/2 in its own process (it is the PTY subscriber + blocks in a loop),
  # returning {runner_pid, ref}. The runner reports run/2's return as {:result, _}.
  defp start_runner(handle, opts) do
    test = self()
    pid = spawn(fn -> send(test, {:result, Terminal.run(handle, opts)}) end)
    {pid, handle.ref}
  end

  test "writes pty output to the writer in order and returns on exit", %{handle: handle} do
    test = self()

    {runner, ref} =
      start_runner(handle,
        write: fn bytes -> send(test, {:wrote, bytes}) end,
        read_byte: fn -> :eof end,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 10_000
      )

    send(runner, {ref, {:pty, "ab"}})
    send(runner, {ref, {:pty, "cd"}})
    assert_receive {:wrote, "ab"}
    assert_receive {:wrote, "cd"}

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, %CommandResult{exit_code: 0}}}
  end

  test "batches typed bytes into a single SendInput (input.pty)", %{bypass: bypass, handle: handle} do
    test = self()

    Bypass.expect_once(bypass, "POST", "/process.Process/SendInput", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, Jason.decode!(raw)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    {:ok, agent} = Agent.start_link(fn -> ["l", "s", "\r"] end)
    read_byte = fn -> Agent.get_and_update(agent, fn [] -> {:eof, []}; [h | t] -> {h, t} end) end

    {runner, ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: read_byte,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 25
      )

    assert_receive {:sent, %{"process" => %{"pid" => 7}, "input" => %{"pty" => pty}}}, 500
    assert pty == Base.encode64("ls\r")

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, _}}
  end

  test "resizes when the polled terminal size changes", %{bypass: bypass, handle: handle} do
    test = self()

    Bypass.expect_once(bypass, "POST", "/process.Process/Update", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:resized, Jason.decode!(raw)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
    end)

    # First call (baseline) => {80, 24}; subsequent calls => {100, 30} (a change).
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    size = fn ->
      n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
      if n == 0, do: {80, 24}, else: {100, 30}
    end

    {runner, ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: fn -> :eof end,
        size: size,
        poll_ms: 20,
        flush_ms: 10_000
      )

    assert_receive {:resized, %{"pty" => %{"size" => %{"cols" => 100, "rows" => 30}}}}, 500

    send(runner, {ref, {:exit, %CommandResult{exit_code: 0}}})
    assert_receive {:result, {:ok, _}}
  end

  test "returns {:error, _} if the handle server crashes", %{handle: handle, server: server} do
    {_runner, _ref} =
      start_runner(handle,
        write: fn _ -> :ok end,
        read_byte: fn -> :eof end,
        size: fn -> :error end,
        poll_ms: 10_000,
        flush_ms: 10_000
      )

    Process.exit(server, :kill)
    assert_receive {:result, {:error, %Error{message: "terminal session terminated"}}}, 500
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/pty/terminal_test.exs`
Expected: FAIL to compile — `E2bEx.Pty.Terminal.run/2 is undefined` (module does not exist).

- [ ] **Step 3: Implement the orchestrator**

Create `lib/e2b_ex/pty/terminal.ex`:

```elixir
defmodule E2bEx.Pty.Terminal do
  @moduledoc false
  # Drives an interactive terminal session over a %Pty.Handle{}: streams PTY
  # output to a writer, forwards (batched) stdin bytes to the PTY, and polls the
  # terminal size to drive resizes. Pure orchestration over injectable IO hooks —
  # the Mix task (Mix.Tasks.E2b.Terminal) supplies the real stdio/stty bits and
  # raw-mode setup. Returns on the PTY's terminal event.

  alias E2bEx.{CommandResult, Error}
  alias E2bEx.Pty.{Handle, InputBatcher}

  @doc """
  Run the terminal session for `handle`. Must be called from the process that
  owns the PTY subscription (it receives `{ref, {:pty, _}}`).

  Options (all injectable for testing):
    * `:write`     — `(binary -> any)`, default `&IO.binwrite(:stdio, &1)`
    * `:read_byte` — `(-> binary | :eof)`, default `fn -> IO.binread(:stdio, 1) end`
    * `:size`      — `(-> {cols, rows} | :error)`, default `fn -> :error end` (no resize)
    * `:poll_ms`   — size-poll interval, default 500
    * `:flush_ms`  — input batch interval, default 10
  """
  @spec run(Handle.t(), keyword()) :: {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Handle{} = handle, opts \\ []) do
    Process.flag(:trap_exit, true)
    write = opts[:write] || (&IO.binwrite(:stdio, &1))
    read_byte = opts[:read_byte] || fn -> IO.binread(:stdio, 1) end
    size = opts[:size] || fn -> :error end
    poll_ms = opts[:poll_ms] || 500
    flush_ms = opts[:flush_ms] || 10

    {:ok, batcher} =
      InputBatcher.start_link(flush_ms: flush_ms, on_flush: fn bytes -> Handle.send_input(handle, bytes) end)

    reader = spawn_link(fn -> reader_loop(read_byte, batcher) end)
    mon = Process.monitor(handle.server)
    Process.send_after(self(), :poll, poll_ms)

    try do
      output_loop(handle, mon, write, size, poll_ms, safe_size(size))
    after
      Process.exit(reader, :kill)
      InputBatcher.stop(batcher)
      Process.demonitor(mon, [:flush])
    end
  end

  defp output_loop(handle, mon, write, size, poll_ms, last_size) do
    ref = handle.ref

    receive do
      {^ref, {:pty, bytes}} ->
        write.(bytes)
        output_loop(handle, mon, write, size, poll_ms, last_size)

      {^ref, {:exit, %CommandResult{} = result}} ->
        {:ok, result}

      {^ref, {:error, %Error{} = error}} ->
        {:error, error}

      {:DOWN, ^mon, :process, _pid, reason} ->
        {:error, %Error{message: "terminal session terminated", reason: reason}}

      :poll ->
        last_size = maybe_resize(handle, safe_size(size), last_size)
        Process.send_after(self(), :poll, poll_ms)
        output_loop(handle, mon, write, size, poll_ms, last_size)

      {:EXIT, _pid, _reason} ->
        # reader/batcher link exits; ignore and keep streaming.
        output_loop(handle, mon, write, size, poll_ms, last_size)
    end
  end

  defp reader_loop(read_byte, batcher) do
    case read_byte.() do
      data when is_binary(data) ->
        InputBatcher.push(batcher, data)
        reader_loop(read_byte, batcher)

      _ ->
        # :eof or {:error, _}: stop reading.
        :ok
    end
  end

  defp maybe_resize(_handle, :error, last_size), do: last_size
  defp maybe_resize(_handle, same, same), do: same

  defp maybe_resize(handle, {cols, rows} = new_size, _last_size) do
    Handle.resize(handle, %{cols: cols, rows: rows})
    new_size
  end

  defp safe_size(size) do
    case size.() do
      {cols, rows} when is_integer(cols) and is_integer(rows) -> {cols, rows}
      _ -> :error
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/pty/terminal_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/pty/terminal.ex test/e2b_ex/pty/terminal_test.exs
git commit -m "feat(terminal): add Pty.Terminal.run/2 session orchestrator"
```

---

## Task 3: `Mix.Tasks.E2b.Terminal`

The CLI wrapper: args, api-key, sandbox lifecycle, raw-tty setup/restore.

**Files:**
- Create: `lib/mix/tasks/e2b.terminal.ex`
- Test: `test/mix/tasks/e2b_terminal_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/mix/tasks/e2b_terminal_test.exs` (note `async: false` — it mutates env):

```elixir
defmodule Mix.Tasks.E2b.TerminalTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.E2b.Terminal

  test "parses a sandbox id target with an explicit --api-key" do
    assert {"k", {:id, "sb_1"}} = Terminal.parse!(["--api-key", "k", "sb_1"])
  end

  test "parses a --template target" do
    assert {"k", {:template, "base"}} = Terminal.parse!(["--api-key", "k", "--template", "base"])
  end

  test "falls back to the E2B_API_KEY env var" do
    System.put_env("E2B_API_KEY", "envk")
    on_exit(fn -> System.delete_env("E2B_API_KEY") end)
    assert {"envk", {:id, "sb_1"}} = Terminal.parse!(["sb_1"])
  end

  test "raises Mix.Error when neither an id nor --template is given" do
    assert_raise Mix.Error, fn -> Terminal.parse!(["--api-key", "k"]) end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mix/tasks/e2b_terminal_test.exs`
Expected: FAIL to compile — `Mix.Tasks.E2b.Terminal.parse!/1 is undefined` (module does not exist).

- [ ] **Step 3: Implement the Mix task**

Create `lib/mix/tasks/e2b.terminal.ex`:

```elixir
defmodule Mix.Tasks.E2b.Terminal do
  @shortdoc "Open an interactive terminal into a sandbox PTY"

  @moduledoc """
  Open a raw interactive terminal into a sandbox's PTY. Run this from a normal
  shell (NOT from `iex`) — it puts your terminal into raw mode and forwards
  keystrokes to the remote shell.

      mix e2b.terminal SANDBOX_ID        # attach to a running sandbox
      mix e2b.terminal --template base   # create a fresh sandbox, attach, kill on exit

  The API key is taken from `--api-key`, else the `E2B_API_KEY` environment
  variable, else `config :e2b_ex, api_key: ...`.

  To leave, end the remote shell (`exit` or Ctrl-D). On a normal exit the terminal
  is restored automatically; after an abrupt `kill -9`, run `reset`.
  """

  use Mix.Task

  alias E2bEx.{Pty, Sandboxes}

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:e2b_ex)
    {api_key, target} = parse!(argv)
    client = E2bEx.client(api_key: api_key)
    {sandbox, created?} = resolve_sandbox!(client, target)
    open(client, sandbox, created?)
  end

  @doc false
  @spec parse!([String.t()]) :: {String.t(), {:id, String.t()} | {:template, String.t()}}
  def parse!(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv, strict: [template: :string, api_key: :string], aliases: [t: :template])

    api_key =
      opts[:api_key] || System.get_env("E2B_API_KEY") || Application.get_env(:e2b_ex, :api_key) ||
        Mix.raise("No API key. Pass --api-key, set E2B_API_KEY, or config :e2b_ex, api_key: ...")

    target =
      cond do
        args != [] -> {:id, hd(args)}
        opts[:template] -> {:template, opts[:template]}
        true -> Mix.raise("Usage: mix e2b.terminal SANDBOX_ID | --template TEMPLATE")
      end

    {api_key, target}
  end

  defp resolve_sandbox!(client, {:id, id}) do
    case Sandboxes.connect(client, id, 60) do
      {:ok, sandbox} -> {sandbox, false}
      {:error, error} -> Mix.raise("Could not connect to sandbox #{id}: #{inspect(error)}")
    end
  end

  defp resolve_sandbox!(client, {:template, tmpl}) do
    case Sandboxes.create(client, %{templateID: tmpl}) do
      {:ok, sandbox} -> {sandbox, true}
      {:error, error} -> Mix.raise("Could not create sandbox from #{tmpl}: #{inspect(error)}")
    end
  end

  defp open(client, sandbox, created?) do
    {cols, rows} = terminal_size()
    orig = String.trim(to_string(:os.cmd(~c"stty -g </dev/tty")))

    try do
      _ = :os.cmd(~c"stty raw -echo </dev/tty")
      {:ok, handle} = Pty.create(client, sandbox, cols: cols, rows: rows, timeout_ms: 0)
      _ = Pty.Terminal.run(handle, size: &terminal_size/0)
      IO.binwrite(:stdio, "\n")
    after
      _ = :os.cmd(~c"stty #{orig} </dev/tty")
      if created?, do: Sandboxes.kill(client, sandbox.sandbox_id)
    end
  end

  # stty size prints "rows cols"; we return {cols, rows}. Falls back to 80x24.
  defp terminal_size do
    case :os.cmd(~c"stty size </dev/tty") |> to_string() |> String.split() do
      [rows, cols] -> {String.to_integer(cols), String.to_integer(rows)}
      _ -> {80, 24}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mix/tasks/e2b_terminal_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Verify strict compile and that the task is discoverable**

Run: `mix compile --warnings-as-errors`
Expected: clean.

Run: `mix help e2b.terminal`
Expected: prints the `@shortdoc`/`@moduledoc` (confirms the task is registered).

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/e2b.terminal.ex test/mix/tasks/e2b_terminal_test.exs
git commit -m "feat(terminal): add mix e2b.terminal CLI task"
```

---

## Task 4: README documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the terminal section**

In `README.md`, locate the `### Interactive PTY sessions` section (added by the PTY feature). Immediately after it (before the `Configuration can also come from application config:` line), insert:

```markdown
### A full interactive terminal (`mix e2b.terminal`)

For a real terminal — arrow keys, tab-completion, `vim`/`htop`, Ctrl-C — use the
Mix task from a normal shell (not from `iex`). It puts your terminal into raw mode
and bridges it to a sandbox PTY:

\`\`\`sh
# Attach to a running sandbox:
mix e2b.terminal SANDBOX_ID

# Or create a fresh sandbox from a template, attach, and kill it on exit:
mix e2b.terminal --template base
\`\`\`

The API key comes from `--api-key`, else `E2B_API_KEY`, else
`config :e2b_ex, api_key: ...`. To leave, end the remote shell (`exit` or Ctrl-D);
the terminal is restored automatically. (Programmatically, the bridge is
`E2bEx.Pty.Terminal.run/2` over an `E2bEx.Pty` handle.)

```

Note: in the actual README the three backticks above must be literal triple-backticks with `sh` — write a normal fenced ```sh code block (the `\`\`\`` shown here is only escaped to embed it in this plan).

- [ ] **Step 2: Verify the markdown renders cleanly**

Run: `grep -n "e2b.terminal" README.md`
Expected: shows the new heading and the two command examples. Re-read the section to confirm the code fence is well-formed (a ```sh block, not escaped backticks).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document mix e2b.terminal in README"
```

---

## Final Review

After all tasks, dispatch a final whole-implementation code reviewer, then use `superpowers:finishing-a-development-branch`.

Sanity checklist before merge:
- [ ] `mix test` green; `mix compile --warnings-as-errors` clean; `mix help e2b.terminal` lists the task.
- [ ] `InputBatcher` coalesces bytes and flushes the remainder on stop.
- [ ] `Terminal.run/2` writes pty output, batches stdin → `send_input` (`input.pty`), resizes on size change, and returns `{:ok, %CommandResult{}}` / `{:error, %Error{}}` (incl. server-crash).
- [ ] The Mix task resolves api-key (opt/env/config) and target (id vs `--template`), and wraps the session in `try/after` that restores the tty and kills a created sandbox.
- [ ] `E2bEx.Pty.Terminal` contains no `stty`/Mix knowledge; all tty/`stty` side effects live in `Mix.Tasks.E2b.Terminal`.
- [ ] Manual smoke (documented, not automated): `mix e2b.terminal --template base` opens a working shell; resizing the window resizes the remote; `exit` restores the local terminal.
```
