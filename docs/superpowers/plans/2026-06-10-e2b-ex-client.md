# E2bEx Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a hand-written Elixir client for the E2B Sandboxes, Templates, and Tags APIs over `Req`, returning typed structs and a uniform error type.

**Architecture:** A `%E2bEx.Client{}` holds credentials/config and builds a base `Req` request. A single internal `E2bEx.Request` module is the only place that performs HTTP and maps non-2xx/transport failures to `%E2bEx.Error{}`. Three resource modules (`Sandboxes`, `Templates`, `Tags`) build paths/params, call `Request`, and decode success bodies into entity structs via each struct's `from_api/1`.

**Tech Stack:** Elixir ~> 1.18, `req ~> 0.5` (HTTP), `Req.Test` (stubbing), `ex_doc` (docs, dev only).

---

## Conventions used throughout this plan

- **Auth:** every request sends the `x-api-key` header from `client.api_key`.
- **Return contract:**
  - Value-returning calls → `{:ok, struct | [struct] | map | boolean}`.
  - Void calls (HTTP 204) → `:ok`.
  - Any non-2xx or transport failure → `{:error, %E2bEx.Error{}}`.
- **Struct fields** are `snake_case`; `from_api/1` maps the API's camelCase JSON keys explicitly.
- **Request bodies** are passed as maps whose keys match the OpenAPI property names (e.g. `%{templateID: "x"}`) and are JSON-encoded as-is by Req.
- **Query params** are built per-function as a keyword list and passed to Req's `params:` option.
- The base E2B server is `https://api.e2b.app`.

---

## File structure

| File | Responsibility |
|---|---|
| `mix.exs` | Deps + project metadata |
| `lib/e2b_ex.ex` | Top-level convenience (`client/1`) + module docs |
| `lib/e2b_ex/client.ex` | `%Client{}` struct, `new/1`, `base_req/1` |
| `lib/e2b_ex/error.ex` | `%Error{}` struct + `from_response/1`, `from_exception/1` |
| `lib/e2b_ex/request.ex` | Internal HTTP chokepoint `request/4` |
| `lib/e2b_ex/sandbox.ex` | `%Sandbox{}`, `%SandboxMetric{}`, `%SandboxLog{}`, `%Snapshot{}` + decoders |
| `lib/e2b_ex/template.ex` | `%Template{}`, `%TemplateBuild{}`, `%TemplateAlias{}`, `%TemplateTag{}` + decoders |
| `lib/e2b_ex/sandboxes.ex` | Sandboxes resource functions |
| `lib/e2b_ex/templates.ex` | Templates resource functions |
| `lib/e2b_ex/tags.ex` | Tags resource functions |
| `test/support/*` + `test/e2b_ex/*_test.exs` | Tests using `Req.Test` |

---

## Task 1: Project setup — dependencies and test support

