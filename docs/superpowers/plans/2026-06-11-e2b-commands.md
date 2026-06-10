# E2bEx Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `E2bEx.Commands.run/4` to execute a shell command inside a running sandbox and return its stdout/stderr/exit code, by talking directly to the sandbox's `envd` daemon over the Connect protocol.

**Architecture:** Command execution does not use the central API. `E2bEx.Commands` builds its own `Req` request to `https://{port}-{sandboxId}.{domain}/process.Process/Start` using the Connect **+JSON** codec. The request and response bodies are wrapped in Connect's length-prefixed frames; `E2bEx.Envd.Connect` is a pure module that encodes/decodes those frames. For a blocking run the whole response is buffered, then the frames are folded into an `E2bEx.CommandResult`.

**Tech Stack:** Elixir ~> 1.18, `Req` (HTTP), `Jason` (JSON, transitive via Req), `Base` (base64), binary pattern matching (framing). No new dependencies.

---

## Conventions used throughout this plan

- Connect frame layout: `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`. Request frames and data/event response frames use `flags == 0`; the Connect end-of-stream **trailer** frame uses `flags &&& 0x02 != 0`.
- The command string is always wrapped as `/bin/bash -l -c "<command>"` (`cmd: "/bin/bash"`, `args: ["-l", "-c", command]`).
- In Connect+JSON, proto3 omits zero values, so a clean exit's `end` event has **no `exitCode` key** → default `exit_code` to `0`. `stdout`/`stderr` in `data` events are **base64-encoded**.
- Return contract: `{:ok, %E2bEx.CommandResult{}}` if the command ran (any exit code); `{:error, %E2bEx.Error{}}` for transport/non-2xx/trailer-error/malformed-framing failures.
- The existing `E2bEx.Error` struct is `%E2bEx.Error{status, code, message, reason, body}` (already defined; do not change it).

## File structure

| File | Responsibility |
|---|---|
| `lib/e2b_ex/command_result.ex` | `%E2bEx.CommandResult{}` struct |
| `lib/e2b_ex/envd/connect.ex` | Pure Connect-protocol framing: `encode_frame/1`, `decode_frames/1` |
| `lib/e2b_ex/commands.ex` | `E2bEx.Commands.run/4` — builds the envd request, folds frames into a result |
| `test/e2b_ex/envd/connect_test.exs` | Unit tests for framing |
| `test/e2b_ex/commands_test.exs` | `Req.Test`-stubbed tests for `run/4` |

---

## Task 1: `E2bEx.CommandResult`

**Files:**
- Create: `lib/e2b_ex/command_result.ex`
- Test: `test/e2b_ex/command_result_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/e2b_ex/command_result_test.exs`:

```elixir
defmodule E2bEx.CommandResultTest do
  use ExUnit.Case, async: true
  alias E2bEx.CommandResult

  test "defaults to empty output and zero exit code" do
    assert %CommandResult{stdout: "", stderr: "", exit_code: 0, error: nil} = %CommandResult{}
  end

  test "holds populated fields" do
    r = %CommandResult{stdout: "hi", stderr: "err", exit_code: 1, error: "boom"}
    assert r.stdout == "hi"
    assert r.exit_code == 1
    assert r.error == "boom"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/command_result_test.exs`
Expected: FAIL — `E2bEx.CommandResult` is undefined.

- [ ] **Step 3: Implement the struct**

Create `lib/e2b_ex/command_result.ex`:

```elixir
defmodule E2bEx.CommandResult do
  @moduledoc """
  Result of a completed sandbox command (see `E2bEx.Commands.run/4`).

  `exit_code` is `0` for success. `error` carries a command-level error string
  reported by envd in the process `end` event (distinct from an operation-level
  `{:error, %E2bEx.Error{}}`, which signals the command could not be run).
  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer(),
          error: String.t() | nil
        }

  defstruct stdout: "", stderr: "", exit_code: 0, error: nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/command_result_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/command_result.ex test/e2b_ex/command_result_test.exs
git commit -m "feat: add E2bEx.CommandResult struct"
```

---

## Task 2: `E2bEx.Envd.Connect` (framing)

**Files:**
- Create: `lib/e2b_ex/envd/connect.ex`
- Test: `test/e2b_ex/envd/connect_test.exs`

This pure module encodes a payload into a single Connect frame and decodes a
buffered response body into `{:ok, messages, trailer}`. `messages` are the
JSON-decoded non-trailer frames (each a `StartResponse` map); `trailer` is the
JSON-decoded end-of-stream frame (or `nil` if absent).

