defmodule E2bEx.Envd.Connect do
  @moduledoc false
  # Connect-protocol (ConnectRPC) framing for the envd process API, JSON codec.
  #
  # Each frame is `<<flags::8, length::unsigned-big-32, data::binary-size(length)>>`.
  # Normal messages use flags 0; the end-of-stream trailer sets bit 0x02.
  # Incremental decoding lives in `E2bEx.Envd.Connect.Decoder`; this module wraps it
  # for the whole-body (buffered) case.

  alias E2bEx.Envd.Connect.Decoder
  alias E2bEx.Error

  @doc "Wrap a payload in a single Connect frame (flags 0)."
  @spec encode_frame(binary()) :: binary()
  def encode_frame(payload) when is_binary(payload) do
    <<0::8, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  @doc """
  Split a buffered Connect response body into `{:ok, messages, trailer}`.

  `messages` is the list of JSON-decoded non-trailer frames; `trailer` is the
  JSON-decoded end-of-stream frame, or `nil` when none is present. Returns
  `{:error, :malformed_frame}` when the body does not parse cleanly into whole
  frames — i.e. truncated framing, or extra bytes remaining after the
  end-of-stream trailer — and `{:error, {:invalid_json, reason}}` when a frame's
  payload is not valid JSON.
  """
  @spec decode_frames(binary()) ::
          {:ok, [map()], map() | nil} | {:error, :malformed_frame | {:invalid_json, term()}}
  def decode_frames(body) when is_binary(body) do
    case Decoder.push(Decoder.new(), body) do
      {:ok, messages, trailer, %Decoder{buffer: ""}} -> {:ok, messages, trailer}
      {:ok, _messages, _trailer, %Decoder{buffer: _leftover}} -> {:error, :malformed_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Map an end-of-stream trailer to an `%E2bEx.Error{}` when it carries a Connect
  error, or `nil` for a success/`nil` trailer.
  """
  @spec trailer_error(map() | nil) :: E2bEx.Error.t() | nil
  def trailer_error(%{"error" => %{} = err}) do
    %Error{message: err["message"], reason: err["code"], body: err}
  end

  def trailer_error(_), do: nil
end
