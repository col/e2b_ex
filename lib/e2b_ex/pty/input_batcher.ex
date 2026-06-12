defmodule E2bEx.Pty.InputBatcher do
  @moduledoc false
  # Accumulates raw input bytes and flushes them in one batch every `:flush_ms`
  # via the `:on_flush` callback. Coalesces fast typing and multi-byte escape
  # sequences (e.g. arrow keys) so the terminal makes one `send_input` per window
  # instead of one per byte. Knows nothing about PTYs.

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Append `bytes` to the pending buffer."
  @spec push(GenServer.server(), binary()) :: :ok
  def push(server, bytes) when is_binary(bytes), do: GenServer.cast(server, {:push, bytes})

  @doc "Flush any remaining bytes and stop."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    flush_ms = Keyword.get(opts, :flush_ms, 10)
    on_flush = Keyword.fetch!(opts, :on_flush)
    schedule(flush_ms)
    {:ok, %{buffer: [], flush_ms: flush_ms, on_flush: on_flush}}
  end

  @impl true
  def handle_cast({:push, bytes}, state) do
    {:noreply, %{state | buffer: [state.buffer, bytes]}}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush(state)
    schedule(state.flush_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  defp flush(%{buffer: buffer, on_flush: on_flush} = state) do
    case IO.iodata_to_binary(buffer) do
      "" ->
        state

      bin ->
        on_flush.(bin)
        %{state | buffer: []}
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :flush, ms)
end
