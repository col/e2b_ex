defmodule E2bEx.Error do
  @moduledoc """
  Uniform error returned by all `E2bEx` calls.

  For API errors (non-2xx responses), `status`, `code`, `message` and the raw
  `body` are populated. For transport failures (timeout, connection closed),
  `reason` is set and `status` is `nil`.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          code: integer() | String.t() | nil,
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