- [ ] **Step 1: Write the failing test**

Create `test/e2b_ex/envd/connect_test.exs`:

```elixir
defmodule E2bEx.Envd.ConnectTest do
  use ExUnit.Case, async: true
  alias E2bEx.Envd.Connect

  # Build a normal (flags 0) frame around a JSON-encodable map.
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  # Build an end-of-stream trailer frame (flags 0x02) around raw JSON.
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "encode_frame/1 prefixes flags 0 and a big-endian length" do
    assert Connect.encode_frame("hello") == <<0::8, 5::unsigned-big-32, "hello">>
  end

  test "decode_frames/1 decodes a single data message and no trailer" do
    body = frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}})
    assert {:ok, [%{"event" => %{"data" => %{"stdout" => "aGk="}}}], nil} = Connect.decode_frames(body)
  end

  test "decode_frames/1 decodes multiple messages followed by a success trailer" do
    body =
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}}) <>
        frame(%{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}) <>
        trailer("{}")

    assert {:ok, messages, %{}} = Connect.decode_frames(body)
    assert length(messages) == 3
    assert List.last(messages) == %{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}
  end

  test "decode_frames/1 surfaces an error trailer" do
    body = trailer(~s({"error":{"code":"unavailable","message":"nope"}}))
    assert {:ok, [], %{"error" => %{"code" => "unavailable", "message" => "nope"}}} =
             Connect.decode_frames(body)
  end

  test "decode_frames/1 treats an empty trailer body as an empty map" do
    body = <<2::8, 0::unsigned-big-32>>
    assert {:ok, [], %{}} = Connect.decode_frames(body)
  end

  test "decode_frames/1 returns an error on truncated framing" do
    body = <<0::8, 10::unsigned-big-32, "short">>
    assert {:error, :malformed_frame} = Connect.decode_frames(body)
  end

  test "decode_frames/1 returns an error on invalid JSON in a frame" do
    body = <<0::8, 3::unsigned-big-32, "{[}">>
    assert {:error, {:invalid_json, _}} = Connect.decode_frames(body)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/envd/connect_test.exs`
Expected: FAIL — `E2bEx.Envd.Connect` is undefined.

- [ ] **Step 3: Implement the framing module**

Create `lib/e2b_ex/envd/connect.ex`:

```elixir
defmodule E2bEx.Envd.Connect do
  @moduledoc false
  # Connect-protocol (ConnectRPC) framing for the envd process API, JSON codec.
  #
  # Each frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # Normal messages use flags 0; the end-of-stream trailer sets bit 0x02.

  import Bitwise

  @end_stream_flag 0x02

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
    with {:ok, frames} <- split(body, []) do
      {trailers, messages} = Enum.split_with(frames, fn {flags, _} -> trailer?(flags) end)

      with {:ok, decoded} <- decode_each(messages, []),
           {:ok, trailer} <- decode_trailer(trailers) do
        {:ok, decoded, trailer}
      end
    end
  end

  defp trailer?(flags), do: (flags &&& @end_stream_flag) != 0

  defp split(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp split(<<flags::8, len::unsigned-big-32, data::binary-size(len), rest::binary>>, acc),
    do: split(rest, [{flags, data} | acc])

  defp split(_partial, _acc), do: {:error, :malformed_frame}

  defp decode_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_each([{_flags, data} | rest], acc) do
    case Jason.decode(data) do
      {:ok, map} -> decode_each(rest, [map | acc])
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_trailer([]), do: {:ok, nil}
  defp decode_trailer([{_flags, ""} | _]), do: {:ok, %{}}

  defp decode_trailer([{_flags, data} | _]) do
    case Jason.decode(data) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/envd/connect_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/envd/connect.ex test/e2b_ex/envd/connect_test.exs
git commit -m "feat: add Connect protocol framing for envd"
```

---

## Task 3: `E2bEx.Commands.run/4`

**Files:**
- Create: `lib/e2b_ex/commands.ex`
- Test: `test/e2b_ex/commands_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/e2b_ex/commands_test.exs`:

