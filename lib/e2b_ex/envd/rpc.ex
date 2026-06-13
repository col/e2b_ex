defmodule E2bEx.Envd.Rpc do
  @moduledoc false
  # The envd request layer: builds the per-sandbox connection context (base_url +
  # headers) shared by the streaming and unary paths, issues unary Connect calls
  # (bare JSON), and provides the process control wrappers (kill/send_stdin/
  # close_stdin/list) built on top of them.

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

  @doc "Kill a process by pid (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(ctx(), non_neg_integer()) :: {:ok, boolean()} | {:error, Error.t()}
  def kill(ctx, pid) do
    case unary(ctx, "/process.Process/SendSignal", %{process: %{pid: pid}, signal: "SIGNAL_SIGKILL"}) do
      {:ok, _} -> {:ok, true}
      {:error, %Error{code: "not_found"}} -> {:ok, false}
      {:error, %Error{status: 404}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc "Send data to a process's stdin by pid."
  @spec send_stdin(ctx(), non_neg_integer(), binary()) :: :ok | {:error, Error.t()}
  def send_stdin(ctx, pid, data) when is_binary(data) do
    body = %{process: %{pid: pid}, input: %{stdin: Base.encode64(data)}}

    case unary(ctx, "/process.Process/SendInput", body) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Close a process's stdin (EOF) by pid."
  @spec close_stdin(ctx(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def close_stdin(ctx, pid) do
    case unary(ctx, "/process.Process/CloseStdin", %{process: %{pid: pid}}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "List running processes; returns the raw `processes` maps."
  @spec list(ctx()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(ctx) do
    case unary(ctx, "/process.Process/List", %{}) do
      {:ok, %{"processes" => procs}} when is_list(procs) -> {:ok, procs}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc "Download file content over HTTP (`GET /files`). Returns the raw body bytes."
  @spec get_file(ctx(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def get_file(ctx, path, opts \\ []) when is_binary(path) do
    req =
      Req.new(
        method: :get,
        base_url: ctx.base_url,
        url: "/files",
        headers: file_headers(ctx),
        params: file_params(path, opts),
        decode_body: false,
        retry: false
      )
      |> Req.merge(ctx.req_options)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body || ""}
      {:ok, %Req.Response{} = resp} -> {:error, Error.from_response(resp)}
      {:error, exception} -> {:error, Error.from_exception(exception)}
    end
  end

  @doc "Upload file content over HTTP (`POST /files`, octet-stream). Returns the WriteInfo list."
  @spec put_file(ctx(), String.t(), binary(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def put_file(ctx, path, data, opts \\ []) when is_binary(path) and is_binary(data) do
    req =
      Req.new(
        method: :post,
        base_url: ctx.base_url,
        url: "/files",
        headers: Map.put(file_headers(ctx), "content-type", "application/octet-stream"),
        params: file_params(path, opts),
        body: data,
        retry: false
      )
      |> Req.merge(ctx.req_options)

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_write(body)}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  defp file_headers(ctx) do
    ctx.headers
    |> Map.delete("content-type")
    |> Map.delete("keepalive-ping-interval")
    |> Map.delete("connect-timeout-ms")
  end

  defp file_params(path, opts) do
    case opts[:user] do
      nil -> [path: path]
      user -> [path: path, username: user]
    end
  end

  defp normalize_write(body) when is_list(body), do: body
  defp normalize_write(_), do: []

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
