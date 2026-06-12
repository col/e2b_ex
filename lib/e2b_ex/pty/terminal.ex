defmodule E2bEx.Pty.Terminal do
  @moduledoc false
  # Drives an interactive terminal session over a %Pty.Handle{}: streams PTY
  # output to a writer, forwards (batched) stdin bytes to the PTY, and polls the
  # terminal size to drive resizes. Pure orchestration over injectable IO hooks —
  # the Mix task (Mix.Tasks.E2b.Terminal) supplies the real stdio/stty bits and
  # raw-mode setup. Returns on the PTY's terminal event.
  #
  # Process shape: this process owns the PTY subscription and the output loop.
  # Size polling is folded into that loop via `:poll` self-messages (no separate
  # poller process). Input is the one piece that must block independently, so a
  # single linked reader process feeds the InputBatcher. `run/2` is one-shot —
  # it must not be reused for a second session.

  alias E2bEx.{CommandResult, Error}
  alias E2bEx.Pty.{Handle, InputBatcher}

  @doc """
  Run the terminal session for `handle`. Must be called from the process that
  owns the PTY subscription (it receives `{ref, {:pty, _}}`).

  Options (all injectable for testing):
    * `:write`     — `(binary -> any)`, default `&IO.binwrite(:stdio, &1)`
    * `:read_byte` — `(-> binary | :eof)`, default `fn -> IO.binread(:stdio, 1) end`
    * `:size`      — `(-> {cols, rows} | :error)`, default `fn -> :error end` (no resize)
    * `:poll_ms`   — size-poll interval, default 500
    * `:flush_ms`  — input batch interval, default 10
  """
  @spec run(Handle.t(), keyword()) :: {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Handle{} = handle, opts \\ []) do
    Process.flag(:trap_exit, true)
    write = opts[:write] || (&IO.binwrite(:stdio, &1))
    read_byte = opts[:read_byte] || fn -> IO.binread(:stdio, 1) end
    size = opts[:size] || fn -> :error end
    poll_ms = opts[:poll_ms] || 500
    flush_ms = opts[:flush_ms] || 10

    {:ok, batcher} =
      InputBatcher.start_link(flush_ms: flush_ms, on_flush: fn bytes -> Handle.send_input(handle, bytes) end)

    reader = spawn_link(fn -> reader_loop(read_byte, batcher) end)
    mon = Process.monitor(handle.server)
    Process.send_after(self(), :poll, poll_ms)

    try do
      output_loop(handle, mon, write, size, poll_ms, safe_size(size))
    after
      # We trap exits, so killing the linked reader/batcher arrives as benign
      # `{:EXIT, _, _}` messages rather than taking us down. They land after the
      # loop has already returned; this process is one-shot and short-lived, so
      # the leftover messages are simply discarded when it exits.
      Process.exit(reader, :kill)
      InputBatcher.stop(batcher)
      Process.demonitor(mon, [:flush])
    end
  end

  defp output_loop(handle, mon, write, size, poll_ms, last_size) do
    ref = handle.ref

    receive do
      {^ref, {:pty, bytes}} ->
        write.(bytes)
        output_loop(handle, mon, write, size, poll_ms, last_size)

      {^ref, {:exit, %CommandResult{} = result}} ->
        {:ok, result}

      {^ref, {:error, %Error{} = error}} ->
        {:error, error}

      {:DOWN, ^mon, :process, _pid, reason} ->
        {:error, %Error{message: "terminal session terminated", reason: reason}}

      :poll ->
        last_size = maybe_resize(handle, safe_size(size), last_size)
        Process.send_after(self(), :poll, poll_ms)
        output_loop(handle, mon, write, size, poll_ms, last_size)

      {:EXIT, _pid, _reason} ->
        # A linked reader/batcher exited mid-session. We deliberately keep
        # streaming output rather than tear down a working terminal: a dead
        # reader/batcher only means local input stops, and the user can still
        # see output and leave by ending the remote shell.
        output_loop(handle, mon, write, size, poll_ms, last_size)
    end
  end

  defp reader_loop(read_byte, batcher) do
    case read_byte.() do
      data when is_binary(data) ->
        InputBatcher.push(batcher, data)
        reader_loop(read_byte, batcher)

      _ ->
        # :eof or {:error, _}: stop reading.
        :ok
    end
  end

  defp maybe_resize(_handle, :error, last_size), do: last_size
  defp maybe_resize(_handle, same, same), do: same

  defp maybe_resize(handle, {cols, rows} = new_size, _last_size) do
    Handle.resize(handle, %{cols: cols, rows: rows})
    new_size
  end

  defp safe_size(size) do
    case size.() do
      {cols, rows} when is_integer(cols) and is_integer(rows) -> {cols, rows}
      _ -> :error
    end
  end
end
