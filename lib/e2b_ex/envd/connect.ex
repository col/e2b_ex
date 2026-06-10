defmodule E2bEx.Envd.Connect do
  @moduledoc false
  # Connect-protocol (ConnectRPC) framing for the envd process API, JSON codec.
  #
  # Each frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # Normal messages use flags 0; the end-of-stream trailer sets bit 0x02.

  import Bitwise

  @end_stream_flag 0x02

  @doc "Wrap a payload in a single Connect frame (flags 0)."
  @spec encode_frame(binary()) :: binary()
  def encode_frame(payload) when is_binary(payload) do
    <<0::8, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  @doc """
  Split a buffered Connect response body into `{:ok, messages, trailer}`.

  `messages` is the list of JSON-decoded non-trailer frames; `trailer` is the
  JSON-decoded end-of-stream frame, or `nil` when none is present. Returns
  `{:error, :malformed_frame}` on truncated framing or `{:error, {:invalid_json,
  reason}}` when a frame's payload is not valid JSON.
  """
  @spec decode_frames(binary()) ::
          {:ok, [map()], map() | nil} | {:error, :malformed_frame | {:invalid_json, term()}}
  def decode_frames(body) when is_binary(body) do
    with {:ok, frames} <- split(body, []) do
      {trailers, messages} = Enum.split_with(frames, fn {flags, _} -> trailer?(flags) end)

      with {:ok, decoded} <- decode_each(messages, []),
           {:ok, trailer} <- decode_trailer(trailers) do
        {:ok, decoded, trailer}
      end
    end
  end

  defp trailer?(flags), do: (flags &&& @end_stream_flag) != 0

  defp split(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp split(<<flags::8, len::unsigned-big-32, data::binary-size(len), rest::binary>>, acc),
    do: split(rest, [{flags, data} | acc])

  defp split(_partial, _acc), do: {:error, :malformed_frame}

  defp decode_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_each([{_flags, data} | rest], acc) do
    case Jason.decode(data) do
      {:ok, map} -> decode_each(rest, [map | acc])
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_trailer([]), do: {:ok, nil}
  defp decode_trailer([{_flags, ""} | _]), do: {:ok, %{}}

  defp decode_trailer([{_flags, data} | _]) do
    case Jason.decode(data) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end
end