**Files:**
- Modify: `mix.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Add dependencies to `mix.exs`**

Replace the `deps/0` function and add `elixirc_paths` so `test/support` compiles in test:

```elixir
  def project do
    [
      app: :e2b_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves and installs `req`, `jason`, `finch`, etc.

- [ ] **Step 3: Configure `Req.Test` in the test helper**

Replace `test/test_helper.exs` with:

```elixir
ExUnit.start()
```

(`Req.Test` stubs are set per-test; no global setup needed.)

- [ ] **Step 4: Verify the project compiles**

Run: `mix compile`
Expected: compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock test/test_helper.exs
git commit -m "chore: add req + ex_doc deps and test support paths"
```

---

## Task 2: `E2bEx.Error`

**Files:**
- Create: `lib/e2b_ex/error.ex`
- Test: `test/e2b_ex/error_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.ErrorTest do
  use ExUnit.Case, async: true
  alias E2bEx.Error

  test "from_response/1 extracts code and message from API error body" do
    resp = %Req.Response{status: 404, body: %{"code" => 404, "message" => "not found"}}
    error = Error.from_response(resp)
    assert %Error{status: 404, code: 404, message: "not found", body: %{"code" => 404, "message" => "not found"}} = error
  end

  test "from_response/1 tolerates a non-standard body" do
    resp = %Req.Response{status: 500, body: "boom"}
    assert %Error{status: 500, code: nil, message: nil, body: "boom"} = Error.from_response(resp)
  end

  test "from_exception/1 captures the transport reason" do
    error = Error.from_exception(%Req.TransportError{reason: :timeout})
    assert %Error{status: nil, reason: :timeout} = error
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/error_test.exs`
Expected: FAIL — `E2bEx.Error` is undefined.

- [ ] **Step 3: Implement `E2bEx.Error`**

```elixir
defmodule E2bEx.Error do
  @moduledoc """
  Uniform error returned by all `E2bEx` calls.

  For API errors (non-2xx responses), `status`, `code`, `message` and the raw
  `body` are populated. For transport failures (timeout, connection closed),
  `reason` is set and `status` is `nil`.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          code: integer() | nil,
          message: String.t() | nil,
          reason: term() | nil,
          body: term()
        }

  defstruct [:status, :code, :message, :reason, :body]

  @doc false
  @spec from_response(Req.Response.t()) :: t()
  def from_response(%Req.Response{status: status, body: body}) do
    {code, message} = extract(body)
    %__MODULE__{status: status, code: code, message: message, body: body}
  end

  @doc false
  @spec from_exception(Exception.t()) :: t()
  def from_exception(exception) do
    %__MODULE__{
      reason: Map.get(exception, :reason),
      message: safe_message(exception),
      body: exception
    }
  end

  defp extract(%{"code" => code, "message" => message}), do: {code, message}
  defp extract(%{"message" => message}), do: {nil, message}
  defp extract(_), do: {nil, nil}

  defp safe_message(exception) when is_exception(exception), do: Exception.message(exception)
  defp safe_message(_), do: nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/error_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/error.ex test/e2b_ex/error_test.exs
git commit -m "feat: add E2bEx.Error struct"
```

---

## Task 3: `E2bEx.Client`

**Files:**
- Create: `lib/e2b_ex/client.ex`
- Test: `test/e2b_ex/client_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.ClientTest do
  use ExUnit.Case, async: true
  alias E2bEx.Client

  test "new/1 builds a client with defaults" do
    client = Client.new(api_key: "key_123")
    assert %Client{api_key: "key_123", base_url: "https://api.e2b.app", req_options: []} = client
  end

  test "new/1 allows overriding base_url and req_options" do
    client = Client.new(api_key: "k", base_url: "http://localhost:3000", req_options: [retry: false])
    assert client.base_url == "http://localhost:3000"
    assert client.req_options == [retry: false]
  end

  test "new/1 raises without an api key" do
    assert_raise ArgumentError, fn -> Client.new([]) end
  end

  test "base_req/1 sets base_url and x-api-key header" do
    req = Client.new(api_key: "key_123") |> Client.base_req()
    assert req.options.base_url == "https://api.e2b.app"
    assert {"x-api-key", ["key_123"]} in Map.to_list(req.headers) or
             req.headers["x-api-key"] == ["key_123"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/client_test.exs`
Expected: FAIL — `E2bEx.Client` is undefined.

- [ ] **Step 3: Implement `E2bEx.Client`**

```elixir
defmodule E2bEx.Client do
  @moduledoc """
  Holds connection configuration for the E2B API.

  Build one with `E2bEx.client/1` (or `E2bEx.Client.new/1`) and pass it as the
  first argument to every resource function.
  """

  @default_base_url "https://api.e2b.app"

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          req_options: keyword()
        }

  defstruct [:api_key, :base_url, req_options: []]

  @doc """
  Build a client.

  ## Options
    * `:api_key` (required) — E2B API key sent as the `X-API-Key` header.
    * `:base_url` — defaults to `#{@default_base_url}`.
    * `:req_options` — extra options merged into every `Req` request (e.g. a
      `:plug` for testing, or `:retry`/`:receive_timeout`).

  Falls back to `Application.get_env(:e2b_ex, key)` for any option not given.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api_key =
      opts[:api_key] || Application.get_env(:e2b_ex, :api_key) ||
        raise ArgumentError, "E2bEx.Client requires an :api_key (or config :e2b_ex, :api_key)"

    %__MODULE__{
      api_key: api_key,
      base_url: opts[:base_url] || Application.get_env(:e2b_ex, :base_url, @default_base_url),
      req_options: opts[:req_options] || Application.get_env(:e2b_ex, :req_options, [])
    }
  end

  @doc false
  @spec base_req(t()) :: Req.Request.t()
  def base_req(%__MODULE__{} = client) do
    Req.new(base_url: client.base_url)
    |> Req.Request.put_header("x-api-key", client.api_key)
    |> Req.merge(client.req_options)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/client_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/client.ex test/e2b_ex/client_test.exs
git commit -m "feat: add E2bEx.Client config struct"
```

---

## Task 4: `E2bEx.Request` (HTTP chokepoint)

**Files:**
- Create: `lib/e2b_ex/request.ex`
- Test: `test/e2b_ex/request_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.RequestTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Error, Request}

  defp client do
    Client.new(api_key: "key_123", req_options: [plug: {Req.Test, __MODULE__}])
  end

  test "request/4 returns {:ok, body} on 2xx and sends the api key + path" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["key_123"]
      Req.Test.json(conn, %{"sandboxID" => "sb_1"})
    end)

    assert {:ok, %{"sandboxID" => "sb_1"}} = Request.request(client(), :get, "/sandboxes/sb_1")
  end

  test "request/4 sends query params and json body" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "metadata=user%3Dabc"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"templateID" => "tmpl_1"}
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, _} =
             Request.request(client(), :post, "/sandboxes",
               params: [metadata: "user=abc"],
               json: %{templateID: "tmpl_1"}
             )
  end

  test "request/4 returns :ok-shaped nil body for empty 204" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert {:ok, nil} = Request.request(client(), :delete, "/sandboxes/sb_1")
  end

  test "request/4 maps non-2xx to %Error{}" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "nope"})
    end)

    assert {:error, %Error{status: 404, code: 404, message: "nope"}} =
             Request.request(client(), :get, "/sandboxes/missing")
  end

  test "request/4 maps transport errors to %Error{}" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Error{reason: :timeout}} = Request.request(client(), :get, "/sandboxes")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/request_test.exs`
Expected: FAIL — `E2bEx.Request` is undefined.

- [ ] **Step 3: Implement `E2bEx.Request`**

```elixir
defmodule E2bEx.Request do
  @moduledoc false
  # The single place that performs HTTP and normalises results. Resource
  # modules call this; nothing else talks to Req directly.

  alias E2bEx.{Client, Error}

  @type result :: {:ok, term()} | {:error, Error.t()}

  @spec request(Client.t(), atom(), String.t(), keyword()) :: result()
  def request(%Client{} = client, method, path, opts \\ []) do
    options =
      [method: method, url: path]
      |> maybe_put(:params, Keyword.get(opts, :params))
      |> maybe_put(:json, Keyword.get(opts, :json))

    req = Req.merge(Client.base_req(client), options)

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, normalize_body(resp.body)}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/request_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/request.ex test/e2b_ex/request_test.exs
git commit -m "feat: add E2bEx.Request HTTP layer"
```

---

## Task 5: Sandbox-domain structs

**Files:**
- Create: `lib/e2b_ex/sandbox.ex`
- Test: `test/e2b_ex/sandbox_test.exs`

These structs decode the superset of `Sandbox` / `SandboxDetail` / `ListedSandbox`
(into `E2bEx.Sandbox`), `SandboxMetric`, `SandboxLogEntry`, and `SnapshotInfo`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.SandboxTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Sandbox, SandboxMetric, SandboxLog, Snapshot}

  test "Sandbox.from_api/1 maps camelCase keys to struct fields" do
    api = %{
      "templateID" => "tmpl_1",
      "sandboxID" => "sb_1",
      "alias" => "base",
      "startedAt" => "2026-06-10T00:00:00Z",
      "endAt" => "2026-06-10T01:00:00Z",
      "state" => "running",
      "cpuCount" => 2,
      "memoryMB" => 512,
      "diskSizeMB" => 1024,
      "envdVersion" => "0.1.0",
      "metadata" => %{"user" => "abc"}
    }

    sb = Sandbox.from_api(api)
    assert sb.template_id == "tmpl_1"
    assert sb.sandbox_id == "sb_1"
    assert sb.state == "running"
    assert sb.cpu_count == 2
    assert sb.metadata == %{"user" => "abc"}
  end

  test "SandboxMetric.from_api/1 maps fields" do
    m = SandboxMetric.from_api(%{"timestampUnix" => 100, "cpuCount" => 2, "cpuUsedPct" => 1.5, "memUsed" => 10, "memTotal" => 20, "memCache" => 1, "diskUsed" => 5, "diskTotal" => 50})
    assert m.timestamp_unix == 100
    assert m.cpu_used_pct == 1.5
    assert m.disk_total == 50
  end

  test "SandboxLog.from_api/1 maps fields" do
    log = SandboxLog.from_api(%{"timestamp" => "2026-06-10T00:00:00Z", "message" => "hi", "level" => "info", "fields" => %{"k" => "v"}})
    assert log.message == "hi"
    assert log.level == "info"
    assert log.fields == %{"k" => "v"}
  end

  test "Snapshot.from_api/1 maps fields" do
    snap = Snapshot.from_api(%{"snapshotID" => "snap_1", "names" => ["team/snap:default"]})
    assert snap.snapshot_id == "snap_1"
    assert snap.names == ["team/snap:default"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/sandbox_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement the structs**

```elixir
defmodule E2bEx.Sandbox do
  @moduledoc "A sandbox, decoded from create/get/list responses."

  @type t :: %__MODULE__{
          template_id: String.t() | nil,
          sandbox_id: String.t() | nil,
          alias: String.t() | nil,
          domain: String.t() | nil,
          started_at: String.t() | nil,
          end_at: String.t() | nil,
          state: String.t() | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          envd_version: String.t() | nil,
          envd_access_token: String.t() | nil,
          traffic_access_token: String.t() | nil,
          allow_internet_access: boolean() | nil,
          metadata: map() | nil,
          network: map() | nil,
          lifecycle: map() | nil,
          volume_mounts: list() | nil
        }

  defstruct [
    :template_id,
    :sandbox_id,
    :alias,
    :domain,
    :started_at,
    :end_at,
    :state,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :envd_version,
    :envd_access_token,
    :traffic_access_token,
    :allow_internet_access,
    :metadata,
    :network,
    :lifecycle,
    :volume_mounts
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      template_id: m["templateID"],
      sandbox_id: m["sandboxID"],
      alias: m["alias"],
      domain: m["domain"],
      started_at: m["startedAt"],
      end_at: m["endAt"],
      state: m["state"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      envd_version: m["envdVersion"],
      envd_access_token: m["envdAccessToken"],
      traffic_access_token: m["trafficAccessToken"],
      allow_internet_access: m["allowInternetAccess"],
      metadata: m["metadata"],
      network: m["network"],
      lifecycle: m["lifecycle"],
      volume_mounts: m["volumeMounts"]
    }
  end
end

defmodule E2bEx.SandboxMetric do
  @moduledoc "A point-in-time resource-usage metric for a sandbox."

  @type t :: %__MODULE__{
          timestamp: String.t() | nil,
          timestamp_unix: integer() | nil,
          cpu_count: integer() | nil,
          cpu_used_pct: float() | nil,
          mem_used: integer() | nil,
          mem_total: integer() | nil,
          mem_cache: integer() | nil,
          disk_used: integer() | nil,
          disk_total: integer() | nil
        }

  defstruct [
    :timestamp,
    :timestamp_unix,
    :cpu_count,
    :cpu_used_pct,
    :mem_used,
    :mem_total,
    :mem_cache,
    :disk_used,
    :disk_total
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      timestamp: m["timestamp"],
      timestamp_unix: m["timestampUnix"],
      cpu_count: m["cpuCount"],
      cpu_used_pct: m["cpuUsedPct"],
      mem_used: m["memUsed"],
      mem_total: m["memTotal"],
      mem_cache: m["memCache"],
      disk_used: m["diskUsed"],
      disk_total: m["diskTotal"]
    }
  end
end

defmodule E2bEx.SandboxLog do
  @moduledoc "A structured sandbox log entry."

  @type t :: %__MODULE__{
          timestamp: String.t() | nil,
          message: String.t() | nil,
          level: String.t() | nil,
          fields: map() | nil
        }

  defstruct [:timestamp, :message, :level, :fields]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      timestamp: m["timestamp"],
      message: m["message"],
      level: m["level"],
      fields: m["fields"]
    }
  end
