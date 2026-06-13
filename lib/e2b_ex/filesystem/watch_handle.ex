defmodule E2bEx.Filesystem.WatchHandle do
  @moduledoc """
  A handle to a directory watch started with `E2bEx.Filesystem.watch_dir/4`.

  Change events are delivered to the subscriber process as messages tagged with
  the handle's `ref`:

      {ref, {:fs_event, %E2bEx.FilesystemEvent{}}}   # each change, live
      {ref, {:error, %E2bEx.Error{}}}                # the stream failed or closed

  `KeepAlive` frames produce no message. `stop/1` ends the watch (no terminal
  message is sent).
  """

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref]

  @type t :: %__MODULE__{server: pid(), ref: reference()}

  @doc "Stop the watch and close the stream. Always returns `:ok`."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{server: server}) do
    if Process.alive?(server), do: GenServer.stop(server)
    :ok
  end
end
