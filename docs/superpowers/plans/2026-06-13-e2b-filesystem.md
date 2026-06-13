# E2bEx Filesystem Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `E2bEx.Filesystem` (Phase 1): read/write file content + metadata ops (list/get_info/exists/make_dir/rename/remove) against the sandbox `envd` daemon.

**Architecture:** Metadata ops reuse the existing `E2bEx.Envd.Rpc.unary/4` (bare-JSON Connect POST) against `filesystem.Filesystem/*` paths; file content uses two new raw-HTTP helpers on `Rpc` (`get_file/3`/`put_file/4` → `GET`/`POST /files`). A typed `E2bEx.EntryInfo` struct decodes responses. No central-API/auth/transport-config changes; watch is Phase 2.

**Tech Stack:** Elixir ~> 1.18, `Req` (envd HTTP), `Bypass` for tests.

**Reference spec:** `docs/superpowers/specs/2026-06-13-e2b-filesystem-design.md`

---

## File Structure

- **Create** `lib/e2b_ex/entry_info.ex` — `E2bEx.EntryInfo` struct + `from_api/1`.
- **Modify** `lib/e2b_ex/envd/rpc.ex` — add `get_file/3`, `put_file/4`, and the private `file_headers/1`/`file_params/2` helpers.
- **Create** `lib/e2b_ex/filesystem.ex` — `E2bEx.Filesystem` public surface.
- **Modify** `README.md` — add a `## Filesystem` section.
- **Test** `test/e2b_ex/entry_info_test.exs`, `test/e2b_ex/filesystem_test.exs`, plus `get_file`/`put_file` cases in `test/e2b_ex/envd/rpc_test.exs`.

### Conventions an implementer must know (verified against the codebase)