end

defmodule E2bEx.Snapshot do
  @moduledoc "Result of snapshotting a sandbox."

  @type t :: %__MODULE__{snapshot_id: String.t() | nil, names: [String.t()] | nil}

  defstruct [:snapshot_id, :names]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{snapshot_id: m["snapshotID"], names: m["names"]}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/sandbox_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/sandbox.ex test/e2b_ex/sandbox_test.exs
git commit -m "feat: add sandbox-domain structs"
```

---

## Task 6: `E2bEx.Sandboxes` — read operations

Functions: `list/2`, `get/2`, `metrics/2`, `list_metrics/2`, `logs/2`, `list_snapshots/2`.

**Files:**
- Create: `lib/e2b_ex/sandboxes.ex`
- Test: `test/e2b_ex/sandboxes_read_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.SandboxesReadTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox, SandboxMetric, SandboxLog, Sandboxes}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /v2/sandboxes and decodes a list, passing filters" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/sandboxes"
      assert conn.query_string =~ "metadata=user%3Dabc"
      Req.Test.json(conn, [%{"sandboxID" => "sb_1"}, %{"sandboxID" => "sb_2"}])
    end)

    assert {:ok, [%Sandbox{sandbox_id: "sb_1"}, %Sandbox{sandbox_id: "sb_2"}]} =
             Sandboxes.list(client(), metadata: "user=abc")
  end

  test "get/2 GETs /sandboxes/:id and decodes one sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1"
      Req.Test.json(conn, %{"sandboxID" => "sb_1", "state" => "running"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1", state: "running"}} = Sandboxes.get(client(), "sb_1")
  end

  test "metrics/2 GETs /sandboxes/:id/metrics and decodes a metric list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/metrics"
      Req.Test.json(conn, [%{"timestampUnix" => 100, "cpuCount" => 2, "cpuUsedPct" => 1.0, "memUsed" => 1, "memTotal" => 2, "memCache" => 0, "diskUsed" => 1, "diskTotal" => 2}])
    end)

    assert {:ok, [%SandboxMetric{timestamp_unix: 100}]} = Sandboxes.metrics(client(), "sb_1")
  end

  test "list_metrics/2 GETs /sandboxes/metrics and decodes the sandboxes map" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/metrics"
      assert conn.query_string =~ "sandbox_ids=sb_1"
      Req.Test.json(conn, %{"sandboxes" => %{"sb_1" => %{"timestampUnix" => 1, "cpuCount" => 1, "cpuUsedPct" => 0.0, "memUsed" => 0, "memTotal" => 0, "memCache" => 0, "diskUsed" => 0, "diskTotal" => 0}}})
    end)

    assert {:ok, %{"sb_1" => %SandboxMetric{timestamp_unix: 1}}} =
             Sandboxes.list_metrics(client(), ["sb_1"])
  end

  test "logs/2 GETs /v2/sandboxes/:id/logs and decodes log entries" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v2/sandboxes/sb_1/logs"
      Req.Test.json(conn, %{"logs" => [%{"timestamp" => "t", "message" => "hi", "level" => "info", "fields" => %{}}]})
    end)

    assert {:ok, [%SandboxLog{message: "hi"}]} = Sandboxes.logs(client(), "sb_1")
  end

  test "list_snapshots/2 GETs /snapshots and returns the raw list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/snapshots"
      Req.Test.json(conn, [%{"sandboxID" => "sb_1"}])
    end)

    assert {:ok, [%Sandbox{sandbox_id: "sb_1"}]} = Sandboxes.list_snapshots(client())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/sandboxes_read_test.exs`
Expected: FAIL — `E2bEx.Sandboxes` is undefined.

- [ ] **Step 3: Implement the read half of `E2bEx.Sandboxes`**

```elixir
defmodule E2bEx.Sandboxes do
  @moduledoc """
  Sandbox operations.

  Every function takes an `E2bEx.Client` as the first argument. Read functions
  return `{:ok, struct | [struct]}`; see `E2bEx.Sandboxes` write functions for
  lifecycle actions.
  """

  alias E2bEx.{Request, Sandbox, SandboxLog, SandboxMetric}

  @doc """
  List running sandboxes (`GET /v2/sandboxes`).

  ## Options (query)
    * `:metadata` — metadata filter string, e.g. `"user=abc&app=prod"`.
    * `:state` — list of states, e.g. `["running", "paused"]`.
    * `:next_token` — pagination cursor.
    * `:limit` — page size.
  """
  @spec list(E2bEx.Client.t(), keyword()) :: {:ok, [Sandbox.t()]} | {:error, E2bEx.Error.t()}
  def list(client, opts \\ []) do
    params =
      []
      |> put_param(:metadata, opts[:metadata])
      |> put_param(:state, opts[:state])
      |> put_param(:nextToken, opts[:next_token])
      |> put_param(:limit, opts[:limit])

    with {:ok, list} <- Request.request(client, :get, "/v2/sandboxes", params: params) do
      {:ok, Enum.map(list, &Sandbox.from_api/1)}
    end
  end

  @doc "Get a sandbox by id (`GET /sandboxes/:id`)."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Sandbox.t()} | {:error, E2bEx.Error.t()}
  def get(client, sandbox_id) do
    with {:ok, body} <- Request.request(client, :get, "/sandboxes/#{sandbox_id}") do
      {:ok, Sandbox.from_api(body)}
    end
  end

  @doc """
  Get metrics for a sandbox (`GET /sandboxes/:id/metrics`).

  ## Options (query): `:start`, `:end` (Unix ms timestamps).
  """
  @spec metrics(E2bEx.Client.t(), String.t(), keyword()) ::
          {:ok, [SandboxMetric.t()]} | {:error, E2bEx.Error.t()}
  def metrics(client, sandbox_id, opts \\ []) do
    params = [] |> put_param(:start, opts[:start]) |> put_param(:end, opts[:end])

    with {:ok, list} <- Request.request(client, :get, "/sandboxes/#{sandbox_id}/metrics", params: params) do
      {:ok, Enum.map(list, &SandboxMetric.from_api/1)}
    end
  end

  @doc """
  Get latest metrics for several sandboxes (`GET /sandboxes/metrics`).

  Returns `{:ok, %{sandbox_id => E2bEx.SandboxMetric.t()}}`.
  """
  @spec list_metrics(E2bEx.Client.t(), [String.t()]) ::
          {:ok, %{String.t() => SandboxMetric.t()}} | {:error, E2bEx.Error.t()}
  def list_metrics(client, sandbox_ids) when is_list(sandbox_ids) do
    with {:ok, %{"sandboxes" => map}} <-
           Request.request(client, :get, "/sandboxes/metrics", params: [sandbox_ids: sandbox_ids]) do
      {:ok, Map.new(map, fn {id, m} -> {id, SandboxMetric.from_api(m)} end)}
    end
  end

  @doc """
  Get structured logs for a sandbox (`GET /v2/sandboxes/:id/logs`).

  ## Options (query): `:cursor`, `:limit`, `:direction`, `:level`, `:search`.
  """
  @spec logs(E2bEx.Client.t(), String.t(), keyword()) ::
          {:ok, [SandboxLog.t()]} | {:error, E2bEx.Error.t()}
  def logs(client, sandbox_id, opts \\ []) do
    params =
      []
      |> put_param(:cursor, opts[:cursor])
      |> put_param(:limit, opts[:limit])
      |> put_param(:direction, opts[:direction])
      |> put_param(:level, opts[:level])
      |> put_param(:search, opts[:search])

    with {:ok, %{"logs" => logs}} <-
           Request.request(client, :get, "/v2/sandboxes/#{sandbox_id}/logs", params: params) do
      {:ok, Enum.map(logs, &SandboxLog.from_api/1)}
    end
  end

  @doc "List paused-sandbox snapshots (`GET /snapshots`)."
  @spec list_snapshots(E2bEx.Client.t(), keyword()) ::
          {:ok, [Sandbox.t()]} | {:error, E2bEx.Error.t()}
  def list_snapshots(client, opts \\ []) do
    params = [] |> put_param(:nextToken, opts[:next_token]) |> put_param(:limit, opts[:limit])

    with {:ok, list} <- Request.request(client, :get, "/snapshots", params: params) do
      {:ok, Enum.map(list, &Sandbox.from_api/1)}
    end
  end

  # --- shared helpers (used by the write half in the next task) ---

  @doc false
  def put_param(params, _key, nil), do: params
  def put_param(params, key, value), do: Keyword.put(params, key, value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/sandboxes_read_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/sandboxes.ex test/e2b_ex/sandboxes_read_test.exs
git commit -m "feat: add Sandboxes read operations"
```

---

## Task 7: `E2bEx.Sandboxes` — write/lifecycle operations

Functions: `create/2`, `kill/2`, `pause/2`, `connect/3`, `set_timeout/3`, `set_network/3`, `refresh/3`, `snapshot/3`.

**Files:**
- Modify: `lib/e2b_ex/sandboxes.ex`
- Test: `test/e2b_ex/sandboxes_write_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.SandboxesWriteTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Sandbox, Snapshot, Sandboxes}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "create/2 POSTs /sandboxes with the body and decodes the sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/sandboxes"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"templateID" => "tmpl_1", "timeout" => 30}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sandboxID" => "sb_1", "templateID" => "tmpl_1"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1"}} =
             Sandboxes.create(client(), %{templateID: "tmpl_1", timeout: 30})
  end

  test "kill/2 DELETEs /sandboxes/:id and returns :ok on 204" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/sandboxes/sb_1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.kill(client(), "sb_1")
  end

  test "pause/2 POSTs /sandboxes/:id/pause and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/pause"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.pause(client(), "sb_1")
  end

  test "connect/3 POSTs /sandboxes/:id/connect with timeout and decodes the sandbox" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/connect"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"timeout" => 60}
      Req.Test.json(conn, %{"sandboxID" => "sb_1"})
    end)

    assert {:ok, %Sandbox{sandbox_id: "sb_1"}} = Sandboxes.connect(client(), "sb_1", 60)
  end

  test "set_timeout/3 POSTs /sandboxes/:id/timeout with the timeout" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/timeout"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"timeout" => 120}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.set_timeout(client(), "sb_1", 120)
  end

  test "set_network/3 PUTs /sandboxes/:id/network with the config" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT" and conn.request_path == "/sandboxes/sb_1/network"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"allowOut" => ["8.8.8.8/32"]}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.set_network(client(), "sb_1", %{allowOut: ["8.8.8.8/32"]})
  end

  test "refresh/3 POSTs /sandboxes/:id/refreshes with optional duration" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/refreshes"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"duration" => 30}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Sandboxes.refresh(client(), "sb_1", duration: 30)
  end

  test "snapshot/3 POSTs /sandboxes/:id/snapshots and decodes the snapshot" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/sandboxes/sb_1/snapshots"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"snapshotID" => "snap_1", "names" => ["n"]})
    end)

    assert {:ok, %Snapshot{snapshot_id: "snap_1"}} = Sandboxes.snapshot(client(), "sb_1", name: "n")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/sandboxes_write_test.exs`
Expected: FAIL — the write functions don't exist.

- [ ] **Step 3: Add the write functions to `E2bEx.Sandboxes`**

Insert these functions before the `# --- shared helpers` comment, and add `Snapshot` to the existing `alias E2bEx.{...}` line (making it `alias E2bEx.{Request, Sandbox, SandboxLog, SandboxMetric, Snapshot}`):

