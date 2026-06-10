defmodule E2bEx.ErrorTest do
  use ExUnit.Case, async: true
  alias E2bEx.Error

  test "from_response/1 extracts code and message from API error body" do
    resp = %Req.Response{status: 404, body: %{"code" => 404, "message" => "not found"}}
    error = Error.from_response(resp)
    assert %Error{status: 404, code: 404, message: "not found", body: %{"code" => 404, "message" => "not found"}} = error
  end

  test "from_response/1 tolerates a non-standard body" do
    resp = %Req.Response{status: 500, body: "boom"}
    assert %Error{status: 500, code: nil, message: nil, body: "boom"} = Error.from_response(resp)
  end

  test "from_exception/1 captures the transport reason" do
    error = Error.from_exception(%Req.TransportError{reason: :timeout})
    assert %Error{status: nil, reason: :timeout} = error
  end
end
