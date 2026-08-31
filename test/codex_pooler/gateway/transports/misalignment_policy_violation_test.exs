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

  test "response-private summary retains only normalized optional misalignment details" do
    response = %Req.Response{status: 403}

    summary = %{
      code: "misalignment_policy_violation",
      message: "blocked",
      misalignment: %{
        "error_type" => "synthetic_error_type",
        "detailed_explanation" => "synthetic detailed explanation",
        "steer" => %{
          "message" => "synthetic steer message",
          "unknown" => "must not escape"
        },
        "unknown" => "must not escape"
      }
    }

    response = MisalignmentPolicyViolation.put_summary(response, summary)

    assert MisalignmentPolicyViolation.fetch_summary(response) == %{
             code: "misalignment_policy_violation",
             message: "blocked",
             misalignment: %{
               "error_type" => "synthetic_error_type",
               "detailed_explanation" => "synthetic detailed explanation",
               "steer" => %{"message" => "synthetic steer message"}
             }
           }

    assert Map.keys(MisalignmentPolicyViolation.fetch_summary(response)) |> Enum.sort() ==
             [:code, :message, :misalignment]

    refute inspect(response.private) =~ "param"
    refute inspect(response.private) =~ "sibling"
    refute inspect(response.private) =~ "unknown"
  end

  test "normalizes only bounded direct-native misalignment continuation details" do
    details = %{
      "error_type" => "synthetic_error_type",
      "detailed_explanation" => "synthetic detailed explanation",
      "steer" => %{
        "message" => "synthetic steer message",
        "unknown" => "must not escape"
      },
      "unknown" => "must not escape"
    }

    for route <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
        status <- [400, 403] do
      assert {:ok,
              %{
                code: "misalignment_policy_violation",
                message: "blocked",
                misalignment: %{
                  "error_type" => "synthetic_error_type",
                  "detailed_explanation" => "synthetic detailed explanation",
                  "steer" => %{"message" => "synthetic steer message"}
                }
              }} =
               MisalignmentPolicyViolation.classify_http(
                 status,
                 exact_body("blocked", details),
                 request_options(route, %{"stream" => true})
               )
    end
  end

  test "omits the whole optional detail projection for absent empty malformed or oversized details" do
    invalid_details = [
      nil,
      %{},
      %{"error_type" => 17},
      %{"detailed_explanation" => []},
      %{"steer" => "invalid"},
      %{"steer" => %{}},
      %{"steer" => %{"message" => 17}},
      %{"error_type" => "valid", "steer" => %{"message" => 17}},
      %{"error_type" => String.duplicate("x", 65_537)}
    ]

    for details <- invalid_details do
      assert {:ok, summary} =
               MisalignmentPolicyViolation.classify_http(
                 400,
                 exact_body("blocked", details),
                 request_options("/backend-api/codex/responses", %{"stream" => false})
               )

      refute Map.has_key?(summary, :misalignment)
    end
  end

  test "keeps details off public compact chat and translated routes" do
    details = %{"error_type" => "private", "steer" => %{"message" => "private"}}

    for route <-
          @eligible_routes -- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
      assert {:ok, summary} =
               MisalignmentPolicyViolation.classify_http(
                 400,
                 exact_body("blocked", details),
                 request_options(route)
               )

      refute Map.has_key?(summary, :misalignment)
    end
  end

  test "request SSE transport label does not suppress pre-stream HTTP JSON details" do
    details = %{"error_type" => "private", "steer" => %{"message" => "private"}}

    assert {:ok, %{misalignment: ^details}} =
             MisalignmentPolicyViolation.classify_http(
               400,
               exact_body("blocked", details),
               request_options("/backend-api/codex/responses", %{"stream" => true})
             )
  end

  test "keeps details off websocket transport" do
    details = %{"error_type" => "private", "steer" => %{"message" => "private"}}

    options =
      RequestOptions.build(
        %{transport: "websocket"},
        "/backend-api/codex/responses",
        %{"stream" => true}
      )

    assert {:ok, summary} =
             MisalignmentPolicyViolation.classify_http(
               400,
               exact_body("blocked", details),
               options
             )

    refute Map.has_key?(summary, :misalignment)
  end

  defp exact_body(message, misalignment \\ nil) do
    error =
      %{
        "code" => "misalignment_policy_violation",
        "message" => message,
        "param" => "input[0]"
      }
      |> maybe_put_misalignment(misalignment)

    Jason.encode!(%{
      "error" => error,
      "sibling" => "must not escape"
    })
  end

  defp maybe_put_misalignment(error, nil), do: error

  defp maybe_put_misalignment(error, misalignment),
    do: Map.put(error, "misalignment", misalignment)

  defp request_options(route, payload \\ %{"stream" => true}),
    do: RequestOptions.build(%{}, route, payload)
end
