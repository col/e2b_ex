defmodule E2bEx.Envd.Rpc do
  @moduledoc false
  # The envd request layer: builds the per-sandbox connection context (base_url +
  # headers) shared by the streaming and unary paths, and issues unary Connect
  # calls (bare JSON). Control wrappers (kill/send_stdin/close_stdin/list) are
  # added in a later task.

  alias E2bEx.{Client, Error, Sandbox}

  @default_port 49_983
  @default_domain "e2b.app"
  @default_timeout_ms 60_000

  @type ctx :: %{
          base_url: String.t(),
          headers: map(),
          sandbox_id: String.t(),
          port: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          req_options: keyword()
        }

  @doc "Build the envd connection context, or `{:error, %Error{}}` if the sandbox has no id."
  @spec context(Client.t(), Sandbox.t(), keyword()) :: {:ok, ctx()} | {:error, Error.t()}
  def context(%Client{} = client, %Sandbox{} = sandbox, opts) do
    with {:ok, sandbox_id} <- fetch_sandbox_id(sandbox) do
      domain = sandbox.domain || opts[:domain] || domain_from(client)
      port = opts[:port] || @default_port
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      base_url = opts[:base_url] || "https://#{port}-#{sandbox_id}.#{domain}"

      ctx = %{
        base_url: base_url,
        headers: headers(sandbox, sandbox_id, port, timeout_ms, opts),
        sandbox_id: sandbox_id,
        port: port,
        timeout_ms: timeout_ms,
        req_options: client.req_options
      }

      {:ok, ctx}
    end
  end

  @doc "Issue a unary Connect call (bare JSON) to the envd `path`."
  @spec unary(ctx(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def unary(ctx, path, request_map, opts \\ []) do
    req =
      Req.new(
        method: :post,
        base_url: ctx.base_url,
        url: path,
        headers:
          ctx.headers
          |> Map.delete("content-type")
          |> Map.delete("keepalive-ping-interval")
          |> Map.delete("connect-timeout-ms"),
        json: request_map,
        retry: false
      )
      |> Req.merge(ctx.req_options)
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
      {:error, exception} -> {:error, Error.from_exception(exception)}
    end
  end

  defp fetch_sandbox_id(%Sandbox{sandbox_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_sandbox_id(_), do: {:error, %Error{message: "sandbox is missing :sandbox_id"}}

  defp domain_from(%Client{base_url: base_url}) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "api.", "")
      _ -> @default_domain
    end
  end

  defp headers(sandbox, sandbox_id, port, timeout_ms, opts) do
    %{
      "content-type" => "application/connect+json",
      "connect-protocol-version" => "1",
      "e2b-sandbox-id" => sandbox_id,
      "e2b-sandbox-port" => Integer.to_string(port),
      "keepalive-ping-interval" => "50"
    }
    |> put_when(sandbox.envd_access_token, "x-access-token", sandbox.envd_access_token)
    |> put_when(timeout_ms != 0, "connect-timeout-ms", Integer.to_string(timeout_ms))
    |> put_when(opts[:user], "authorization", "Basic " <> Base.encode64("#{opts[:user]}:"))
  end

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
