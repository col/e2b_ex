defmodule E2bEx.Envd.ConnectTest do
  use ExUnit.Case, async: true
  alias E2bEx.Envd.Connect

  # Build a normal (flags 0) frame around a JSON-encodable map.
  defp frame(map), do: Connect.encode_frame(Jason.encode!(map))
  # Build an end-of-stream trailer frame (flags 0x02) around raw JSON.
  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "encode_frame/1 prefixes flags 0 and a big-endian length" do
    assert Connect.encode_frame("hello") == <<0::8, 5::unsigned-big-32, "hello">>
  end

  test "decode_frames/1 decodes a single data message and no trailer" do
    body = frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}})
    assert {:ok, [%{"event" => %{"data" => %{"stdout" => "aGk="}}}], nil} = Connect.decode_frames(body)
  end

  test "decode_frames/1 decodes multiple messages followed by a success trailer" do
    body =
      frame(%{"event" => %{"start" => %{"pid" => 1}}}) <>
        frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}}) <>
        frame(%{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}) <>
        trailer("{}")

    assert {:ok, messages, %{}} = Connect.decode_frames(body)
    assert length(messages) == 3
    assert List.last(messages) == %{"event" => %{"end" => %{"exited" => true, "status" => "exit"}}}
  end

  test "decode_frames/1 surfaces an error trailer" do
    body = trailer(~s({"error":{"code":"unavailable","message":"nope"}}))
    assert {:ok, [], %{"error" => %{"code" => "unavailable", "message" => "nope"}}} =
             Connect.decode_frames(body)
  end

  test "decode_frames/1 treats an empty trailer body as an empty map" do
    body = <<2::8, 0::unsigned-big-32>>
    assert {:ok, [], %{}} = Connect.decode_frames(body)
  end

  test "decode_frames/1 returns an error on truncated framing" do
    body = <<0::8, 10::unsigned-big-32, "short">>
    assert {:error, :malformed_frame} = Connect.decode_frames(body)
  end

  test "decode_frames/1 treats bytes after the trailer as malformed" do
    body = trailer("{}") <> frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}})
    assert {:error, :malformed_frame} = Connect.decode_frames(body)
  end

  test "decode_frames/1 returns an error on invalid JSON in a frame" do
    body = <<0::8, 3::unsigned-big-32, "{[}">>
    assert {:error, {:invalid_json, _}} = Connect.decode_frames(body)
  end
end