```elixir
  @doc """
  Create a sandbox (`POST /sandboxes`).

  `params` is a map matching the OpenAPI `NewSandbox` schema, e.g.
  `%{templateID: "tmpl_1", timeout: 30, metadata: %{user: "abc"}}`.
  """
  @spec create(E2bEx.Client.t(), map()) :: {:ok, Sandbox.t()} | {:error, E2bEx.Error.t()}
  def create(client, params) when is_map(params) do
    with {:ok, body} <- Request.request(client, :post, "/sandboxes", json: params) do
      {:ok, Sandbox.from_api(body)}
    end
  end

  @doc "Kill (delete) a sandbox (`DELETE /sandboxes/:id`)."
  @spec kill(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def kill(client, sandbox_id), do: void(client, :delete, "/sandboxes/#{sandbox_id}")

  @doc "Pause a sandbox (`POST /sandboxes/:id/pause`)."
  @spec pause(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def pause(client, sandbox_id), do: void(client, :post, "/sandboxes/#{sandbox_id}/pause")

  @doc "Connect to (resume) a sandbox with a new timeout (`POST /sandboxes/:id/connect`)."
  @spec connect(E2bEx.Client.t(), String.t(), non_neg_integer()) ::
          {:ok, Sandbox.t()} | {:error, E2bEx.Error.t()}
  def connect(client, sandbox_id, timeout) when is_integer(timeout) do
    with {:ok, body} <-
           Request.request(client, :post, "/sandboxes/#{sandbox_id}/connect", json: %{timeout: timeout}) do
      {:ok, Sandbox.from_api(body)}
    end
  end

  @doc "Set a sandbox's timeout in seconds from now (`POST /sandboxes/:id/timeout`)."
  @spec set_timeout(E2bEx.Client.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, E2bEx.Error.t()}
  def set_timeout(client, sandbox_id, timeout) when is_integer(timeout) do
    void(client, :post, "/sandboxes/#{sandbox_id}/timeout", json: %{timeout: timeout})
  end

  @doc """
  Replace a running sandbox's egress network config (`PUT /sandboxes/:id/network`).

  `config` is a map matching the OpenAPI `SandboxNetworkUpdateConfig` schema.
  """
  @spec set_network(E2bEx.Client.t(), String.t(), map()) :: :ok | {:error, E2bEx.Error.t()}
  def set_network(client, sandbox_id, config) when is_map(config) do
    void(client, :put, "/sandboxes/#{sandbox_id}/network", json: config)
  end

  @doc """
  Refresh (extend) a sandbox (`POST /sandboxes/:id/refreshes`).

  ## Options: `:duration` — extension in seconds (optional).
  """
  @spec refresh(E2bEx.Client.t(), String.t(), keyword()) :: :ok | {:error, E2bEx.Error.t()}
  def refresh(client, sandbox_id, opts \\ []) do
    body = if opts[:duration], do: %{duration: opts[:duration]}, else: %{}
    void(client, :post, "/sandboxes/#{sandbox_id}/refreshes", json: body)
  end

  @doc """
  Snapshot a sandbox into a reusable template (`POST /sandboxes/:id/snapshots`).

  ## Options: `:name` — optional snapshot name.
  """
  @spec snapshot(E2bEx.Client.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, E2bEx.Error.t()}
  def snapshot(client, sandbox_id, opts \\ []) do
    body = if opts[:name], do: %{name: opts[:name]}, else: %{}

    with {:ok, resp} <- Request.request(client, :post, "/sandboxes/#{sandbox_id}/snapshots", json: body) do
      {:ok, Snapshot.from_api(resp)}
    end
  end

  defp void(client, method, path, opts \\ []) do
    case Request.request(client, method, path, opts) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/sandboxes_write_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/sandboxes.ex test/e2b_ex/sandboxes_write_test.exs
git commit -m "feat: add Sandboxes write/lifecycle operations"
```

