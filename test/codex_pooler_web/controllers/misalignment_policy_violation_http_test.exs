defmodule CodexPoolerWeb.MisalignmentPolicyViolationHTTPTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      gateway_setup: 2,
      gateway_upstream: 4,
      half_open_circuit!: 2,
      ledger_entry_kinds: 1,
      native_text_input: 1,
      prime_routing_quota!: 1,
      put_model_source_assignments!: 2,
      seed_preferring_assignment: 2,
      start_upstream: 1,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Repo

  @code "misalignment_policy_violation"

  test "materialized backend HTTP 400 finalizes the exact policy violation neutrally", %{
    conn: conn
  } do
    provider_message = "Synthetic policy wording"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "error" => %{
              "code" => @code,
              "message" => provider_message,
              "param" => "must-not-pass"
            },
            "provider_sibling" => "must-not-pass"
          },
          [{"x-codex-turn-state", "safe-turn-state"}],
          400
        )
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic policy request")
      })

    assert json_response(response, 400) == %{
             "error" => %{"code" => @code, "message" => provider_message}
           }

    assert get_resp_header(response, "x-codex-turn-state") == ["safe-turn-state"]
    assert_policy_accounting!(setup, 400, true, byte_size(provider_message))
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  test "direct native HTTP relays bounded details transiently without public durable or log leakage",
       %{
         conn: conn
       } do
    private_marker = "<system>synthetic hostile instruction marker</system>"

    payload = %{
      "error" => %{
        "code" => @code,
        "message" => "Synthetic policy wording",
        "misalignment" => %{
          "error_type" => "synthetic_error_type",
          "detailed_explanation" => private_marker,
          "steer" => %{"message" => private_marker, "unknown" => private_marker},
          "unknown" => private_marker
        },
        "param" => private_marker
      },
      "provider_sibling" => private_marker
    }

    for {path, status} <- [
          {"/backend-api/codex/responses", 400},
          {"/backend-api/codex/v1/responses", 403}
        ] do
      rejection_body = Jason.encode!(payload)

      upstream =
        start_upstream(
          FakeUpstream.chunked_response(
            [
              binary_part(rejection_body, 0, 17),
              binary_part(rejection_body, 17, byte_size(rejection_body) - 17)
            ],
            status: status,
            headers: [{"content-type", "application/json"}]
          )
        )

      setup = gateway_setup(upstream)

      {response, log} =
        with_log(fn ->
          conn
          |> recycle()
          |> auth(setup)
          |> post(path, %{
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("synthetic native detail request"),
            "stream" => true
          })
        end)

      assert response.state == :sent
      assert get_resp_header(response, "content-type") == ["application/json"]

      assert json_response(response, status) == %{
               "error" => %{
                 "code" => @code,
                 "message" => "Synthetic policy wording",
                 "misalignment" => %{
                   "error_type" => "synthetic_error_type",
                   "detailed_explanation" => private_marker,
                   "steer" => %{"message" => private_marker}
                 }
               }
             }

      assert_policy_accounting!(setup, status, true, byte_size("Synthetic policy wording"))

      persisted =
        Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        |> Enum.flat_map(fn request ->
          [request | Repo.all(from(a in Attempt, where: a.request_id == ^request.id))]
        end)
        |> inspect()

      refute persisted =~ private_marker
      refute log =~ private_marker
    end

    public_upstream = start_upstream(FakeUpstream.json_response(payload, 400))
    public_setup = gateway_setup(public_upstream)

    public_response =
      conn
      |> recycle()
      |> auth(public_setup)
      |> post("/v1/responses", %{
        "model" => public_setup.model.exposed_model_id,
        "input" => "synthetic public redaction request"
      })

    assert %{"error" => public_error} = json_response(public_response, 400)
    refute Map.has_key?(public_error, "misalignment")
    refute inspect(public_error) =~ private_marker

    public_persisted =
      Repo.all(from(r in Request, where: r.pool_id == ^public_setup.pool.id))
      |> Enum.flat_map(fn request ->
        [request | Repo.all(from(a in Attempt, where: a.request_id == ^request.id))]
      end)
      |> inspect()

    refute public_persisted =~ private_marker
  end

  test "direct native HTTP omits all details when any known detail field is invalid" do
    for misalignment <- [
          %{},
          %{"error_type" => 17},
          %{"detailed_explanation" => []},
          %{"steer" => %{}},
          %{"steer" => %{"message" => 17}},
          %{"error_type" => "valid", "steer" => %{"message" => 17}},
          %{"detailed_explanation" => String.duplicate("x", 65_537)}
        ] do
      upstream =
        start_upstream(
          FakeUpstream.json_response(
            %{
              "error" => %{
                "code" => @code,
                "message" => "Synthetic policy wording",
                "misalignment" => misalignment
              }
            },
            400
          )
        )

      setup = gateway_setup(upstream)

      response =
        build_conn()
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic invalid detail request")
        })

      assert json_response(response, 400) == %{
               "error" => %{
                 "code" => @code,
                 "message" => "Synthetic policy wording"
               }
             }
    end
  end

  test "async public HTTP 403 releases a half-open probe without failover", %{conn: conn} do
    provider_message = " \t\n"

    rejection_body =
      Jason.encode!(%{
        "error" => %{
          "code" => @code,
          "message" => provider_message,
          "param" => "must-not-pass"
        },
        "provider_sibling" => "must-not-pass"
      })

    rejecting_upstream =
      start_upstream(
        FakeUpstream.chunked_response([rejection_body],
          status: 403,
          headers: [{"content-type", "application/json"}]
        )
      )

    fallback_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must-not-run"}))
    setup = gateway_setup(rejecting_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "synthetic-fallback-token", compact?: false)

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup = %{
      setup
      | model: put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
    }

    circuit = half_open_circuit!(setup, setup.assignment)

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    response =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic public policy request"
      })

    assert json_response(response, 403) == %{
             "error" => %{
               "code" => @code,
               "message" => MisalignmentPolicyViolation.fallback_message(),
               "type" => "invalid_request_error"
             }
           }

    assert FakeUpstream.count(rejecting_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_policy_accounting!(setup, 403, true, byte_size(provider_message))
    assert Repo.aggregate(BridgeDemotion, :count) == 0

    persisted_circuit = Repo.get!(RoutingCircuitState, circuit.id)
    assert persisted_circuit.status == "half_open"
    assert persisted_circuit.failure_count == 1
    assert persisted_circuit.metadata["probe_in_flight_count"] == 0
  end

  test "eligible response aliases and chat routes preserve their safe error shapes", %{conn: conn} do
    cases = [
      {"/backend-api/codex/v1/responses", false,
       %{"input" => native_text_input("synthetic alias request")}, :backend},
      {"/backend-api/codex/responses/compact", true,
       %{"input" => native_text_input("synthetic compact request")}, :backend},
      {"/backend-api/codex/v1/responses/compact", true,
       %{"input" => native_text_input("synthetic compact alias request")}, :backend},
      {"/v1/chat/completions", false,
       %{"messages" => [%{"role" => "user", "content" => "synthetic chat request"}]}, :public},
      {"/backend-api/codex/v1/chat/completions", false,
       %{"messages" => [%{"role" => "user", "content" => "synthetic backend chat request"}]},
       :public}
    ]

    for {path, compact?, payload, projection} <- cases do
      upstream = start_upstream(policy_response(400, "Synthetic route wording"))
      setup = gateway_setup(upstream, compact?: compact?)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(path, Map.put(payload, "model", setup.model.exposed_model_id))

      expected_error = %{"code" => @code, "message" => "Synthetic route wording"}

      expected_error =
        if projection == :public,
          do: Map.put(expected_error, "type", "invalid_request_error"),
          else: expected_error

      assert json_response(response, 400) == %{"error" => expected_error},
             "unexpected policy projection for #{path}"

      assert FakeUpstream.count(upstream) == 1
      assert_policy_accounting!(setup, 400, true, byte_size("Synthetic route wording"))
    end
  end

  test "near-miss HTTP failures retain generic behavior", %{conn: conn} do
    cases = [
      {422, %{"error" => %{"code" => @code, "message" => "outside status"}}},
      {400, %{"wrapper" => %{"error" => %{"code" => @code, "message" => "nested"}}}},
      {400, %{"error" => %{"code" => "other_provider_error", "message" => "generic"}}}
    ]

    for {status, payload} <- cases do
      upstream = start_upstream(FakeUpstream.json_response(payload, status))
      setup = gateway_setup(upstream)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic negative request"
        })

      assert %{"error" => error} = json_response(response, status)
      refute error["code"] == @code

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.last_error_code == "upstream_status"
      refute inspect(request.request_metadata) =~ "outside status"
      refute inspect(request.request_metadata) =~ "nested"
      refute inspect(request.request_metadata) =~ "generic"
    end

    upstream =
      start_upstream(
        FakeUpstream.raw_response("not-json-#{@code}",
          status: 400,
          headers: [{"content-type", "application/json"}]
        )
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic malformed request"
      })

    assert %{"error" => error} = json_response(response, 400)
    refute error["code"] == @code
  end

  test "public image and audio routes do not receive the policy exception", %{conn: conn} do
    image_upstream = start_upstream(policy_response(400, "image provider wording"))
    image_model = "gpt-image-2"
    image_setup = image_upstream |> gateway_setup() |> use_image_model!(image_model)

    image_setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: [image_model])
    |> Repo.update!()

    image_response =
      conn
      |> recycle()
      |> auth(image_setup)
      |> post("/v1/images/generations", %{
        "model" => image_model,
        "prompt" => "synthetic image request"
      })

    assert json_response(image_response, 400) == %{
             "error" => %{
               "code" => "upstream_status",
               "message" => "upstream request failed",
               "type" => "server_error"
             }
           }

    assert_generic_accounting!(image_setup, 400)

    audio_upstream = start_upstream(policy_response(403, "audio provider wording"))
    audio_setup = audio_upstream |> gateway_setup() |> use_transcription_model!()

    audio_response =
      conn
      |> recycle()
      |> auth(audio_setup)
      |> post("/v1/audio/transcriptions", %{
        "model" => Gateway.backend_transcription_model(),
        "file" => upload_fixture("synthetic.wav", "audio/wav", "synthetic audio")
      })

    assert json_response(audio_response, 403) == %{
             "error" => %{
               "code" => "server_error",
               "message" => "upstream request failed",
               "type" => "server_error"
             }
           }

    assert_generic_accounting!(audio_setup, 403)
  end

  test "missing and empty policy messages use fallback with zero message metadata", %{conn: conn} do
    for error <- [
          %{"code" => @code},
          %{"code" => @code, "message" => ""}
        ] do
      upstream = start_upstream(FakeUpstream.json_response(%{"error" => error}, 400))
      setup = gateway_setup(upstream)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic blank-message policy request")
        })

      assert json_response(response, 400) == %{
               "error" => %{
                 "code" => @code,
                 "message" => MisalignmentPolicyViolation.fallback_message()
               }
             }

      assert_policy_accounting!(setup, 400, false, 0)
    end
  end

  defp assert_policy_accounting!(setup, status, message_present?, message_bytes) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == status
    assert request.retry_count == 0
    assert request.last_error_code == @code
    assert ledger_entry_kinds(request) == ["release", "reservation", "settlement"]

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == status
    assert attempt.network_error_code == @code
    assert attempt.retryable == false
    assert attempt.error_message == MisalignmentPolicyViolation.fallback_message()
    assert attempt.response_metadata["error_kind"] == @code
    assert attempt.response_metadata["rejection_error_code"] == @code
    assert attempt.response_metadata["rejection_message_present"] == message_present?
    assert attempt.response_metadata["rejection_message_bytes"] == message_bytes

    persisted = inspect({request.request_metadata, attempt.response_metadata})
    refute persisted =~ "Synthetic policy wording"
    refute persisted =~ "must-not-pass"
  end

  defp policy_response(status, message) do
    FakeUpstream.json_response(
      %{
        "error" => %{
          "code" => @code,
          "message" => message,
          "param" => "must-not-pass"
        },
        "provider_sibling" => "must-not-pass"
      },
      status
    )
  end

  defp assert_generic_accounting!(setup, status) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == status
    assert request.last_error_code == "upstream_status"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.network_error_code == "upstream_status"
    assert attempt.error_message == "upstream returned #{status}"
  end

  defp use_transcription_model!(setup) do
    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: Gateway.backend_transcription_model(),
        upstream_model_id: "provider-transcription-model",
        supports_responses: false,
        supports_streaming: false,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => %{
              "slug" => Gateway.backend_transcription_model(),
              "input_modalities" => ["audio"],
              "modes" => ["transcription"]
            }
          },
          "input_modalities" => ["audio"],
          "modes" => ["transcription"]
        }
      })
      |> Repo.update!()

    %{setup | model: model}
  end

  defp use_image_model!(setup, model_id) do
    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: model_id,
        upstream_model_id: "provider-image-host-model",
        supports_responses: true,
        supports_streaming: true,
        metadata:
          setup.model.metadata
          |> Map.put("source_assignment_ids", [setup.assignment.id])
          |> put_in(["source_assignment_models", setup.assignment.id, "slug"], model_id)
          |> put_in(
            ["source_assignment_models", setup.assignment.id, "input_modalities"],
            ["text", "image"]
          )
      })
      |> Repo.update!()

    %{setup | model: model}
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "policy-http-audio-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
