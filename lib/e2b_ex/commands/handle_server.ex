defmodule E2bEx.Commands.HandleServer do
  @moduledoc false
  # GenServer owning one envd Start/Connect server-stream (Req `into: :self`).
  # Folds events via `Commands.Fold` and pushes `{ref, _}` messages to the
  # subscriber: `{:stdout, bin}` / `{:stderr, bin}` while running, then a terminal
  # `{:exit, result}` or `{:error, error}`. Replies to `:await_start` with the
  # envd pid once the first `start` event arrives. Holds no control logic.

  use GenServer

  alias E2bEx.Error
  alias E2bEx.Commands.Fold
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
      fold: Fold.new(),
      trailer: nil,
      error_body: "",
      pid: nil,
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
      state.pid != nil -> {:reply, {:ok, state.pid}, state}
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
    # Cancel the Req/Finch async stream so disconnect closes the envd connection
    # promptly (Finch otherwise only tears down on the next chunk or the receive
    # timeout). Harmless if the stream already completed.
    if state.resp, do: Req.cancel_async_response(state.resp)
    :ok
  end

  # ---- streamed parts ----

  # Req.parse_message/2 returns {:ok, parts} where parts is a keyword list:
  #   [data: binary]   - a data chunk
  #   [:done]          - stream finished
  #   [trailers: map]  - HTTP trailers (ignored; we use Connect-protocol trailer frames)
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

  # non-2xx: accumulate the raw error body, then fail on :done.
  defp process_part({:data, chunk}, %{status: status} = state) when status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp process_part(:done, %{status: status} = state) when status not in 200..299 do
    failure(state, Error.from_response(%Req.Response{status: status, body: state.error_body}))
  end

  # 2xx streaming
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
      state.decoder.buffer != "" ->
        failure(state, malformed(:malformed_frame))

      match?(%Error{}, trailer_error) ->
        failure(state, trailer_error)

      state.pid == nil ->
        failure(state, %Error{message: "command failed to start"})

      Fold.ended?(state.fold) ->
        send_msg(state, {:exit, Fold.result(state.fold)})
        {:stop, state}

      true ->
        failure(state, %Error{message: "command ended without a result"})
    end
  end

  # HTTP trailers (not Connect-protocol trailers) — ignore
  defp process_part({:trailers, _}, state), do: {:cont, state}

  defp apply_messages(messages, state) do
    Enum.reduce_while(messages, {:cont, state}, fn message, {:cont, state} ->
      event = message["event"]
      state = maybe_capture_pid(event, state)

      case Fold.apply_event(state.fold, event) do
        {:ok, fold, outputs} ->
          Enum.each(outputs, fn {kind, bytes} -> send_msg(state, {kind, bytes}) end)
          {:cont, {:cont, %{state | fold: fold}}}

        {:error, reason} ->
          {:halt, failure(state, malformed(reason))}
      end
    end)
  end

  defp maybe_capture_pid(%{"start" => %{"pid" => pid}}, %{pid: nil} = state) do
    state = %{state | pid: pid}

    if state.await_from do
      GenServer.reply(state.await_from, {:ok, pid})
      %{state | await_from: nil}
    else
      state
    end
  end

  defp maybe_capture_pid(_event, state), do: state

  # Deliver an error: to the start caller if not started yet, else to the
  # subscriber as a terminal message. Returns a {:cont | :stop, state} tuple.
  defp failure(state, error) do
    cond do
      state.pid != nil ->
        send_msg(state, {:error, error})
        {:stop, state}

      state.await_from != nil ->
        GenServer.reply(state.await_from, {:error, error})
        {:stop, %{state | await_from: nil}}

      true ->
        # Failed before start and before the await_start call arrived: stay alive
        # so handle_call(:await_start) can return the error, then stop. Keep the
        # first (most specific) error if one was already stashed.
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
