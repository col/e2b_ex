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

  # --- shared helpers (used by the write half in the next task) ---

  @doc false
  def put_param(params, _key, nil), do: params

  def put_param(params, key, values) when is_list(values),
    do: Keyword.put(params, key, Enum.join(values, ","))

  def put_param(params, key, value), do: Keyword.put(params, key, value)
end
