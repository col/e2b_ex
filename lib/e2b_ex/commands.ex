defmodule E2bEx.Commands do
  @moduledoc """
  Run shell commands inside a running sandbox.

  Unlike the rest of `E2bEx`, this talks directly to the sandbox's `envd` daemon
  (not `api.e2b.app`) over the Connect protocol. v1 supports blocking execution:
  the command runs to completion and the result is returned.

      {:ok, result} = E2bEx.Commands.run(client, sandbox, "echo hello")
      result.stdout    # => "hello\\n"
      result.exit_code # => 0

  A command that runs returns `{:ok, %E2bEx.CommandResult{}}` regardless of its
  exit code; `{:error, %E2bEx.Error{}}` is reserved for transport, connection, or
  protocol failures.
  """

  alias E2bEx.{Client, CommandResult, Error, Sandbox}
  alias E2bEx.Envd.Connect

  @default_port 49_983
  @default_domain "e2b.app"
  @default_timeout_ms 60_000
  @start_path "/process.Process/Start"

  @doc """
  Run `command` in `sandbox` and wait for it to finish.

  `sandbox` is an `%E2bEx.Sandbox{}` and must carry a `:sandbox_id` and an
  `:envd_access_token`. Use a sandbox from `E2bEx.Sandboxes.create/2`,
  `connect/3`, or `get/2` — these return the access token. A sandbox from
  `list/2` does **not** carry the token (the API omits it from listed
  sandboxes), so envd will reject the request with `401`; call `connect/3` or
  `get/2` on its `sandbox_id` first. `client` supplies shared `Req` config via
  its `:req_options`.

  ## Options
    * `:cwd` — working directory.
    * `:envs` — environment variables (`%{String.t() => String.t()}`).
    * `:user` — Linux user to run as (adds an `Authorization: Basic` header).
    * `:timeout_ms` — total command timeout; default `#{@default_timeout_ms}`, `0` disables.
    * `:domain` — override the sandbox domain.
    * `:port` — envd port; default `#{@default_port}`.
    * `:base_url` — override the full envd base URL (advanced; self-hosted/testing).
  """
  @spec run(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, sandbox_id} <- fetch_sandbox_id(sandbox) do
      domain = sandbox.domain || opts[:domain] || domain_from(client)
      port = opts[:port] || @default_port
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      base_url = opts[:base_url] || "https://#{port}-#{sandbox_id}.#{domain}"
      body = Connect.encode_frame(Jason.encode!(start_request(command, opts)))

      req =
        Req.new(
          method: :post,
          base_url: base_url,
          url: @start_path,
          headers: headers(sandbox, sandbox_id, port, timeout_ms, opts),
          body: body,
          retry: false,
          decode_body: false
        )
        |> Req.merge(client.req_options)
        |> with_timeout(timeout_ms)

      case Req.request(req) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          parse_result(resp_body)

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          {:error, Error.from_exception(exception)}
      end
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

  defp start_request(command, opts) do
    process =
      %{cmd: "/bin/bash", args: ["-l", "-c", command]}
      |> put_present(:cwd, opts[:cwd])
      |> put_present(:envs, opts[:envs])

    %{process: process, stdin: false}
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

  defp with_timeout(req, 0), do: Req.merge(req, receive_timeout: :infinity)
  defp with_timeout(req, ms), do: Req.merge(req, receive_timeout: ms + 5_000)

  defp parse_result(body) do
    case Connect.decode_frames(body) do
      {:ok, messages, trailer} ->
        case trailer_error(trailer) do
          nil -> fold_result(fold_events(messages), body)
          %Error{} = error -> {:error, error}
        end

      {:error, reason} ->
        {:error, %Error{message: "malformed envd response", reason: reason, body: body}}
    end
  end

  defp fold_result({:ok, result}, _body), do: {:ok, result}

  defp fold_result({:error, reason}, body),
    do: {:error, %Error{message: "malformed envd response", reason: reason, body: body}}

  defp trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  defp trailer_error(_), do: nil

  defp fold_events(messages) do
    Enum.reduce_while(messages, {:ok, %CommandResult{}}, fn message, {:ok, acc} ->
      case apply_event(acc, message["event"]) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_event(acc, %{"data" => %{"stdout" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk), do: {:ok, %{acc | stdout: acc.stdout <> bytes}}
  end

  defp apply_event(acc, %{"data" => %{"stderr" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk), do: {:ok, %{acc | stderr: acc.stderr <> bytes}}
  end

  defp apply_event(acc, %{"end" => end_event}),
    do: {:ok, %{acc | exit_code: Map.get(end_event, "exitCode", 0), error: Map.get(end_event, "error")}}

  defp apply_event(acc, _other), do: {:ok, acc}

  defp decode_chunk(chunk) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
