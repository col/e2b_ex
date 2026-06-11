defmodule E2bEx.Envd.Connect.DecoderTest do
  use ExUnit.Case, async: true
  alias E2bEx.Envd.Connect.Decoder

  defp frame(map) do
    json = Jason.encode!(map)
    <<0::8, byte_size(json)::unsigned-big-32, json::binary>>
  end

  defp trailer(json), do: <<2::8, byte_size(json)::unsigned-big-32, json::binary>>

  test "push/2 returns a complete frame and an empty buffer" do
    assert {:ok, [%{"a" => 1}], nil, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), frame(%{"a" => 1}))
  end

  test "push/2 reassembles a frame split across two pushes" do
    f = frame(%{"event" => %{"data" => %{"stdout" => "aGk="}}})
    <<head::binary-size(4), tail::binary>> = f

    assert {:ok, [], nil, %Decoder{buffer: ^head} = d} = Decoder.push(Decoder.new(), head)

    assert {:ok, [%{"event" => %{"data" => %{"stdout" => "aGk="}}}], nil, %Decoder{buffer: ""}} =
             Decoder.push(d, tail)
  end

  test "push/2 returns multiple complete frames from one push" do
    body = frame(%{"n" => 1}) <> frame(%{"n" => 2})

    assert {:ok, [%{"n" => 1}, %{"n" => 2}], nil, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), body)
  end

  test "push/2 buffers a partial header (< 5 bytes)" do
    assert {:ok, [], nil, %Decoder{buffer: <<0, 0>>}} = Decoder.push(Decoder.new(), <<0, 0>>)
  end

  test "push/2 buffers a complete header with a partial body" do
    partial = <<0::8, 10::unsigned-big-32, "short">>
    assert {:ok, [], nil, %Decoder{buffer: ^partial}} = Decoder.push(Decoder.new(), partial)
  end

  test "push/2 returns a success trailer with empty data as an empty map" do
    assert {:ok, [], %{}, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), <<2::8, 0::unsigned-big-32>>)
  end

  test "push/2 returns an error trailer map" do
    assert {:ok, [], %{"error" => %{"code" => "x", "message" => "y"}}, %Decoder{buffer: ""}} =
             Decoder.push(Decoder.new(), trailer(~s({"error":{"code":"x","message":"y"}})))
  end

  test "push/2 returns messages preceding a trailer in one push" do
    body = frame(%{"n" => 1}) <> trailer("{}")
    assert {:ok, [%{"n" => 1}], %{}, %Decoder{buffer: ""}} = Decoder.push(Decoder.new(), body)
  end

  test "push/2 errors on invalid JSON in a complete frame" do
    bad = <<0::8, 3::unsigned-big-32, "{[}">>
    assert {:error, {:invalid_json, _}} = Decoder.push(Decoder.new(), bad)
  end

  test "push/2 errors on invalid JSON in a trailer" do
    bad = <<2::8, 3::unsigned-big-32, "{[}">>
    assert {:error, {:invalid_json, _}} = Decoder.push(Decoder.new(), bad)
  end
end