```elixir
defmodule E2bEx.CommandsTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, CommandResult, Commands, Error, Sandbox}
  alias E2bEx.Envd.Connect

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  defp respond(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/connect+json")
    |> Plug.Conn.send_resp(200, body)
  end

  test "run/4 posts a wrapped command and folds stdout/exit code" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/process.Process/Start"
      assert conn.host == "49983-sb_1.e2b.app"
      assert Plug.Conn.get_req_header(conn, "x-access-token") == ["tok_1"]
      assert Plug.Conn.get_req_header(conn, "connect-protocol-version") == ["1"]
      assert Plug.Conn.get_req_header(conn, "e2b-sandbox-id") == ["sb_1"]
      assert ["application/connect+json"] = Plug.Conn.get_req_header(conn, "content-type")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw
      assert Jason.decode!(json) ==
               %{"process" => %{"cmd" => "/bin/bash", "args" => ["-l", "-c", "echo hi"]}, "stdin" => false}

      body =
        frame(%{"event" => %{"start" => %{"pid" => 7}}}) <>
          frame(%{"event" => %{"data" => %{"stdout" => Base.encode64("hi\n")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}) <>
          trailer("{}")

      respond(conn, body)
    end)

    assert {:ok, %CommandResult{stdout: "hi\n", stderr: "", exit_code: 0, error: nil}} =
             Commands.run(client(), sandbox(), "echo hi")
  end

  test "run/4 sends cwd, envs, and a Basic auth header for :user" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("root:")]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      <<0::8, len::unsigned-big-32, json::binary-size(len)>> = raw

      assert Jason.decode!(json) == %{
               "process" => %{
                 "cmd" => "/bin/bash",
                 "args" => ["-l", "-c", "ls"],
                 "cwd" => "/tmp",
                 "envs" => %{"FOO" => "bar"}
               },
               "stdin" => false
             }

      respond(conn, frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    assert {:ok, %CommandResult{}} =
             Commands.run(client(), sandbox(), "ls", cwd: "/tmp", envs: %{"FOO" => "bar"}, user: "root")
  end

  test "run/4 returns a non-zero exit code with stderr (still {:ok, _})" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        frame(%{"event" => %{"data" => %{"stderr" => Base.encode64("boom\n")}}}) <>
          frame(%{"event" => %{"end" => %{"exited" => true, "exitCode" => 2}}}) <>
          trailer("{}")

      respond(conn, body)
    end)

    assert {:ok, %CommandResult{exit_code: 2, stderr: "boom\n"}} =
             Commands.run(client(), sandbox(), "false")
  end

  test "run/4 maps a Connect error trailer to {:error, %Error{}}" do
    Req.Test.stub(__MODULE__, fn conn ->
      respond(conn, trailer(~s({"error":{"code":"unavailable","message":"sandbox gone"}})))
    end)

    assert {:error, %Error{message: "sandbox gone", reason: "unavailable"}} =
             Commands.run(client(), sandbox(), "echo hi")
  end

  test "run/4 maps a transport error to {:error, %Error{}}" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, %Error{reason: :econnrefused}} = Commands.run(client(), sandbox(), "echo hi")
  end

  test "run/4 omits x-access-token when the sandbox has none" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-access-token") == []
      respond(conn, frame(%{"event" => %{"end" => %{"exited" => true}}}) <> trailer("{}"))
    end)

    sb = %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: nil}
    assert {:ok, %CommandResult{}} = Commands.run(client(), sb, "echo hi")
  end

  test "run/4 errors when the sandbox is missing its id" do
    assert {:error, %Error{message: "sandbox is missing :sandbox_id" <> _}} =
             Commands.run(client(), %Sandbox{sandbox_id: nil}, "echo hi")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/commands_test.exs`
Expected: FAIL — `E2bEx.Commands` is undefined.

- [ ] **Step 3: Implement `E2bEx.Commands`**

