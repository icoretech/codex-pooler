defmodule CodexPooler.GatewayTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Usage

  test "execute rejects whitespace-only model values as missing model" do
    payload = %{"model" => " \n\t "}
    request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

    assert {:error,
            %{
              status: 400,
              code: "invalid_request",
              message: "model is required",
              param: "model"
            }} =
             Gateway.execute(%{}, "/backend-api/codex/responses", payload, request_options)
  end

  test "usage auth fallback accepts typed request options at the public boundary" do
    request_options =
      RequestOptions.build([chatgpt_account_id: "acct_example"], "/api/codex/usage", %{})

    assert {:error,
            %{
              status: 401,
              code: "invalid_authorization",
              message: "chatgpt token is required"
            }} =
             Usage.resolve_codex_usage_auth({:error, :invalid_api_key}, request_options)
  end
end
