defmodule CodexPoolerWeb.FacadeLeakageTest do
  use CodexPoolerWeb.ConnCase, async: true

  alias CodexPoolerWeb.GatewayControllerHelpers

  @hidden_model "gpt-5.6-sol-controller-sentinel"
  @hidden_provider "provider-controller-sentinel"
  @hidden_account "account-controller-sentinel"

  test "runtime JSON results keep local request identity and cloak upstream metadata" do
    assistant_text =
      "Literal #{@hidden_model} and #{@hidden_provider} content must stay unchanged."

    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_resp_header("x-request-id", "local-public-request-id")
      |> GatewayControllerHelpers.send_gateway_result(%{
        status: 200,
        headers: [
          {"content-type", "application/json; provider=#{@hidden_provider}"},
          {"x-request-id", "provider-request-id"},
          {"x-openai-model", @hidden_model},
          {"x-provider-account", @hidden_account}
        ],
        body: %{
          "id" => "resp_controller_projection",
          "object" => "response",
          "model" => @hidden_model,
          "provider" => @hidden_provider,
          "account_id" => @hidden_account,
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => assistant_text}]
            }
          ]
        }
      })

    body = json_response(conn, 200)
    assert body["model"] == "gemma3"

    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             assistant_text

    refute Map.has_key?(body, "provider")
    refute Map.has_key?(body, "account_id")
    assert get_resp_header(conn, "x-request-id") == ["local-public-request-id"]
    assert get_resp_header(conn, "x-openai-model") == []
    assert get_resp_header(conn, "x-provider-account") == []
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "runtime raw JSON and gateway errors cannot expose hidden routing sentinels" do
    raw_conn =
      Phoenix.ConnTest.build_conn(:post, "/v1/responses")
      |> GatewayControllerHelpers.send_gateway_result(%{
        status: 200,
        raw_body:
          Jason.encode!(%{
            "id" => "resp_raw_projection",
            "object" => "response",
            "model" => @hidden_model,
            "provider" => @hidden_provider,
            "output" => []
          })
      })

    assert %{"model" => "gemma3"} = json_response(raw_conn, 200)
    refute raw_conn.resp_body =~ @hidden_provider

    error_conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> GatewayControllerHelpers.send_error(%{
        status: 502,
        code: "provider_#{@hidden_model}",
        message: "#{@hidden_provider} #{@hidden_account} failed at upstream.invalid",
        param: @hidden_model
      })

    serialized = error_conn.resp_body

    for hidden <- [@hidden_model, @hidden_provider, @hidden_account, "upstream.invalid"] do
      refute serialized =~ hidden
    end

    assert %{"error" => %{"param" => nil}} = json_response(error_conn, 502)
  end
end
