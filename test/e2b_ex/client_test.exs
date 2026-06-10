defmodule E2bEx.ClientTest do
  use ExUnit.Case, async: true
  alias E2bEx.Client

  test "new/1 builds a client with defaults" do
    client = Client.new(api_key: "key_123")
    assert %Client{api_key: "key_123", base_url: "https://api.e2b.app", req_options: []} = client
  end

  test "new/1 allows overriding base_url and req_options" do
    client = Client.new(api_key: "k", base_url: "http://localhost:3000", req_options: [retry: false])
    assert client.base_url == "http://localhost:3000"
    assert client.req_options == [retry: false]
  end

  test "new/1 raises without an api key" do
    assert_raise ArgumentError, fn -> Client.new([]) end
  end

  test "base_req/1 sets base_url and x-api-key header" do
    req = Client.new(api_key: "key_123") |> Client.base_req()
    assert req.options.base_url == "https://api.e2b.app"
    assert {"x-api-key", ["key_123"]} in Map.to_list(req.headers) or
             req.headers["x-api-key"] == ["key_123"]
  end
end
