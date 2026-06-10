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
