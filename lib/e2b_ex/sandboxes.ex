defmodule E2bEx.Sandboxes do
  @moduledoc """
  Sandbox operations.

  Every function takes an `E2bEx.Client` as the first argument. Read functions
  return `{:ok, struct | [struct]}`; see `E2bEx.Sandboxes` write functions for
  lifecycle actions.
  """

  alias E2bEx.{Request, Sandbox, SandboxLog, SandboxMetric, Snapshot}

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

  ## Options (query): `:start`, `:end` (Unix timestamps, in seconds).
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
    params = put_param([], :sandbox_ids, sandbox_ids)

    with {:ok, %{"sandboxes" => map}} <-
           Request.request(client, :get, "/sandboxes/metrics", params: params) do
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

  @doc """
  List the team's snapshots (`GET /snapshots`).

  ## Options (query): `:sandbox_id` (filter by source sandbox), `:next_token`, `:limit`.
  """
  @spec list_snapshots(E2bEx.Client.t(), keyword()) ::
          {:ok, [Snapshot.t()]} | {:error, E2bEx.Error.t()}
  def list_snapshots(client, opts \\ []) do
    params =
      []
      |> put_param(:sandboxID, opts[:sandbox_id])
      |> put_param(:nextToken, opts[:next_token])
      |> put_param(:limit, opts[:limit])

    with {:ok, list} <- Request.request(client, :get, "/snapshots", params: params) do
      {:ok, Enum.map(list, &Snapshot.from_api/1)}
    end
  end

  @doc """
  Create a sandbox (`POST /sandboxes`).

  `params` is a map matching the OpenAPI `NewSandbox` schema, e.g.
  `%{templateID: "tmpl_1", timeout: 30, metadata: %{user: "abc"}}`.

  Mount team volumes (see `E2bEx.Volumes`) with `volumeMounts`:
  `%{templateID: "tmpl_1", volumeMounts: [%{name: "my-vol", path: "/data"}]}`.
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

  # --- shared helpers (used by the write half in the next task) ---

  @doc false
  def put_param(params, _key, nil), do: params

  def put_param(params, key, values) when is_list(values),
    do: Keyword.put(params, key, Enum.join(values, ","))

  def put_param(params, key, value), do: Keyword.put(params, key, value)
end
