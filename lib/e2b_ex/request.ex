defmodule E2bEx.Request do
  @moduledoc false
  # The single place that performs HTTP and normalises results. Resource
  # modules call this; nothing else talks to Req directly.

  alias E2bEx.{Client, Error}

  @type result :: {:ok, term()} | {:error, Error.t()}

  @spec request(Client.t(), atom(), String.t(), keyword()) :: result()
  def request(%Client{} = client, method, path, opts \\ []) do
    req = Req.merge(Client.base_req(client), build_options(method, path, opts))

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, normalize_body(resp.body)}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  # Builds the keyword list of options merged into the base Req request.
  #
  # Write methods (POST/PUT/PATCH) with no JSON body get an explicit
  # empty-string body so Finch emits `Content-Length: 0`. E2B's GCP frontend
  # returns `411 Length Required` for bodyless POSTs (body would otherwise be
  # `nil`, which Finch sends with no Content-Length header).
  @doc false
  @spec build_options(atom(), String.t(), keyword()) :: keyword()
  def build_options(method, path, opts) do
    json = Keyword.get(opts, :json)

    [method: method, url: path]
    |> maybe_put(:params, Keyword.get(opts, :params))
    |> maybe_put(:json, json)
    |> maybe_put_body(method, json)
  end

  defp maybe_put_body(options, method, nil) when method in [:post, :put, :patch],
    do: Keyword.put(options, :body, "")

  defp maybe_put_body(options, _method, _json), do: options

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body
end
