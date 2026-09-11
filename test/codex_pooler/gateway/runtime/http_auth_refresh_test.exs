defmodule CodexPooler.Gateway.Runtime.HttpAuthRefreshTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Dispatch.HttpAuthRefresh
  alias CodexPooler.Gateway.Transports.RejectionBody

  describe "auth_failure?/1" do
    test "any 401 is an auth failure regardless of body shape" do
      assert HttpAuthRefresh.auth_failure?(response(401, ""))
      assert HttpAuthRefresh.auth_failure?(response(401, "not json"))
      assert HttpAuthRefresh.auth_failure?(response(401, error_body("unauthorized")))
    end

    test "403 is an auth failure only with an auth-refresh body code" do
      assert HttpAuthRefresh.auth_failure?(response(403, error_body("invalid_api_key")))
      assert HttpAuthRefresh.auth_failure?(response(403, error_body("invalid_authentication")))
      refute HttpAuthRefresh.auth_failure?(response(403, error_body("insufficient_quota")))
      refute HttpAuthRefresh.auth_failure?(response(403, ""))
      refute HttpAuthRefresh.auth_failure?(response(403, "not json"))
    end

    test "a drained streaming rejection body is honored" do
      drained = RejectionBody.put(response(403, ""), error_body("invalid_api_key"))
      assert HttpAuthRefresh.auth_failure?(drained)
    end

    test "other statuses never refresh" do
      refute HttpAuthRefresh.auth_failure?(response(400, error_body("invalid_api_key")))
      refute HttpAuthRefresh.auth_failure?(response(429, error_body("invalid_api_key")))
      refute HttpAuthRefresh.auth_failure?(response(200, ""))
    end
  end

  defp response(status, body), do: %Req.Response{status: status, body: body}

  defp error_body(code) do
    CodexPooler.JSON.encode!(%{"error" => %{"code" => code, "message" => "sentinel"}})
  end
end
