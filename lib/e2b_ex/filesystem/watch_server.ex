defmodule E2bEx.Filesystem.WatchServer do
  @moduledoc false
  # GenServer owning one WatchDir server-stream (Req `into: :self`). Decodes
  # Connect frames and pushes `{ref, {:fs_event, %FilesystemEvent{}}}` to a
  # subscriber, then a terminal `{ref, {:error, %Error{}}}` when the stream fails
  # or closes (watch has no result). Replies to `:await_start` with `:ok` on the
  # first `start` frame. Modeled on `E2bEx.Commands.HandleServer`; the key
  # difference is that WatchDir frames are bare `WatchDirResponse` (no `event`
  # wrapper).

  use GenServer

  alias E2bEx.{Error, FilesystemEvent}
  alias E2bEx.Envd.Connect

  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(arg) when is_map(arg), do: GenServer.start(__MODULE__, arg)

  @impl true
  def init(arg) do
    state = %{
      ctx: arg.ctx,
      path: arg.path,
      request: arg.request,
      subscriber: arg.subscriber,
      ref: arg.ref,
      timeout_ms: arg.timeout_ms,
      resp: nil,
      status: nil,
      decoder: Connect.Decoder.new(),
      trailer: nil,
      error_body: "",
      started?: false,
      await_from: nil,
      start_error: nil
    }

    {:ok, state, {:continue, :request}}
  end

  @impl true
  def handle_continue(:request, state) do
    body = Connect.encode_frame(Jason.encode!(state.request))

    req =
      Req.new(
        method: :post,
        base_url: state.ctx.base_url,
        url: state.path,
        headers: state.ctx.headers,
        body: body,
        retry: false,
        decode_body: false,
        compressed: false,
        into: :self,
        receive_timeout: receive_timeout(state.timeout_ms)
      )
      |> Req.merge(state.ctx.req_options)

    case Req.request(req) do
      {:ok, resp} ->
        {:noreply, %{state | resp: resp, status: resp.status}}

      {:error, exception} ->
        continue_after(failure(state, Error.from_exception(exception)))
    end
  end

  @impl true
  def handle_call(:await_start, from, state) do
    cond do
      state.started? -> {:reply, :ok, state}
      state.start_error != nil -> {:stop, :normal, {:error, state.start_error}, state}
      true -> {:noreply, %{state | await_from: from}}
    end
  end

  @impl true
  def handle_info(message, %{resp: resp} = state) when not is_nil(resp) do
    case Req.parse_message(resp, message) do
      {:ok, parts} -> process_parts(parts, state)
      {:error, reason} -> continue_after(failure(state, %Error{message: "envd stream error", reason: reason}))
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.resp, do: Req.cancel_async_response(state.resp)
    :ok
  end

  # ---- streamed parts ----

  defp process_parts(parts, state) do
    parts
    |> Enum.reduce_while({:cont, state}, fn part, {:cont, state} ->
      case process_part(part, state) do
        {:cont, _} = ok -> {:cont, ok}
        {:stop, _} = stop -> {:halt, stop}
      end
    end)
    |> continue_after()
  end

  defp process_part({:data, chunk}, %{status: status} = state) when status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp process_part(:done, %{status: status} = state) when status not in 200..299 do
    failure(state, Error.from_response(%Req.Response{status: status, body: state.error_body}))
  end

  defp process_part({:data, chunk}, state) do
    case Connect.Decoder.push(state.decoder, chunk) do
      {:ok, messages, trailer, decoder} ->
        apply_messages(messages, %{state | decoder: decoder, trailer: trailer || state.trailer})

      {:error, reason} ->
        failure(state, malformed(reason))
    end
  end

  defp process_part(:done, state) do
    trailer_error = Connect.trailer_error(state.trailer)

    cond do
      state.decoder.buffer != "" -> failure(state, malformed(:malformed_frame))
      match?(%Error{}, trailer_error) -> failure(state, trailer_error)
      not state.started? -> failure(state, %Error{message: "watch failed to start"})
      true -> failure(state, %Error{message: "watch stream closed"})
    end
  end

  defp process_part({:trailers, _}, state), do: {:cont, state}

  # WatchDir frames are bare WatchDirResponse: %{"start"|"filesystem"|"keepalive" => _}.
  defp apply_messages(messages, state) do
    {:cont, Enum.reduce(messages, state, &dispatch/2)}
  end

  defp dispatch(%{"start" => _}, state), do: mark_started(state)

  defp dispatch(%{"filesystem" => fs}, state) do
    send_msg(state, {:fs_event, FilesystemEvent.from_api(fs)})
    state
  end

  defp dispatch(_other, state), do: state

  defp mark_started(%{started?: true} = state), do: state

  defp mark_started(state) do
    state = %{state | started?: true}

    if state.await_from do
      GenServer.reply(state.await_from, :ok)
      %{state | await_from: nil}
    else
      state
    end
  end

  # Deliver an error: to the subscriber if watching is active, else to the
  # await_start caller, else stash until await_start arrives.
  defp failure(state, error) do
    cond do
      state.started? ->
        send_msg(state, {:error, error})
        {:stop, state}

      state.await_from != nil ->
        GenServer.reply(state.await_from, {:error, error})
        {:stop, %{state | await_from: nil}}

      true ->
        {:cont, %{state | start_error: state.start_error || error}}
    end
  end

  defp continue_after({:cont, state}), do: {:noreply, state}
  defp continue_after({:stop, state}), do: {:stop, :normal, state}

  defp send_msg(state, payload), do: send(state.subscriber, {state.ref, payload})

  defp malformed(reason), do: %Error{message: "malformed envd response", reason: reason}

  defp receive_timeout(0), do: :infinity
  defp receive_timeout(ms), do: ms + 5_000
end