---

## Task 8: Template-domain structs

**Files:**
- Create: `lib/e2b_ex/template.ex`
- Test: `test/e2b_ex/template_test.exs`

Structs: `E2bEx.Template` (superset of `Template` + `TemplateWithBuilds`),
`E2bEx.TemplateBuild`, `E2bEx.TemplateAlias`, `E2bEx.TemplateTag`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.TemplateTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Template, TemplateBuild, TemplateAlias, TemplateTag}

  test "Template.from_api/1 maps fields and nested builds" do
    api = %{
      "templateID" => "tmpl_1",
      "buildID" => "build_1",
      "public" => true,
      "names" => ["team/base"],
      "cpuCount" => 2,
      "memoryMB" => 512,
      "spawnCount" => 5,
      "buildStatus" => "ready",
      "builds" => [%{"buildID" => "build_1", "status" => "ready"}]
    }

    t = Template.from_api(api)
    assert t.template_id == "tmpl_1"
    assert t.public == true
    assert t.spawn_count == 5
    assert [%TemplateBuild{build_id: "build_1", status: "ready"}] = t.builds
  end

  test "TemplateBuild.from_api/1 maps fields" do
    b = TemplateBuild.from_api(%{"buildID" => "b1", "status" => "building", "createdAt" => "t", "cpuCount" => 1, "memoryMB" => 256})
    assert b.build_id == "b1"
    assert b.status == "building"
    assert b.cpu_count == 1
  end

  test "TemplateAlias.from_api/1 maps fields" do
    a = TemplateAlias.from_api(%{"templateID" => "tmpl_1", "public" => false})
    assert a.template_id == "tmpl_1"
    assert a.public == false
  end

  test "TemplateTag.from_api/1 maps fields" do
    tag = TemplateTag.from_api(%{"tag" => "v1", "buildID" => "b1", "createdAt" => "t"})
    assert tag.tag == "v1"
    assert tag.build_id == "b1"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/template_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement the structs**

