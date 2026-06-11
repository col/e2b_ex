defmodule E2bEx.Commands do
  @moduledoc """
  Run shell commands inside a running sandbox.

  Unlike the rest of `E2bEx`, this talks directly to the sandbox's `envd` daemon
  (not `api.e2b.app`) over the Connect protocol. v1 supports blocking execution:
  the command runs to completion and the result is returned.

      {:ok, result} = E2bEx.Commands.run(client, sandbox, "echo hello")
      result.stdout    # => "hello\\n"
      result.exit_code # => 0

  Output can be streamed as it arrives by passing `:on_stdout` / `:on_stderr`
  callbacks; the fully accumulated result is still returned:

      {:ok, _result} =
        E2bEx.Commands.run(client, sandbox, "make",
          on_stdout: &IO.write/1,
          on_stderr: &IO.write/1)

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
    * `:on_stdout` — `(String.t() -> any())` invoked with each stdout chunk as it
      arrives.
    * `:on_stderr` — `(String.t() -> any())` invoked with each stderr chunk as it
      arrives.
    * `:cwd` — working directory.
    * `:envs` — environment variables (`%{String.t() => String.t()}`).
    * `:user` — Linux user to run as (adds an `Authorization: Basic` header).
    * `:timeout_ms` — total command timeout; default `#{@default_timeout_ms}`, `0` disables.
    * `:domain` — override the sandbox domain.
    * `:port` — envd port; default `#{@default_port}`.
    * `:base_url` — override the full envd base URL (advanced; self-hosted/testing).

  Callbacks run synchronously in arrival order from the calling process; a callback
  that raises propagates to the caller.
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
          decode_body: false,
          compressed: false,
          into: collector(opts)
        )
        |> Req.merge(client.req_options)
        |> with_timeout(timeout_ms)

      case Req.request(req) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          finalize(resp)

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          {:error, Error.from_exception(exception)}
      end
    end
  end

  # ---- streaming collection ----

  # Req `into:` reducer. Accumulates raw bytes onto `resp.body` (so non-2xx error
  # bodies stay intact for `Error.from_response/1`) and, for 2xx responses, feeds
  # the incremental decoder, folding events and firing callbacks. Parse state lives
  # in `resp.private[:e2b_stream]`.
  defp collector(opts) do
    fn {:data, chunk}, {req, resp} ->
      resp = %{resp | body: (resp.body || "") <> chunk}

      if resp.status in 200..299 do
        state = Req.Response.get_private(resp, :e2b_stream, nil) || new_state(opts)
        {action, state} = consume(state, chunk)
        {action, {req, Req.Response.put_private(resp, :e2b_stream, state)}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  defp new_state(opts) do
    %{
      decoder: Connect.Decoder.new(),
      result: %CommandResult{},
      on_stdout: opts[:on_stdout],
      on_stderr: opts[:on_stderr],
      trailer: nil,
      error: nil
    }
  end

  defp consume(state, chunk) do
    case Connect.Decoder.push(state.decoder, chunk) do
      {:ok, messages, trailer, decoder} ->
        state = %{state | decoder: decoder, trailer: trailer || state.trailer}

        case apply_messages(state, messages) do
          {:ok, state} -> {:cont, state}
          {:error, reason} -> {:halt, %{state | error: reason}}
        end

      {:error, reason} ->
        {:halt, %{state | error: reason}}
    end
  end

  defp apply_messages(state, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn message, {:ok, state} ->
      case apply_event(state, message["event"]) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_event(state, %{"data" => %{"stdout" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      invoke(state.on_stdout, bytes)
      {:ok, %{state | result: %{state.result | stdout: state.result.stdout <> bytes}}}
    end
  end

  defp apply_event(state, %{"data" => %{"stderr" => chunk}}) do
    with {:ok, bytes} <- decode_chunk(chunk) do
      invoke(state.on_stderr, bytes)
      {:ok, %{state | result: %{state.result | stderr: state.result.stderr <> bytes}}}
    end
  end

  defp apply_event(state, %{"end" => end_event}) do
    result = %{
      state.result
      | exit_code: Map.get(end_event, "exitCode", 0),
        error: Map.get(end_event, "error")
    }

    {:ok, %{state | result: result}}
  end

  defp apply_event(state, _other), do: {:ok, state}

  defp invoke(nil, _chunk), do: :ok

  defp invoke(fun, chunk) when is_function(fun, 1) do
    fun.(chunk)
    :ok
  end

  defp finalize(resp) do
    state = Req.Response.get_private(resp, :e2b_stream, new_state([]))

    cond do
      state.error != nil ->
        {:error, %Error{message: "malformed envd response", reason: state.error, body: resp.body}}

      state.decoder.buffer != "" ->
        {:error, %Error{message: "malformed envd response", reason: :malformed_frame, body: resp.body}}

      true ->
        case trailer_error(state.trailer) do
          %Error{} = error -> {:error, error}
          nil -> {:ok, state.result}
        end
    end
  end

  defp trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  defp trailer_error(_), do: nil

  defp decode_chunk(chunk) do
    case Base.decode64(chunk) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  # ---- request building ----

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

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_when(map, nil, _key, _value), do: map
  defp put_when(map, false, _key, _value), do: map
  defp put_when(map, _truthy, key, value), do: Map.put(map, key, value)
end
