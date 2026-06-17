defmodule E2bEx.WebhookEvent do
  @moduledoc """
  A sandbox lifecycle event delivered to your webhook endpoint.

  Hand the raw request body and the `e2b-signature` header to `parse/3`:

      case E2bEx.WebhookEvent.parse(raw_body, signature, secret) do
        {:ok, %E2bEx.WebhookEvent{} = event} -> handle(event)
        {:error, :invalid_signature} -> send_resp(conn, 401, "")
        {:error, :invalid_payload} -> send_resp(conn, 400, "")
      end

  The delivered payload is already snake_case, so `from_api/1` reads its keys directly
  (unlike the central-API decoders, which convert from camelCase). `event_data` is kept
  as a raw map.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          version: String.t() | nil,
          type: String.t() | nil,
          timestamp: String.t() | nil,
          event_category: String.t() | nil,
          event_label: String.t() | nil,
          event_data: map() | nil,
          sandbox_id: String.t() | nil,
          sandbox_execution_id: String.t() | nil,
          sandbox_template_id: String.t() | nil,
          sandbox_build_id: String.t() | nil,
          sandbox_team_id: String.t() | nil
        }

  defstruct [
    :id,
    :version,
    :type,
    :timestamp,
    :event_category,
    :event_label,
    :event_data,
    :sandbox_id,
    :sandbox_execution_id,
    :sandbox_template_id,
    :sandbox_build_id,
    :sandbox_team_id
  ]

  @doc false
  @spec from_api(map()) :: t()
  def from_api(m) when is_map(m) do
    %__MODULE__{
      id: m["id"],
      version: m["version"],
      type: m["type"],
      timestamp: m["timestamp"],
      event_category: m["event_category"],
      event_label: m["event_label"],
      event_data: m["event_data"],
      sandbox_id: m["sandbox_id"],
      sandbox_execution_id: m["sandbox_execution_id"],
      sandbox_template_id: m["sandbox_template_id"],
      sandbox_build_id: m["sandbox_build_id"],
      sandbox_team_id: m["sandbox_team_id"]
    }
  end
end