- `E2bEx.Envd.Rpc.context(client, sandbox, opts)` → `{:ok, ctx}` where `ctx` has `.base_url`, `.headers` (incl. `x-access-token`, and `authorization` Basic when `:user` given), `.req_options`, `.timeout_ms`. `Rpc.unary(ctx, path, request_map)` → `{:ok, decoded_body} | {:error, %E2bEx.Error{}}` (it strips `content-type`/`keepalive-ping-interval`/`connect-timeout-ms` from the headers and POSTs bare JSON).
- `%E2bEx.Error{}` has `code` (string for envd Connect errors, e.g. `"not_found"`) and `status`. The `Rpc.kill/2` boolean idiom (`{:error, %Error{code: "not_found"}} -> {:ok, false}`) is the template for `exists`/`make_dir`.
- envd APIs are tested with **Bypass** (not `Req.Test`), pointing at it via the `:base_url` opt. See `test/e2b_ex/envd/rpc_test.exs` and `test/e2b_ex/commands_background_test.exs`.
- This repo is **hand-formatted** and does NOT use `mix format`. Do NOT run `mix format`; use the code below verbatim.
- proto3 JSON: enum `type` is a string (`"FILE_TYPE_FILE"`); `Timestamp` is an RFC3339 string under `modifiedTime`; `symlink_target → symlinkTarget`; empty repeated fields (e.g. an empty dir's `entries`) are **omitted** entirely.

---

## Task 1: `E2bEx.EntryInfo` struct

**Files:**
- Create: `lib/e2b_ex/entry_info.ex`
- Test: `test/e2b_ex/entry_info_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/entry_info_test.exs`:

```elixir
defmodule E2bEx.EntryInfoTest do
  use ExUnit.Case, async: true
  alias E2bEx.EntryInfo

  test "from_api/1 decodes a file entry (type, camelCase fields)" do
    entry =
      EntryInfo.from_api(%{
        "name" => "a.txt",
        "type" => "FILE_TYPE_FILE",
        "path" => "/d/a.txt",
        "size" => 3,
        "mode" => 420,
        "permissions" => "rw-r--r--",
        "owner" => "user",
        "group" => "user",
        "modifiedTime" => "2024-01-02T03:04:05Z",
        "symlinkTarget" => "/d/target",
        "metadata" => %{"k" => "v"}
      })

    assert %EntryInfo{
             name: "a.txt",
             type: :file,
             path: "/d/a.txt",
             size: 3,
             mode: 420,
             permissions: "rw-r--r--",
             owner: "user",
             group: "user",
             modified_time: "2024-01-02T03:04:05Z",
             symlink_target: "/d/target",
             metadata: %{"k" => "v"}
           } = entry
  end

  test "from_api/1 maps the directory type" do
    assert %EntryInfo{type: :dir} = EntryInfo.from_api(%{"type" => "FILE_TYPE_DIRECTORY"})
  end

  test "from_api/1 leaves omitted fields nil and unknown type nil" do
    assert %EntryInfo{name: "x", type: nil, size: nil, symlink_target: nil} =
             EntryInfo.from_api(%{"name" => "x"})
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/entry_info_test.exs`
Expected: FAIL to compile — `E2bEx.EntryInfo.__struct__/1 is undefined`.

- [ ] **Step 3: Create the struct**

Create `lib/e2b_ex/entry_info.ex`:

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

  defstruct [
    :name,
    :type,
    :path,
    :size,
    :mode,
    :permissions,
    :owner,
    :group,
    :modified_time,
    :symlink_target,
    :metadata
  ]

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

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/entry_info_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/entry_info.ex test/e2b_ex/entry_info_test.exs
git commit -m "feat(fs): add E2bEx.EntryInfo struct"
```

---

## Task 2: `Rpc.get_file/3` + `put_file/4` (HTTP file content)

**Files:**
- Modify: `lib/e2b_ex/envd/rpc.ex`
- Test: `test/e2b_ex/envd/rpc_test.exs`

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `test/e2b_ex/envd/rpc_test.exs` (the module already aliases `E2bEx.Error` as `Error`, `E2bEx.Envd.Rpc` as `Rpc`, and has `client/0`/`sandbox/0` helpers):

```elixir
  describe "file content (via Bypass)" do
    setup do
      bypass = Bypass.open()
      {:ok, ctx} = Rpc.context(client(), sandbox(), base_url: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, ctx: ctx}
    end

    test "get_file/3 GETs /files?path= with the access token and returns raw bytes",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["path"] == "/tmp/a.txt"
        assert Plug.Conn.get_req_header(conn, "x-access-token") == ["tok_1"]
        assert Plug.Conn.get_req_header(conn, "keepalive-ping-interval") == []
        Plug.Conn.resp(conn, 200, "hello bytes")
      end)

      assert {:ok, "hello bytes"} = Rpc.get_file(ctx, "/tmp/a.txt")
    end

    test "get_file/3 adds username when :user is given and returns \"\" for an empty file",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["username"] == "root"
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, ""} = Rpc.get_file(ctx, "/tmp/a.txt", user: "root")
    end

    test "get_file/3 maps a non-2xx to {:error, %Error{}}", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"code":"not_found","message":"no file"}))
      end)

      assert {:error, %Error{status: 404}} = Rpc.get_file(ctx, "/missing")
    end

    test "put_file/4 POSTs /files octet-stream with the raw body and returns the WriteInfo list",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/files", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["path"] == "/tmp/a.txt"
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert raw == "payload"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s([{"name":"a.txt","type":"FILE_TYPE_FILE","path":"/tmp/a.txt"}]))
      end)

      assert {:ok, [%{"name" => "a.txt", "path" => "/tmp/a.txt"}]} =
               Rpc.put_file(ctx, "/tmp/a.txt", "payload")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/envd/rpc_test.exs`
Expected: FAIL — `(UndefinedFunctionError) function E2bEx.Envd.Rpc.get_file/3 is undefined` (and `put_file/4`).

- [ ] **Step 3: Implement the content helpers**

In `lib/e2b_ex/envd/rpc.ex`, add these public functions after `list/1` (before the private `fetch_sandbox_id/1`):

```elixir
  @doc "Download file content over HTTP (`GET /files`). Returns the raw body bytes."
  @spec get_file(ctx(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def get_file(ctx, path, opts \\ []) when is_binary(path) do
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
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body || ""}
      {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
      {:error, exception} -> {:error, Error.from_exception(exception)}
    end
  end

  @doc "Upload file content over HTTP (`POST /files`, octet-stream). Returns the WriteInfo list."
  @spec put_file(ctx(), String.t(), binary(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def put_file(ctx, path, data, opts \\ []) when is_binary(path) and is_binary(data) do
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
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_write(body)}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  defp file_headers(ctx) do
    ctx.headers
    |> Map.delete("content-type")
    |> Map.delete("keepalive-ping-interval")
    |> Map.delete("connect-timeout-ms")
  end

  defp file_params(path, opts) do
    case opts[:user] do
      nil -> [path: path]
      user -> [path: path, username: user]
    end
  end

  defp normalize_write(body) when is_list(body), do: body
  defp normalize_write(_), do: []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/envd/rpc_test.exs`
Expected: PASS (new + existing).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/envd/rpc.ex test/e2b_ex/envd/rpc_test.exs
git commit -m "feat(fs): add Rpc.get_file/3 and put_file/4 (HTTP /files)"
```

---

## Task 3: `E2bEx.Filesystem` metadata ops

Creates the module with `list`/`get_info`/`exists`/`make_dir`/`rename`/`remove` (the Connect-unary metadata operations). `read`/`write` come in Task 4.

**Files:**
- Create: `lib/e2b_ex/filesystem.ex`
- Test: `test/e2b_ex/filesystem_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/e2b_ex/filesystem_test.exs`:

```elixir
defmodule E2bEx.FilesystemTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, EntryInfo, Error, Filesystem, Sandbox}

  defp client, do: Client.new(api_key: "k")
  defp sandbox, do: %Sandbox{sandbox_id: "sb_1", domain: "e2b.app", envd_access_token: "tok_1"}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp respond_json(conn, status, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(map))
  end

  test "list/4 ListDir sends path+depth and decodes entries", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d", "depth" => 1}

      respond_json(conn, 200, %{
        "entries" => [%{"name" => "a.txt", "type" => "FILE_TYPE_FILE", "path" => "/d/a.txt", "size" => 3}]
      })
    end)

    assert {:ok, [%EntryInfo{name: "a.txt", type: :file, path: "/d/a.txt", size: 3}]} =
             Filesystem.list(client(), sandbox(), "/d", base_url: base_url)
  end

  test "list/4 returns [] for an empty dir (no entries key)", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      respond_json(conn, 200, %{})
    end)

    assert {:ok, []} = Filesystem.list(client(), sandbox(), "/empty", base_url: base_url)
  end

  test "list/4 honours an explicit :depth", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/ListDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d", "depth" => 3}
      respond_json(conn, 200, %{"entries" => []})
    end)

    assert {:ok, []} = Filesystem.list(client(), sandbox(), "/d", depth: 3, base_url: base_url)
  end

  test "get_info/4 Stat decodes a directory entry incl. timestamp + symlink",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d"}

      respond_json(conn, 200, %{
        "entry" => %{
          "name" => "d",
          "type" => "FILE_TYPE_DIRECTORY",
          "path" => "/d",
          "modifiedTime" => "2024-01-02T03:04:05Z",
          "symlinkTarget" => "/x"
        }
      })
    end)

    assert {:ok, %EntryInfo{type: :dir, modified_time: "2024-01-02T03:04:05Z", symlink_target: "/x"}} =
             Filesystem.get_info(client(), sandbox(), "/d", base_url: base_url)
  end

  test "exists/4 is true when Stat succeeds", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 200, %{"entry" => %{"name" => "a", "type" => "FILE_TYPE_FILE", "path" => "/a"}})
    end)

    assert {:ok, true} = Filesystem.exists(client(), sandbox(), "/a", base_url: base_url)
  end

  test "exists/4 is false on a not_found error", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 404, %{"code" => "not_found", "message" => "missing"})
    end)

    assert {:ok, false} = Filesystem.exists(client(), sandbox(), "/missing", base_url: base_url)
  end

  test "make_dir/4 is true on success", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/MakeDir", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/d/new"}
      respond_json(conn, 200, %{"entry" => %{"name" => "new", "type" => "FILE_TYPE_DIRECTORY", "path" => "/d/new"}})
    end)

    assert {:ok, true} = Filesystem.make_dir(client(), sandbox(), "/d/new", base_url: base_url)
  end

  test "make_dir/4 is false when the directory already exists", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/MakeDir", fn conn ->
      respond_json(conn, 409, %{"code" => "already_exists", "message" => "exists"})
    end)

    assert {:ok, false} = Filesystem.make_dir(client(), sandbox(), "/d/old", base_url: base_url)
  end

  test "rename/5 Move sends source+destination and decodes the entry",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Move", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"source" => "/a.txt", "destination" => "/b.txt"}
      respond_json(conn, 200, %{"entry" => %{"name" => "b.txt", "type" => "FILE_TYPE_FILE", "path" => "/b.txt"}})
    end)

    assert {:ok, %EntryInfo{name: "b.txt", path: "/b.txt"}} =
             Filesystem.rename(client(), sandbox(), "/a.txt", "/b.txt", base_url: base_url)
  end

  test "remove/4 Remove returns :ok", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Remove", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"path" => "/a.txt"}
      respond_json(conn, 200, %{})
    end)

    assert :ok = Filesystem.remove(client(), sandbox(), "/a.txt", base_url: base_url)
  end

  test "get_info/4 propagates a non-2xx as {:error, %Error{}}", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/filesystem.Filesystem/Stat", fn conn ->
      respond_json(conn, 500, %{"code" => "internal", "message" => "boom"})
    end)

    assert {:error, %Error{status: 500}} = Filesystem.get_info(client(), sandbox(), "/x", base_url: base_url)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/filesystem_test.exs`
Expected: FAIL to compile — `E2bEx.Filesystem.list/4 is undefined`.

- [ ] **Step 3: Create the module with the metadata ops**

Create `lib/e2b_ex/filesystem.ex`:

```elixir
defmodule E2bEx.Filesystem do
  @moduledoc """
  Read, write, and manage files inside a sandbox.

  Like `E2bEx.Commands`, this talks to the sandbox's `envd` daemon, so the
  `sandbox` must carry an `:envd_access_token` (from `E2bEx.Sandboxes.create/2`,
  `connect/3`, or `get/2`); a `list/2`-derived sandbox gets `401` from envd.

  Metadata operations (`list`/`get_info`/`exists`/`make_dir`/`rename`/`remove`)
  use the envd Connect API; file content (`read`/`write`) uses envd's HTTP file
  transfer. All functions accept `:user`, `:timeout_ms`, `:domain`, `:port`, and
  `:base_url` options, as for `E2bEx.Commands`.
  """

  alias E2bEx.{Client, EntryInfo, Error, Sandbox}
  alias E2bEx.Envd.Rpc

  @stat_path "/filesystem.Filesystem/Stat"
  @list_path "/filesystem.Filesystem/ListDir"
  @make_dir_path "/filesystem.Filesystem/MakeDir"
  @move_path "/filesystem.Filesystem/Move"
  @remove_path "/filesystem.Filesystem/Remove"

  @doc "List a directory's entries (`ListDir`). `:depth` defaults to 1."
  @spec list(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, [EntryInfo.t()]} | {:error, Error.t()}
  def list(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, body} <- Rpc.unary(ctx, @list_path, %{path: path, depth: opts[:depth] || 1}) do
      {:ok, Enum.map(Map.get(body, "entries", []), &EntryInfo.from_api/1)}
    end
  end

  @doc "Stat a file or directory (`Stat`)."
  @spec get_info(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def get_info(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, %{"entry" => entry}} <- Rpc.unary(ctx, @stat_path, %{path: path}) do
      {:ok, EntryInfo.from_api(entry)}
    end
  end

  @doc "Whether a path exists (`Stat`). `{:ok, false}` on a not_found error."
  @spec exists(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def exists(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @stat_path, %{path: path}) do
        {:ok, _} -> {:ok, true}
        {:error, %Error{code: "not_found"}} -> {:ok, false}
        {:error, %Error{status: 404}} -> {:ok, false}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Create a directory (`MakeDir`, recursive). `{:ok, false}` if it already existed."
  @spec make_dir(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def make_dir(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @make_dir_path, %{path: path}) do
        {:ok, _} -> {:ok, true}
        {:error, %Error{code: "already_exists"}} -> {:ok, false}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Move/rename a file or directory (`Move`)."
  @spec rename(Client.t(), Sandbox.t(), String.t(), String.t(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def rename(%Client{} = client, %Sandbox{} = sandbox, old_path, new_path, opts \\ [])
      when is_binary(old_path) and is_binary(new_path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, %{"entry" => entry}} <-
           Rpc.unary(ctx, @move_path, %{source: old_path, destination: new_path}) do
      {:ok, EntryInfo.from_api(entry)}
    end
  end

  @doc "Remove a file or directory (`Remove`)."
  @spec remove(Client.t(), Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def remove(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      case Rpc.unary(ctx, @remove_path, %{path: path}) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/filesystem_test.exs`
Expected: PASS (all metadata-op tests).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/filesystem.ex test/e2b_ex/filesystem_test.exs
git commit -m "feat(fs): add Filesystem metadata ops (list/get_info/exists/make_dir/rename/remove)"
```

---

## Task 4: `E2bEx.Filesystem` content ops (`read`/`write`)

**Files:**
- Modify: `lib/e2b_ex/filesystem.ex`
- Test: `test/e2b_ex/filesystem_test.exs`

- [ ] **Step 1: Write the failing tests**

Add these tests to `test/e2b_ex/filesystem_test.exs`:

```elixir
  test "read/4 returns the file content as a binary", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/files", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["path"] == "/tmp/a.txt"
      Plug.Conn.resp(conn, 200, "file contents")
    end)

    assert {:ok, "file contents"} = Filesystem.read(client(), sandbox(), "/tmp/a.txt", base_url: base_url)
  end

  test "write/5 uploads octet-stream and returns the written EntryInfo",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/files", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["path"] == "/tmp/a.txt"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert raw == "hello"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([{"name":"a.txt","type":"FILE_TYPE_FILE","path":"/tmp/a.txt"}]))
    end)

    assert {:ok, %EntryInfo{name: "a.txt", type: :file, path: "/tmp/a.txt"}} =
             Filesystem.write(client(), sandbox(), "/tmp/a.txt", "hello", base_url: base_url)
  end

  test "write/5 returns an empty EntryInfo when envd returns no WriteInfo",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/files", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)

    assert {:ok, %EntryInfo{name: nil, path: nil}} =
             Filesystem.write(client(), sandbox(), "/tmp/a.txt", "hello", base_url: base_url)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/e2b_ex/filesystem_test.exs`
Expected: FAIL — `E2bEx.Filesystem.read/4 is undefined` (and `write/5`).

- [ ] **Step 3: Add `read`/`write` and the `write_info` helper**

In `lib/e2b_ex/filesystem.ex`, add these functions after `remove/4` (before the final `end`):

```elixir
  @doc "Read a file's content (`GET /files`). Returns the raw bytes; `\"\"` for an empty file."
  @spec read(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read(%Client{} = client, %Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      Rpc.get_file(ctx, path, opts)
    end
  end

  @doc """
  Write `data` (a binary) to a file (`POST /files`), overwriting if it exists.
  Returns the written entry.
  """
  @spec write(Client.t(), Sandbox.t(), String.t(), binary(), keyword()) ::
          {:ok, EntryInfo.t()} | {:error, Error.t()}
  def write(%Client{} = client, %Sandbox{} = sandbox, path, data, opts \\ [])
      when is_binary(path) and is_binary(data) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, infos} <- Rpc.put_file(ctx, path, data, opts) do
      {:ok, write_info(infos)}
    end
  end

  defp write_info([entry | _]) when is_map(entry), do: EntryInfo.from_api(entry)
  defp write_info(_), do: %EntryInfo{}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/e2b_ex/filesystem_test.exs`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Verify strict compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/e2b_ex/filesystem.ex test/e2b_ex/filesystem_test.exs
git commit -m "feat(fs): add Filesystem read/5 and write/5 (HTTP content)"
```

---

## Task 5: README documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the Filesystem section**

In `README.md`, find the `## Volumes` section. Immediately AFTER it (before the line `Configuration can also come from application config:`), insert this section. The code block must be a REAL fenced ```elixir block (three backticks); it is shown indented here only to embed it in this plan:

    ## Filesystem

    Read, write, and manage files inside a sandbox (via the sandbox's `envd`
    daemon — the sandbox must carry an `:envd_access_token`, as for commands):

    ```elixir
    {:ok, _entry}     = E2bEx.Filesystem.write(client, sandbox, "/tmp/hello.txt", "hi there")
    {:ok, "hi there"} = E2bEx.Filesystem.read(client, sandbox, "/tmp/hello.txt")
    {:ok, entries}    = E2bEx.Filesystem.list(client, sandbox, "/tmp")   # [%E2bEx.EntryInfo{}]
    {:ok, info}       = E2bEx.Filesystem.get_info(client, sandbox, "/tmp/hello.txt")
    {:ok, true}       = E2bEx.Filesystem.exists(client, sandbox, "/tmp/hello.txt")
    {:ok, true}       = E2bEx.Filesystem.make_dir(client, sandbox, "/tmp/sub")
    {:ok, _entry}     = E2bEx.Filesystem.rename(client, sandbox, "/tmp/hello.txt", "/tmp/bye.txt")
    :ok               = E2bEx.Filesystem.remove(client, sandbox, "/tmp/bye.txt")
    ```

    Watching for live filesystem changes is planned for a later release.

- [ ] **Step 2: Verify**

Run: `grep -n "## Filesystem\|E2bEx.Filesystem.write" README.md`
Expected: shows the new heading and the write example.

Re-read the inserted section to confirm the ```elixir fence is well-formed and the `Configuration ...` line still follows it.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(fs): add Filesystem section to README"
```

---

## Final Review

After all tasks, dispatch a final reviewer over the whole change, then use `superpowers:finishing-a-development-branch`.

Sanity checklist before merge:
- [ ] `mix test` green; `mix compile --warnings-as-errors` clean.
- [ ] `EntryInfo.from_api/1` decodes the type enum, `modifiedTime`, `symlinkTarget`; omitted fields → nil.
- [ ] `Rpc.get_file/3` returns raw bytes (`""` empty) and strips Connect-only headers; `put_file/4` POSTs octet-stream and returns the WriteInfo list; both map non-2xx → `{:error, %Error{}}`.
- [ ] `Filesystem` ops hit the right `filesystem.Filesystem/*` paths with the right bodies; `list` → `[]` for an empty dir; `exists`/`make_dir` return booleans; `remove` → `:ok`; `read` → `{:ok, binary}`; `write` → `{:ok, %EntryInfo{}}`.
- [ ] No central-API/auth changes; `Rpc.unary`/`context` and existing process wrappers unchanged.
- [ ] README has a `## Filesystem` section.
```
