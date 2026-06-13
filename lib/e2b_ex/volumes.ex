defmodule E2bEx.Volumes do
  @moduledoc """
  Team volume operations (`/volumes`). Every function takes an `E2bEx.Client`.

  A volume can be mounted into a sandbox at create time via `volumeMounts`:

      E2bEx.Sandboxes.create(client, %{templateID: "base",
        volumeMounts: [%{name: "my-vol", path: "/data"}]})
  """

  alias E2bEx.{Request, Volume}

  @doc "List all team volumes (`GET /volumes`)."
  @spec list(E2bEx.Client.t()) :: {:ok, [Volume.t()]} | {:error, E2bEx.Error.t()}
  def list(client) do
    with {:ok, list} <- Request.request(client, :get, "/volumes") do
      {:ok, Enum.map(list, &Volume.from_api/1)}
    end
  end

  @doc "Create a team volume (`POST /volumes`). Returns the volume with its token."
  @spec create(E2bEx.Client.t(), String.t()) :: {:ok, Volume.t()} | {:error, E2bEx.Error.t()}
  def create(client, name) when is_binary(name) do
    with {:ok, volume} <- Request.request(client, :post, "/volumes", json: %{name: name}) do
      {:ok, Volume.from_api(volume)}
    end
  end

  @doc "Get a team volume by id (`GET /volumes/:id`). Returns the volume with its token."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Volume.t()} | {:error, E2bEx.Error.t()}
  def get(client, volume_id) when is_binary(volume_id) do
    with {:ok, volume} <- Request.request(client, :get, "/volumes/#{volume_id}") do
      {:ok, Volume.from_api(volume)}
    end
  end

  @doc "Delete a team volume by id (`DELETE /volumes/:id`)."
  @spec delete(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, volume_id) when is_binary(volume_id) do
    case Request.request(client, :delete, "/volumes/#{volume_id}") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
