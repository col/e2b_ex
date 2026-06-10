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
