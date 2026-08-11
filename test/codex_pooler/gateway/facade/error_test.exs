defmodule CodexPooler.Gateway.Facade.ErrorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Error

  @secret_error %{
    status: 503,
    code: "provider_account_failed",
    message: "OpenAI gpt-5.6-sol account acct_secret failed at upstream.example",
    param: "gpt-5.6-sol"
  }

  test "uses Ollama's one-field error envelope" do
    assert Error.body(:ollama, 503, @secret_error) == %{
             "error" => "gemma3 is temporarily unavailable"
           }
  end

  test "uses Anthropic error types without exposing internal details" do
    for {status, expected_type} <- [
          {400, "invalid_request_error"},
          {401, "authentication_error"},
          {403, "permission_error"},
          {404, "not_found_error"},
          {429, "rate_limit_error"},
          {503, "api_error"},
          {504, "api_error"}
        ] do
      body = Error.body(:anthropic, status, Map.put(@secret_error, :status, status))

      assert body["type"] == "error"
      assert body["error"]["type"] == expected_type
      assert_safe(body)
    end
  end

  test "keeps the OpenAI and Codex compatibility envelope" do
    for protocol <- [:openai, :codex, :runtime_metadata] do
      assert %{
               "error" => %{
                 "message" => "gemma3 is temporarily unavailable",
                 "type" => "invalid_request_error",
                 "code" => "service_unavailable",
                 "param" => nil
               }
             } = Error.body(protocol, 503, @secret_error)
    end
  end

  test "preserves status classes with fixed safe messages" do
    for {status, expected_message} <- [
          {400, "Request is invalid"},
          {401, "Pool API key is required or invalid"},
          {403, "Request denied by local Pool policy"},
          {429, "Local request limit exceeded"},
          {503, "gemma3 is temporarily unavailable"},
          {504, "gemma3 request timed out"}
        ] do
      error = Map.put(@secret_error, :status, status)
      assert Error.public_message(status, error) == expected_message
    end
  end

  defp assert_safe(value) do
    encoded = Jason.encode!(value)

    for forbidden <- ["OpenAI", "gpt-5.6-sol", "acct_secret", "upstream.example"] do
      refute encoded =~ forbidden
    end
  end
end
