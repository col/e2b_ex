defmodule E2bEx.Request do
  @moduledoc false
  # The single place that performs HTTP and normalises results. Resource
  # modules call this; nothing else talks to Req directly.

  alias E2bEx.{Client, Error}

  @type result :: {:ok, term()} | {:error, Error.t()}

  @spec request(Client.t(), atom(), String.t(), keyword()) :: result()
  def request(%Client{} = client, method, path, opts \\ []) do
    options =
      [method: method, url: path]
      |> maybe_put(:params, Keyword.get(opts, :params))
      |> maybe_put(:json, Keyword.get(opts, :json))

    req = Req.merge(Client.base_req(client), options)

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, normalize_body(resp.body)}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body
end
