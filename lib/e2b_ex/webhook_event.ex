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

  @doc """
  Verify a delivery's `e2b-signature` header against the raw request body.

  Computes `base64(sha256(secret <> raw_body))` with trailing `=` stripped (plain
  SHA256, not HMAC — per the E2B docs) and compares it to `signature` in constant time.
  The raw body must be the exact bytes received; re-encoding a parsed map would change
  them and fail verification.
  """
  @spec verify_signature(binary(), binary(), binary()) :: boolean()
  def verify_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    expected =
      :crypto.hash(:sha256, secret <> raw_body)
      |> Base.encode64()
      |> String.trim_trailing("=")

    secure_compare(expected, signature)
  end

  @doc """
  Verify and decode a delivery in one step.

  Returns `{:ok, %E2bEx.WebhookEvent{}}` when the signature is valid and the body is
  JSON, `{:error, :invalid_signature}` when the signature does not match, or
  `{:error, :invalid_payload}` when the body is not valid JSON. These atom reasons are
  intentional: signature/JSON checks are local, not HTTP failures, so they do not use
  `%E2bEx.Error{}`.
  """
  @spec parse(binary(), binary(), binary()) ::
          {:ok, t()} | {:error, :invalid_signature | :invalid_payload}
  def parse(raw_body, signature, secret) do
    if verify_signature(raw_body, signature, secret) do
      case Jason.decode(raw_body) do
        {:ok, map} -> {:ok, from_api(map)}
        {:error, _} -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_signature}
    end
  end

  # Constant-time comparison. Byte-wise XOR fold avoids depending on
  # `:crypto.hash_equals/2` (OTP 25+).
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.exor(a, b) == :binary.copy(<<0>>, byte_size(a))
  end

  defp secure_compare(_, _), do: false
end