```elixir
defmodule E2bEx.TemplateBuild do
  @moduledoc "A single template build."

  @type t :: %__MODULE__{
          build_id: String.t() | nil,
          status: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          finished_at: String.t() | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          envd_version: String.t() | nil
        }

  defstruct [
    :build_id,
    :status,
    :created_at,
    :updated_at,
    :finished_at,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :envd_version
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      build_id: m["buildID"],
      status: m["status"],
      created_at: m["createdAt"],
      updated_at: m["updatedAt"],
      finished_at: m["finishedAt"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      envd_version: m["envdVersion"]
    }
  end
end

defmodule E2bEx.Template do
  @moduledoc "A template, decoded from list (`Template`) and get (`TemplateWithBuilds`) responses."

  alias E2bEx.TemplateBuild

  @type t :: %__MODULE__{
          template_id: String.t() | nil,
          build_id: String.t() | nil,
          public: boolean() | nil,
          names: [String.t()] | nil,
          aliases: [String.t()] | nil,
          cpu_count: integer() | nil,
          memory_mb: integer() | nil,
          disk_size_mb: integer() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          last_spawned_at: String.t() | nil,
          spawn_count: integer() | nil,
          build_count: integer() | nil,
          envd_version: String.t() | nil,
          build_status: String.t() | nil,
          builds: [TemplateBuild.t()] | nil
        }

  defstruct [
    :template_id,
    :build_id,
    :public,
    :names,
    :aliases,
    :cpu_count,
    :memory_mb,
    :disk_size_mb,
    :created_at,
    :updated_at,
    :last_spawned_at,
    :spawn_count,
    :build_count,
    :envd_version,
    :build_status,
    :builds
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      template_id: m["templateID"],
      build_id: m["buildID"],
      public: m["public"],
      names: m["names"],
      aliases: m["aliases"],
      cpu_count: m["cpuCount"],
      memory_mb: m["memoryMB"],
      disk_size_mb: m["diskSizeMB"],
      created_at: m["createdAt"],
      updated_at: m["updatedAt"],
      last_spawned_at: m["lastSpawnedAt"],
      spawn_count: m["spawnCount"],
      build_count: m["buildCount"],
      envd_version: m["envdVersion"],
      build_status: m["buildStatus"],
      builds: decode_builds(m["builds"])
    }
  end

  defp decode_builds(nil), do: nil
  defp decode_builds(builds) when is_list(builds), do: Enum.map(builds, &TemplateBuild.from_api/1)
end

defmodule E2bEx.TemplateAlias do
  @moduledoc "Result of `GET /templates/aliases/:alias`."

  @type t :: %__MODULE__{template_id: String.t() | nil, public: boolean() | nil}

  defstruct [:template_id, :public]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m), do: %__MODULE__{template_id: m["templateID"], public: m["public"]}
end

defmodule E2bEx.TemplateTag do
  @moduledoc "A tag assigned to a template build."

  @type t :: %__MODULE__{
          tag: String.t() | nil,
          build_id: String.t() | nil,
          created_at: String.t() | nil
        }

  defstruct [:tag, :build_id, :created_at]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{tag: m["tag"], build_id: m["buildID"], created_at: m["createdAt"]}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/template_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/template.ex test/e2b_ex/template_test.exs
git commit -m "feat: add template-domain structs"
```

---

## Task 9: `E2bEx.Templates` — CRUD + alias + file check

Functions: `list/2`, `create/2`, `get/2`, `delete/2`, `update/3`, `get_by_alias/2`, `file_exists?/3`.

**Files:**
- Create: `lib/e2b_ex/templates.ex`
- Test: `test/e2b_ex/templates_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.TemplatesTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Template, TemplateAlias, Templates}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /templates with optional team filter and decodes a list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates"
      assert conn.query_string =~ "teamID=team_1"
      Req.Test.json(conn, [%{"templateID" => "tmpl_1"}])
    end)

    assert {:ok, [%Template{template_id: "tmpl_1"}]} = Templates.list(client(), team_id: "team_1")
  end

  test "create/2 POSTs /v3/templates and returns the raw response map" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/v3/templates"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "my-tmpl"}
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"templateID" => "tmpl_1", "buildID" => "b1"})
    end)

    assert {:ok, %{"templateID" => "tmpl_1", "buildID" => "b1"}} =
             Templates.create(client(), %{name: "my-tmpl"})
  end

  test "get/2 GETs /templates/:id and decodes with builds" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1"
      Req.Test.json(conn, %{"templateID" => "tmpl_1", "builds" => [%{"buildID" => "b1", "status" => "ready"}]})
    end)

    assert {:ok, %Template{template_id: "tmpl_1", builds: [%{build_id: "b1"}]}} =
             Templates.get(client(), "tmpl_1")
  end

  test "delete/2 DELETEs /templates/:id and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/templates/tmpl_1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Templates.delete(client(), "tmpl_1")
  end

  test "update/3 PATCHes /v2/templates/:id with the body" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PATCH" and conn.request_path == "/v2/templates/tmpl_1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"public" => true}
      Req.Test.json(conn, %{"names" => ["team/base"]})
    end)

    assert {:ok, %{"names" => ["team/base"]}} = Templates.update(client(), "tmpl_1", %{public: true})
  end

  test "get_by_alias/2 GETs /templates/aliases/:alias and decodes" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/aliases/base"
      Req.Test.json(conn, %{"templateID" => "tmpl_1", "public" => true})
    end)

    assert {:ok, %TemplateAlias{template_id: "tmpl_1", public: true}} =
             Templates.get_by_alias(client(), "base")
  end

  test "file_exists?/3 returns {:ok, true} on 2xx" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/files/abc123"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, true} = Templates.file_exists?(client(), "tmpl_1", "abc123")
  end

  test "file_exists?/3 returns {:ok, false} on 404" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404, "message" => "no"})
    end)

    assert {:ok, false} = Templates.file_exists?(client(), "tmpl_1", "missing")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/templates_test.exs`
Expected: FAIL — `E2bEx.Templates` is undefined.

- [ ] **Step 3: Implement the CRUD half of `E2bEx.Templates`**

