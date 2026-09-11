defmodule CodexPooler.Gateway.Runtime.Finalization.ValidationRejectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.ValidationRejection
  alias CodexPooler.Gateway.Transports.RejectionBody

  @provider_sentinel "private-provider-validation-sentinel"
  @observed_message "Unsupported value: 'none' is not supported with the 'example-model' model. Supported values are: 'low', 'medium', 'high', and 'xhigh'."

  test "relays only allowlisted invalid_request_error codes on HTTP 400" do
    options = request_options("/backend-api/codex/responses")

    for code <- ValidationRejection.relayable_codes() do
      assert %{code: ^code, param: "reasoning.effort"} =
               ValidationRejection.fetch(rejection(400, code, "reasoning.effort"), options)
    end

    assert ValidationRejection.relayable_codes() == ~w(
             unsupported_value
             invalid_value
             unsupported_parameter
             missing_required_parameter
             invalid_type
             string_above_max_length
           )
  end

  test "renders a Pooler-authored error with supported values only for value codes" do
    options = request_options("/backend-api/codex/responses")

    for code <- ["unsupported_value", "invalid_value"] do
      rejection =
        ValidationRejection.fetch(
          rejection(400, code, "reasoning.effort", "invalid_request_error", @observed_message),
          options
        )

      assert rejection == %{
               code: code,
               param: "reasoning.effort",
               supported_values: ~w(low medium high xhigh)
             }

      assert ValidationRejection.error(rejection) == %{
               "type" => "invalid_request_error",
               "code" => code,
               "param" => "reasoning.effort",
               "message" =>
                 "upstream rejected parameter reasoning.effort (#{code}); supported values: low, medium, high, xhigh"
             }
    end

    for code <- ValidationRejection.relayable_codes() -- ["unsupported_value", "invalid_value"] do
      rejection =
        ValidationRejection.fetch(
          rejection(400, code, "reasoning.effort", "invalid_request_error", @observed_message),
          options
        )

      assert rejection.supported_values == nil

      assert ValidationRejection.error(rejection)["message"] ==
               "upstream rejected parameter reasoning.effort (#{code})"
    end
  end

  test "error applies the param mapper and falls back on an invalid mapping" do
    rejection = %{code: "unsupported_value", param: "reasoning.effort", supported_values: nil}

    mapped = ValidationRejection.error(rejection, fn "reasoning.effort" -> "reasoning_effort" end)
    assert mapped["param"] == "reasoning_effort"
    assert mapped["message"] == "upstream rejected parameter reasoning_effort (unsupported_value)"

    for invalid <- ["", nil, 42] do
      assert ValidationRejection.error(rejection, fn _param -> invalid end)["param"] ==
               "reasoning.effort"
    end

    assert ValidationRejection.error(%{rejection | param: nil}, fn _param -> "x" end)["param"] ==
             nil
  end

  test "extracts identifier-shaped supported values from the trailing provider list" do
    assert ValidationRejection.supported_values(@observed_message) == ~w(low medium high xhigh)

    assert ValidationRejection.supported_values(
             "Invalid value: 'ultra'. Supported values are: 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', and 'max'."
           ) == ~w(none minimal low medium high xhigh max)

    assert ValidationRejection.supported_values("Supported values are: 'low' and 'high'.") ==
             ~w(low high)

    assert ValidationRejection.supported_values("Supported values are: 'auto'") == ["auto"]

    assert ValidationRejection.supported_values(
             "Supported values are: 'gpt-5.5', 'v1_beta', and 'a.b-c'."
           ) == ~w(gpt-5.5 v1_beta a.b-c)

    twelve = Enum.map_join(1..12, ", ", &"'v#{&1}'")

    assert ValidationRejection.supported_values("Supported values are: #{twelve}.") ==
             Enum.map(1..12, &"v#{&1}")
  end

  test "never includes the rejected value or any value quoted before the list" do
    assert ValidationRejection.supported_values(
             "Unsupported value: 'low' is not supported. Supported values are: 'low' and 'high'."
           ) == ["high"]

    assert ValidationRejection.supported_values(
             "Unsupported value: 'max' with 'high'. Supported values are: 'max' and 'high'."
           ) == nil
  end

  test "rejects unsafe, repeated, trailing, oversized, or malformed lists" do
    thirteen = Enum.map_join(1..13, ", ", &"'v#{&1}'")
    long_token = String.duplicate("a", 33)

    for message <- [
          "Invalid value: 'x'. Supported values are: 'secret'. Supported values are: 'low'.",
          "Supported values are: 'low' and 'high'. " <> @provider_sentinel,
          "Supported values are: 'low', 'drop table', and 'high'.",
          "Supported values are: 'low', 'it''s', and 'high'.",
          "Supported values are: 'a<b>' and 'high'.",
          "Supported values are: 'café' and 'high'.",
          "Supported values are: \"low\" and \"high\".",
          "Supported values are: low, medium, high.",
          "Supported values are: '#{long_token}' and 'high'.",
          "Supported values are: #{thirteen}.",
          "Supported values are: ''.",
          "Supported values are: 'low',, 'high'.",
          "Supported values are: .",
          "Supported values are:'low'.",
          "No list here: 'low' and 'high'.",
          String.duplicate("x", 2_049) <> " Supported values are: 'low'.",
          "",
          nil,
          42,
          %{"message" => "Supported values are: 'low'."}
        ] do
      assert ValidationRejection.supported_values(message) == nil, inspect(message)
    end
  end

  test "never relays other statuses, types, codes, or body shapes" do
    options = request_options("/backend-api/codex/responses")

    for status <- [401, 403, 404, 409, 422, 429, 500, 503] do
      assert ValidationRejection.fetch(rejection(status, "unsupported_value", "x"), options) ==
               nil
    end

    for type <- ["server_error", "api_error", "", nil, 42] do
      response = rejection(400, "unsupported_value", "reasoning.effort", type)
      assert ValidationRejection.fetch(response, options) == nil
    end

    for code <- [
          "context_length_exceeded",
          "usage_limit_reached",
          "insufficient_quota",
          "invalid_api_key",
          "misalignment_policy_violation",
          "unsupported_value; drop",
          "",
          nil
        ] do
      assert ValidationRejection.fetch(rejection(400, code, "reasoning.effort"), options) == nil
    end

    for body <- [
          ~s({"detail":"Unsupported value"}),
          ~s({"error":"unsupported_value"}),
          "not json",
          "",
          CodexPooler.JSON.encode!(%{
            "error" => %{
              "code" => "unsupported_value",
              "type" => "invalid_request_error",
              "message" => String.duplicate("x", 70_000)
            }
          })
        ] do
      assert ValidationRejection.fetch(%Req.Response{status: 400, body: body}, options) == nil
    end
  end

  test "drops an invalid param and never reuses provider message text" do
    options = request_options("/backend-api/codex/responses")

    for param <- ["input[0]; " <> @provider_sentinel, String.duplicate("a", 161), 42, nil] do
      rejection = ValidationRejection.fetch(rejection(400, "invalid_value", param), options)

      assert ValidationRejection.error(rejection) == %{
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => nil,
               "message" => "upstream rejected the request (invalid_value)"
             }
    end

    rejection =
      ValidationRejection.fetch(rejection(400, "invalid_type", "tools[3].name"), options)

    refute inspect(ValidationRejection.error(rejection)) =~ @provider_sentinel
    refute inspect(ValidationRejection.error(rejection)) =~ "Supported values"
  end

  test "reads the private streaming drain before the materialized body" do
    options = request_options("/backend-api/codex/responses")

    private_body =
      CodexPooler.JSON.encode!(%{
        "error" => %{
          "code" => "unsupported_value",
          "message" => @observed_message,
          "param" => "reasoning.effort",
          "type" => "invalid_request_error"
        }
      })

    response =
      %Req.Response{status: 400, body: ""}
      |> RejectionBody.put(private_body)

    assert %{code: "unsupported_value", supported_values: ~w(low medium high xhigh)} =
             ValidationRejection.fetch(response, options)

    authoritative_empty =
      rejection(400, "unsupported_value", "reasoning.effort")
      |> RejectionBody.put("")

    assert ValidationRejection.fetch(authoritative_empty, options) == nil
  end

  test "applies only to ordinary Responses routes" do
    response = rejection(400, "unsupported_value", "reasoning.effort")

    for endpoint <- [
          "/backend-api/codex/responses",
          "/backend-api/codex/v1/responses",
          "/backend-api/codex/v1/chat/completions",
          "/v1/responses",
          "/v1/chat/completions"
        ] do
      assert %{code: "unsupported_value"} =
               ValidationRejection.fetch(response, request_options(endpoint)),
             endpoint
    end

    for endpoint <- [
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/v1/responses/compact",
          "/backend-api/transcribe"
        ] do
      assert ValidationRejection.fetch(response, request_options(endpoint)) == nil, endpoint
    end

    assert ValidationRejection.fetch(response, %{}) == nil
  end

  defp request_options(endpoint) do
    RequestOptions.build(%{}, endpoint, %{"model" => "example-model"})
  end

  defp rejection(status, code, param, type \\ "invalid_request_error", message \\ nil) do
    %Req.Response{
      status: status,
      body:
        CodexPooler.JSON.encode!(%{
          "error" => %{
            "code" => code,
            "message" =>
              message || "Unsupported value. Supported values are: 'low'. " <> @provider_sentinel,
            "param" => param,
            "type" => type
          }
        })
    }
  end
end
