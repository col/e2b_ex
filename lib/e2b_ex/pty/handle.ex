defmodule E2bEx.Pty.Handle do
  @moduledoc """
  A handle to a background PTY started with `E2bEx.Pty.create/3` (or reconnected
  via `E2bEx.Pty.connect/4`).

  Terminal output is delivered to the subscriber process as messages tagged with
  the handle's `ref`:

      {ref, {:pty, binary}}                    # merged terminal output, live
      {ref, {:exit, %E2bEx.CommandResult{}}}   # terminal, any exit code
      {ref, {:error, %E2bEx.Error{}}}          # terminal, failure

  Consume the message stream **or** call `wait/1` (which drains the stream and
  returns the result) — not both from the same process.
  """

  alias E2bEx.{CommandResult, Error}
  alias E2bEx.Envd.Rpc

  @enforce_keys [:server, :ref, :pid, :context]
  defstruct [:server, :ref, :pid, :context]

  @type t :: %__MODULE__{
          server: pid(),
          ref: reference(),
          pid: non_neg_integer(),
          context: map()
        }

  @doc "The envd process id of the running PTY."
  @spec pid(t()) :: non_neg_integer()
  def pid(%__MODULE__{pid: pid}), do: pid

  @doc "Send `data` to the PTY (the PTY input channel, not stdin)."
  @spec send_input(t(), binary()) :: :ok | {:error, E2bEx.Error.t()}
  def send_input(%__MODULE__{context: ctx, pid: pid}, data) when is_binary(data),
    do: Rpc.send_pty_input(ctx, pid, data)

  @doc "Resize the PTY. `size` is `%{cols: c, rows: r}`."
  @spec resize(t(), %{cols: non_neg_integer(), rows: non_neg_integer()}) ::
          :ok | {:error, E2bEx.Error.t()}
  def resize(%__MODULE__{context: ctx, pid: pid}, %{cols: _, rows: _} = size),
    do: Rpc.resize(ctx, pid, size)

  @doc "Kill the PTY (SIGKILL). `{:ok, false}` if it was already gone."
  @spec kill(t()) :: {:ok, boolean()} | {:error, E2bEx.Error.t()}
  def kill(%__MODULE__{context: ctx, pid: pid}), do: Rpc.kill(ctx, pid)

  @doc """
  Block until the PTY finishes and return its result.

  Drains the intermediate `{ref, {:pty, _}}` messages from the caller's mailbox
  and returns on the terminal message: `{:ok, %E2bEx.CommandResult{}}` for any
  exit code (PTY output is **not** buffered, so `stdout`/`stderr` are empty), or
  `{:error, %E2bEx.Error{}}`. Must be called from the subscriber process. Returns
  `{:error, %E2bEx.Error{}}` if the handle server crashes.
  """
  @spec wait(t()) :: {:ok, CommandResult.t()} | {:error, Error.t()}
  def wait(%__MODULE__{server: server, ref: ref}) do
    mon = Process.monitor(server)
    result = wait_loop(ref, mon)
    Process.demonitor(mon, [:flush])
    result
  end

  defp wait_loop(ref, mon) do
    receive do
      {^ref, {:exit, %CommandResult{} = result}} -> {:ok, result}
      {^ref, {:error, %Error{} = error}} -> {:error, error}
      {^ref, {:pty, _}} -> wait_loop(ref, mon)
      {:DOWN, ^mon, :process, _pid, reason} ->
        {:error, %Error{message: "command handle terminated", reason: reason}}
    end
  end

  @doc """
  Stop streaming from the PTY without killing it. The envd process keeps running;
  reconnect with `E2bEx.Pty.connect/4`. No terminal message is sent.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{server: server}) do
    if Process.alive?(server), do: GenServer.stop(server)
    :ok
  end
end