```elixir
defmodule E2bEx.Templates do
  @moduledoc """
  Template operations.

  Every function takes an `E2bEx.Client` as the first argument. `create/2` and
  `update/3` return the raw decoded response map (the API returns minimal,
  build-oriented payloads there); `get/2` and `list/2` return `E2bEx.Template`
  structs.
  """

  alias E2bEx.{Request, Template, TemplateAlias, TemplateBuild}

  @doc """
  List templates (`GET /templates`).

  ## Options (query): `:team_id`.
  """
  @spec list(E2bEx.Client.t(), keyword()) :: {:ok, [Template.t()]} | {:error, E2bEx.Error.t()}
  def list(client, opts \\ []) do
    params = put_param([], :teamID, opts[:team_id])

    with {:ok, list} <- Request.request(client, :get, "/templates", params: params) do
      {:ok, Enum.map(list, &Template.from_api/1)}
    end
  end

  @doc """
  Create a template (`POST /v3/templates`).

  `params` is a map matching the OpenAPI `TemplateBuildRequestV3` schema, e.g.
  `%{name: "my-tmpl", cpuCount: 2}`. Returns the raw response map containing
  `templateID`, `buildID`, etc.
  """
  @spec create(E2bEx.Client.t(), map()) :: {:ok, map()} | {:error, E2bEx.Error.t()}
  def create(client, params) when is_map(params) do
    Request.request(client, :post, "/v3/templates", json: params)
  end

  @doc "Get a template with its builds (`GET /templates/:id`)."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Template.t()} | {:error, E2bEx.Error.t()}
  def get(client, template_id) do
    with {:ok, body} <- Request.request(client, :get, "/templates/#{template_id}") do
      {:ok, Template.from_api(body)}
    end
  end

  @doc "Delete a template (`DELETE /templates/:id`)."
  @spec delete(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, template_id) do
    case Request.request(client, :delete, "/templates/#{template_id}") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Update a template (`PATCH /v2/templates/:id`).

  `params` matches the OpenAPI `TemplateUpdateRequest` schema, e.g. `%{public: true}`.
  Returns the raw response map.
  """
  @spec update(E2bEx.Client.t(), String.t(), map()) :: {:ok, map()} | {:error, E2bEx.Error.t()}
  def update(client, template_id, params) when is_map(params) do
    Request.request(client, :patch, "/v2/templates/#{template_id}", json: params)
  end

  @doc "Look up a template by alias (`GET /templates/aliases/:alias`)."
  @spec get_by_alias(E2bEx.Client.t(), String.t()) ::
          {:ok, TemplateAlias.t()} | {:error, E2bEx.Error.t()}
  def get_by_alias(client, alias_name) do
    with {:ok, body} <- Request.request(client, :get, "/templates/aliases/#{alias_name}") do
      {:ok, TemplateAlias.from_api(body)}
    end
  end

  @doc """
  Check whether a build-cache file exists (`GET /templates/:id/files/:hash`).

  Returns `{:ok, true}` on success, `{:ok, false}` on 404, and `{:error, %Error{}}`
  for any other failure.
  """
  @spec file_exists?(E2bEx.Client.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, E2bEx.Error.t()}
  def file_exists?(client, template_id, hash) do
    case Request.request(client, :get, "/templates/#{template_id}/files/#{hash}") do
      {:ok, _} -> {:ok, true}
      {:error, %E2bEx.Error{status: 404}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def put_param(params, _key, nil), do: params
  def put_param(params, key, value), do: Keyword.put(params, key, value)
end
```

