defmodule E2bEx.Envd.Connect.Decoder do
  @moduledoc false
  # Incremental Connect-protocol frame decoder. Feed response-body byte chunks via
  # push/2; it extracts every complete frame and buffers any partial remainder for
  # the next push.
  #
  # A frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # The end-of-stream trailer sets bit 0x02 and ends the stream; its data is JSON
  # (`{}` on success, `{"error": {...}}` on a Connect-level error).

  import Bitwise

  @end_stream_flag 0x02

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "A fresh decoder with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append `bytes` and extract complete frames.

  Returns `{:ok, messages, trailer, decoder}` where `messages` are the
  JSON-decoded non-trailer frames completed by this push, `trailer` is the decoded
  end-of-stream frame if it arrived (else `nil`), and `decoder` carries any partial
  remainder. Returns `{:error, {:invalid_json, reason}}` if a *complete* frame's
  payload is not valid JSON. An incomplete frame is buffered, never an error.

  The decoder keeps no end-of-stream state across calls; once a non-nil `trailer`
  is returned the stream has ended and callers should stop feeding it bytes.
  """
  @spec push(t(), binary()) ::
          {:ok, [map()], map() | nil, t()} | {:error, {:invalid_json, term()}}
  def push(%__MODULE__{buffer: buffer}, bytes) when is_binary(bytes) do
    extract(buffer <> bytes, [])
  end

  defp extract(<<flags::8, len::unsigned-big-32, data::binary-size(len), rest::binary>>, acc) do
    if trailer?(flags) do
      case decode_trailer(data) do
        {:ok, trailer} -> {:ok, Enum.reverse(acc), trailer, %__MODULE__{buffer: rest}}
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    else
      case Jason.decode(data) do
        {:ok, message} -> extract(rest, [message | acc])
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    end
  end

  defp extract(remainder, acc) do
    {:ok, Enum.reverse(acc), nil, %__MODULE__{buffer: remainder}}
  end

  defp trailer?(flags), do: (flags &&& @end_stream_flag) != 0

  defp decode_trailer(""), do: {:ok, %{}}
  defp decode_trailer(data), do: Jason.decode(data)
end
