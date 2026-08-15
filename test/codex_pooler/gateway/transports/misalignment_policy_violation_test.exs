defmodule CodexPooler.Gateway.Transports.MisalignmentPolicyViolationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation

  @eligible_routes [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses",
    "/backend-api/codex/responses/compact",
    "/backend-api/codex/v1/responses/compact",
    "/v1/responses",
    "/v1/chat/completions",
    "/backend-api/codex/v1/chat/completions"
  ]

  test "exports the exact code and fallback message" do
    assert MisalignmentPolicyViolation.code() == "misalignment_policy_violation"

    assert MisalignmentPolicyViolation.fallback_message() ==
             "This request was blocked due to a misalignment policy violation."
  end

  test "preserves every nonblank binary message and falls back for other values" do
    for message <- ["provider wording", "  provider wording  ", "\nprovider wording\t"] do
      assert MisalignmentPolicyViolation.normalize_message(message) == message
    end

    for message <- [nil, "", " \n\t ", 17, %{}] do
      assert MisalignmentPolicyViolation.normalize_message(message) ==
               MisalignmentPolicyViolation.fallback_message()
    end
  end

  test "matches exact direct errors for both eligible statuses and every eligible route" do
    for route <- @eligible_routes, status <- [400, 403] do
      options = request_options(route)

      assert {:ok,
              %{
                code: "misalignment_policy_violation",
                message: "  exact provider wording  "
              }} =
               MisalignmentPolicyViolation.classify_http(
                 status,
                 exact_body("  exact provider wording  "),
                 options
               )
    end
  end

  test "uses the fixed fallback for a blank direct message" do
    assert {:ok,
            %{
              code: "misalignment_policy_violation",
              message: "This request was blocked due to a misalignment policy violation."
            }} =
             MisalignmentPolicyViolation.classify_http(
               400,
               exact_body(" \n "),
               request_options("/v1/responses")
             )
  end

  test "rejects status, code, envelope, JSON, and route near misses" do
    eligible_options = request_options("/v1/responses")

    near_misses =
      for(
        status <- [401, 404, 409, 429, 500],
        do: {status, exact_body("blocked"), eligible_options}
      ) ++
        [
          {400, Jason.encode!(%{"error" => %{"code" => "other_code"}}), eligible_options},
          {400,
           Jason.encode!(%{
             "response" => %{
               "error" => %{"code" => "misalignment_policy_violation"}
             }
           }), eligible_options},
          {400,
           Jason.encode!(%{
             "status_details" => %{
               "error" => %{"code" => "misalignment_policy_violation"}
             }
           }), eligible_options},
          {400,
           Jason.encode!(%{
             "response" => %{
               "status_details" => %{
                 "error" => %{"code" => "misalignment_policy_violation"}
               }
             }
           }), eligible_options},
          {400,
           Jason.encode!(%{
             "type" => "error",
             "code" => "misalignment_policy_violation",
             "message" => "blocked"
           }), eligible_options},
          {400, "not-json", eligible_options},
          {400, "", eligible_options}
        ] ++
        for(
          route <- [
            "/v1/images/generations",
            "/v1/audio/transcriptions",
            "/backend-api/files",
            "/backend-api/codex/models",
            "/backend-api/codex/usage"
          ],
          do: {400, exact_body("blocked"), request_options(route)}
        )

    for {status, body, options} <- near_misses do
      assert MisalignmentPolicyViolation.classify_http(status, body, options) == :no_match
    end
  end

  test "gates translated traffic by the original route rather than its upstream target" do
    image_options =
      RequestOptions.build(
        %{
          openai_source_endpoint: "/v1/images/generations",
          openai_translated_endpoint: "/backend-api/codex/responses"
        },
        "/backend-api/codex/responses",
        %{"stream" => true}
      )

    chat_options =
      RequestOptions.build(
        %{
          openai_source_endpoint: "/v1/chat/completions",
          openai_translated_endpoint: "/backend-api/codex/responses"
        },
        "/backend-api/codex/responses",
        %{"stream" => true}
      )

    assert MisalignmentPolicyViolation.classify_http(400, exact_body("blocked"), image_options) ==
             :no_match

    assert {:ok, %{code: "misalignment_policy_violation", message: "blocked"}} =
             MisalignmentPolicyViolation.classify_http(400, exact_body("blocked"), chat_options)
  end

  test "response-private summary contains exactly code and normalized message" do
    response = %Req.Response{status: 403}
    summary = %{code: "misalignment_policy_violation", message: "blocked"}

    response = MisalignmentPolicyViolation.put_summary(response, summary)

    assert MisalignmentPolicyViolation.fetch_summary(response) == summary

    assert Map.keys(MisalignmentPolicyViolation.fetch_summary(response)) |> Enum.sort() ==
             [:code, :message]

    refute inspect(response.private) =~ "param"
    refute inspect(response.private) =~ "sibling"
  end

  defp exact_body(message) do
    Jason.encode!(%{
      "error" => %{
        "code" => "misalignment_policy_violation",
        "message" => message,
        "param" => "input[0]"
      },
      "sibling" => "must not escape"
    })
  end

  defp request_options(route) do
    RequestOptions.build(%{}, route, %{"stream" => true})
  end
end