(Note: `TemplateBuild` is aliased here because Task 10 adds build functions that decode it. It is unused until then; if the compiler warns, leave it — Task 10 resolves the warning.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/templates_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/templates.ex test/e2b_ex/templates_test.exs
git commit -m "feat: add Templates CRUD, alias, and file-exists operations"
```

---

## Task 10: `E2bEx.Templates` — build operations

Functions: `trigger_build/4`, `build_status/4`, `build_logs/4`.

**Files:**
- Modify: `lib/e2b_ex/templates.ex`
- Test: `test/e2b_ex/templates_build_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.TemplatesBuildTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, Templates}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "trigger_build/4 POSTs /v2/templates/:id/builds/:build with the body and returns :ok on 202" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/v2/templates/tmpl_1/builds/b1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"fromImage" => "ubuntu:22.04"}
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = Templates.trigger_build(client(), "tmpl_1", "b1", %{fromImage: "ubuntu:22.04"})
  end

  test "build_status/4 GETs the status endpoint and returns the raw map with passed options" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/builds/b1/status"
      assert conn.query_string =~ "logsOffset=10"
      Req.Test.json(conn, %{"templateID" => "tmpl_1", "buildID" => "b1", "status" => "building", "logs" => ["a"]})
    end)

    assert {:ok, %{"status" => "building", "logs" => ["a"]}} =
             Templates.build_status(client(), "tmpl_1", "b1", logs_offset: 10)
  end

  test "build_logs/4 GETs the logs endpoint and returns the logs list" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/builds/b1/logs"
      Req.Test.json(conn, %{"logs" => [%{"timestamp" => "t", "message" => "m", "level" => "info"}]})
    end)

    assert {:ok, [%{"message" => "m"}]} = Templates.build_logs(client(), "tmpl_1", "b1")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/templates_build_test.exs`
Expected: FAIL — the build functions don't exist.

- [ ] **Step 3: Add build functions to `E2bEx.Templates`**

Insert before the final `put_param/3` helper definitions:

```elixir
  @doc """
  Start a build for a template (`POST /v2/templates/:id/builds/:build_id`).

  `params` matches the OpenAPI `TemplateBuildStartV2` schema, e.g.
  `%{fromImage: "ubuntu:22.04", steps: [...]}`. Returns `:ok` on 202.
  """
  @spec trigger_build(E2bEx.Client.t(), String.t(), String.t(), map()) ::
          :ok | {:error, E2bEx.Error.t()}
  def trigger_build(client, template_id, build_id, params \\ %{}) when is_map(params) do
    case Request.request(client, :post, "/v2/templates/#{template_id}/builds/#{build_id}", json: params) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get build status and logs (`GET /templates/:id/builds/:build_id/status`).

  ## Options (query): `:logs_offset`, `:logs_limit`, `:level`.

  Returns the raw `TemplateBuildInfo` map (`status`, `logs`, `logEntries`, `reason`).
  """
  @spec build_status(E2bEx.Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, E2bEx.Error.t()}
  def build_status(client, template_id, build_id, opts \\ []) do
    params =
      []
      |> put_param(:logsOffset, opts[:logs_offset])
      |> put_param(:logsLimit, opts[:logs_limit])
      |> put_param(:level, opts[:level])

    Request.request(client, :get, "/templates/#{template_id}/builds/#{build_id}/status", params: params)
  end

  @doc """
  Get structured build logs (`GET /templates/:id/builds/:build_id/logs`).

  ## Options (query): `:start`, `:limit`, `:direction`, `:level`, `:source`.

  Returns the raw list of `BuildLogEntry` maps.
  """
  @spec build_logs(E2bEx.Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, E2bEx.Error.t()}
  def build_logs(client, template_id, build_id, opts \\ []) do
    params =
      []
      |> put_param(:start, opts[:start])
      |> put_param(:limit, opts[:limit])
      |> put_param(:direction, opts[:direction])
      |> put_param(:level, opts[:level])
      |> put_param(:source, opts[:source])

    with {:ok, %{"logs" => logs}} <-
           Request.request(client, :get, "/templates/#{template_id}/builds/#{build_id}/logs", params: params) do
      {:ok, logs}
    end
  end
```

Then, because `TemplateBuild` is now genuinely unused in this module (decoding of
builds happens inside `E2bEx.Template`), remove `TemplateBuild` from the
`alias E2bEx.{...}` line so it reads `alias E2bEx.{Request, Template, TemplateAlias}`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/templates_build_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/templates.ex test/e2b_ex/templates_build_test.exs
git commit -m "feat: add Templates build operations"
```

---

## Task 11: `E2bEx.Tags`

Functions: `list/2`, `add/3`, `delete/3`.

**Files:**
- Create: `lib/e2b_ex/tags.ex`
- Test: `test/e2b_ex/tags_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule E2bEx.TagsTest do
  use ExUnit.Case, async: true
  alias E2bEx.{Client, TemplateTag, Tags}

  defp client, do: Client.new(api_key: "k", req_options: [plug: {Req.Test, __MODULE__}])

  test "list/2 GETs /templates/:id/tags and decodes tags" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/templates/tmpl_1/tags"
      Req.Test.json(conn, [%{"tag" => "v1", "buildID" => "b1", "createdAt" => "t"}])
    end)

    assert {:ok, [%TemplateTag{tag: "v1", build_id: "b1"}]} = Tags.list(client(), "tmpl_1")
  end

  test "add/3 POSTs /templates/tags with target + tags and returns the assigned tags" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST" and conn.request_path == "/templates/tags"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"target" => "my-tmpl:latest", "tags" => ["v1", "v2"]}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"tags" => ["v1", "v2"], "buildID" => "b1"})
    end)

    assert {:ok, %{"tags" => ["v1", "v2"], "buildID" => "b1"}} =
             Tags.add(client(), "my-tmpl:latest", ["v1", "v2"])
  end

  test "delete/3 DELETEs /templates/tags with name + tags and returns :ok" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE" and conn.request_path == "/templates/tags"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "my-tmpl", "tags" => ["v1"]}
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Tags.delete(client(), "my-tmpl", ["v1"])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex/tags_test.exs`
Expected: FAIL — `E2bEx.Tags` is undefined.

- [ ] **Step 3: Implement `E2bEx.Tags`**

```elixir
defmodule E2bEx.Tags do
  @moduledoc """
  Template tag operations.

  Every function takes an `E2bEx.Client` as the first argument.
  """

  alias E2bEx.{Request, TemplateTag}

  @doc "List all tags for a template (`GET /templates/:id/tags`)."
  @spec list(E2bEx.Client.t(), String.t()) ::
          {:ok, [TemplateTag.t()]} | {:error, E2bEx.Error.t()}
  def list(client, template_id) do
    with {:ok, list} <- Request.request(client, :get, "/templates/#{template_id}/tags") do
      {:ok, Enum.map(list, &TemplateTag.from_api/1)}
    end
  end

  @doc """
  Assign tags to a template build (`POST /templates/tags`).

  `target` is a `"name:tag"` string. Returns the raw `AssignedTemplateTags` map
  (`tags`, `buildID`).
  """
  @spec add(E2bEx.Client.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, E2bEx.Error.t()}
  def add(client, target, tags) when is_list(tags) do
    Request.request(client, :post, "/templates/tags", json: %{target: target, tags: tags})
  end

  @doc "Delete tags from a template (`DELETE /templates/tags`)."
  @spec delete(E2bEx.Client.t(), String.t(), [String.t()]) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, name, tags) when is_list(tags) do
    case Request.request(client, :delete, "/templates/tags", json: %{name: name, tags: tags}) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex/tags_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/e2b_ex/tags.ex test/e2b_ex/tags_test.exs
git commit -m "feat: add Tags operations"
```

---

## Task 12: Top-level `E2bEx` convenience + docs

**Files:**
- Modify: `lib/e2b_ex.ex`
- Modify: `mix.exs` (docs metadata)
- Modify: `README.md`
- Test: `test/e2b_ex_test.exs`

- [ ] **Step 1: Write the failing test**

Replace `test/e2b_ex_test.exs` with:

```elixir
defmodule E2bExTest do
  use ExUnit.Case, async: true

  test "client/1 builds an E2bEx.Client" do
    assert %E2bEx.Client{api_key: "k"} = E2bEx.client(api_key: "k")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/e2b_ex_test.exs`
Expected: FAIL — `E2bEx.client/1` is undefined (default generated file has no such function).

- [ ] **Step 3: Implement the top-level module**

Replace `lib/e2b_ex.ex` with:

```elixir
defmodule E2bEx do
  @moduledoc """
  Elixir client for the [E2B](https://e2b.dev) API (Sandboxes, Templates, Tags).

  ## Quick start

      client = E2bEx.client(api_key: "e2b_...")

      {:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})
      {:ok, sandboxes} = E2bEx.Sandboxes.list(client)
      :ok = E2bEx.Sandboxes.kill(client, sandbox.sandbox_id)

  Every call returns `{:ok, value}` / `:ok`, or `{:error, %E2bEx.Error{}}`.

  See `E2bEx.Sandboxes`, `E2bEx.Templates`, and `E2bEx.Tags` for the full API.
  """

  @doc "Build a client. See `E2bEx.Client.new/1` for options."
  @spec client(keyword()) :: E2bEx.Client.t()
  defdelegate client(opts \\ []), to: E2bEx.Client, as: :new
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/e2b_ex_test.exs`
Expected: PASS.

- [ ] **Step 5: Add docs metadata to `mix.exs`**

In `project/0`, add `name`, `source_url` (optional placeholder if no repo), and `docs`:

```elixir
      deps: deps(),
      name: "E2bEx",
      docs: [
        main: "E2bEx",
        extras: ["README.md"]
      ]
```

- [ ] **Step 6: Update `README.md`**

Replace the `## Installation` body's TODO description with a one-paragraph summary and the quick-start example:

```markdown
# E2bEx

An Elixir client for the [E2B](https://e2b.dev) API, covering Sandboxes,
Templates, and Tags. Built on [`Req`](https://hex.pm/packages/req).

## Installation

Add `e2b_ex` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:e2b_ex, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
client = E2bEx.client(api_key: "e2b_...")

{:ok, sandbox} = E2bEx.Sandboxes.create(client, %{templateID: "base"})
{:ok, sandboxes} = E2bEx.Sandboxes.list(client)
:ok = E2bEx.Sandboxes.kill(client, sandbox.sandbox_id)
```

Configuration can also come from application config:

```elixir
config :e2b_ex, api_key: "e2b_..."
```
```

- [ ] **Step 7: Run the full suite + compile with warnings as errors**

Run: `mix test`
Expected: PASS (all tests across all files).

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly with no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/e2b_ex.ex mix.exs README.md test/e2b_ex_test.exs
git commit -m "feat: add top-level E2bEx convenience and docs"
```

---

## Self-review notes (resolved during planning)

- **Spec coverage:** All 27 in-scope functions from the spec map to a task —
  Sandboxes read (Task 6) + write (Task 7) = 14; Templates CRUD/alias/file (Task 9)
  + build (Task 10) = 10; Tags (Task 11) = 3.
- **Auth:** `x-api-key` header set once in `Client.base_req/1`; covers every endpoint.
- **Error contract:** single `%E2bEx.Error{}`, mapped only in `E2bEx.Request`.
- **Naming consistency:** `from_api/1` on every struct; `put_param/3` helper name
  reused in `Sandboxes` and `Templates`; `void/3` private helper in `Sandboxes`.
- **`file_exists?/3`** is the one function that intentionally swallows a 404 into
  `{:ok, false}` — documented and tested.
```
