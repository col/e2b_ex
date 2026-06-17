defmodule E2bEx.Webhooks do
  @moduledoc """
  Webhook management (`/events/webhooks`). Every function takes an `E2bEx.Client`.

  Webhooks deliver sandbox lifecycle events. Register one with a `signatureSecret`,
  then verify and decode deliveries with `E2bEx.WebhookEvent`.

      {:ok, wh} =
        E2bEx.Webhooks.create(client, %{
          name: "my-hook",
          url: "https://example.com/hook",
          enabled: true,
          events: ["sandbox.lifecycle.created"],
          signatureSecret: "whsec_..."
        })

  These endpoints are not in `openapi.yml`; the source of truth is
  https://e2b.dev/docs/sandbox/lifecycle-events-webhooks.
  """

  alias E2bEx.{Error, Request, Webhook}

  @doc "List all webhooks (`GET /events/webhooks`)."
  @spec list(E2bEx.Client.t()) :: {:ok, [Webhook.t()]} | {:error, E2bEx.Error.t()}
  def list(client) do
    with {:ok, list} <- Request.request(client, :get, "/events/webhooks") do
      {:ok, Enum.map(list, &Webhook.from_api/1)}
    end
  end

  @doc """
  Create a webhook (`POST /events/webhooks`). `attrs` is a map in API shape
  (camelCase): `name`, `url`, `enabled`, `events`, `signatureSecret`.
  """
  @spec create(E2bEx.Client.t(), map()) :: {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def create(client, attrs) when is_map(attrs) do
    with {:ok, wh} <- Request.request(client, :post, "/events/webhooks", json: attrs) do
      decode_webhook(wh)
    end
  end

  @doc "Get a webhook by id (`GET /events/webhooks/:id`)."
  @spec get(E2bEx.Client.t(), String.t()) :: {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def get(client, webhook_id) when is_binary(webhook_id) do
    with {:ok, wh} <- Request.request(client, :get, "/events/webhooks/#{webhook_id}") do
      {:ok, Webhook.from_api(wh)}
    end
  end

  @doc """
  Update a webhook (`PATCH /events/webhooks/:id`). `attrs` is a partial map in API
  shape: any of `url`, `enabled`, `events`.
  """
  @spec update(E2bEx.Client.t(), String.t(), map()) ::
          {:ok, Webhook.t()} | {:error, E2bEx.Error.t()}
  def update(client, webhook_id, attrs) when is_binary(webhook_id) and is_map(attrs) do
    with {:ok, wh} <- Request.request(client, :patch, "/events/webhooks/#{webhook_id}", json: attrs) do
      decode_webhook(wh)
    end
  end

  defp decode_webhook(wh) when is_map(wh), do: {:ok, Webhook.from_api(wh)}

  defp decode_webhook(_),
    do:
      {:error,
       %Error{
         message: "webhook endpoint returned an empty or unexpected body",
         reason: :empty_response_body
       }}

  @doc "Delete a webhook by id (`DELETE /events/webhooks/:id`)."
  @spec delete(E2bEx.Client.t(), String.t()) :: :ok | {:error, E2bEx.Error.t()}
  def delete(client, webhook_id) when is_binary(webhook_id) do
    case Request.request(client, :delete, "/events/webhooks/#{webhook_id}") do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