Create `lib/e2b_ex/commands.ex`:

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

  `sandbox` is an `%E2bEx.Sandbox{}` (from `E2bEx.Sandboxes.create/2`,
  `connect/3`, or `get/2`) and must carry a `:sandbox_id`. `client` supplies
  shared `Req` config via its `:req_options`.

  ## Options
    * `:cwd` — working directory.
    * `:envs` — environment variables (`%{String.t() => String.t()}`).
    * `:user` — Linux user to run as (adds an `Authorization: Basic` header).
    * `:timeout_ms` — total command timeout; default `#{@default_timeout_ms}`, `0` disables.
    * `:domain` — override the sandbox domain.
    * `:port` — envd port; default `#{@default_port}`.
  """
  @spec run(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, sandbox_id} <- fetch_sandbox_id(sandbox) do
      domain = sandbox.domain || opts[:domain] || domain_from(client)
      port = opts[:port] || @default_port
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      body = Connect.encode_frame(Jason.encode!(start_request(command, opts)))

      req =
        Req.new(
          method: :post,
          base_url: "https://#{port}-#{sandbox_id}.#{domain}",
          url: @start_path,
          headers: headers(sandbox, sandbox_id, port, timeout_ms, opts),
          body: body,
          retry: false,
          decode_body: false
        )
        |> Req.merge(client.req_options)
        |> with_timeout(timeout_ms)

      case Req.request(req) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          parse_result(resp_body)

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          {:error, Error.from_exception(exception)}
      end
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

  defp parse_result(body) do
    case Connect.decode_frames(body) do
      {:ok, messages, trailer} ->
        case trailer_error(trailer) do
          nil -> {:ok, fold_events(messages)}
          %Error{} = error -> {:error, error}
        end

      {:error, reason} ->
        {:error, %Error{message: "malformed envd response", reason: reason, body: body}}
    end
  end

  defp trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  defp trailer_error(_), do: nil

  defp fold_events(messages) do
    Enum.reduce(messages, %CommandResult{}, fn message, acc ->
      apply_event(acc, message["event"])
    end)
  end

  defp apply_event(acc, %{"data" => %{"stdout" => chunk}}),
    do: %{acc | stdout: acc.stdout <> decode_chunk(chunk)}

  defp apply_event(acc, %{"data" => %{"stderr" => chunk}}),
    do: %{acc | stderr: acc.stderr <> decode_chunk(chunk)}

  defp apply_event(acc, %{"end" => end_event}),
    do: %{acc | exit_code: Map.get(end_event, "exitCode", 0), error: Map.get(end_event, "error")}

  defp apply_event(acc, _other), do: acc

  defp decode_chunk(chunk), do: Base.decode64!(chunk)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/commands_test.exs`
Expected: PASS (7 tests).

Then run `mix compile --warnings-as-errors` (must be clean) and the full suite `mix test`.

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/commands.ex test/e2b_ex/commands_test.exs
git commit -m "feat: add E2bEx.Commands.run for blocking sandbox commands"
```

---

## Task 4: Document command execution in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a usage section**

Append the following section to `README.md` (after the existing `## Usage` section):

```markdown
## Running commands in a sandbox

Commands run directly against the sandbox's `envd` daemon (not the central API),
using the `%E2bEx.Sandbox{}` returned by `create/2` or `connect/3`:

\`\`\`elixir
client = E2bEx.client(api_key: "e2b_...")
{:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})

{:ok, result} =
  E2bEx.Commands.run(client, sandbox,
    ~s(codex exec --full-auto --skip-git-repo-check "Create a hello world HTTP server in Go"))

result.exit_code  # 0
result.stdout     # "..."
\`\`\`

`run/4` returns `{:ok, %E2bEx.CommandResult{}}` whenever the command runs (check
`exit_code` for success); `{:error, %E2bEx.Error{}}` signals it could not be run.
Options: `:cwd`, `:envs`, `:user`, `:timeout_ms`.
```

IMPORTANT: In the actual `README.md`, the inner code fence must be real triple-backticks (```), not the backslash-escaped form shown above.

- [ ] **Step 2: Verify the suite still passes and docs build**

Run: `mix test`
Expected: PASS (all tests).

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document running commands in a sandbox"
```

---

## Self-review notes (resolved during planning)

- **Spec coverage:** `CommandResult` (Task 1) → spec §"E2bEx.CommandResult"; `Envd.Connect` framing (Task 2) → spec §"Connect protocol details" + §"Architecture"; `Commands.run/4` request building, event folding, error handling (Task 3) → spec §"Public API" / §"Data flow" / §"Error handling"; README (Task 4) → ergonomics. All testing bullets from the spec map to tests in Tasks 2 and 3.
- **Return contract:** ran-command → `{:ok, %CommandResult{}}` (incl. non-zero exit); transport/non-2xx/trailer-error/malformed → `{:error, %Error{}}`. Matches the spec table.
- **Naming consistency:** `encode_frame/1`, `decode_frames/1`, `run/4`, `%CommandResult{}` used identically across tasks and tests. Trailer detection uses `flags &&& 0x02`.
- **No new deps:** `Jason` and `Base` are already available (Jason transitively via Req).
- **Known minor:** on a non-2xx envd response, `Error.from_response/1` sees a raw (undecoded) body because `decode_body: false`, so `code`/`message` may be nil and the raw JSON lands in `body`. Acceptable for v1; the common failures (transport, trailer error) are mapped richly.
```
