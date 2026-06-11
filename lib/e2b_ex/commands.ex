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

  alias E2bEx.{Client, CommandResult, Error, ProcessInfo, Sandbox}
  alias E2bEx.Commands.Fold
  alias E2bEx.Envd.Connect
  alias E2bEx.Envd.Rpc

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
    * `:timeout_ms` — total command timeout; default `60000`, `0` disables.
      (defaults are defined in `E2bEx.Envd.Rpc`)
    * `:domain` — override the sandbox domain.
    * `:port` — envd port; default `49983`.
    * `:base_url` — override the full envd base URL (advanced; self-hosted/testing).

  Callbacks run synchronously in arrival order from the calling process; a callback
  that raises propagates to the caller.
  """
  @spec run(Client.t(), Sandbox.t(), String.t(), keyword()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Client{} = client, %Sandbox{} = sandbox, command, opts \\ []) when is_binary(command) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts) do
      body = Connect.encode_frame(Jason.encode!(start_request(command, opts)))

      req =
        Req.new(
          method: :post,
          base_url: ctx.base_url,
          url: @start_path,
          headers: ctx.headers,
          body: body,
          retry: false,
          decode_body: false,
          compressed: false,
          into: collector(opts)
        )
        |> Req.merge(ctx.req_options)
        |> with_timeout(ctx.timeout_ms)

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
      fold: Fold.new(),
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
      case Fold.apply_event(state.fold, message["event"]) do
        {:ok, fold, outputs} ->
          Enum.each(outputs, fn
            {:stdout, bytes} -> invoke(state.on_stdout, bytes)
            {:stderr, bytes} -> invoke(state.on_stderr, bytes)
          end)

          {:cont, {:ok, %{state | fold: fold}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

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
        case Connect.trailer_error(state.trailer) do
          %Error{} = error -> {:error, error}
          nil -> {:ok, Fold.result(state.fold)}
        end
    end
  end

  # ---- request building ----

  defp start_request(command, opts) do
    process =
      %{cmd: "/bin/bash", args: ["-l", "-c", command]}
      |> put_present(:cwd, opts[:cwd])
      |> put_present(:envs, opts[:envs])

    %{process: process, stdin: false}
  end

  defp with_timeout(req, 0), do: Req.merge(req, receive_timeout: :infinity)
  defp with_timeout(req, ms), do: Req.merge(req, receive_timeout: ms + 5_000)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "List running commands/PTYs in `sandbox` (`/process.Process/List`)."
  @spec list(Client.t(), Sandbox.t(), keyword()) :: {:ok, [ProcessInfo.t()]} | {:error, Error.t()}
  def list(%Client{} = client, %Sandbox{} = sandbox, opts \\ []) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts),
         {:ok, procs} <- Rpc.list(ctx) do
      {:ok, Enum.map(procs, &ProcessInfo.from_api/1)}
    end
  end

  @doc "Kill a process by pid (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def kill(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.kill(ctx, pid)
  end

  @doc "Send `data` to a process's stdin by pid (requires the process was started with `stdin: true`)."
  @spec send_stdin(Client.t(), Sandbox.t(), non_neg_integer(), binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def send_stdin(%Client{} = client, %Sandbox{} = sandbox, pid, data, opts \\ [])
      when is_integer(pid) and is_binary(data) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.send_stdin(ctx, pid, data)
  end

  @doc "Close a process's stdin (EOF) by pid."
  @spec close_stdin(Client.t(), Sandbox.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, Error.t()}
  def close_stdin(%Client{} = client, %Sandbox{} = sandbox, pid, opts \\ []) when is_integer(pid) do
    with {:ok, ctx} <- Rpc.context(client, sandbox, opts), do: Rpc.close_stdin(ctx, pid)
  end
end
