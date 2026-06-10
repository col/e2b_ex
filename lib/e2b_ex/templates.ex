defmodule E2bEx.Templates do
  @moduledoc """
  Template operations.

  Every function takes an `E2bEx.Client` as the first argument. `create/2` and
  `update/3` return the raw decoded response map (the API returns minimal,
  build-oriented payloads there); `get/2` and `list/2` return `E2bEx.Template`
  structs.
  """

  alias E2bEx.{Request, Template, TemplateAlias}

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
      |> put_param(:limit, opts[:logs_limit])
      |> put_param(:level, opts[:level])

    Request.request(client, :get, "/templates/#{template_id}/builds/#{build_id}/status", params: params)
  end

  @doc """
  Get structured build logs (`GET /templates/:id/builds/:build_id/logs`).

  ## Options (query): `:cursor`, `:limit`, `:direction`, `:level`, `:source`.

  Returns the raw list of `BuildLogEntry` maps.
  """
  @spec build_logs(E2bEx.Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, E2bEx.Error.t()}
  def build_logs(client, template_id, build_id, opts \\ []) do
    params =
      []
      |> put_param(:cursor, opts[:cursor])
      |> put_param(:limit, opts[:limit])
      |> put_param(:direction, opts[:direction])
      |> put_param(:level, opts[:level])
      |> put_param(:source, opts[:source])

    with {:ok, %{"logs" => logs}} <-
           Request.request(client, :get, "/templates/#{template_id}/builds/#{build_id}/logs", params: params) do
      {:ok, logs}
    end
  end

  @doc false
  def put_param(params, _key, nil), do: params
  def put_param(params, key, value), do: Keyword.put(params, key, value)
end
