defmodule CodexPoolerWeb.Runtime.BackendCodexControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias Ecto.Adapters.SQL.Sandbox, as: Sandbox

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request, RequestLogs}
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Metadata
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Transports.BoundedResponseBody

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle

  @supported_compression_model "gpt-4o"

  defmodule ClosedChunkAdapter do
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  test "GET /backend-api/codex/models returns Codex-specific shape", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-request-id", Ecto.UUID.generate())
      |> auth(setup)
      |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["slug"] == setup.model.exposed_model_id
    assert model["description"] == setup.model.display_name

    assert model["supported_reasoning_levels"] == [
             %{"description" => "low", "effort" => "low"},
             %{"description" => "medium", "effort" => "medium"},
             %{"description" => "high", "effort" => "high"},
             %{"description" => "xhigh", "effort" => "xhigh"}
           ]

    assert model["shell_type"] == "shell_command"
    assert model["visibility"] == "list"
    assert model["base_instructions"] == ""
    assert model["truncation_policy"] == %{"mode" => "bytes", "limit" => 10_000}
    assert model["include_skills_usage_instructions"] == false
    assert model["supports_parallel_tool_calls"] == setup.model.supports_tools
    assert model["input_modalities"] == ["text"]
    assert model["upstream_model_id"] == setup.model.upstream_model_id
    assert model["supported_in_api"] == true
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/models"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.upstream_account_label == setup.identity.account_label
    assert is_nil(request.upstream_account_email)
    assert request.request_metadata["operation"] == "models"
    assert request.request_metadata["model_source"]["upstream_identity_id"] == setup.identity.id
  end

  test "GET /backend-api/codex/models records unique server correlation ids for repeated client request ids",
       %{conn: conn} do
    client_request_id = "duplicate-client-models-request-id"
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    first_conn =
      conn
      |> put_req_header("x-request-id", client_request_id)
      |> auth(setup)
      |> get("/backend-api/codex/models")

    second_conn =
      build_conn()
      |> put_req_header("x-request-id", client_request_id)
      |> auth(setup)
      |> get("/backend-api/codex/models")

    assert %{"models" => [_model]} = json_response(first_conn, 200)
    assert %{"models" => [_model]} = json_response(second_conn, 200)

    requests =
      Repo.all(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/models",
          order_by: [asc: request.admitted_at]
      )

    assert length(requests) == 2
    assert Enum.map(requests, & &1.correlation_id) |> Enum.uniq() |> length() == 2
    refute Enum.any?(requests, &(&1.correlation_id == client_request_id))
    assert Enum.all?(requests, &(&1.request_metadata["client_request_id"] == client_request_id))
  end

  test "POST /backend-api/codex/responses records unique server correlation ids for repeated client request ids",
       %{conn: conn} do
    client_request_id = "duplicate-client-responses-request-id"

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_duplicate_request_id",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream)

    first_conn =
      conn
      |> put_req_header("x-request-id", client_request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "first duplicate request id fixture"
      })

    second_conn =
      build_conn()
      |> put_req_header("x-request-id", client_request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "second duplicate request id fixture"
      })

    assert %{"id" => "resp_duplicate_request_id"} = json_response(first_conn, 200)
    assert %{"id" => "resp_duplicate_request_id"} = json_response(second_conn, 200)

    requests =
      Repo.all(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/responses",
          order_by: [asc: request.admitted_at]
      )

    assert length(requests) == 2
    assert Enum.map(requests, & &1.correlation_id) |> Enum.uniq() |> length() == 2
    refute Enum.any?(requests, &(&1.correlation_id == client_request_id))
    assert Enum.all?(requests, &(&1.request_metadata["client_request_id"] == client_request_id))
  end

  test "GET /backend-api/codex/v1/models routes through the alias path and keeps backend auth semantics",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-request-id", Ecto.UUID.generate())
      |> auth(setup)
      |> get("/backend-api/codex/v1/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["slug"] == setup.model.exposed_model_id
    assert model["supported_in_api"] == true
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/models"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "models"
    assert request.request_metadata["model_source"]["upstream_identity_id"] == setup.identity.id
  end

  test "backend Codex model metadata accepts typed endpoint options" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    request_options = RequestOptions.build(%{}, "/backend-api/codex/models", %{})

    assert {:ok, %{body: %{"models" => [_model]}}} =
             Metadata.serve_codex_models(auth, request_options)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/models"
    assert request.status == "succeeded"
  end

  test "GET /backend-api/codex/models keeps generic backend API-key auth semantics", %{
    conn: conn
  } do
    setup = paused_api_key_fixture()

    conn =
      conn
      |> auth(setup)
      |> get("/backend-api/codex/models")

    assert %{
             "error" => %{
               "code" => "api_key_paused",
               "message" => "api key is paused",
               "type" => "invalid_request_error"
             }
           } = json_response(conn, 401)

    assert Repo.aggregate(Request, :count, :id) == 0
    assert Repo.aggregate(Attempt, :count, :id) == 0
  end

  test "GET /backend-api/codex/models only exposes policy-authorized visible models", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    %{assignment: allowed_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Allowed visible upstream"
      })

    allowed_visible =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-backend-visible-allowed",
        upstream_model_id: "provider-gpt-backend-visible-allowed",
        display_name: "Backend Visible Allowed",
        metadata: %{"source_assignment_ids" => [allowed_assignment.id]}
      })

    %{assignment: hidden_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Backend policy hidden upstream"
      })

    hidden_by_policy =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-backend-policy-hidden",
        upstream_model_id: "provider-gpt-backend-policy-hidden",
        display_name: "Backend Policy Hidden",
        metadata: %{"source_assignment_ids" => [hidden_assignment.id]}
      })

    setup.api_key
    |> Ecto.Changeset.change(%{
      allowed_model_identifiers: [setup.model.exposed_model_id, allowed_visible.exposed_model_id]
    })
    |> Repo.update!()

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => models} = json_response(conn, 200)

    assert Enum.map(models, & &1["slug"]) |> Enum.sort() ==
             [setup.model.exposed_model_id, allowed_visible.exposed_model_id] |> Enum.sort()

    refute Enum.any?(models, &(&1["slug"] == hidden_by_policy.exposed_model_id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "GET /backend-api/codex/models logs the highest-plan model source account", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    assert {:ok, free_identity} =
             IdentityLifecycle.activate_upstream_identity_with_plan(
               setup.identity,
               %{
                 plan_family: "free",
                 plan_label: "free"
               }
             )

    %{identity: pro_identity, assignment: pro_assignment} =
      upstream_assignment_fixture(setup.pool, %{
        account_label: "Pro model source",
        plan_family: "pro",
        plan_label: "pro"
      })

    setup.model
    |> Ecto.Changeset.change(%{
      source_assignment_count: 2,
      metadata: %{"source_assignment_ids" => [setup.assignment.id, pro_assignment.id]}
    })
    |> Repo.update!()

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [_model]} = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/models"
    assert request.upstream_account_label == pro_identity.account_label
    assert is_nil(request.upstream_account_email)
    assert request.upstream_account_plan_family == "pro"
    assert request.upstream_account_plan_label == "pro"
    assert request.request_metadata["model_source"]["upstream_identity_id"] == pro_identity.id
    refute request.upstream_account_label == free_identity.account_label
  end

  test "GET /backend-api/codex/models preserves upstream image input metadata", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "supported_input_modalities" => ["text", "image"],
            "supports_image_detail_original" => true
          }
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["input_modalities"] == ["text", "image"]
    assert model["supports_image_detail_original"] == true
    assert FakeUpstream.count(upstream) == 0
  end

  test "POST /backend-api/codex/images/generations proxies authenticated JSON image requests and keeps metadata sanitized",
       %{conn: conn} do
    upstream_response = %{
      "created" => 1_717_171_717,
      "data" => [%{"b64_json" => "backend-image-generation-b64-sentinel"}]
    }

    upstream = start_upstream(FakeUpstream.json_response(upstream_response))
    setup = gateway_setup(upstream)
    prompt_sentinel = "backend-image-generation-prompt-sentinel-do-not-log"

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/images/generations", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => prompt_sentinel,
        "size" => "1024x1024"
      })

    assert json_response(conn, 200) == upstream_response

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/images/generations"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["prompt"] == prompt_sentinel
    assert captured.json["size"] == "1024x1024"

    request =
      Repo.one!(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/images/generations",
          order_by: [desc: request.admitted_at],
          limit: 1
      )

    assert request.endpoint == "/backend-api/codex/images/generations"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert get_in(request.request_metadata, ["routing", "route_class"]) in [nil, "proxy_http"]

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ prompt_sentinel
    refute metadata_text =~ "backend-image-generation-b64-sentinel"
  end

  test "POST /backend-api/codex/images/edits proxies authenticated JSON image edit requests and keeps metadata sanitized",
       %{conn: conn} do
    upstream_response = %{
      "created" => 1_818_181_818,
      "data" => [%{"b64_json" => "backend-image-edit-b64-sentinel"}]
    }

    upstream = start_upstream(FakeUpstream.json_response(upstream_response))
    setup = gateway_setup(upstream)
    prompt_sentinel = "backend-image-edit-prompt-sentinel-do-not-log"
    image_reference_sentinel = "https://example.com/backend-image-edit-source-sentinel.png"

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/images/edits", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => prompt_sentinel,
        "size" => "1024x1024",
        "images" => [%{"image_url" => image_reference_sentinel}]
      })

    assert json_response(conn, 200) == upstream_response

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == "POST"
    assert captured.path == "/backend-api/codex/images/edits"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["prompt"] == prompt_sentinel
    assert captured.json["size"] == "1024x1024"
    assert captured.json["images"] == [%{"image_url" => image_reference_sentinel}]

    request =
      Repo.one!(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/images/edits",
          order_by: [desc: request.admitted_at],
          limit: 1
      )

    assert request.endpoint == "/backend-api/codex/images/edits"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert get_in(request.request_metadata, ["routing", "route_class"]) in [nil, "proxy_http"]

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ prompt_sentinel
    refute metadata_text =~ image_reference_sentinel
    refute metadata_text =~ "backend-image-edit-b64-sentinel"
  end

  test "POST /backend-api/codex/images/generations requires a bearer token before upstream dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"created" => 1, "data" => []}))
    _setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/images/generations", %{
        "model" => "gpt-image-fixture",
        "prompt" => "unauthenticated backend image request",
        "size" => "1024x1024"
      })

    assert %{"error" => %{"code" => "api_key_missing"}} = json_response(conn, 401)
    assert FakeUpstream.count(upstream) == 0
  end

  test "GET /backend-api/codex/models passes through guarded upstream model metadata fields", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "available_in_plans" => ["pro", "team"],
            "default_service_tier" => "auto",
            "minimal_client_version" => %{
              "ios" => "1.2.3",
              "web" => ["1.2.0", "1.2.1"]
            },
            "model_messages" => %{
              "instructions_template" => "Use {{PERSONALITY}}.\nReturn concise answers.",
              "instructions_variables" => %{
                "personality_default" => "default voice",
                "personality_friendly" => "friendly voice",
                "personality_pragmatic" => "pragmatic voice"
              }
            },
            "include_skills_usage_instructions" => true,
            "prefer_websockets" => true,
            "reasoning_summary_format" => "json",
            "supported_reasoning_levels" => ["max", "low", "focused"],
            "default_reasoning_level" => "focused",
            "comp_hash" => " comp-fixture-hash ",
            "tool_mode" => "code_mode_only",
            "use_responses_lite" => true,
            "source_assignment_ids" => ["upstream-source-id"],
            "source_assignment_models" => %{"upstream-source-id" => %{"id" => "provider"}},
            "raw_model_listing" => %{"id" => "provider"}
          },
          "default_service_tier" => "priority"
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["available_in_plans"] == ["pro", "team"]
    assert model["default_service_tier"] == "priority"

    assert model["minimal_client_version"] == %{
             "ios" => "1.2.3",
             "web" => ["1.2.0", "1.2.1"]
           }

    assert model["model_messages"] == %{
             "instructions_template" => "Use {{PERSONALITY}}.\nReturn concise answers.",
             "instructions_variables" => %{
               "personality_default" => "default voice",
               "personality_friendly" => "friendly voice",
               "personality_pragmatic" => "pragmatic voice"
             }
           }

    assert model["prefer_websockets"] == true
    assert model["reasoning_summary_format"] == "json"

    assert model["supported_reasoning_levels"] == [
             %{"description" => "max", "effort" => "max"},
             %{"description" => "low", "effort" => "low"},
             %{"description" => "focused", "effort" => "focused"}
           ]

    assert model["default_reasoning_level"] == "focused"
    assert model["comp_hash"] == "comp-fixture-hash"
    assert model["tool_mode"] == "code_mode_only"
    assert model["use_responses_lite"] == true
    assert model["include_skills_usage_instructions"] == true
    refute Map.has_key?(model, "upstream_model")
    refute Map.has_key?(model, "source_assignment_ids")
    refute Map.has_key?(model, "source_assignment_models")
    refute Map.has_key?(model, "raw_model_listing")
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "upstream-source-id"
    refute metadata_text =~ "source_assignment_models"
    refute metadata_text =~ setup.raw_key
  end

  test "GET /backend-api/codex/models neutralizes missing and malformed guarded metadata", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "available_in_plans" => "pro",
            "default_service_tier" => 123,
            "minimal_client_version" => nil,
            "model_messages" => ["unexpected"],
            "prefer_websockets" => "true",
            "include_skills_usage_instructions" => "true",
            "reasoning_summary_format" => %{"format" => "json"},
            "comp_hash" => ["unexpected"],
            "tool_mode" => "future_mode"
          }
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["available_in_plans"] == []
    assert is_nil(model["default_service_tier"])
    assert is_nil(model["minimal_client_version"])
    assert is_nil(model["model_messages"])
    assert model["prefer_websockets"] == false
    assert model["include_skills_usage_instructions"] == false
    assert is_nil(model["reasoning_summary_format"])
    refute Map.has_key?(model, "comp_hash")
    assert is_nil(model["tool_mode"])
    assert FakeUpstream.count(upstream) == 0
  end

  test "GET /backend-api/codex/models applies context window overrides", %{conn: conn} do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        model_context_window_overrides: %{"gpt-test-model" => 128_000}
      }
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "context_window" => 272_000,
            "max_context_window" => 272_000,
            "auto_compact_token_limit" => nil
          }
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["context_window"] == 128_000
    assert model["max_context_window"] == 128_000
    assert model["auto_compact_token_limit"] == 115_200
  end

  test "GET /backend-api/codex/models derives short context window from pricing", %{conn: conn} do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{model_context_window_overrides: %{}}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "context_window" => 272_000,
            "max_context_window" => 272_000,
            "auto_compact_token_limit" => nil
          }
        }
      )

    pricing_snapshot!(setup.model, %{config: pricing_config(%{"price_bucket" => "short_context"})})

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["context_window"] == 121_600
    assert model["max_context_window"] == 128_000
    assert model["auto_compact_token_limit"] == 109_440
  end

  test "GET /backend-api/codex/models promotes long context window from pricing", %{conn: conn} do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{model_context_window_overrides: %{}}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "context_window" => 272_000,
            "max_context_window" => 1_000_000,
            "auto_compact_token_limit" => nil
          }
        }
      )

    pricing_snapshot!(setup.model, %{config: pricing_config(%{"price_bucket" => "long_context"})})

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["context_window"] == 950_000
    assert model["max_context_window"] == 1_000_000
    assert model["auto_compact_token_limit"] == 855_000
  end

  test "GET /backend-api/codex/models exposes service tiers for fast mode", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "additional_speed_tiers" => ["fast"],
            "service_tiers" => [
              %{
                "id" => "priority",
                "name" => "Fast",
                "description" => "1.5x speed, increased usage"
              },
              %{
                "id" => "latency_preview",
                "name" => "Latency preview",
                "description" => "Preview routing tier advertised by the upstream catalog."
              }
            ]
          }
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["additional_speed_tiers"] == ["fast"]

    assert model["service_tiers"] == [
             %{
               "id" => "priority",
               "name" => "Fast",
               "description" => "1.5x speed, increased usage"
             },
             %{
               "id" => "latency_preview",
               "name" => "Latency preview",
               "description" => "Preview routing tier advertised by the upstream catalog."
             }
           ]

    assert FakeUpstream.count(upstream) == 0
  end

  test "POST /backend-api/codex/responses routes requested service tiers to compatible assignments",
       %{conn: conn} do
    free_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_free_tier",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    pro_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_latency_preview_tier",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })
      )

    setup = gateway_setup(free_upstream)

    pro =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_latency_preview_tier",
        metadata: %{"base_url" => FakeUpstream.url(pro_upstream)},
        access_token: "latency-preview-tier-token"
      })

    prime_routing_quota!(pro.identity)

    free_model = %{
      "id" => setup.model.upstream_model_id,
      "service_tiers" => [],
      "capabilities" => %{"responses" => true, "streaming" => true}
    }

    pro_model = %{
      "id" => setup.model.upstream_model_id,
      "service_tiers" => [
        %{
          "id" => "latency_preview",
          "name" => "Latency preview",
          "description" => "Preview routing tier advertised by the upstream catalog."
        }
      ],
      "capabilities" => %{"responses" => true, "streaming" => true}
    }

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id, pro.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => free_model,
            pro.assignment.id => pro_model
          },
          "upstream_model" => pro_model
        }
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)

    default_conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "use default mode"
      })

    assert %{"id" => default_response_id} = json_response(default_conn, 200)
    assert default_response_id in ["resp_free_tier", "resp_latency_preview_tier"]

    free_count_before_latency_preview = FakeUpstream.count(free_upstream)
    pro_count_before_latency_preview = FakeUpstream.count(pro_upstream)
    assert free_count_before_latency_preview + pro_count_before_latency_preview == 1

    conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "use latency preview mode",
        "service_tier" => "latency_preview"
      })

    assert %{"id" => "resp_latency_preview_tier"} = json_response(conn, 200)
    assert FakeUpstream.count(free_upstream) == free_count_before_latency_preview
    assert FakeUpstream.count(pro_upstream) == pro_count_before_latency_preview + 1
    captured = pro_upstream |> FakeUpstream.requests() |> List.last()
    assert captured.json["service_tier"] == "latency_preview"
  end

  test "POST /backend-api/codex/v1/responses proxies to canonical backend responses and records the canonical endpoint",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_v1_alias",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic alias response request"
      })

    assert %{"id" => "resp_backend_v1_alias"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"
  end

  test "POST /backend-api/codex/v1/responses preserves request-shaped additional_tools input items",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_v1_additional_tools",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    additional_tools_item = additional_tools_item()

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{"role" => "user", "content" => "synthetic alias response input"},
          additional_tools_item
        ]
      })

    assert %{"id" => "resp_backend_v1_additional_tools"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured.json, "tools")
    refute Map.has_key?(captured.json, "tool_choice")

    assert captured.json["input"] == [
             %{"role" => "user", "content" => "synthetic alias response input"},
             additional_tools_item
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "synthetic alias response input"
    refute metadata_text =~ "lookup_additional_fixture"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /backend-api/codex/responses keeps disabled request compression as passthrough",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_compression_disabled",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    original_output = compression_log_fixture("disabled backend sentinel")

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_backend_compression_disabled",
            "output" => original_output
          }
        ]
      })

    assert %{"id" => "resp_backend_compression_disabled"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["input"] |> List.first() |> Map.fetch!("output") == original_output

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert get_in(attempt.response_metadata, ["payload_compression", "status"]) == "disabled"
    assert get_in(attempt.response_metadata, ["payload_compression", "reason"]) == "pool_disabled"
  end

  test "POST /backend-api/codex/responses skips lossy streaming local shell tool output",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_backend_stream_compressed",
               "status" => "completed",
               "usage" => %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream, supported_compression_model_opts())
    enable_request_compression!(setup.pool)
    omitted_sentinel = "backend streaming omitted sentinel"
    original_output = compression_log_fixture(omitted_sentinel)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "stream" => true,
        "input" => [
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_backend_stream_compressed",
            "output" => original_output
          }
        ]
      })

    assert conn.resp_body =~ "resp_backend_stream_compressed"
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    forwarded_output = captured.json["input"] |> List.first() |> Map.fetch!("output")
    assert forwarded_output == original_output

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert_skipped_payload_metadata!(
      attempt,
      "proxy_stream",
      "http_sse",
      "lossy_unrecoverable_tool_output"
    )

    refute inspect(attempt.response_metadata["payload_compression"]) =~ omitted_sentinel

    refute inspect(attempt.response_metadata["payload_compression"]) =~
             "call_backend_stream_compressed"
  end

  test "POST /backend-api/codex/v1/responses compresses eligible alias tool output",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_alias_compressed",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, supported_compression_model_opts())
    enable_request_compression!(setup.pool)
    original_rows = compression_rows_fixture()
    original_output = Jason.encode!(original_rows, pretty: true)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_backend_alias_compressed",
            "output" => original_output
          }
        ]
      })

    assert %{"id" => "resp_backend_alias_compressed"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    compressed_output = captured.json["input"] |> List.first() |> Map.fetch!("output")
    assert compressed_output != original_output
    assert Jason.decode!(compressed_output) == original_rows

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_json"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert_compressed_payload_metadata!(attempt, "proxy_http", "http_json", "json_array_lossless")
  end

  @tag :installation_id_metadata
  test "POST /backend-api/codex/responses forwards only approved lineage metadata headers",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_lineage_headers",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    metadata = lineage_metadata_fixture("forked-thread-task4-canonical")

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/responses",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic lineage forwarding request"
        },
        lineage_request_headers(metadata)
      )

    assert %{"id" => "resp_backend_lineage_headers"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert_approved_lineage_headers_forwarded!(captured, metadata)
    assert_disallowed_client_headers_not_forwarded!(captured, setup)
    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses preserves canonical turn metadata in client_metadata",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_client_metadata",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    metadata = client_metadata_fixture("http")

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic client metadata request",
        "client_metadata" => metadata.client_metadata
      })

    assert %{"id" => "resp_backend_client_metadata"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["client_metadata"] == metadata.client_metadata
    assert captured.json["client_metadata"]["x-codex-turn-metadata"] == metadata.turn_metadata

    assert_client_metadata_not_persisted!(setup, metadata)
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses forwards and relays x-codex-turn-state for backend continuity",
       %{conn: conn} do
    request_turn_state = "backend-http-turn-state-#{System.unique_integer([:positive])}"
    response_turn_state = "upstream-http-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "id" => "resp_backend_turn_state",
            "object" => "response",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
          },
          [{"x-codex-turn-state", response_turn_state}]
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic turn-state forwarding request"
      })

    assert %{"id" => "resp_backend_turn_state"} = json_response(conn, 200)
    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses relays x-codex-turn-state on upstream status failures",
       %{conn: conn} do
    request_turn_state = "backend-http-failure-turn-state-#{System.unique_integer([:positive])}"

    response_turn_state =
      "upstream-http-failure-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "error" => %{
              "code" => "rate_limit_exceeded",
              "message" => "synthetic upstream demand failure"
            }
          },
          [{"x-codex-turn-state", response_turn_state}],
          429
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic turn-state failure relay request"
      })

    assert %{"error" => %{"code" => "rate_limit_exceeded"}} = json_response(conn, 429)
    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_status"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == 429

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  test "POST /backend-api/codex/responses rejects oversized upstream response bodies metadata-only",
       %{conn: conn} do
    sentinel = "raw-oversized-upstream-response-sentinel"

    oversized_body =
      ~s({"sentinel":"#{sentinel}","padding":") <>
        String.duplicate("x", BoundedResponseBody.default_max_bytes()) <> ~s("})

    upstream =
      start_upstream(
        FakeUpstream.raw_response(oversized_body,
          headers: [
            {"content-type", "application/json"},
            {"content-length", to_string(byte_size(oversized_body))}
          ]
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic oversized upstream response request"
      })

    assert %{
             "error" => %{
               "code" => "upstream_response_too_large",
               "message" => "upstream response body exceeded maximum allowed size"
             }
           } = response = json_response(conn, 502)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "failed"
    assert request.response_status_code == 502
    assert request.last_error_code == "upstream_response_too_large"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == 502
    assert attempt.network_error_code == "upstream_response_too_large"
    assert attempt.error_message == "upstream response body exceeded maximum allowed size"
    assert attempt.response_metadata["error_kind"] == "upstream_response_too_large"
    assert attempt.response_metadata["status_code"] == 200
    assert attempt.response_metadata["response_body_limit_exceeded"] == true

    assert attempt.response_metadata["response_body_limit_bytes"] ==
             BoundedResponseBody.default_max_bytes()

    assert attempt.response_metadata["response_body_content_length"] == byte_size(oversized_body)
    assert is_integer(attempt.response_metadata["response_body_seen_bytes"])

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.reason_code == "upstream_response_too_large"

    refute inspect(response) =~ sentinel
    refute inspect(request.request_metadata) =~ sentinel
    refute inspect(attempt.response_metadata) =~ sentinel
    refute inspect(RequestLogs.list(setup.pool.id, limit: 10).items) =~ sentinel
  end

  @tag :client_metadata
  test "POST /v1/responses does not forward or relay backend x-codex-turn-state",
       %{conn: conn} do
    request_turn_state = "public-v1-request-turn-state-#{System.unique_integer([:positive])}"
    response_turn_state = "public-v1-response-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "id" => "resp_public_turn_state_boundary",
            "object" => "response",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
          },
          [{"x-codex-turn-state", response_turn_state}]
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic public turn-state boundary request"
      })

    assert %{"id" => "resp_public_turn_state_boundary"} = json_response(conn, 200)
    assert get_resp_header(conn, "x-codex-turn-state") == []

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(Map.new(captured.headers), "x-codex-turn-state")

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  test "POST /v1/responses terminal-missing SSE close does not poison route health",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.created",
             %{
               "type" => "response.created",
               "response" => %{"id" => "resp_public_terminal_missing"}
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic public terminal-missing stream request",
        "stream" => true
      })

    assert conn.status == 200
    assert conn.resp_body =~ "event: response.failed\n"
    assert conn.resp_body =~ ~s("code":"upstream_stream_error")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == 200
    assert attempt.network_error_code == "upstream_stream_error"
    assert attempt.response_metadata["error_kind"] == "stream_interrupted"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "POST /backend-api/codex/responses sends trusted Responses Lite marker from selected model metadata",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_responses_lite_marker",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup =
      upstream
      |> gateway_setup()
      |> put_setup_model_source_metadata!(%{"use_responses_lite" => true})

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/responses",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic Responses Lite marker request"
        },
        [{"x-openai-internal-unapproved", "client-internal-spoof"}]
      )

    assert %{"id" => "resp_backend_responses_lite_marker"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    assert captured_headers["x-openai-internal-codex-responses-lite"] == "true"
    refute Map.has_key?(captured_headers, "x-openai-internal-unapproved")
  end

  test "POST /backend-api/codex/responses ignores client-spoofed Responses Lite marker for non-Lite models",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_responses_lite_spoof_ignored",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/responses",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic Responses Lite spoof request"
        },
        [
          {"x-openai-internal-codex-responses-lite", "true"},
          {"x-openai-internal-unapproved", "client-internal-spoof"}
        ]
      )

    assert %{"id" => "resp_backend_responses_lite_spoof_ignored"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    refute Map.has_key?(captured_headers, "x-openai-internal-codex-responses-lite")
    refute Map.has_key?(captured_headers, "x-openai-internal-unapproved")
  end

  @tag :installation_id_metadata
  test "POST /backend-api/codex/v1/responses forwards approved lineage metadata with trusted Codex identity",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_v1_lineage_headers",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    metadata = lineage_metadata_fixture("forked-thread-task4-alias")

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/v1/responses",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic alias lineage forwarding request"
        },
        lineage_request_headers(metadata)
      )

    assert %{"id" => "resp_backend_v1_lineage_headers"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert_approved_lineage_headers_forwarded!(captured, metadata)
    assert_disallowed_client_headers_not_forwarded!(captured, setup)
    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  test "POST /backend-api/codex/v1/chat/completions does not forward lineage metadata headers",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_backend_v1_chat_lineage_boundary",
               "status" => "completed",
               "model" => "provider-gpt-test-model",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "alias chat answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    metadata = lineage_metadata_fixture("forked-thread-task4-chat")

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/v1/chat/completions",
        %{
          "model" => setup.model.exposed_model_id,
          "messages" => [%{"role" => "user", "content" => "Synthetic user"}]
        },
        lineage_request_headers(metadata)
      )

    assert %{"id" => "resp_backend_v1_chat_lineage_boundary"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    captured_headers = Map.new(captured.headers)

    Enum.each(approved_lineage_header_names(), fn header_name ->
      refute Map.has_key?(captured_headers, header_name)
    end)

    assert_disallowed_client_headers_not_forwarded!(captured, setup)
    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  test "POST /backend-api/codex/responses keeps lineage metadata out of upstream error surfaces",
       %{conn: conn} do
    metadata = lineage_metadata_fixture("forked-thread-task4-error")

    upstream =
      start_upstream(
        FakeUpstream.http_500_json_error(%{
          "error" => %{
            "code" => "server_error",
            "message" => "synthetic upstream failure"
          }
        })
      )

    setup = gateway_setup(upstream)

    logs =
      capture_log(fn ->
        conn =
          conn
          |> auth(setup)
          |> post_json_runtime_with_headers(
            "/backend-api/codex/responses",
            %{
              "model" => setup.model.exposed_model_id,
              "input" => "synthetic lineage upstream error request"
            },
            lineage_request_headers(metadata)
          )

        response = json_response(conn, 500)
        assert %{"error" => %{"code" => "server_error"}} = response
        refute_lineage_text!(inspect(response), metadata)
      end)

    refute_lineage_text!(logs, metadata)

    assert [captured] = FakeUpstream.requests(upstream)
    assert_approved_lineage_headers_forwarded!(captured, metadata)
    assert_disallowed_client_headers_not_forwarded!(captured, setup)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "upstream_status"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"

    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  test "POST /backend-api/codex/v1/chat/completions returns OpenAI chat shape through the canonical backend responses path",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_backend_v1_chat_alias",
               "status" => "completed",
               "model" => "provider-gpt-test-model",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "alias chat answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "messages" => [
          %{"role" => "system", "content" => "Synthetic system"},
          %{"role" => "user", "content" => "Synthetic user"}
        ]
      })

    assert %{
             "id" => "resp_backend_v1_chat_alias",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "alias chat answer"},
                 "finish_reason" => "stop"
               }
             ]
           } = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"
  end

  test "POST /backend-api/codex/responses keeps instruction-role input messages backend-native",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_native_instruction_roles",
          "object" => "response",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "instructions" => "synthetic backend top-level instruction",
        "input" => [
          %{"role" => "developer", "content" => "synthetic backend developer input"},
          %{
            "role" => "system",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic backend system input"}
            ]
          },
          %{"role" => "user", "content" => "synthetic backend user input"}
        ]
      })

    assert %{"id" => "resp_backend_native_instruction_roles"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["instructions"] == "synthetic backend top-level instruction"

    assert captured.json["input"] == [
             %{"role" => "developer", "content" => "synthetic backend developer input"},
             %{
               "role" => "system",
               "content" => [
                 %{"type" => "input_text", "text" => "synthetic backend system input"}
               ]
             },
             %{"role" => "user", "content" => "synthetic backend user input"}
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    metadata_text = inspect({request.request_metadata, RequestLogs.list(setup.pool)})
    refute metadata_text =~ "synthetic backend top-level instruction"
    refute metadata_text =~ "synthetic backend developer input"
    refute metadata_text =~ "synthetic backend system input"
    refute metadata_text =~ "synthetic backend user input"
  end

  test "POST /backend-api/codex/v1/chat/completions falls back to input without executable tool merging",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_v1_chat_fallback",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "fallback alias answer"}]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    additional_tools_item = additional_tools_item()

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "messages" => [],
        "input" => [
          %{"role" => "user", "content" => "synthetic alias chat fallback input"},
          additional_tools_item
        ]
      })

    assert %{
             "id" => "resp_backend_v1_chat_fallback",
             "object" => "chat.completion",
             "choices" => [
               %{
                 "message" => %{"role" => "assistant", "content" => "fallback alias answer"},
                 "finish_reason" => "stop"
               }
             ]
           } = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured.json, "tools")
    refute Map.has_key?(captured.json, "tool_choice")

    assert captured.json["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "synthetic alias chat fallback input"}
               ]
             },
             additional_tools_item
           ]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.status == "succeeded"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "synthetic alias chat fallback input"
    refute metadata_text =~ "lookup_additional_fixture"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /backend-api/codex/responses omits neutral service tiers at the upstream boundary",
       %{conn: _conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_neutral_tier",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    prompt_marker = "neutral-tier-prompt-do-not-log"

    payloads = [
      %{
        "model" => setup.model.exposed_model_id,
        "input" => "#{prompt_marker}-omitted"
      },
      %{
        "model" => setup.model.exposed_model_id,
        "input" => "#{prompt_marker}-default",
        "service_tier" => "default"
      },
      %{
        "model" => setup.model.exposed_model_id,
        "input" => "#{prompt_marker}-auto",
        "service_tier" => "auto"
      }
    ]

    for payload <- payloads do
      conn = build_conn() |> auth(setup) |> post("/backend-api/codex/responses", payload)
      assert %{"id" => "resp_neutral_tier"} = json_response(conn, 200)
    end

    requests = FakeUpstream.requests(upstream)
    assert length(requests) == 3
    assert Enum.all?(requests, &(not Map.has_key?(&1.json, "service_tier")))

    request_rows =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
        )
      )

    assert Enum.map(
             request_rows,
             &get_in(&1.request_metadata, ["pricing", "requested_service_tier"])
           ) == [
             nil,
             "default",
             "auto"
           ]

    metadata_text = inspect(Enum.map(request_rows, & &1.request_metadata))
    refute metadata_text =~ prompt_marker
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"
  end

  test "POST /backend-api/codex/responses preserves concrete tiers and applies API-key policy",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_policy_tier",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "service_tiers" => [
              %{
                "id" => "priority",
                "name" => "Priority",
                "description" => "Priority processing for synthetic tests."
              }
            ]
          }
        }
      )

    setup.model
    |> Ecto.Changeset.change(%{
      metadata:
        Map.put(setup.model.metadata, "source_assignment_models", %{
          setup.assignment.id => setup.model.metadata["upstream_model"]
        })
    })
    |> Repo.update!()

    priority_payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "concrete tier prompt should not log",
      "service_tier" => "priority"
    }

    conn = conn |> auth(setup) |> post("/backend-api/codex/responses", priority_payload)
    assert %{"id" => "resp_policy_tier"} = json_response(conn, 200)
    assert [priority_request] = FakeUpstream.requests(upstream)
    assert priority_request.json["service_tier"] == "priority"

    setup.api_key
    |> Ecto.Changeset.change(%{enforced_service_tier: "default"})
    |> Repo.update!()

    default_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", priority_payload)

    assert %{"id" => "resp_policy_tier"} = json_response(default_conn, 200)
    default_request = upstream |> FakeUpstream.requests() |> List.last()
    refute Map.has_key?(default_request.json, "service_tier")

    setup.api_key
    |> Ecto.Changeset.change(%{enforced_service_tier: "priority"})
    |> Repo.update!()

    enforced_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "enforced tier prompt should not log",
        "service_tier" => "default"
      })

    assert %{"id" => "resp_policy_tier"} = json_response(enforced_conn, 200)
    enforced_request = upstream |> FakeUpstream.requests() |> List.last()
    assert enforced_request.json["service_tier"] == "priority"

    request_rows =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
        )
      )

    assert Enum.map(
             request_rows,
             &get_in(&1.request_metadata, ["pricing", "requested_service_tier"])
           ) == [
             "priority",
             "default",
             "priority"
           ]

    metadata_text = inspect(Enum.map(request_rows, & &1.request_metadata))
    refute metadata_text =~ "concrete tier prompt should not log"
    refute metadata_text =~ "enforced tier prompt should not log"
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"
  end

  test "POST /backend-api/codex/responses skips assignments without response capability",
       %{conn: conn} do
    incompatible_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_incompatible",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    compatible_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_compatible",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })
      )

    setup = gateway_setup(incompatible_upstream)

    compatible =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_response_capable",
        metadata: %{"base_url" => FakeUpstream.url(compatible_upstream)},
        access_token: "response-capable-token"
      })

    prime_routing_quota!(compatible.identity)

    incompatible_model = %{
      "id" => setup.model.upstream_model_id,
      "capabilities" => %{"responses" => false, "streaming" => true}
    }

    compatible_model = %{
      "id" => setup.model.upstream_model_id,
      "capabilities" => %{"responses" => true, "streaming" => true}
    }

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id, compatible.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => incompatible_model,
            compatible.assignment.id => compatible_model
          },
          "upstream_model" => compatible_model
        }
      })
      |> Repo.update!()

    setup = Map.put(setup, :model, model)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "use responses"
      })

    assert %{"id" => "resp_compatible"} = json_response(conn, 200)
    assert FakeUpstream.requests(incompatible_upstream) == []
    assert [_captured] = FakeUpstream.requests(compatible_upstream)
  end

  test "POST /backend-api/codex/responses accepts sparse real Codex model metadata", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_sparse_metadata",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })
      )

    setup = gateway_setup(upstream)

    sparse_model = %{
      "id" => setup.model.upstream_model_id,
      "capabilities" => %{},
      "input_modalities" => ["text", "image"],
      "prefer_websockets" => true,
      "supports_parallel_tool_calls" => true,
      "supported_reasoning_levels" => ["low", "medium", "high", "xhigh"]
    }

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{setup.assignment.id => sparse_model},
          "upstream_model" => sparse_model
        }
      })
      |> Repo.update!()

    conn =
      conn
      |> auth(%{setup | model: model})
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "use sparse real metadata",
        "reasoning" => %{},
        "service_tier" => "default",
        "stream" => true,
        "tools" => []
      })

    assert %{"id" => "resp_sparse_metadata"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(captured.json, "service_tier")
  end

  test "GET /backend-api/codex/models keeps explicit top-level image metadata over nested upstream overrides",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true,
          "upstream_model" => %{
            "supported_input_modalities" => ["text"],
            "supports_image_detail_original" => false
          }
        }
      )

    conn = conn |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [model]} = json_response(conn, 200)
    assert model["input_modalities"] == ["text", "image"]
    assert model["supports_image_detail_original"] == true
    assert FakeUpstream.count(upstream) == 0
  end

  test "POST /backend-api/codex/responses accounts local endpoint and forwards upstream backend responses",
       %{
         conn: conn
       } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hello",
        "max_output_tokens" => 128,
        "prompt_cache_retention" => "24h",
        "safety_identifier" => "safe_fixture",
        "temperature" => 0.2,
        "top_p" => 0.9
      })

    assert %{"id" => "resp_backend"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured.json, "max_output_tokens")
    refute Map.has_key?(captured.json, "prompt_cache_retention")
    refute Map.has_key?(captured.json, "safety_identifier")
    refute Map.has_key?(captured.json, "temperature")
    refute Map.has_key?(captured.json, "top_p")
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
  end

  test "POST /backend-api/codex/responses uses session-id for local continuity without forwarding it",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_session_id_continuity",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    session_header = "session-id-continuity-fixture"

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-session-id", " ")
      |> put_req_header("session-id", session_header)
      |> put_req_header("x-session-id", "lower-priority-session-id-continuity-fixture")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "session id continuity fixture"
      })

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "session id continuity reuse fixture"
      })

    assert %{"id" => "resp_session_id_continuity"} = json_response(first_conn, 200)
    assert %{"id" => "resp_session_id_continuity"} = json_response(second_conn, 200)

    assert %CodexSession{} = session = Repo.get_by(CodexSession, session_key: session_header)

    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
      )

    assert length(requests) == 2
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_id"] == session.id))
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_key"] == session_header))

    assert [first_upstream_request, second_upstream_request] = FakeUpstream.requests(upstream)

    for captured <- [first_upstream_request, second_upstream_request] do
      captured_headers = Map.new(captured.headers)

      refute Map.has_key?(captured_headers, "session-id")
      refute Map.has_key?(captured_headers, "x-session-id")
      refute Map.has_key?(captured_headers, "x-session-affinity")
    end
  end

  test "POST /backend-api/codex/responses uses x-session-id for local continuity without forwarding it",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_x_session_id_continuity",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    session_header = "x-session-id-continuity-fixture"

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", session_header)
      |> put_req_header("x-session-affinity", "lower-priority-affinity-fixture")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "x-session-id continuity fixture"
      })

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("x-session-id", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "x-session-id continuity reuse fixture"
      })

    assert %{"id" => "resp_x_session_id_continuity"} = json_response(first_conn, 200)
    assert %{"id" => "resp_x_session_id_continuity"} = json_response(second_conn, 200)

    assert %CodexSession{} = session = Repo.get_by(CodexSession, session_key: session_header)
    refute Repo.get_by(CodexSession, session_key: "lower-priority-affinity-fixture")

    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
      )

    assert length(requests) == 2
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_id"] == session.id))
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_key"] == session_header))

    assert [first_upstream_request, second_upstream_request] = FakeUpstream.requests(upstream)

    for captured <- [first_upstream_request, second_upstream_request] do
      captured_headers = Map.new(captured.headers)

      refute Map.has_key?(captured_headers, "session-id")
      refute Map.has_key?(captured_headers, "x-session-id")
      refute Map.has_key?(captured_headers, "x-session-affinity")
    end
  end

  test "POST /backend-api/codex/responses uses x-session-affinity for local continuity without forwarding it",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_session_affinity_continuity",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    session_header = "session-affinity-continuity-fixture"

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-affinity", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "session affinity continuity fixture"
      })

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("x-session-affinity", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "session affinity continuity reuse fixture"
      })

    assert %{"id" => "resp_session_affinity_continuity"} = json_response(first_conn, 200)
    assert %{"id" => "resp_session_affinity_continuity"} = json_response(second_conn, 200)

    assert %CodexSession{} = session = Repo.get_by(CodexSession, session_key: session_header)

    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
      )

    assert length(requests) == 2
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_id"] == session.id))
    assert Enum.all?(requests, &(&1.request_metadata["codex_session_key"] == session_header))

    assert [first_upstream_request, second_upstream_request] = FakeUpstream.requests(upstream)

    for captured <- [first_upstream_request, second_upstream_request] do
      captured_headers = Map.new(captured.headers)

      refute Map.has_key?(captured_headers, "session-id")
      refute Map.has_key?(captured_headers, "x-session-id")
      refute Map.has_key?(captured_headers, "x-session-affinity")
    end
  end

  test "POST /backend-api/codex/responses prefers x-codex-window-id over broader continuity headers",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_header_precedence",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    raw_window_id = "window-session-wins-fixture"
    expected_session_key = hashed_window_session_key(raw_window_id)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-window-id", raw_window_id)
      |> put_req_header("x-codex-session-id", "codex-session-lower-priority-fixture")
      |> put_req_header("session-id", "session-id-lower-priority-fixture")
      |> put_req_header("x-session-id", "x-session-id-lower-priority-fixture")
      |> put_req_header("x-session-affinity", "session-affinity-lower-priority-fixture")
      |> put_req_header("session_id", "session-underscore-lower-priority-fixture")
      |> put_req_header("x-codex-conversation-id", "conversation-lower-priority-fixture")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "header precedence continuity fixture"
      })

    assert %{"id" => "resp_header_precedence"} = json_response(conn, 200)

    assert %CodexSession{} =
             session =
             Repo.get_by(CodexSession, session_key: expected_session_key)

    refute Repo.get_by(CodexSession, session_key: "codex-session-lower-priority-fixture")
    refute Repo.get_by(CodexSession, session_key: "session-id-lower-priority-fixture")
    refute Repo.get_by(CodexSession, session_key: "x-session-id-lower-priority-fixture")
    refute Repo.get_by(CodexSession, session_key: "session-affinity-lower-priority-fixture")
    refute Repo.get_by(CodexSession, session_key: "session-underscore-lower-priority-fixture")
    refute Repo.get_by(CodexSession, session_key: "conversation-lower-priority-fixture")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.request_metadata["codex_session_id"] == session.id
    assert request.request_metadata["codex_session_key"] == expected_session_key

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    refute Map.has_key?(captured_headers, "session-id")
    refute Map.has_key?(captured_headers, "x-session-id")
    refute Map.has_key?(captured_headers, "x-session-affinity")
  end

  test "backend control-plane proxy routes are absent before auth, parsing, or upstream dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    for {method, path, content_type} <- pruned_control_plane_requests() do
      conn =
        conn
        |> recycle()
        |> auth(setup)
        |> dispatch_pruned_control_plane_request(method, path, content_type)

      assert html_response(conn, 404) =~ "Not Found"
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0

    assert Repo.aggregate(Attempt, :count, :id) == 0
  end

  test "POST /backend-api/codex/responses rejects malformed JSON after auth before upstream dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post_raw_runtime("/backend-api/codex/responses", ~s({"model":), "application/json")

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "request body must be valid JSON"
             }
           } = json_response(conn, 400)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
  end

  test "POST /backend-api/codex/responses records HTTP latency after upstream response", %{
    conn: conn
  } do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
      )

    setup = gateway_setup(upstream)

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(CodexPooler.Repo, parent, self())

        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "hello"
        })
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    conn = Task.await(task, 1_000)

    assert %{"late" => true} = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert is_integer(attempt.latency_ms)
    assert attempt.latency_ms >= 0
  end

  test "POST /backend-api/codex/responses normalizes assignment base URLs ending in backend-api",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_normalized_base_url",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    base_url = FakeUpstream.url(upstream) <> "/backend-api"

    assignment =
      setup.assignment
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    setup = %{setup | assignment: assignment}

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hello"
      })

    assert %{"id" => "resp_normalized_base_url"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
  end

  test "POST /backend-api/codex/responses finalizes reservation on upstream transport error",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_transport_error_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)
    closed_base_url = "http://127.0.0.1:#{port}"

    assert {:ok, _identity} =
             IdentityLifecycle.update_upstream_identity(setup.identity, %{
               metadata: %{"base_url" => closed_base_url}
             })

    assert {:ok, _assignment} =
             PoolAssignments.update_pool_assignment(setup.assignment, %{
               metadata: %{"base_url" => closed_base_url}
             })

    logs =
      capture_log(fn ->
        conn =
          conn
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "sensitive transport body"
          })

        public_payload = json_response(conn, 502)

        assert %{"error" => %{"code" => "upstream_request_failed", "message" => message}} =
                 public_payload

        assert message == "upstream request failed"
        refute inspect(public_payload) =~ "transport_failure"
        refute inspect(public_payload) =~ "Req.TransportError"
      end)

    assert logs =~ "gateway upstream transport failed"
    assert logs =~ "endpoint=/backend-api/codex/responses"
    assert logs =~ "upstream_identity_id=#{setup.identity.id}"
    assert logs =~ "pool_upstream_assignment_id=#{setup.assignment.id}"
    assert logs =~ "exception="
    assert logs =~ "reason="
    refute logs =~ "sensitive transport body"
    refute logs =~ "upstream-token"
    refute logs =~ "authorization"
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_json"
    assert request.status == "failed"
    assert request.response_status_code == 502
    assert request.last_error_code == "upstream_network_error"
    refute inspect(request.request_metadata) =~ "sensitive transport body"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_network_error"
    assert attempt.usage_status == "usage_unknown"
    assert attempt.response_metadata["error_code"] == "upstream_network_error"

    assert_safe_transport_failure_metadata!(attempt, [
      "sensitive transport body",
      "upstream-token",
      "authorization"
    ])

    refute inspect(attempt.response_metadata) =~ "sensitive transport body"
  end

  test "POST /backend-api/codex/responses finalizes reservation on upstream HTTP protocol error",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_protocol_error_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    %{base_url: invalid_base_url, served_ref: served_ref} = start_invalid_content_length_server!()

    assert {:ok, _identity} =
             IdentityLifecycle.update_upstream_identity(setup.identity, %{
               metadata: %{"base_url" => invalid_base_url}
             })

    assert {:ok, _assignment} =
             PoolAssignments.update_pool_assignment(setup.assignment, %{
               metadata: %{"base_url" => invalid_base_url}
             })

    logs =
      capture_log(fn ->
        conn =
          conn
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "sensitive protocol body"
          })

        public_payload = json_response(conn, 502)

        assert %{"error" => %{"code" => "upstream_request_failed", "message" => message}} =
                 public_payload

        assert message == "upstream request failed"
        refute inspect(public_payload) =~ "transport_failure"
        refute inspect(public_payload) =~ "Req.HTTPError"
        refute inspect(public_payload) =~ "invalid_content_length_header"
      end)

    assert_receive {^served_ref, :served}, 1_000

    assert logs =~ "gateway upstream transport failed"
    assert logs =~ "endpoint=/backend-api/codex/responses"
    assert logs =~ "upstream_identity_id=#{setup.identity.id}"
    assert logs =~ "pool_upstream_assignment_id=#{setup.assignment.id}"
    assert logs =~ "exception=Req.HTTPError"
    assert logs =~ "reason=invalid_content_length_header"
    refute logs =~ "sensitive protocol body"
    refute logs =~ "upstream-token"
    refute logs =~ "authorization"
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_json"
    assert request.status == "failed"
    assert request.response_status_code == 502
    assert request.last_error_code == "upstream_network_error"
    refute inspect(request.request_metadata) =~ "sensitive protocol body"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_network_error"
    assert attempt.usage_status == "usage_unknown"
    assert attempt.response_metadata["error_code"] == "upstream_network_error"

    assert_transport_failure_metadata!(attempt, %{
      "exception" => "Req.HTTPError",
      "phase" => "request",
      "reason" => "invalid_content_length_header",
      "reason_class" => "Req.HTTPError"
    })

    assert_safe_transport_failure_metadata!(attempt, [
      "sensitive protocol body",
      "upstream-token",
      "authorization"
    ])

    refute inspect(attempt.response_metadata) =~ "sensitive protocol body"
  end

  test "POST /backend-api/codex/responses persists retryable transport diagnostics after fallback success",
       %{conn: conn} do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_transport_retry_should_not_run",
          "object" => "response"
        })
      )

    success_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_transport_retry_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream)
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)
    closed_base_url = "http://127.0.0.1:#{port}"

    assert {:ok, _identity} =
             IdentityLifecycle.update_upstream_identity(setup.identity, %{
               metadata: %{"base_url" => closed_base_url}
             })

    assert {:ok, _assignment} =
             PoolAssignments.update_pool_assignment(setup.assignment, %{
               metadata: %{"base_url" => closed_base_url}
             })

    success =
      gateway_upstream(setup.pool, success_upstream, "upstream-token-transport-fallback",
        compact?: false
      )

    prime_routing_quota!(success.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, success.assignment])
      )

    request_id = seed_with_assignment_order([setup.assignment.id, success.assignment.id])

    logs =
      capture_log(fn ->
        conn =
          conn
          |> put_req_header("x-request-id", request_id)
          |> put_req_header("x-sensitive-header", "secret-header-value")
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "retryable transport body token"
          })

        assert %{"id" => "resp_transport_retry_success"} = json_response(conn, 200)
      end)

    assert logs =~ "gateway upstream transport failed"
    assert logs =~ "transport=http_json"
    refute logs =~ "retryable transport body token"
    refute logs =~ "secret-header-value"
    assert FakeUpstream.count(first_upstream) == 0
    assert FakeUpstream.count(success_upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_network_error"
    assert first_attempt.response_metadata["error_code"] == "upstream_network_error"

    assert_safe_transport_failure_metadata!(first_attempt, [
      "retryable transport body token",
      "secret-header-value",
      "upstream-token-transport-fallback",
      "authorization"
    ])

    assert second_attempt.pool_upstream_assignment_id == success.assignment.id
    assert second_attempt.status == "succeeded"
    refute Map.has_key?(second_attempt.response_metadata, "transport_failure")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_json"
    assert request.retry_count == 1
    assert request.last_error_code == nil
    refute inspect(request.request_metadata) =~ "retryable transport body token"
    refute inspect(request.request_metadata) =~ "secret-header-value"
  end

  test "POST /backend-api/codex/responses keeps pre-header receive timeout as network error" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    capture_log(fn ->
      assert {:error, %{code: "upstream_request_failed"}} =
               execute_gateway(
                 auth,
                 "/backend-api/codex/responses",
                 %{
                   "model" => setup.model.exposed_model_id,
                   "input" => "pre-header timeout fixture"
                 },
                 %{
                   request_id: "pre-header-receive-timeout",
                   upstream_endpoint: "/backend-api/codex/responses",
                   receive_timeout: 100
                 }
               )
    end)

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_json"
    assert request.last_error_code == "upstream_network_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_network_error"
    assert attempt.response_metadata["error_code"] == "upstream_network_error"
    assert_safe_transport_failure_metadata!(attempt, ["pre-header timeout fixture"])
  end

  test "POST /backend-api/codex/responses keeps silent pre-first-event SSE stalls metadata-only" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.timeout_after_sse_headers(notify: self(), release_ref: release_ref)
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_silent_fallback_should_not_run",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-silent-fallback",
        compact?: false
      )

    setup =
      setup
      |> Map.put(:fallback_assignment, fallback.assignment)
      |> Map.put(:fallback_identity, fallback.identity)
      |> Map.put(
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "silent after headers stall fixture",
                 "stream" => true
               },
               %{
                 request_id: "silent-after-headers-stall",
                 upstream_endpoint: "/backend-api/codex/responses",
                 receive_timeout: 100
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert stream_conn.status == 200
    assert get_resp_header(stream_conn, "content-type") == ["text/event-stream; charset=utf-8"]

    assert {:ok, stream_conn} = stream.(stream_conn)

    refute stream_conn.resp_body =~ "response.created"
    refute stream_conn.resp_body =~ "response.failed"
    refute stream_conn.resp_body =~ "[DONE]"
    refute stream_conn.resp_body =~ "resp_silent_fallback_should_not_run"

    assert_receive {:fake_upstream_timeout_barrier, :after_sse_headers, upstream_pid,
                    ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pre_first_stream_idle_timeout!(setup)
  end

  test "POST /backend-api/codex/responses keeps partial pre-first-event SSE stalls metadata-only" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_raw_partial_stall"}),
          notify: self(),
          release_ref: release_ref
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_partial_fallback_should_not_run",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-partial-fallback",
        compact?: false
      )

    setup =
      setup
      |> Map.put(:fallback_assignment, fallback.assignment)
      |> Map.put(:fallback_identity, fallback.identity)
      |> Map.put(
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "partial frame stall fixture",
                 "stream" => true
               },
               %{
                 request_id: "partial-frame-stall",
                 upstream_endpoint: "/backend-api/codex/responses",
                 receive_timeout: 100
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert stream_conn.status == 200
    assert get_resp_header(stream_conn, "content-type") == ["text/event-stream; charset=utf-8"]

    assert {:ok, stream_conn} = stream.(stream_conn)

    refute stream_conn.resp_body =~ "response.created"
    refute stream_conn.resp_body =~ "response.failed"
    refute stream_conn.resp_body =~ "[DONE]"
    refute stream_conn.resp_body =~ "resp_raw_partial_stall"
    refute stream_conn.resp_body =~ "resp_partial_fallback_should_not_run"

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pre_first_stream_idle_timeout!(setup)
  end

  test "unsupported upstream field stripping is scoped to local backend responses route" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_openai_compat",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{raw_body: body}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses/compact",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "hello",
                 "max_output_tokens" => 128,
                 "temperature" => 0.2,
                 "top_p" => 0.9
               },
               %{
                 request_id: "non-target-field-preservation",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    assert %{"id" => "resp_openai_compat"} = Jason.decode!(body)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["max_output_tokens"] == 128
    assert captured.json["temperature"] == 0.2
    assert captured.json["top_p"] == 0.9
  end

  test "gateway service receives typed request options from the boundary" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_request_options_boundary",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "hello",
      "stream" => false
    }

    boundary_opts = %{
      request_id: Ecto.UUID.generate(),
      upstream_endpoint: "/backend-api/codex/responses"
    }

    typed_opts =
      boundary_opts
      |> Map.put(:request_id, Ecto.UUID.generate())
      |> RequestOptions.build("/backend-api/codex/responses/compact", payload)

    boundary_request_options =
      RequestOptions.from_conn_metadata(
        boundary_opts,
        "/backend-api/codex/responses/compact",
        payload
      )

    assert {:ok, %{raw_body: typed_body}} =
             RuntimeGateway.execute(
               auth,
               "/backend-api/codex/responses/compact",
               payload,
               typed_opts
             )

    assert {:ok, %{raw_body: boundary_body}} =
             RuntimeGateway.execute(
               auth,
               "/backend-api/codex/responses/compact",
               payload,
               boundary_request_options
             )

    assert %{"id" => "resp_request_options_boundary"} = Jason.decode!(typed_body)
    assert %{"id" => "resp_request_options_boundary"} = Jason.decode!(boundary_body)

    assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
             "/backend-api/codex/responses",
             "/backend-api/codex/responses"
           ]

    request_rows =
      Request
      |> where([request], request.pool_id == ^setup.pool.id)
      |> order_by([request], asc: request.admitted_at)
      |> Repo.all()

    assert Enum.map(request_rows, & &1.transport) == ["http_compact_json", "http_compact_json"]

    assert Enum.map(request_rows, & &1.endpoint) == [
             "/backend-api/codex/responses/compact",
             "/backend-api/codex/responses/compact"
           ]
  end

  test "POST /backend-api/codex/responses preserves input_image payloads on the HTTP path", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_image",
          "object" => "response",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true
        }
      )

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "describe this image"},
          %{
            "type" => "input_image",
            "image_url" => "https://example.com/test-image.png",
            "detail" => "high"
          }
        ]
      }
    ]

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => input
      })

    assert %{"id" => "resp_http_image"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["input"] == input
  end

  test "POST /backend-api/codex/responses preserves input_image.file_id", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_file_id"}))
    setup = gateway_setup(upstream)
    file_id = "file_backend_upload_reference"

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "describe this image"},
              %{"type" => "input_image", "file_id" => file_id}
            ]
          }
        ]
      })

    assert %{"id" => "resp_file_id"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [
             %{
               "content" => [
                 %{"type" => "input_text"},
                 %{"type" => "input_image", "file_id" => ^file_id}
               ]
             }
           ] = captured.json["input"]
  end

  test "POST /backend-api/codex/responses rejects sediment input_image URLs before dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    sentinel_url = "sediment://image-reference-do-not-log"

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "describe this image"},
              %{"type" => "input_image", "image_url" => sentinel_url}
            ]
          }
        ]
      })

    assert %{
             "error" => %{
               "code" => "unsupported_input_image_format",
               "type" => "invalid_request_error",
               "param" => "input",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~
             "Responses input_image values must use https image URLs or supported image data URLs"

    refute conn.resp_body =~ sentinel_url
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_input_image_format"
    assert request.request_metadata["gateway_denial"]["param"] == "input"
    refute inspect(request.request_metadata) =~ sentinel_url
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects plain HTTP input_image URLs before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    sentinel_url = "http://example.com/image-reference-do-not-log.png"

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "describe this image"},
              %{"type" => "input_image", "image_url" => sentinel_url}
            ]
          }
        ]
      })

    assert %{
             "error" => %{
               "code" => "unsupported_input_image_format",
               "type" => "invalid_request_error",
               "param" => "input",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~
             "Responses input_image values must use https image URLs or supported image data URLs"

    refute conn.resp_body =~ sentinel_url
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "unsupported_input_image_format"
    assert request.request_metadata["gateway_denial"]["param"] == "input"
    refute inspect(request.request_metadata) =~ sentinel_url
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses preserves inline data URL input_image payloads for image-capable models",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_image_data_url",
          "object" => "response",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text", "image"],
          "supports_image_detail_original" => true
        }
      )

    inline_image_bytes = "inline image fixture"
    inline_image_url = "data:image/png;base64," <> Base.encode64(inline_image_bytes)

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "describe this image"},
          %{
            "type" => "input_image",
            "image_url" => inline_image_url,
            "detail" => "high"
          }
        ]
      }
    ]

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => input
      })

    assert %{"id" => "resp_http_image_data_url"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["input"] == input

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ inline_image_url
    refute metadata =~ inline_image_bytes
    refute metadata =~ Base.encode64(inline_image_bytes)
  end

  test "POST /backend-api/codex/responses rejects input_image for text-only models before dispatch",
       %{
         conn: conn
       } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_input_modalities" => ["text"],
          "supports_image_detail_original" => false
        }
      )

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "describe this image"},
              %{"type" => "input_image", "image_url" => "data:image/png;base64,AA=="}
            ]
          }
        ]
      })

    assert %{"error" => %{"code" => "unsupported_model_capability"}} = json_response(conn, 400)
    assert FakeUpstream.requests(upstream) == []
  end

  test "POST /backend-api/codex/responses rejects strict schemas missing additionalProperties before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    sentinel = "STRICT_SCHEMA_SENTINEL_DO_NOT_LOG"

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "description" => sentinel,
          "properties" => %{
            "answer" => %{"type" => "string", "description" => sentinel}
          },
          "required" => ["answer"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "type" => "invalid_request_error",
               "param" => "text.format.schema",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "additionalProperties"
    refute conn.resp_body =~ sentinel
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "invalid_json_schema"
    assert request.request_metadata["gateway_denial"]["param"] == "text.format.schema"
    refute inspect(request.request_metadata) =~ sentinel
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects top-level strict schemas without type before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    sentinel = "STRICT_SCHEMA_TYPE_SENTINEL_DO_NOT_LOG"

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "description" => sentinel,
          "additionalProperties" => false,
          "properties" => %{
            "answer" => %{"type" => "string", "description" => sentinel}
          },
          "required" => ["answer"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "type" => "invalid_request_error",
               "param" => "text.format.schema.type",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "type must be a string or a non-empty array of strings"
    refute conn.resp_body =~ sentinel
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "invalid_json_schema"
    assert request.request_metadata["gateway_denial"]["param"] == "text.format.schema.type"
    refute inspect(request.request_metadata) =~ sentinel
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects nested strict property schemas without type",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "answer" => %{"description" => "nested type missing"}
          },
          "required" => ["answer"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "type" => "invalid_request_error",
               "param" => "text.format.schema.properties.answer.type",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "type must be a string or a non-empty array of strings"
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "invalid_json_schema"

    assert request.request_metadata["gateway_denial"]["param"] ==
             "text.format.schema.properties.answer.type"

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects strict schemas when required omits a property",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "answer" => %{"type" => "string"},
            "confidence" => %{"type" => "number"}
          },
          "required" => ["answer"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "param" => "text.format.schema.required",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "missing confidence"
    assert FakeUpstream.requests(upstream) == []
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.last_error_code == "invalid_json_schema"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects strict schemas when required includes an unknown property",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "answer" => %{"type" => "string"}
          },
          "required" => ["answer", "confidence"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "param" => "text.format.schema.required",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "extra confidence"
    assert FakeUpstream.requests(upstream) == []
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "invalid_json_schema"
    assert request.request_metadata["gateway_denial"]["param"] == "text.format.schema.required"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses rejects strict schemas with invalid nested $defs",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "step" => %{"$ref" => "#/$defs/step"}
          },
          "required" => ["step"],
          "$defs" => %{
            "step" => %{
              "type" => "object",
              "properties" => %{
                "summary" => %{"type" => "string"}
              },
              "required" => ["summary"]
            }
          }
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "param" => "text.format.schema.properties.step",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "additionalProperties"
    assert FakeUpstream.requests(upstream) == []
  end

  test "POST /backend-api/codex/responses rejects strict schemas with invalid nested items",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(%{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "steps" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{
                  "title" => %{"type" => "string"},
                  "notes" => %{"type" => "string"}
                },
                "required" => ["title"]
              }
            }
          },
          "required" => ["steps"]
        })
      )

    assert %{
             "error" => %{
               "code" => "invalid_json_schema",
               "param" => "text.format.schema.properties.steps.items.required",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "missing notes"
    assert FakeUpstream.requests(upstream) == []
  end

  test "POST /backend-api/codex/responses rejects invalid strict nested function tools before dispatch",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_unexpected"}))
    setup = gateway_setup(upstream)
    sentinel = "STRICT_FUNCTION_SENTINEL_DO_NOT_LOG"

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic input",
          "tools" => [
            %{
              "type" => "function",
              "function" => %{
                "name" => "lookup_fixture",
                "description" => sentinel,
                "strict" => true,
                "parameters" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "description" => sentinel,
                  "properties" => %{
                    "ok" => %{"type" => "boolean", "description" => sentinel}
                  },
                  "required" => []
                }
              }
            }
          ]
        }
      )

    assert %{
             "error" => %{
               "code" => "invalid_function_parameters",
               "type" => "invalid_request_error",
               "param" => "tools.0.function.parameters.required",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "missing ok"
    refute conn.resp_body =~ sentinel
    assert FakeUpstream.requests(upstream) == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "invalid_function_parameters"

    assert request.request_metadata["gateway_denial"]["param"] ==
             "tools.0.function.parameters.required"

    refute inspect(request.request_metadata) =~ sentinel
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
  end

  test "POST /backend-api/codex/responses lets non-strict json_schema payloads pass through",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_non_strict"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post(
        "/backend-api/codex/responses",
        strict_text_format_payload(
          %{
            "type" => "object",
            "properties" => %{
              "answer" => %{"type" => "string"}
            }
          },
          false
        )
      )

    assert %{"id" => "resp_non_strict"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["text"]["format"]["strict"] == false
  end

  test "POST /backend-api/codex/responses lets valid strict json_schema payloads pass through",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_strict_valid"}))
    setup = gateway_setup(upstream)

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "answer" => %{"type" => "string"},
        "steps" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "title" => %{"type" => "string"}
            },
            "required" => ["title"]
          }
        }
      },
      "required" => ["answer", "steps"]
    }

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", strict_text_format_payload(schema))

    assert %{"id" => "resp_strict_valid"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["text"]["format"]["schema"] == schema
  end

  @tag :routes_input_file_to_owner_assignment
  test "POST /backend-api/codex/responses routes input_file requests to the finalized owner assignment",
       %{
         conn: conn
       } do
    unique = System.unique_integer([:positive])

    owner_file_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_owner_route_#{unique}",
          file_name: "owner-route.txt",
          mime_type: "text/plain"
        )
      )

    setup = gateway_setup(owner_file_upstream)
    owner_file_id = create_and_finalize_backend_file!(setup, "owner-route.txt", 14)

    owner_response_upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_owner_route",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    other_response_upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_other_route",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = swap_upstream_base_url!(setup, owner_response_upstream)

    other =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_other_route",
        metadata: %{"base_url" => FakeUpstream.url(other_response_upstream)},
        access_token: "other-route-token"
      })

    prime_routing_quota!(other.identity)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{"source_assignment_ids" => [setup.assignment.id, other.assignment.id]}
      })
      |> Repo.update!()

    setup = Map.merge(setup, %{model: model})
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{session_header: "file-owner-session"})

    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
    |> Repo.update!()

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               %{"id" => "resp_owner_previous"}
             )

    assert {:error, :invalid_session_continuity} =
             Gateway.register_codex_session_continuity(nil, %{}, %{"id" => "resp_ignored"})

    owner_response_before = FakeUpstream.count(owner_response_upstream)
    other_response_before = FakeUpstream.count(other_response_upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "instructions" => "read the referenced file",
        "previous_response_id" => "resp_owner_previous",
        "store" => false,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "hello"},
              %{"type" => "input_file", "file_id" => owner_file_id}
            ]
          }
        ]
      })

    assert %{"id" => "resp_owner_route"} = json_response(conn, 200)

    assert owner_response_before + 1 == FakeUpstream.count(owner_response_upstream)
    assert other_response_before == FakeUpstream.count(other_response_upstream)

    assert [captured] = FakeUpstream.requests(owner_response_upstream)
    assert captured.json["instructions"] == "read the referenced file"
    assert captured.json["store"] == false

    assert captured.json["input"]
           |> Enum.at(0)
           |> Map.fetch!("content")
           |> Enum.at(1)
           |> Map.fetch!("file_id") == owner_file_id

    refute inspect(captured.json) =~ "upload.invalid"
    refute inspect(captured.json) =~ "download.invalid"
  end

  @tag :rejects_conflicting_input_file_assignments
  test "POST /backend-api/codex/responses rejects conflicting or unavailable input_file assignment affinity",
       %{
         conn: conn
       } do
    unique = System.unique_integer([:positive])

    owner_file_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_conflict_owner_#{unique}",
          file_name: "conflict-owner.txt",
          mime_type: "text/plain"
        )
      )

    setup = gateway_setup(owner_file_upstream)
    owner_file_id = create_and_finalize_backend_file!(setup, "conflict-owner.txt", 13)

    other_file_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_conflict_other_#{unique}",
          file_name: "conflict-other.txt",
          mime_type: "text/plain"
        )
      )

    other =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_conflict_other",
        metadata: %{"base_url" => FakeUpstream.url(other_file_upstream)},
        access_token: "conflict-other-token"
      })

    prime_routing_quota!(other.identity)

    setup.assignment
    |> Ecto.Changeset.change(%{eligibility_status: "ineligible"})
    |> Repo.update!()

    other_file_id = create_and_finalize_backend_file!(setup, "conflict-other.txt", 12)

    setup.assignment
    |> Ecto.Changeset.change(%{eligibility_status: "eligible"})
    |> Repo.update!()

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        source_assignment_count: 2,
        metadata: %{"source_assignment_ids" => [setup.assignment.id, other.assignment.id]}
      })
      |> Repo.update!()

    setup = Map.merge(setup, %{model: model})
    owner_dispatch_count = FakeUpstream.count(owner_file_upstream)
    other_dispatch_count = FakeUpstream.count(other_file_upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{"type" => "input_file", "file_id" => owner_file_id},
          %{"type" => "input_file", "file_id" => other_file_id}
        ]
      })

    assert_file_assignment_conflict_without_recovery!(conn)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, conflict_session} =
      Gateway.start_codex_session(auth, %{session_header: "file-conflict-session"})

    conflict_session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: other.assignment.id})
    |> Repo.update!()

    assert :ok =
             Gateway.register_codex_session_continuity(
               conflict_session,
               %{},
               %{"id" => "resp_other_previous"}
             )

    conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_other_previous",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_file", "file_id" => owner_file_id}]
          }
        ]
      })

    assert_file_assignment_conflict_without_recovery!(conn)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    pending_file_id =
      response_affinity_file_fixture(setup, setup.assignment, setup.identity,
        file_id: "file_pending_route_#{unique}",
        filename: "pending-route.txt",
        byte_size: 11,
        status: "pending_upload",
        finalize_status: "pending"
      ).file_id

    pending_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => pending_file_id}]
      })

    assert %{"error" => %{"code" => "file_not_ready"}} = json_response(pending_conn, 409)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    failed_file_id =
      response_affinity_file_fixture(setup, setup.assignment, setup.identity,
        file_id: "file_failed_route_#{unique}",
        filename: "failed-route.txt",
        byte_size: 10,
        status: "abandoned",
        finalize_status: "failed"
      ).file_id

    failed_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => failed_file_id}]
      })

    assert %{"error" => %{"code" => "file_not_ready"}} = json_response(failed_conn, 409)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    expired_file_id =
      response_affinity_file_fixture(setup, setup.assignment, setup.identity,
        file_id: "file_expired_route_#{unique}",
        filename: "expired-route.txt",
        byte_size: 9,
        status: "expired",
        finalize_status: "succeeded",
        expires_at:
          DateTime.add(DateTime.utc_now() |> DateTime.truncate(:microsecond), -60, :second)
      ).file_id

    expired_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => expired_file_id}]
      })

    assert %{"error" => %{"code" => "file_not_found"}} = json_response(expired_conn, 404)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    retry_timeout_file_id =
      response_affinity_file_fixture(setup, setup.assignment, setup.identity,
        file_id: "file_retry_timeout_route_#{unique}",
        filename: "retry-timeout-route.txt",
        byte_size: 8,
        status: "pending_upload",
        finalize_status: "pending"
      ).file_id

    retry_timeout_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => retry_timeout_file_id}]
      })

    assert %{"error" => %{"code" => "file_not_ready"}} = json_response(retry_timeout_conn, 409)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    missing_conn =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => "file_missing_route"}]
      })

    assert %{"error" => %{"code" => "file_not_found"}} = json_response(missing_conn, 404)
    assert FakeUpstream.count(owner_file_upstream) == owner_dispatch_count
    assert FakeUpstream.count(other_file_upstream) == other_dispatch_count

    assert {:ok, %{^owner_file_id => owner_assignment_id}} =
             Files.assignment_affinities(setup, [owner_file_id])

    assert owner_assignment_id == setup.assignment.id

    refute inspect(Repo.all(Request)) =~ "upload.invalid"
    refute inspect(Repo.all(Request)) =~ "download.invalid"
    refute inspect(Repo.all(Request)) =~ "conflict-other-token"
  end

  test "POST /backend-api/codex/responses fails closed for pinned reauth continuation anchors",
       %{conn: _conn} do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_pinned_reauth_should_not_dispatch",
          "object" => "response"
        })
      )

    fresh_start_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_pinned_reauth_fresh_start",
          "object" => "response",
          "usage" => %{
            "input_tokens" => 5,
            "output_tokens" => 2,
            "total_tokens" => 7
          }
        })
      )

    setup = gateway_setup(pinned_upstream)

    fresh_start =
      gateway_upstream(
        setup.pool,
        fresh_start_upstream,
        "upstream-token-pinned-reauth-fresh-start",
        compact?: false
      )

    prime_routing_quota!(fresh_start.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fresh_start.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    visible_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{
            "type" => "input_text",
            "text" => "visible pinned reauth context must not persist"
          }
        ]
      },
      %{
        "type" => "future_tool_call_output",
        "call_id" => "call_pinned_reauth",
        "output" => "visible tool result must not persist"
      }
    ]

    mark_pinned_assignment_reauth_required!(setup)

    previous_response_id = "resp_pinned_reauth_#{System.unique_integer([:positive])}"
    register_previous_response_anchor!(auth, setup.assignment, previous_response_id)

    anchored_cases = [
      {"body previous_response_id", [],
       %{
         "previous_response_id" => previous_response_id,
         "input" => visible_input
       }},
      {"header previous response", [{"x-codex-previous-response-id", previous_response_id}],
       %{"input" => visible_input}},
      {"tool result continuation", [],
       %{
         "previous_response_id" => previous_response_id,
         "input" => [
           %{
             "type" => "future_tool_call_output",
             "call_id" => "future_call_pinned_reauth",
             "result" => %{
               "type" => "text",
               "text" => "visible future tool result must not persist"
             }
           }
         ]
       }}
    ]

    for {{label, headers, payload}, index} <- Enum.with_index(anchored_cases) do
      conn = post_backend_response(setup, headers, payload)

      assert_pinned_reauth_recovery_response!(conn)

      error_text = inspect(json_response(conn, 503))
      refute error_text =~ previous_response_id, label
      refute error_text =~ "visible pinned reauth context must not persist", label
      refute error_text =~ "call_pinned_reauth", label
      refute error_text =~ "visible tool result must not persist", label
      refute error_text =~ setup.authorization, label
      refute error_text =~ setup.raw_key, label
      refute error_text =~ "Bearer ", label

      assert FakeUpstream.count(pinned_upstream) == 0, label
      assert FakeUpstream.count(fresh_start_upstream) == 0, label
      assert Repo.aggregate(Attempt, :count) == 0, label

      denied_requests =
        Repo.all(
          from(r in Request,
            where: r.pool_id == ^setup.pool.id,
            order_by: [asc: r.admitted_at, asc: r.id]
          )
        )

      assert length(denied_requests) == index + 1, label
      denied_request = List.last(denied_requests)
      assert denied_request.status == "rejected", label
      assert denied_request.last_error_code == "pinned_continuation_reauth_required", label

      assert denied_request.request_metadata["continuity_denial"]["denial_family"] ==
               "pinned_continuation_reauth"

      denied_metadata_text =
        inspect({
          Enum.map(denied_requests, & &1.request_metadata),
          RequestLogs.list(setup.pool)
        })

      refute denied_metadata_text =~ previous_response_id, label
      refute denied_metadata_text =~ "visible pinned reauth context must not persist", label
      refute denied_metadata_text =~ "call_pinned_reauth", label
      refute denied_metadata_text =~ "visible tool result must not persist", label
      refute denied_metadata_text =~ "future_call_pinned_reauth", label
      refute denied_metadata_text =~ "visible future tool result must not persist", label
      refute denied_metadata_text =~ setup.authorization, label
      refute denied_metadata_text =~ setup.raw_key, label
      refute denied_metadata_text =~ "upstream-token", label
    end

    fresh_conn =
      post_backend_response(setup, [], %{
        "input" => visible_input
      })

    assert %{"id" => "resp_pinned_reauth_fresh_start"} = json_response(fresh_conn, 200)
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fresh_start_upstream) == 1

    fresh_request =
      Repo.one!(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id and r.status == "succeeded",
          order_by: [desc: r.admitted_at],
          limit: 1
        )
      )

    assert [fresh_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^fresh_request.id))

    assert fresh_request.status == "succeeded"
    assert fresh_attempt.status == "succeeded"
    assert fresh_attempt.pool_upstream_assignment_id == fresh_start.assignment.id

    assert [captured] = FakeUpstream.requests(fresh_start_upstream)
    assert captured.json["input"] == visible_input
    refute Map.has_key?(captured.json, "previous_response_id")

    metadata_text =
      inspect(
        {fresh_request.request_metadata, fresh_attempt.response_metadata,
         RequestLogs.list(setup.pool)}
      )

    refute metadata_text =~ previous_response_id
    refute metadata_text =~ "visible pinned reauth context must not persist"
    refute metadata_text =~ "visible tool result must not persist"
    refute metadata_text =~ "call_pinned_reauth"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"
  end

  test "POST /backend-api/codex/responses settles auto pricing from upstream response tier", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.reject_json_field(
          "service_tier",
          %{
            "id" => "resp_backend_flex",
            "object" => "response",
            "service_tier" => "flex",
            "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
          },
          %{"error" => %{"code" => "unsupported_service_tier"}}
        )
      )

    setup = gateway_setup(upstream)

    flex_pricing =
      pricing_snapshot!(setup.model, %{
        config: pricing_config(%{"service_tier" => "flex"}),
        input_token_micros: Decimal.new(25),
        output_token_micros: Decimal.new(50)
      })

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hello",
        "service_tier" => "auto"
      })

    assert %{"id" => "resp_backend_flex"} = json_response(conn, 200)
    assert [%{json: upstream_payload}] = FakeUpstream.requests(upstream)
    refute Map.has_key?(upstream_payload, "service_tier")

    assert %Request{} =
             request =
             Repo.one!(
               from request in Request,
                 where:
                   request.pool_id == ^setup.pool.id and
                     request.endpoint == "/backend-api/codex/responses",
                 order_by: [desc: request.admitted_at],
                 limit: 1
             )

    assert request.request_metadata["pricing"]["status"] == "priced"
    assert request.request_metadata["pricing"]["requested_service_tier"] == "auto"
    assert request.request_metadata["pricing"]["actual_service_tier"] == "flex"
    assert request.request_metadata["pricing"]["service_tier"] == "flex"

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "hello"
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.pricing_snapshot_id == flex_pricing.id
    assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(100))
  end

  test "POST /backend-api/codex/responses records per-request RouteState snapshot inputs" do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_route_state_snapshot_first",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_route_state_snapshot_second",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(first_upstream)

    alternate =
      gateway_upstream(
        setup.pool,
        second_upstream,
        "upstream-token-route-state-snapshot",
        compact?: false
      )

    prime_routing_quota!(alternate.identity)

    setup = %{
      setup
      | model:
          put_model_source_assignments!(setup.model, [setup.assignment, alternate.assignment])
    }

    use_routing_strategy!(setup.pool, "bridge_ring", 1)

    first_conn =
      post_backend_response(setup, [], %{
        "input" => "route state snapshot first request"
      })

    assert %{"id" => first_id} = json_response(first_conn, 200)
    assert first_id in ["resp_route_state_snapshot_first", "resp_route_state_snapshot_second"]

    [first_request] =
      Repo.all(
        from request in Request,
          where: request.pool_id == ^setup.pool.id,
          order_by: [asc: request.admitted_at, asc: request.id]
      )

    assert first_request.request_metadata["routing"]["strategy"] == "bridge_ring"
    assert first_request.request_metadata["routing"]["bridge_ring_size"] == 1

    assert %{
             "pool_id" => pool_id,
             "api_key_id" => api_key_id,
             "effective_model" => effective_model,
             "route_class" => "proxy_http",
             "request_class" => "http_json",
             "estimated_input_tokens" => input_tokens,
             "estimated_output_tokens" => output_tokens,
             "estimated_total_tokens" => total_tokens,
             "quota_window_dimension_keys" => quota_window_dimension_keys
           } = first_request.request_metadata["reservation_snapshot_inputs"]

    assert pool_id == setup.pool.id
    assert api_key_id == setup.api_key.id
    assert effective_model == setup.model.exposed_model_id
    assert total_tokens == input_tokens + output_tokens

    assert Enum.map(quota_window_dimension_keys, & &1["policy_field"]) == [
             "max_requests_per_minute",
             "max_tokens_per_day",
             "max_tokens_per_week"
           ]

    use_routing_strategy!(setup.pool, "deterministic_rotation", 2)

    second_conn =
      post_backend_response(setup, [], %{
        "input" => "route state snapshot second request"
      })

    assert %{"id" => second_id} = json_response(second_conn, 200)
    assert second_id in ["resp_route_state_snapshot_first", "resp_route_state_snapshot_second"]

    [first_request, second_request] =
      Repo.all(
        from request in Request,
          where: request.pool_id == ^setup.pool.id,
          order_by: [asc: request.admitted_at, asc: request.id]
      )

    assert first_request.request_metadata["routing"]["strategy"] == "bridge_ring"
    assert first_request.request_metadata["routing"]["bridge_ring_size"] == 1
    assert second_request.request_metadata["routing"]["strategy"] == "deterministic_rotation"
    assert second_request.request_metadata["routing"]["bridge_ring_size"] == 2
  end

  test "POST /backend-api/codex/responses bridge_ring retries only within the default shortlist",
       %{
         conn: conn
       } do
    retryable_upstream = start_upstream(FakeUpstream.http_500_json_error())

    shortlisted_success_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_bridge_ring_shortlist_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    excluded_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_bridge_ring_excluded_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(retryable_upstream)

    shortlisted_success =
      gateway_upstream(setup.pool, shortlisted_success_upstream, "upstream-token-shortlisted",
        compact?: false
      )

    excluded =
      gateway_upstream(setup.pool, excluded_upstream, "upstream-token-excluded", compact?: false)

    prime_routing_quota!(shortlisted_success.identity)
    prime_routing_quota!(excluded.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          shortlisted_success.assignment,
          excluded.assignment
        ])
      )

    request_id =
      seed_with_assignment_order([
        setup.assignment.id,
        shortlisted_success.assignment.id,
        excluded.assignment.id
      ])

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "bridge ring retry metadata sentinel"
      })

    assert %{"id" => "resp_bridge_ring_shortlist_success"} = json_response(conn, 200)
    assert FakeUpstream.count(retryable_upstream) == 1
    assert FakeUpstream.count(shortlisted_success_upstream) == 1
    assert FakeUpstream.count(excluded_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert second_attempt.pool_upstream_assignment_id == shortlisted_success.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_json"
    assert request.retry_count == 1

    assert_http_json_routing_metadata!(request, "bridge_ring", shortlisted_success.assignment, 2)

    assert_attempt_routing_metadata!(first_attempt, setup.assignment, setup.identity, 1)

    assert_attempt_routing_metadata!(
      second_attempt,
      shortlisted_success.assignment,
      shortlisted_success.identity,
      2
    )

    assert_safe_runtime_routing_metadata!(request, [first_attempt, second_attempt], setup)
  end

  test "POST /backend-api/codex/responses records prompt-cache routing-locality metadata safely",
       %{
         conn: conn
       } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_prompt_cache_locality_primary",
          "object" => "response",
          "usage" => %{
            "input_tokens" => 9,
            "input_tokens_details" => %{"cached_tokens" => 3},
            "output_tokens" => 2,
            "total_tokens" => 11
          }
        })
      )

    alternate_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_prompt_cache_locality_alternate",
          "object" => "response",
          "usage" => %{
            "input_tokens" => 9,
            "input_tokens_details" => %{"cached_tokens" => 3},
            "output_tokens" => 2,
            "total_tokens" => 11
          }
        })
      )

    setup = gateway_setup(upstream)

    alternate =
      gateway_upstream(setup.pool, alternate_upstream, "upstream-token-prompt-cache-alternate",
        compact?: false
      )

    prime_routing_quota!(alternate.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, alternate.assignment])
      )

    raw_prompt_cache_key = "raw-prompt-cache-routing-key-do-not-log"

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "prompt-cache locality metadata prompt must not persist",
        "prompt_cache_key" => raw_prompt_cache_key
      })

    assert %{"id" => response_id} = json_response(conn, 200)

    assert response_id in [
             "resp_prompt_cache_locality_primary",
             "resp_prompt_cache_locality_alternate"
           ]

    assert [attempt] = Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    selected_assignment_id = request.request_metadata["routing"]["selected_bridge_candidate_id"]

    selected_assignment =
      if selected_assignment_id == setup.assignment.id,
        do: setup.assignment,
        else: alternate.assignment

    selected_identity =
      if selected_assignment_id == setup.assignment.id,
        do: setup.identity,
        else: alternate.identity

    assert_http_json_routing_metadata!(request, "bridge_ring", selected_assignment, 2)
    assert_attempt_routing_metadata!(attempt, selected_assignment, selected_identity, 1)

    assert_prompt_cache_locality_metadata_safe!(
      request.request_metadata["routing"],
      raw_prompt_cache_key,
      selected_assignment.id,
      2
    )

    assert_prompt_cache_locality_metadata_safe!(
      attempt.response_metadata["routing"],
      raw_prompt_cache_key,
      selected_assignment.id,
      2
    )

    settlement =
      Repo.get_by!(LedgerEntry,
        request_id: request.id,
        entry_kind: "settlement",
        amount_status: "recorded"
      )

    assert settlement.cached_input_tokens == 3

    assert %{items: [log], total: 1} = RequestLogs.list(setup.pool)

    assert_prompt_cache_locality_metadata_safe!(
      log.metadata["routing"],
      raw_prompt_cache_key,
      selected_assignment.id,
      2
    )

    metadata_text = inspect({request, attempt, log})
    refute metadata_text =~ raw_prompt_cache_key
    refute metadata_text =~ "prompt-cache locality metadata prompt must not persist"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
    refute metadata_text =~ "cache_hit"
    refute metadata_text =~ "cache hit"
    refute metadata_text =~ "provider_cache"
    refute metadata_text =~ "provider cache"
    refute metadata_text =~ "prompt cache hit"
  end

  test "POST /backend-api/codex/responses deterministic_rotation retries only within the bridge ring shortlist",
       %{
         conn: conn
       } do
    retryable_upstream = start_upstream(FakeUpstream.http_500_json_error())

    shortlisted_success_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_shortlist_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    excluded_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_excluded_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(retryable_upstream)

    shortlisted_success =
      gateway_upstream(setup.pool, shortlisted_success_upstream, "upstream-token-shortlisted",
        compact?: false
      )

    excluded =
      gateway_upstream(setup.pool, excluded_upstream, "upstream-token-excluded", compact?: false)

    prime_routing_quota!(shortlisted_success.identity)
    prime_routing_quota!(excluded.identity)
    use_routing_strategy!(setup.pool, "deterministic_rotation", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          shortlisted_success.assignment,
          excluded.assignment
        ])
      )

    rotation_seed = deterministic_rotation_seed(3, 0)

    conn =
      conn
      |> put_req_header("x-request-id", rotation_seed)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "retry within shortlist"
      })

    assert %{"id" => "resp_shortlist_success"} = json_response(conn, 200)
    assert FakeUpstream.count(retryable_upstream) == 1
    assert FakeUpstream.count(shortlisted_success_upstream) == 1
    assert FakeUpstream.count(excluded_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert second_attempt.pool_upstream_assignment_id == shortlisted_success.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1

    assert_http_json_routing_metadata!(
      request,
      "deterministic_rotation",
      shortlisted_success.assignment,
      2
    )

    assert_attempt_routing_metadata!(first_attempt, setup.assignment, setup.identity, 1)

    assert_attempt_routing_metadata!(
      second_attempt,
      shortlisted_success.assignment,
      shortlisted_success.identity,
      2
    )

    assert_safe_runtime_routing_metadata!(request, [first_attempt, second_attempt], setup)
  end

  test "POST /backend-api/codex/responses least_recent_success selects oldest successful assignment",
       %{conn: conn} do
    older_success_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_oldest_success_assignment",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    newer_success_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_newer_success_assignment",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(older_success_upstream)

    newer_success =
      gateway_upstream(setup.pool, newer_success_upstream, "upstream-token-newer",
        compact?: false
      )

    prime_routing_quota!(newer_success.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, newer_success.assignment])
      )

    use_routing_strategy!(setup.pool, "least_recent_success", 2)

    base_time = ~U[2026-05-12 10:00:00.000000Z]

    older_request =
      request_fixture(setup, %{model_id: setup.model.id, correlation_id: "least-recent-older"})

    newer_request =
      request_fixture(setup, %{model_id: setup.model.id, correlation_id: "least-recent-newer"})

    attempt_fixture(older_request, setup.assignment, %{
      attempt_number: 1,
      completed_at: base_time
    })

    attempt_fixture(newer_request, newer_success.assignment, %{
      attempt_number: 1,
      completed_at: DateTime.add(base_time, 60, :second)
    })

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, newer_success.assignment.id],
        newer_success.assignment.id
      )

    first_conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "least recent success route"
      })

    assert %{"id" => "resp_oldest_success_assignment"} = json_response(first_conn, 200)
    assert FakeUpstream.count(older_success_upstream) == 1
    assert FakeUpstream.count(newer_success_upstream) == 0

    second_request_id =
      seed_preferring_assignment(
        [setup.assignment.id, newer_success.assignment.id],
        setup.assignment.id
      )

    second_conn =
      build_conn()
      |> put_req_header("x-request-id", second_request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "least recent success moves after runtime success"
      })

    assert %{"id" => "resp_newer_success_assignment"} = json_response(second_conn, 200)
    assert FakeUpstream.count(older_success_upstream) == 1
    assert FakeUpstream.count(newer_success_upstream) == 1

    [runtime_first_request, runtime_second_request] =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [desc: r.admitted_at],
          limit: 2
        )
      )
      |> Enum.reverse()

    assert runtime_first_request.status == "succeeded"
    assert runtime_second_request.status == "succeeded"

    runtime_request_ids = [runtime_first_request.id, runtime_second_request.id]

    [runtime_first_attempt, runtime_second_attempt] =
      Repo.all(
        from(a in Attempt,
          where: a.request_id in ^runtime_request_ids,
          order_by: [asc: a.started_at, asc: a.attempt_number, asc: a.id]
        )
      )

    assert runtime_first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert runtime_second_attempt.pool_upstream_assignment_id == newer_success.assignment.id

    assert_http_json_routing_metadata!(
      runtime_first_request,
      "least_recent_success",
      setup.assignment,
      2
    )

    assert_http_json_routing_metadata!(
      runtime_second_request,
      "least_recent_success",
      newer_success.assignment,
      2
    )

    assert_attempt_routing_metadata!(runtime_first_attempt, setup.assignment, setup.identity, 1)

    assert_attempt_routing_metadata!(
      runtime_second_attempt,
      newer_success.assignment,
      newer_success.identity,
      1
    )

    assert_safe_runtime_routing_metadata!(runtime_second_request, [runtime_second_attempt], setup)
  end

  test "POST /backend-api/codex/responses quota_first selects the lower quota usage assignment",
       %{conn: conn} do
    high_usage_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_high_usage_assignment",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    lower_usage_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_lower_usage_assignment",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    exhausted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_quota_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    resetless_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_resetless_quota_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(high_usage_upstream, quota?: false)

    lower_usage =
      gateway_upstream(setup.pool, lower_usage_upstream, "upstream-token-lower-usage",
        compact?: false
      )

    exhausted =
      gateway_upstream(setup.pool, exhausted_upstream, "upstream-token-exhausted-quota",
        compact?: false
      )

    resetless =
      gateway_upstream(setup.pool, resetless_upstream, "upstream-token-resetless-quota",
        compact?: false
      )

    prime_routing_quota!(setup.identity, %{used_percent: Decimal.new("90")})
    prime_routing_quota!(lower_usage.identity, %{used_percent: Decimal.new("10")})
    prime_exhausted_routing_quota!(exhausted.identity)
    prime_resetless_routing_quota!(resetless.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          lower_usage.assignment,
          exhausted.assignment,
          resetless.assignment
        ])
      )

    use_routing_strategy!(setup.pool, "quota_first", 4)

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, lower_usage.assignment.id],
        setup.assignment.id
      )

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "quota first route metadata sentinel"
      })

    assert %{"id" => "resp_lower_usage_assignment"} = json_response(conn, 200)
    assert FakeUpstream.count(high_usage_upstream) == 0
    assert FakeUpstream.count(lower_usage_upstream) == 1
    assert FakeUpstream.count(exhausted_upstream) == 0
    assert FakeUpstream.count(resetless_upstream) == 0

    assert [attempt] = Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))
    assert attempt.pool_upstream_assignment_id == lower_usage.assignment.id
    assert attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "eligible_candidate_count"]) == 2

    assert get_in(request.request_metadata, ["quota_decision", "precise_candidate_count"]) == 2

    assert_http_json_routing_metadata!(request, "quota_first", lower_usage.assignment, 4)

    assert_attempt_routing_metadata!(attempt, lower_usage.assignment, lower_usage.identity, 1)
    assert_safe_runtime_routing_metadata!(request, [attempt], setup)
  end

  @tag :task_5_sse_strategy_reliability
  test "SSE bridge_ring first-event retry stays within the strategy shortlist" do
    retryable_upstream =
      start_upstream(first_event_terminal_sse("response.failed", "upstream_request_timeout"))

    shortlisted_success_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_sse_bridge_ring_shortlist_success",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    excluded_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_sse_excluded_should_not_run",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(retryable_upstream)

    shortlisted_success =
      gateway_upstream(setup.pool, shortlisted_success_upstream, "upstream-token-sse-shortlisted",
        compact?: false
      )

    excluded =
      gateway_upstream(setup.pool, excluded_upstream, "upstream-token-sse-excluded",
        compact?: false
      )

    prime_routing_quota!(shortlisted_success.identity)
    prime_routing_quota!(excluded.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          shortlisted_success.assignment,
          excluded.assignment
        ])
      )

    request_id =
      seed_with_assignment_order([
        setup.assignment.id,
        shortlisted_success.assignment.id,
        excluded.assignment.id
      ])

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "sse bridge ring retry fixture",
                 "stream" => true
               },
               %{
                 request_id: request_id,
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "resp_sse_bridge_ring_shortlist_success"
    assert stream_conn.resp_body =~ "data: [DONE]\n\n"

    assert FakeUpstream.count(retryable_upstream) == 1
    assert FakeUpstream.count(shortlisted_success_upstream) == 1
    assert FakeUpstream.count(excluded_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_request_timeout"
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"
    assert first_attempt.response_metadata["stream_error_code"] == "upstream_request_timeout"

    assert second_attempt.pool_upstream_assignment_id == shortlisted_success.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert request.retry_count == 1

    assert_http_sse_routing_metadata!(request, "bridge_ring", shortlisted_success.assignment, 2)
    assert_attempt_routing_metadata!(first_attempt, setup.assignment, setup.identity, 1)

    assert_attempt_routing_metadata!(
      second_attempt,
      shortlisted_success.assignment,
      shortlisted_success.identity,
      2
    )

    assert_safe_runtime_routing_metadata!(request, [first_attempt, second_attempt], setup)
  end

  @tag :task_5_sse_strategy_reliability
  test "SSE deterministic_rotation visible interruption demotes without hidden fallback" do
    release_ref = make_ref()

    failing_upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.output_text.delta\ndata: {"delta":"partial"}\n\n),
          notify: self(),
          release_ref: release_ref
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_stream_fallback_should_not_run",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    excluded_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_stream_excluded_should_not_run",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(failing_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    excluded =
      gateway_upstream(setup.pool, excluded_upstream, "upstream-token-excluded", compact?: false)

    prime_routing_quota!(fallback.identity)
    prime_routing_quota!(excluded.identity)
    use_routing_strategy!(setup.pool, "deterministic_rotation", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          fallback.assignment,
          excluded.assignment
        ])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "stream failure after visible output",
                 "stream" => true
               },
               %{
                 request_id: deterministic_rotation_seed(3, 0),
                 upstream_endpoint: "/backend-api/codex/responses",
                 receive_timeout: 100
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.output_text.delta\n"
    assert stream_conn.resp_body =~ ~s("delta":"partial")

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert FakeUpstream.count(excluded_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_idle_timeout"
    assert_http_sse_routing_metadata!(request, "deterministic_rotation", setup.assignment, 2)

    assert get_in(request.request_metadata, ["routing", "demotion_reason"]) ==
             "stream_idle_timeout"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.pool_upstream_assignment_id == setup.assignment.id
    assert attempt.network_error_code == "stream_idle_timeout"
    assert_attempt_routing_metadata!(attempt, setup.assignment, setup.identity, 1)

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.pool_upstream_assignment_id == setup.assignment.id
    assert demotion.reason_code == "stream_idle_timeout"
    assert demotion.status == "active"
    assert demotion.metadata == %{"source" => "gateway_failure"}

    assert [circuit] =
             Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_stream"))

    assert circuit.pool_upstream_assignment_id == setup.assignment.id
    assert circuit.reason_code == "stream_idle_timeout"
    assert circuit.failure_count == 1

    assert_safe_runtime_routing_metadata!(request, [attempt], setup)
  end

  test "SSE upstream read timeout after downstream keepalives remains upstream idle", %{
    conn: _conn
  } do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 50}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          ~s(event: response.output_text.delta\ndata: {"delta":"partial"}\n\n),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "stream idle timeout after keepalive",
                 "stream" => true
               },
               %{
                 request_id: "sse-idle-timeout-after-keepalive",
                 upstream_endpoint: "/backend-api/codex/responses",
                 receive_timeout: 150
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.output_text.delta\n"
    assert stream_conn.resp_body =~ ~s("delta":"partial")
    assert stream_conn.resp_body =~ ": keepalive\n\n"

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_idle_timeout"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_idle_timeout"
    assert attempt.error_message == "upstream stream idle timeout"
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event upstream_request_timeout retries and second attempt succeeds" do
    {setup, failing_upstream, success_upstream} =
      stream_retry_setup(first_event_terminal_sse("response.failed", "upstream_request_timeout"))

    execute_backend_stream!(setup, "first-event-timeout-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "upstream_request_timeout")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event stream_incomplete retries and second attempt succeeds" do
    {setup, failing_upstream, success_upstream} =
      stream_retry_setup(first_event_terminal_sse("response.incomplete", "stream_incomplete"))

    execute_backend_stream!(setup, "first-event-incomplete-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "stream_incomplete")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event server_error retries and second attempt succeeds" do
    {setup, failing_upstream, success_upstream} =
      stream_retry_setup(first_event_terminal_sse("response.failed", "server_error"))

    execute_backend_stream!(setup, "first-event-server-error-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "server_error")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event overloaded_error retries and second attempt succeeds" do
    {setup, failing_upstream, success_upstream} =
      stream_retry_setup(first_event_terminal_sse("response.failed", "overloaded_error"))

    execute_backend_stream!(setup, "first-event-overloaded-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "overloaded_error")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event server_is_overloaded retries and second attempt succeeds" do
    {setup, failing_upstream, success_upstream} =
      stream_retry_setup(first_event_terminal_sse("response.failed", "server_is_overloaded"))

    execute_backend_stream!(setup, "first-event-server-is-overloaded-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "server_is_overloaded")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE visible output followed by transient failure does not retry" do
    first_upstream =
      FakeUpstream.sse_stream(
        [
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible"}},
          first_event_terminal_payload("response.failed", "upstream_request_timeout")
        ],
        done: false
      )

    {setup, failing_upstream, fallback_upstream} = stream_retry_setup(first_upstream)

    execute_backend_stream!(setup, "visible-output-no-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_stream_terminal_failure!(setup, "upstream_request_timeout")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-and-only usage-limit terminal failure stays failed without retry" do
    first_upstream =
      FakeUpstream.sse_stream(
        [
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "resp_usage_limit_terminal",
               "status" => "failed",
               "error" => %{"code" => "usage_limit_exceeded"},
               "usage" => %{
                 "input_tokens" => 10,
                 "cached_input_tokens" => 4,
                 "output_tokens" => 2,
                 "reasoning_tokens" => 1,
                 "total_tokens" => 12
               }
             }
           }}
        ],
        done: false,
        headers: [{"x-codex-rate-limit-reached-type", "workspace_owner_usage_limit_reached"}]
      )

    {setup, failing_upstream, fallback_upstream} = stream_retry_setup(first_upstream)

    execute_backend_stream!(setup, "first-and-only-usage-limit-terminal")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "usage_limit_exceeded"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "usage_limit_exceeded"

    assert attempt.response_metadata["rate_limit_reached_type"] ==
             "workspace_owner_usage_limit_reached"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    assert metadata_text =~ "workspace_owner_usage_limit_reached"
    refute metadata_text =~ "resp_usage_limit_terminal"
    refute metadata_text =~ "x-codex-rate-limit-reached-type"
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "cookie"
    refute metadata_text =~ "upstream-token"
    refute metadata_text =~ "auth.json"
  end

  test "SSE usage-limit-reached terminal failure stays health-neutral without retry" do
    first_upstream =
      FakeUpstream.sse_stream(
        [
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "resp_usage_limit_reached_terminal",
               "status" => "failed",
               "error" => %{"code" => "usage_limit_reached"},
               "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
             }
           }}
        ],
        done: false
      )

    {setup, failing_upstream, fallback_upstream} = stream_retry_setup(first_upstream)

    execute_backend_stream!(setup, "usage-limit-reached-terminal")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "usage_limit_reached"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "usage_limit_reached"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE downstream closed chunk is logged as client disconnect" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible"}}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "stream client disconnect fixture",
                 "stream" => true
               },
               %{upstream_endpoint: "/backend-api/codex/responses"}
             )

    %Plug.Conn{} = conn = Phoenix.ConnTest.build_conn()
    closed_conn = %{conn | adapter: {ClosedChunkAdapter, nil}, state: :chunked}

    assert {:ok, _conn} = stream.(closed_conn)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "client_disconnected"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
    assert attempt.error_message == "client disconnected while writing downstream stream"
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE noncanonical upstream context error stays health-neutral" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "sequence_number" => 1,
               "response" => %{"status" => "failed"},
               "error" => %{
                 "code" => "context_length_exceeded",
                 "message" => "Input exceeds this model context window."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "large context fixture",
                 "stream" => true
               },
               %{
                 request_id: "top-level-context-error",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("type":"response.failed")
    assert stream_conn.resp_body =~ ~s("code":"context_length_exceeded")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "context_length_exceeded"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "context_length_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE previous response miss is masked while preserving upstream metadata" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "previous_response_not_found",
                 "message" => "Previous response with id 'resp_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue",
                 "stream" => true,
                 "previous_response_id" => "resp_missing"
               },
               %{
                 request_id: "sse-previous-response-not-found",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")
    refute stream_conn.resp_body =~ "previous_response_not_found"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_incomplete"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE wrapped status_code previous response miss is masked while preserving metadata" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "previous_response_not_found",
                 "message" => "Previous response with id 'resp_status_code_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue",
                 "stream" => true,
                 "previous_response_id" => "resp_status_code_missing"
               },
               %{
                 request_id: "sse-status-code-previous-response-not-found",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")
    refute stream_conn.resp_body =~ "previous_response_not_found"
    refute stream_conn.resp_body =~ "resp_status_code_missing"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_incomplete"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE wrapped status_code rate limit preserves nested code without broadening retry" do
    first_mode =
      FakeUpstream.sse_stream(
        [
          {"error",
           %{
             "type" => "error",
             "status_code" => 429,
             "error" => %{
               "type" => "requests",
               "code" => "rate_limit_exceeded",
               "message" => "rate limited"
             }
           }}
        ],
        done: false,
        headers: [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"}]
      )

    {setup, failing_upstream, fallback_upstream} = stream_retry_setup(first_mode)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "rate limit wrapped error fixture",
                 "stream" => true
               },
               %{
                 request_id: deterministic_rotation_seed(2, 0),
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("code":"rate_limit_exceeded")
    refute stream_conn.resp_body =~ ~s("code":"error")
    refute stream_conn.resp_body =~ "stream_incomplete"

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_stream_terminal_failure!(setup, "rate_limit_exceeded")

    assert [attempt] = Repo.all(from(a in Attempt))

    assert attempt.response_metadata["rate_limit_reached_type"] ==
             "workspace_member_usage_limit_reached"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE previous response miss after partial output is masked without retrying" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}},
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{"status" => "failed"},
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "previous_response_not_found",
                 "message" => "Previous response with id 'resp_partial_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue after partial output",
                 "stream" => true,
                 "previous_response_id" => "resp_partial_missing"
               },
               %{
                 request_id: "sse-partial-previous-response-not-found",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ ~s("delta":"partial")
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")
    refute stream_conn.resp_body =~ "previous_response_not_found"
    refute stream_conn.resp_body =~ "resp_partial_missing"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_incomplete"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE invalid previous response id after partial output is masked without retrying" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}},
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{"status" => "failed"},
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_previous_response_id",
                 "message" => "invalid previous_response_id"
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue after invalid partial output",
                 "stream" => true,
                 "previous_response_id" => "resp_invalid_partial"
               },
               %{
                 request_id: "sse-partial-invalid-previous-response-id",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ ~s("delta":"partial")
    assert stream_conn.resp_body =~ "event: response.failed\n"
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")
    refute stream_conn.resp_body =~ "invalid_previous_response_id"
    refute stream_conn.resp_body =~ "resp_invalid_partial"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "stream_incomplete"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "invalid_previous_response_id"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE invalid previous response id stays health-neutral after masking" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{"status" => "failed"},
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_previous_response_id",
                 "message" => "invalid previous_response_id"
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue",
                 "stream" => true,
                 "previous_response_id" => "resp_invalid"
               },
               %{
                 request_id: "sse-invalid-previous-response-id",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")
    refute stream_conn.resp_body =~ "invalid_previous_response_id"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.last_error_code == "stream_incomplete"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "invalid_previous_response_id"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE previous response param errors are semantically masked" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{"status" => "failed"},
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request_error",
                 "param" => "previous_response_id",
                 "message" => "Previous response with id 'resp_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "continue",
                 "stream" => true,
                 "previous_response_id" => "resp_missing"
               },
               %{
                 request_id: "sse-semantic-previous-response-not-found",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    assert stream_conn.resp_body =~ ~s("code":"stream_incomplete")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  @tag :task_4_first_event_stream_retry
  test "SSE tool output followed by transient failure does not retry" do
    first_upstream =
      FakeUpstream.sse_stream(
        [
          {"response.output_item.added",
           %{
             "type" => "response.output_item.added",
             "item" => %{"type" => "function_call", "call_id" => "call_fixture"}
           }},
          first_event_terminal_payload("response.failed", "server_error")
        ],
        done: false
      )

    {setup, failing_upstream, fallback_upstream} = stream_retry_setup(first_upstream)

    execute_backend_stream!(setup, "tool-output-no-retry")

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_stream_terminal_failure!(setup, "server_error")

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "SSE streams inject keepalive comments during upstream idle gaps" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 50}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "first"}},
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_keepalive",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, stream_conn} =
             execute_stream_after_releasing_barrier(
               auth,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "keepalive fixture",
                 "stream" => true
               },
               %{
                 request_id: "sse-keepalive",
                 upstream_endpoint: "/backend-api/codex/responses"
               },
               release_ref,
               125
             )

    assert stream_conn.resp_body =~ "event: response.output_text.delta\n"
    assert stream_conn.resp_body =~ "\"type\":\"response.output_text.delta\""
    assert stream_conn.resp_body =~ ": keepalive\n\n"
    assert stream_conn.resp_body =~ "data: [DONE]\n\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
  end

  test "SSE streams can disable keepalive comments" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 0}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_keepalive_disabled",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "keepalive disabled fixture",
                 "stream" => true
               },
               %{
                 request_id: "sse-keepalive-disabled",
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, stream_conn} = stream.(stream_conn)
    refute stream_conn.resp_body =~ ": keepalive\n\n"
    assert stream_conn.resp_body =~ "resp_keepalive_disabled"
    assert stream_conn.resp_body =~ "data: [DONE]\n\n"
  end

  @tag :task_4_first_event_stream_retry
  test "SSE keepalive before retryable first event preserves current stream state" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 50}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    release_ref = make_ref()

    first_mode =
      FakeUpstream.barrier_sse_stream(
        [first_event_terminal_payload("response.failed", "upstream_request_timeout")],
        barrier_after: 0,
        done: false,
        notify: self(),
        release_ref: release_ref
      )

    {setup, failing_upstream, success_upstream} = stream_retry_setup(first_mode)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, stream_conn} =
             execute_stream_after_releasing_barrier(
               auth,
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "keepalive before first event retry fixture",
                 "stream" => true
               },
               %{
                 request_id: deterministic_rotation_seed(2, 0),
                 upstream_endpoint: "/backend-api/codex/responses"
               },
               release_ref,
               125
             )

    assert stream_conn.resp_body =~ ": keepalive\n\n"
    assert stream_conn.resp_body =~ "resp_stream_retry_success"
    assert stream_conn.resp_body =~ "data: [DONE]\n\n"

    assert FakeUpstream.count(failing_upstream) == 1
    assert FakeUpstream.count(success_upstream) == 1
    assert_stream_retry_success!(setup, "upstream_request_timeout")
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event transient failures exhaust planned retries with safe metadata" do
    first_mode = first_event_terminal_sse("response.failed", "upstream_request_timeout")
    second_mode = first_event_terminal_sse("response.failed", "server_error")
    {setup, first_upstream, second_upstream} = stream_retry_setup(first_mode, second_mode)

    execute_backend_stream!(setup, "first-event-retry-exhausted")

    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(second_upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_request_timeout"
    assert second_attempt.status == "failed"
    assert second_attempt.network_error_code == "server_error"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "server_error"
    assert_safe_stream_metadata!(request, [first_attempt, second_attempt])
  end

  @tag :task_4_first_event_stream_retry
  test "SSE first-event retry propagates fallback dispatch errors" do
    first_mode = first_event_terminal_sse("response.failed", "upstream_request_timeout")
    {setup, first_upstream, fallback_upstream} = stream_retry_setup(first_mode)

    {:ok, _assignment} =
      PoolAssignments.update_pool_assignment(setup.fallback_assignment, %{
        metadata: Map.put(setup.fallback_assignment.metadata, "base_url", "http://127.0.0.1:1")
      })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             execute_gateway(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "stream retry fallback dispatch error fixture",
                 "stream" => true
               },
               %{
                 request_id: deterministic_rotation_seed(2, 0),
                 upstream_endpoint: "/backend-api/codex/responses"
               }
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    logs =
      capture_log(fn ->
        assert {:error, %{code: "upstream_request_failed"}} = stream.(stream_conn)
      end)

    assert logs =~ "gateway upstream transport failed"
    assert logs =~ "transport=http_sse"
    assert logs =~ "endpoint=/backend-api/codex/responses"
    assert logs =~ "upstream_identity_id=#{setup.fallback_assignment.upstream_identity_id}"
    assert logs =~ "pool_upstream_assignment_id=#{setup.fallback_assignment.id}"
    assert logs =~ "exception="
    assert logs =~ "reason="
    refute logs =~ "stream retry fallback dispatch error fixture"
    refute logs =~ "upstream-token"
    refute logs =~ "authorization"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_request_timeout"
    refute Map.has_key?(first_attempt.response_metadata, "transport_failure")

    assert second_attempt.status == "failed"
    assert second_attempt.network_error_code == "upstream_network_error"

    assert_safe_transport_failure_metadata!(second_attempt, [
      "stream retry fallback dispatch error fixture",
      "upstream-token",
      "authorization"
    ])

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "upstream_network_error"
  end

  test "POST /backend-api/codex/responses finalizes reservation when all planned candidates reject at circuit begin",
       %{
         conn: conn
       } do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_circuit_first_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_circuit_second_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    {setup, first_state, second_state} =
      unboxed_run(fn ->
        setup = gateway_setup(first_upstream)

        second =
          gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

        prime_routing_quota!(second.identity)
        use_deterministic_rotation!(setup.pool, 2)

        setup =
          Map.put(
            setup,
            :model,
            put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
          )

        first_state = half_open_circuit!(setup, setup.assignment)
        second_state = half_open_circuit!(setup, second.assignment)

        {setup, first_state, second_state}
      end)

    register_unboxed_pool_cleanup!(setup.pool)
    first_lock = lock_circuit_probe!(first_state)
    second_lock = lock_circuit_probe!(second_state)

    :ok = CodexPooler.Events.subscribe_pool(setup.pool)

    request_task =
      Task.async(fn ->
        unboxed_run(fn ->
          conn
          |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "post reservation circuit rejection"
          })
        end)
      end)

    request_id = assert_request_reserved!()
    release_circuit_probe!(first_lock, first_state)
    release_circuit_probe!(second_lock, second_state)

    conn = Task.await(request_task, 5_000)

    assert %{"error" => %{"code" => "no_eligible_backend"}} = json_response(conn, 503)
    assert FakeUpstream.count(first_upstream) == 0
    assert FakeUpstream.count(second_upstream) == 0

    request = Repo.get!(Request, request_id)
    assert request.status == "failed"
    assert request.last_error_code == "no_eligible_backend"

    refute Repo.exists?(
             from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress")
           )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    assert ["release", "reservation"] == ledger_entry_kinds(request)
  end

  test "POST /backend-api/codex/responses retries the next planned candidate after circuit begin rejects",
       %{
         conn: conn
       } do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_circuit_first_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_circuit_second_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    {setup, second, first_state} =
      unboxed_run(fn ->
        setup = gateway_setup(first_upstream)

        second =
          gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

        prime_routing_quota!(second.identity)
        use_deterministic_rotation!(setup.pool, 2)

        setup =
          Map.put(
            setup,
            :model,
            put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
          )

        first_state = half_open_circuit!(setup, setup.assignment)

        {setup, second, first_state}
      end)

    register_unboxed_pool_cleanup!(setup.pool)
    first_lock = lock_circuit_probe!(first_state)

    :ok = CodexPooler.Events.subscribe_pool(setup.pool)

    request_task =
      Task.async(fn ->
        unboxed_run(fn ->
          conn
          |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "retry post reservation circuit rejection"
          })
        end)
      end)

    request_id = assert_request_reserved!()
    release_circuit_probe!(first_lock, first_state)

    conn = Task.await(request_task, 5_000)

    assert %{"id" => "resp_circuit_second_success"} = json_response(conn, 200)
    assert FakeUpstream.count(first_upstream) == 0
    assert FakeUpstream.count(second_upstream) == 1

    request = Repo.get!(Request, request_id)
    assert request.status == "succeeded"

    refute Repo.exists?(
             from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "in_progress")
           )

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == second.assignment.id
    assert attempt.status == "succeeded"
    assert ["release", "reservation", "settlement"] == ledger_entry_kinds(request)
  end

  test "POST /backend-api/codex/responses/compact maps to upstream backend compact path", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)

    raw_prompt_cache_key = "raw-compact-prompt-cache-routing-key-do-not-log"

    conn =
      conn
      |> put_req_header("x-codex-turn-state", "compact-turn-state")
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact",
        "prompt_cache_key" => raw_prompt_cache_key,
        "max_output_tokens" => 128,
        "temperature" => 0.2,
        "top_p" => 0.9,
        "reasoning" => %{"effort" => "ultra"}
      })

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert captured.json["max_output_tokens"] == 128
    assert captured.json["temperature"] == 0.2
    assert captured.json["top_p"] == 0.9
    assert captured.json["reasoning"] == %{"effort" => "max"}
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"

    routing = request.request_metadata["routing"]
    assert routing["routing_locality_status"] == "unavailable"
    assert routing["routing_locality_applied"] == false
    assert routing["routing_locality_unhonored_reason"] == "prompt_cache_key_absent"
    refute Map.has_key?(routing, "routing_locality_seed_fingerprint")
    refute Map.has_key?(routing, "routing_locality_assignment_fingerprint")

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ raw_prompt_cache_key
    refute metadata_text =~ "cache_hit"
    refute metadata_text =~ "provider_cache"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert turn.transport_kind == "http_json"
    assert turn.status == "succeeded"
  end

  test "POST /backend-api/codex/responses/compact attempts compression and no-ops without candidates",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, supported_compression_model_opts(compact?: true))
    enable_request_compression!(setup.pool)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact without candidate output"
      })

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert captured.json["input"] == "compact without candidate output"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert %{
             "status" => "no_change",
             "reason" => "no_candidates",
             "route_class" => "proxy_compact",
             "transport" => "http_compact_json",
             "candidate_count" => 0,
             "compressed_count" => 0,
             "skipped_count" => 0
           } = attempt.response_metadata["payload_compression"]
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses/compact forwards and relays x-codex-turn-state",
       %{conn: conn} do
    request_turn_state = "compact-request-turn-state-#{System.unique_integer([:positive])}"
    response_turn_state = "compact-response-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "object" => "response.compaction",
            "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
          },
          [{"x-codex-turn-state", response_turn_state}]
        )
      )

    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic compact turn-state forwarding request"
      })

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  @tag :client_metadata
  test "POST /backend-api/codex/responses forwards and relays x-codex-turn-state for streaming responses",
       %{conn: conn} do
    request_turn_state = "backend-stream-turn-state-#{System.unique_integer([:positive])}"
    response_turn_state = "upstream-stream-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_backend_stream_turn_state",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          headers: [{"x-codex-turn-state", response_turn_state}]
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic streaming turn-state relay request",
        "stream" => true
      })

    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]
    assert conn.resp_body =~ "event: response.completed\n"
    assert conn.resp_body =~ "resp_backend_stream_turn_state"
    assert conn.resp_body =~ "data: [DONE]\n\n"

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  test "POST /backend-api/codex/responses does not synthesize public terminal events for raw backend stream closes",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "backend-visible-before-close"}}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic backend interrupted stream request",
        "stream" => true
      })

    assert conn.status == 200
    assert conn.resp_body =~ "backend-visible-before-close"
    refute conn.resp_body =~ "event: response.failed"
    refute conn.resp_body =~ "upstream_stream_error"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /backend-api/codex/responses relays stream safety-buffering metadata without persisting it",
       %{conn: conn} do
    safety_buffering = %{
      "model" => "safety-buffering-model-sentinel",
      "use_cases" => ["cyber"],
      "reasons" => ["user-risk-sentinel"]
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{
             "type" => "response.output_text.delta",
             "delta" => "visible synthetic safety-buffered text",
             "safety_buffering" => safety_buffering
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_backend_stream_safety_buffering",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic streaming safety-buffering relay request",
        "stream" => true
      })

    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ ~s("safety_buffering":)
    assert conn.resp_body =~ "safety-buffering-model-sentinel"
    assert conn.resp_body =~ "user-risk-sentinel"
    assert conn.resp_body =~ "data: [DONE]\n\n"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "safety-buffering-model-sentinel"
    refute metadata_text =~ "user-risk-sentinel"
  end

  test "POST /backend-api/codex/responses/compact keeps opencode continuity headers local without forwarding",
       %{
         conn: conn
       } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    session_id_header = "compact-session-id-#{System.unique_integer([:positive])}"
    x_session_id_header = "compact-x-session-id-#{System.unique_integer([:positive])}"
    affinity_header = "compact-session-affinity-#{System.unique_integer([:positive])}"

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-session-id", " ")
      |> put_req_header("session-id", session_id_header)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact session-id continuity fixture"
      })

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", x_session_id_header)
      |> put_req_header("x-session-affinity", "compact-lower-priority-affinity")
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact x-session-id continuity fixture"
      })

    third_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", " ")
      |> put_req_header("x-session-id", " ")
      |> put_req_header("x-session-affinity", affinity_header)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact affinity continuity fixture"
      })

    assert %{"object" => "response.compaction"} = json_response(first_conn, 200)
    assert %{"object" => "response.compaction"} = json_response(second_conn, 200)
    assert %{"object" => "response.compaction"} = json_response(third_conn, 200)

    assert %CodexSession{} =
             session_id_session = Repo.get_by(CodexSession, session_key: session_id_header)

    assert %CodexSession{} =
             x_session_id_session = Repo.get_by(CodexSession, session_key: x_session_id_header)

    assert %CodexSession{} =
             affinity_session = Repo.get_by(CodexSession, session_key: affinity_header)

    refute Repo.get_by(CodexSession, session_key: "compact-lower-priority-affinity")

    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^setup.pool.id,
          order_by: [asc: r.admitted_at]
      )

    assert Enum.map(requests, & &1.request_metadata["codex_session_id"]) == [
             session_id_session.id,
             x_session_id_session.id,
             affinity_session.id
           ]

    assert Enum.map(requests, & &1.request_metadata["codex_session_key"]) == [
             session_id_header,
             x_session_id_header,
             affinity_header
           ]

    assert [first_upstream_request, second_upstream_request, third_upstream_request] =
             FakeUpstream.requests(upstream)

    for captured <- [first_upstream_request, second_upstream_request, third_upstream_request] do
      assert captured.path == "/backend-api/codex/responses/compact"
      captured_headers = Map.new(captured.headers)

      refute Map.has_key?(captured_headers, "session-id")
      refute Map.has_key?(captured_headers, "x-session-id")
      refute Map.has_key?(captured_headers, "x-session-affinity")
    end
  end

  test "POST /backend-api/codex/v1/responses/compact proxies to canonical compact path", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", "v1-compact-turn-state")
      |> auth(setup)
      |> post("/backend-api/codex/v1/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact through v1 alias"
      })

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"
  end

  test "POST /backend-api/codex/responses/compact accepts large raw JSON bodies", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 8, "output_tokens" => 2, "total_tokens" => 10}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    large_entry = String.duplicate("a", 8_100_000)

    body =
      Jason.encode!(%{
        "model" => setup.model.exposed_model_id,
        "input" => large_entry
      })

    assert byte_size(body) > 8_000_000
    assert byte_size(body) < OperationalSettings.current().max_decompressed_body_bytes

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-codex-turn-state", "compact-large-turn-state")
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", body)

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert byte_size(captured.json["input"]) == byte_size(large_entry)
  end

  test "POST /backend-api/codex/responses/compact finalizes upstream demand failures", %{
    conn: conn
  } do
    request_turn_state = "compact-failure-turn-state-#{System.unique_integer([:positive])}"

    response_turn_state =
      "compact-failure-response-turn-state-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{
            "error" => %{
              "code" => "rate_limit_exceeded",
              "message" =>
                "We're currently experiencing high demand, which may cause temporary errors."
            }
          },
          [{"x-codex-turn-state", response_turn_state}],
          429
        )
      )

    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> put_req_header("x-codex-turn-state", request_turn_state)
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact failure"
      })

    assert %{"error" => %{"code" => "rate_limit_exceeded"}} = json_response(conn, 429)
    assert get_resp_header(conn, "x-codex-turn-state") == [response_turn_state]

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert Map.new(captured.headers)["x-codex-turn-state"] == request_turn_state

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "failed"
    assert request.response_status_code == 429
    assert request.last_error_code == "upstream_status"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == 429

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert turn.transport_kind == "http_json"
    assert turn.status == "failed"

    assert_turn_state_not_persisted!(setup, request_turn_state)
    assert_turn_state_not_persisted!(setup, response_turn_state)
  end

  test "POST /backend-api/codex/responses/compact proxies without explicit compact metadata", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
        })
      )

    setup = gateway_setup(upstream, compact?: false)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "compact"
      })

    assert %{"object" => "response.compaction"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses/compact"
    assert request.transport == "http_compact_json"
    assert request.status == "succeeded"
  end

  @tag :installation_id_metadata
  test "POST /backend-api/codex/responses/compact forwards approved lineage metadata headers and redacts metadata",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_compact_lineage_headers",
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    metadata = lineage_metadata_fixture("forked-thread-task5-compact-canonical")

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/responses/compact",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic compact lineage forwarding request"
        },
        lineage_request_headers(metadata)
      )

    assert %{"object" => "response.compaction"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"

    captured_headers = Map.new(captured.headers)

    assert Map.take(captured_headers, approved_lineage_header_names()) == %{
             "x-codex-turn-metadata" => metadata.turn_metadata,
             "x-codex-window-id" => metadata.window_id,
             "x-codex-parent-thread-id" => metadata.parent_thread_id,
             "x-codex-installation-id" => metadata.installation_id,
             "x-openai-subagent" => metadata.subagent
           }

    assert_approved_lineage_headers_forwarded!(captured, metadata)
    assert_disallowed_client_headers_not_forwarded!(captured, setup)
    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  test "POST /backend-api/codex/responses/compact sends trusted Responses Lite marker from selected model metadata",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup =
      upstream
      |> gateway_setup(compact?: true)
      |> put_setup_model_source_metadata!(%{"use_responses_lite" => true})

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/responses/compact",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic compact Responses Lite marker request"
        },
        [{"x-openai-internal-unapproved", "client-internal-spoof"}]
      )

    assert %{"object" => "response.compaction"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    assert captured_headers["x-openai-internal-codex-responses-lite"] == "true"
    refute Map.has_key?(captured_headers, "x-openai-internal-unapproved")
  end

  @tag :installation_id_metadata
  test "POST /backend-api/codex/v1/responses/compact forwards approved lineage metadata with trusted Codex identity",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_backend_v1_compact_lineage_headers",
          "object" => "response.compaction",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    metadata = lineage_metadata_fixture("forked-thread-task5-compact-alias")

    conn =
      conn
      |> auth(setup)
      |> post_json_runtime_with_headers(
        "/backend-api/codex/v1/responses/compact",
        %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic alias compact lineage forwarding request"
        },
        lineage_request_headers(metadata)
      )

    assert %{"object" => "response.compaction"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses/compact"

    captured_headers = Map.new(captured.headers)

    assert Map.take(captured_headers, approved_lineage_header_names()) == %{
             "x-codex-turn-metadata" => metadata.turn_metadata,
             "x-codex-window-id" => metadata.window_id,
             "x-codex-parent-thread-id" => metadata.parent_thread_id,
             "x-codex-installation-id" => metadata.installation_id,
             "x-openai-subagent" => metadata.subagent
           }

    assert_approved_lineage_headers_forwarded!(captured, metadata)
    assert_disallowed_client_headers_not_forwarded!(captured, setup)
    assert_lineage_metadata_not_persisted!(setup, metadata)
  end

  test "POST /backend-api/codex/responses includes weekly-only probe candidates beside precise candidates",
       %{conn: conn} do
    precise_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_precise_candidate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    weekly_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_weekly_candidate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(precise_upstream)

    weekly =
      gateway_upstream(setup.pool, weekly_upstream, "upstream-token-weekly", compact?: false)

    prime_weekly_probe_quota!(weekly.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, weekly.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, weekly.assignment.id],
        weekly.assignment.id
      )

    conn =
      conn
      |> put_req_header("x-request-id", request_id)
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "route weekly probe quota"
      })

    assert %{"id" => "resp_weekly_candidate"} = json_response(conn, 200)
    assert FakeUpstream.count(precise_upstream) == 0
    assert FakeUpstream.count(weekly_upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "eligible_candidate_count"]) == 2
    assert get_in(request.request_metadata, ["quota_decision", "precise_candidate_count"]) == 1

    assert get_in(request.request_metadata, ["quota_decision", "weekly_probe_candidate_count"]) ==
             1
  end

  test "POST /backend-api/codex/responses allows weekly-only probe fallback when no precise candidate exists",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_weekly_probe_only",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, quota?: false)
    prime_weekly_probe_quota!(setup.identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "weekly probe fallback"
      })

    assert %{"id" => "resp_weekly_probe_only"} = json_response(conn, 200)
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) ==
             "weekly_only_probe"
  end

  test "POST /backend-api/codex/responses routes monthly-only account primary quota evidence",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_monthly_primary_only",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream, quota?: false)

    assert {:ok, [_monthly]} =
             QuotaWindows.upsert_quota_windows(setup.identity, [
               monthly_only_account_primary_quota_window_attrs()
             ])

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "monthly account primary only"
      })

    assert %{"id" => "resp_monthly_primary_only"} = json_response(conn, 200)
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "precise_candidate_count"]) == 1
    refute inspect(request.request_metadata) =~ "quota_account_primary_missing"
  end

  test "POST /backend-api/codex/responses refreshes stale reset-bearing quota before rejecting",
       %{conn: conn} do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 12,
                    "limit_window_seconds" => 18_000,
                    "reset_at" => DateTime.to_iso8601(reset_at)
                  }
                }
              }},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_refreshed_stale_quota",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)
    prime_stale_routing_quota!(setup.identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "recover stale quota"
      })

    assert %{"id" => "resp_refreshed_stale_quota"} = json_response(conn, 200)

    {_usage_request, response_request} = assert_usage_probe_then_response(upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    assert [window] = QuotaWindows.list_quota_windows(setup.identity)
    assert window.source == "codex_usage_api"
    assert QuotaWindows.usable_window?(window)
  end

  test "candidate quota classification returns a refresh plan without refreshing itself" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 12,
                    "limit_window_seconds" => 18_000,
                    "reset_at" => DateTime.to_iso8601(reset_at)
                  }
                }
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)
    prime_stale_routing_quota!(setup.identity)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{"model" => setup.model.exposed_model_id, "input" => "classify stale quota"}

    request_options =
      RequestOptions.build(
        %{upstream_endpoint: "/backend-api/codex/responses"},
        "/backend-api/codex/responses",
        payload
      )

    input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: payload,
        request_options: request_options,
        candidates: [{setup.assignment, setup.identity}]
      })

    assert {:refreshable_quota, plan} =
             CandidateEligibility.filter_quota_eligible_candidates(input)

    assert plan.filter_input == input
    assert plan.refreshable_candidates == [{setup.assignment, setup.identity}]

    assert [%{freshness_state: "stale"}] =
             QuotaWindows.list_quota_windows(setup.identity)

    assert FakeUpstream.requests(upstream) == []
  end

  test "POST /backend-api/codex/responses refreshes expired stale quota before rejecting",
       %{conn: conn} do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 12,
                    "limit_window_seconds" => 18_000,
                    "reset_at" => DateTime.to_iso8601(reset_at)
                  }
                }
              }},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_refreshed_expired_stale_quota",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)
    prime_expired_stale_routing_quota!(setup.identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "recover expired stale quota"
      })

    assert %{"id" => "resp_refreshed_expired_stale_quota"} = json_response(conn, 200)

    {_usage_request, response_request} = assert_usage_probe_then_response(upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    assert [window] = QuotaWindows.list_quota_windows(setup.identity)
    assert window.source == "codex_usage_api"
    assert QuotaWindows.usable_window?(window)
  end

  test "POST /backend-api/codex/responses refreshes expired stale account and model quota windows",
       %{conn: conn} do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)
    secondary_reset_at = DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 12,
                    "limit_window_seconds" => 18_000,
                    "reset_at" => DateTime.to_iso8601(reset_at)
                  },
                  "secondary_window" => %{
                    "used_percent" => 24,
                    "limit_window_seconds" => 604_800,
                    "reset_at" => DateTime.to_iso8601(secondary_reset_at)
                  }
                },
                "additional_rate_limits" => [
                  %{
                    "limit_name" => "gpt-test-model",
                    "rate_limit" => %{
                      "primary_window" => %{
                        "used_percent" => 8,
                        "limit_window_seconds" => 18_000,
                        "reset_at" => DateTime.to_iso8601(reset_at)
                      },
                      "secondary_window" => %{
                        "used_percent" => 16,
                        "limit_window_seconds" => 604_800,
                        "reset_at" => DateTime.to_iso8601(secondary_reset_at)
                      }
                    }
                  }
                ]
              }},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_refreshed_all_known_quota_windows",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)
    prime_expired_stale_known_quota_windows!(setup.identity, setup.model)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "recover all known quota windows"
      })

    assert %{"id" => "resp_refreshed_all_known_quota_windows"} = json_response(conn, 200)

    {_usage_request, response_request} = assert_usage_probe_then_response(upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    window_keys =
      setup.identity
      |> QuotaWindows.list_quota_windows()
      |> Enum.map(&{&1.quota_scope, &1.quota_family, &1.quota_key, &1.window_kind})
      |> Enum.sort()

    assert window_keys ==
             [
               {"account", "account", "account", "primary"},
               {"account", "account", "account", "secondary"},
               {"model", "codex_model", "gpt_test_model", "primary"},
               {"model", "codex_model", "gpt_test_model", "secondary"}
             ]
  end

  test "POST /backend-api/codex/responses keeps local session pin soft when pinned quota is exhausted",
       %{conn: conn} do
    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_soft_pinned_quota_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_soft_pin_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-soft-pinned", compact?: false)

    prime_exhausted_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    session_header = "soft-quota-session-#{System.unique_integer([:positive])}"
    session = register_session_header_anchor!(auth, pinned.assignment, session_header)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("session-id", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "soft pinned quota fallback",
        "stream" => true
      })

    assert %{"id" => "resp_soft_pinned_quota_fallback"} = json_response(conn, 200)
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert request.request_metadata["codex_session_id"] == session.id
    assert request.request_metadata["codex_session_key"] == session_header
    assert get_in(request.request_metadata, ["quota_decision", "eligible_candidate_count"]) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == setup.assignment.id
  end

  test "POST /backend-api/codex/responses keeps local session pin soft for non-streaming fallback",
       %{conn: conn} do
    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_soft_pinned_non_streaming_quota_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_non_streaming_soft_pin_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-soft-pinned-json",
        compact?: false
      )

    prime_exhausted_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    session_header = "soft-json-quota-session-#{System.unique_integer([:positive])}"
    session = register_session_header_anchor!(auth, pinned.assignment, session_header)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("session-id", session_header)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "non-streaming soft pinned quota fallback"
      })

    assert %{"id" => "resp_soft_pinned_non_streaming_quota_fallback"} =
             json_response(conn, 200)

    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_json"
    assert request.request_metadata["codex_session_id"] == session.id
    assert request.request_metadata["codex_session_key"] == session_header
    assert get_in(request.request_metadata, ["quota_decision", "eligible_candidate_count"]) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == setup.assignment.id

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "non-streaming soft pinned quota fallback"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token-soft-pinned-json"
  end

  @tag :hard_pinned_quota_recovery
  test "POST /backend-api/codex/responses keeps previous_response_id hard pinned when pinned quota is exhausted",
       %{conn: conn} do
    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_hard_anchor_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_hard_pin_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-hard-pinned", compact?: false)

    prime_exhausted_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    previous_response_id = "resp_hard_quota_anchor_#{System.unique_integer([:positive])}"
    register_previous_response_anchor!(auth, pinned.assignment, previous_response_id)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hard pinned quota rejection",
        "previous_response_id" => previous_response_id
      })

    assert_pinned_unavailable_recovery_response!(conn)
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "pinned_continuation_unavailable"
    assert Repo.aggregate(Attempt, :count) == 0

    assert_pinned_unavailable_metadata!(
      request,
      pinned.assignment,
      pinned.identity,
      "previous_response_id",
      "quota_exhausted"
    )
  end

  @tag :hard_pinned_quota_recovery
  test "POST /backend-api/codex/responses keeps file affinity hard pinned when quota is exhausted",
       %{conn: conn} do
    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_file_affinity_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_file_affinity_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-file-affinity-exhausted",
        compact?: false
      )

    prime_exhausted_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    file_id =
      response_affinity_file_fixture(setup, pinned.assignment, pinned.identity,
        file_id: "file_exhausted_quota_affinity_#{System.unique_integer([:positive])}",
        filename: "exhausted-quota-affinity.txt",
        byte_size: 23,
        status: "uploaded",
        finalize_status: "succeeded"
      ).file_id

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => file_id}]
      })

    assert_pinned_unavailable_recovery_response!(conn)
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "pinned_continuation_unavailable"
    assert Repo.aggregate(Attempt, :count) == 0

    assert_pinned_unavailable_metadata!(
      request,
      pinned.assignment,
      pinned.identity,
      "file_affinity",
      "quota_exhausted"
    )

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ file_id
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token-file-affinity-exhausted"
  end

  @tag :hard_pinned_quota_recovery
  test "POST /backend-api/codex/responses refreshes hard previous-response stale quota before rejection",
       %{conn: conn} do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    exhausted_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 18_000,
          "reset_at" => DateTime.to_iso8601(reset_at)
        }
      }
    }

    pinned_upstream =
      start_upstream(
        {:path_json, %{"/backend-api/wham/usage" => {200, exhausted_quota_response}}}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_previous_anchor_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-previous-anchor-stale",
        compact?: false
      )

    prime_stale_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    previous_response_id = "resp_stale_quota_anchor_#{System.unique_integer([:positive])}"
    register_previous_response_anchor!(auth, pinned.assignment, previous_response_id)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "hard previous-response quota rejection",
        "previous_response_id" => previous_response_id
      })

    assert_pinned_unavailable_recovery_response!(conn)
    assert_usage_probe_requests(pinned_upstream)
    assert FakeUpstream.requests(fallback_upstream) == []
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "pinned_continuation_unavailable"

    assert_pinned_unavailable_metadata!(
      request,
      pinned.assignment,
      pinned.identity,
      "previous_response_id",
      "quota_evidence_unavailable"
    )
  end

  test "POST /backend-api/codex/responses refreshes hard file-affinity stale quota before fallback candidates",
       %{conn: conn} do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    stale_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => DateTime.to_iso8601(reset_at)
        }
      }
    }

    pinned_upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, stale_quota_response},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_file_affinity_refreshed_quota",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_file_affinity_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(fallback_upstream)

    pinned =
      gateway_upstream(setup.pool, pinned_upstream, "upstream-token-file-affinity-stale",
        compact?: false
      )

    prime_stale_routing_quota!(pinned.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [pinned.assignment, setup.assignment])
      )

    file_id =
      response_affinity_file_fixture(setup, pinned.assignment, pinned.identity,
        file_id: "file_stale_quota_affinity_#{System.unique_integer([:positive])}",
        filename: "stale-quota-affinity.txt",
        byte_size: 21,
        status: "uploaded",
        finalize_status: "succeeded"
      ).file_id

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => file_id}]
      })

    assert %{"id" => "resp_file_affinity_refreshed_quota"} = json_response(conn, 200)
    assert FakeUpstream.requests(fallback_upstream) == []

    {_usage_request, response_request} = assert_usage_probe_then_response(pinned_upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             pinned.assignment.id

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == pinned.assignment.id
  end

  test "POST /backend-api/codex/responses excludes exhausted stale and resetless quota candidates from routing",
       %{conn: conn} do
    precise_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_precise_survivor",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    exhausted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_candidate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    stale_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_stale_candidate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    resetless_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_resetless_candidate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(precise_upstream)

    exhausted =
      gateway_upstream(setup.pool, exhausted_upstream, "upstream-token-exhausted",
        compact?: false
      )

    stale = gateway_upstream(setup.pool, stale_upstream, "upstream-token-stale", compact?: false)

    resetless =
      gateway_upstream(setup.pool, resetless_upstream, "upstream-token-resetless",
        compact?: false
      )

    prime_exhausted_routing_quota!(exhausted.identity)
    prime_stale_routing_quota!(stale.identity)
    prime_resetless_routing_quota!(resetless.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          exhausted.assignment,
          stale.assignment,
          resetless.assignment
        ])
      )

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "exclude unusable quota windows"
      })

    assert %{"id" => "resp_precise_survivor"} = json_response(conn, 200)
    assert FakeUpstream.count(precise_upstream) == 1
    assert FakeUpstream.count(exhausted_upstream) == 0

    refute Enum.any?(
             FakeUpstream.requests(stale_upstream),
             &(&1.path == "/backend-api/codex/responses")
           )

    assert FakeUpstream.count(resetless_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "precise"
    assert get_in(request.request_metadata, ["quota_decision", "eligible_candidate_count"]) == 1
  end

  test "POST /backend-api/codex/responses returns deterministic quota_exhausted when all candidates are exhausted",
       %{conn: conn} do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_first_exhausted_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_second_exhausted_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream, quota?: false)

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second-exhausted",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_exhausted_routing_quota!(second.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "all exhausted quota rejection"
      })

    response = json_response(conn, 503)

    assert %{"error" => %{"code" => "quota_exhausted", "message" => message}} = response
    assert message == "upstream quota is exhausted until its reset time"
    assert FakeUpstream.count(first_upstream) == 0
    assert FakeUpstream.count(second_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "quota_exhausted"
    assert Repo.aggregate(Attempt, :count) == 0

    reason_codes =
      request.request_metadata["candidate_exclusions"]
      |> Enum.map(fn exclusion -> exclusion["reasons"] |> hd() |> Map.fetch!("reason_codes") end)
      |> Enum.sort()

    assert reason_codes == [["exhausted"], ["exhausted"]]

    metadata_text = inspect({response, request.request_metadata})
    refute metadata_text =~ "all exhausted quota rejection"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token-second-exhausted"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "POST /backend-api/codex/responses returns metadata-only 503 details when all quota candidates are excluded",
       %{conn: conn} do
    exhausted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_exhausted_only",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    stale_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_stale_only",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    resetless_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_resetless_only",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(exhausted_upstream, quota?: false)

    stale = gateway_upstream(setup.pool, stale_upstream, "upstream-token-stale", compact?: false)

    resetless =
      gateway_upstream(setup.pool, resetless_upstream, "upstream-token-resetless",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_stale_routing_quota!(stale.identity)
    prime_resetless_routing_quota!(resetless.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          stale.assignment,
          resetless.assignment
        ])
      )

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "sensitive prompt body for quota exclusion"
      })

    response = json_response(conn, 503)

    assert %{"error" => %{"code" => "quota_exhausted", "message" => message}} = response
    assert message == "upstream quota is exhausted until its reset time"
    assert FakeUpstream.count(exhausted_upstream) == 0

    refute Enum.any?(
             FakeUpstream.requests(stale_upstream),
             &(&1.path == "/backend-api/codex/responses")
           )

    assert FakeUpstream.count(resetless_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.last_error_code == "quota_exhausted"

    reason_codes =
      request.request_metadata["candidate_exclusions"]
      |> Enum.map(fn exclusion -> exclusion["reasons"] |> hd() |> Map.fetch!("reason_codes") end)
      |> Enum.sort()

    assert reason_codes == [["exhausted"], ["not_fresh"], ["reset_missing"]]

    metadata_text = inspect({response, request.request_metadata})
    refute metadata_text =~ "sensitive prompt body for quota exclusion"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token-stale"
    refute metadata_text =~ "upstream-token-resetless"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  defp seed_with_assignment_order(assignment_ids) do
    Enum.find_value(1..500, fn index ->
      seed = "bridge-ring-ordered-seed-#{index}"

      ordered_ids =
        assignment_ids
        |> Enum.sort_by(&rendezvous_score(seed, &1), :desc)

      if ordered_ids == assignment_ids, do: seed
    end) || raise "missing bridge ring ordered seed"
  end

  defp assert_http_sse_routing_metadata!(request, strategy, assignment, ring_size) do
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"

    assert %{"routing" => routing} = request.request_metadata
    assert routing["strategy"] == strategy
    assert routing["bridge_ring_size"] == ring_size
    assert routing["selected_bridge_candidate_id"] == assignment.id
    assert routing["affinity_enabled"] in [true, false]
    assert routing["affinity_status"] in ["disabled", "miss", "hit"]
    assert is_boolean(routing["affinity_hit"])
  end

  defp assert_http_json_routing_metadata!(request, strategy, assignment, ring_size) do
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_json"

    assert %{"routing" => routing} = request.request_metadata
    assert routing["strategy"] == strategy
    assert routing["bridge_ring_size"] == ring_size
    assert routing["selected_bridge_candidate_id"] == assignment.id
    assert routing["affinity_enabled"] in [true, false]
    assert routing["affinity_status"] in ["disabled", "miss", "hit"]
    assert is_boolean(routing["affinity_hit"])
  end

  defp assert_attempt_routing_metadata!(attempt, assignment, identity, rank) do
    assert %{"routing" => routing} = attempt.response_metadata
    assert routing["bridge_candidate_id"] == assignment.id
    assert routing["bridge_candidate_rank"] == rank
    assert routing["upstream_identity_id"] == identity.id
  end

  defp assert_transport_failure_metadata!(attempt, expected) do
    assert %{} = transport_failure = attempt.response_metadata["transport_failure"]

    Enum.each(expected, fn {key, value} ->
      assert transport_failure[key] == value
    end)

    transport_failure
  end

  defp assert_safe_transport_failure_metadata!(attempt, forbidden_values) do
    transport_failure = assert_transport_failure_metadata!(attempt, %{"phase" => "request"})

    assert is_binary(transport_failure["exception"])
    assert is_binary(transport_failure["reason_class"])
    assert Map.keys(transport_failure) -- transport_failure_metadata_keys() == []

    metadata_text = inspect(transport_failure)

    Enum.each(forbidden_values, fn forbidden ->
      refute metadata_text =~ forbidden
    end)

    transport_failure
  end

  defp transport_failure_metadata_keys do
    ~w(exception phase pre_visible_output reason reason_class terminal_seen text_frame_count)
  end

  defp assert_prompt_cache_locality_metadata_safe!(
         routing,
         raw_prompt_cache_key,
         assignment_id,
         count
       ) do
    assert routing["routing_locality_strategy"] == "prompt_cache_routing_locality"
    assert routing["routing_locality_status"] == "applied"
    assert routing["routing_locality_applied"] == true
    assert routing["routing_locality_eligible_candidate_count"] == count
    assert routing["routing_locality_seed_basis_class"] == "pool_api_key_model_prompt_cache"
    assert routing["routing_locality_seed_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
    assert routing["routing_locality_assignment_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
    refute routing["routing_locality_seed_fingerprint"] == raw_prompt_cache_key
    refute routing["routing_locality_assignment_fingerprint"] == assignment_id
    refute inspect(routing) =~ raw_prompt_cache_key
    refute inspect(routing) =~ "cache_hit"
    refute inspect(routing) =~ "provider_cache"
  end

  defp assert_safe_runtime_routing_metadata!(request, attempts, setup) do
    metadata_text =
      inspect({request.request_metadata, Enum.map(attempts, & &1.response_metadata)})

    refute metadata_text =~ "metadata sentinel"
    refute metadata_text =~ "retry within shortlist"
    refute metadata_text =~ "least recent success"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  defp enable_request_compression!(pool) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      request_compression_enabled: true,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp compression_log_fixture(omitted_sentinel) do
    middle =
      1..96
      |> Enum.map(fn
        48 -> "ordinary build line 48 #{omitted_sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
    |> Enum.join("\n")
  end

  defp compression_rows_fixture do
    for index <- 1..32 do
      %{
        "id" => index,
        "status" => "ok",
        "value" => "row value #{index}"
      }
    end
  end

  defp assert_compressed_payload_metadata!(attempt, route_class, transport, strategy) do
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "compressed",
             "route_class" => ^route_class,
             "transport" => ^transport,
             "candidate_count" => 1,
             "compressed_count" => 1,
             "skipped_count" => 0
           } = metadata = attempt.response_metadata["payload_compression"]

    assert strategy in metadata["strategies"]
    assert metadata["original_bytes"] > metadata["compressed_bytes"]
    assert metadata["saved_bytes"] > 0
    assert metadata["original_tokens"] > metadata["compressed_tokens"]
    assert metadata["saved_tokens"] > 0
  end

  defp assert_skipped_payload_metadata!(attempt, route_class, transport, reason) do
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "skipped",
             "reason" => ^reason,
             "route_class" => ^route_class,
             "transport" => ^transport,
             "candidate_count" => 1,
             "compressed_count" => 0,
             "skipped_count" => 1,
             "lossy_unrecoverable_tool_output_skipped_count" => 1
           } = metadata = attempt.response_metadata["payload_compression"]

    refute Map.has_key?(metadata, "strategies")
    refute Map.has_key?(metadata, "original_tokens")
    refute Map.has_key?(metadata, "compressed_tokens")
    refute Map.has_key?(metadata, "saved_tokens")
  end

  defp supported_compression_model_opts(opts \\ []) do
    Keyword.merge(
      [
        exposed_model_id: @supported_compression_model,
        upstream_model_id: @supported_compression_model,
        pricing_ref: @supported_compression_model
      ],
      opts
    )
  end

  defp execute_gateway(auth, endpoint, payload, opts) do
    request_options = RequestOptions.build(opts, endpoint, payload)
    RuntimeGateway.execute(auth, endpoint, payload, request_options)
  end

  defp execute_stream_after_releasing_barrier(
         auth,
         payload,
         opts,
         release_ref,
         keepalive_wait_ms
       ) do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :sandbox_allowed -> :ok
        after
          1_000 -> raise "timed out waiting for stream task sandbox allowance"
        end

        assert {:ok, %{stream: stream}} =
                 execute_gateway(
                   auth,
                   "/backend-api/codex/responses",
                   payload,
                   opts
                 )

        stream_conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        stream.(stream_conn)
      end)

    Sandbox.allow(Repo, parent, task.pid)
    send(task.pid, :sandbox_allowed)

    assert_receive {:fake_upstream_chunk_barrier, _index, upstream_pid, ^release_ref}, 1_000
    wait_for_keepalive_window(keepalive_wait_ms)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    Task.await(task, 2_000)
  end

  defp wait_for_keepalive_window(0), do: :ok

  defp wait_for_keepalive_window(timeout_ms) do
    receive do
    after
      timeout_ms -> :ok
    end
  end

  defp lineage_metadata_fixture(forked_thread_id) do
    request_kind = "task3-lineage-request-#{forked_thread_id}"
    window_id = "window-#{forked_thread_id}"
    installation_id = "installation-#{forked_thread_id}"
    compaction_source_window_id = "compaction-source-#{forked_thread_id}"
    compaction_target_window_id = "compaction-target-#{forked_thread_id}"
    compaction_strategy = "task3-synthetic-summary"
    compaction_trigger = "task3-manual-fixture"

    %{
      turn_metadata:
        Jason.encode!(%{
          "forked_from_thread_id" => forked_thread_id,
          "request_kind" => request_kind,
          "window_id" => window_id,
          "compaction" => %{
            "source_window_id" => compaction_source_window_id,
            "target_window_id" => compaction_target_window_id,
            "strategy" => compaction_strategy,
            "trigger" => compaction_trigger
          }
        }),
      forked_thread_id: forked_thread_id,
      request_kind: request_kind,
      window_id: window_id,
      installation_id: installation_id,
      parent_thread_id: "parent-#{forked_thread_id}",
      subagent: "subagent-#{forked_thread_id}",
      compaction_source_window_id: compaction_source_window_id,
      compaction_target_window_id: compaction_target_window_id,
      compaction_strategy: compaction_strategy,
      compaction_trigger: compaction_trigger
    }
  end

  defp client_metadata_fixture(label) do
    forked_thread_id = "client-metadata-fork-#{label}"
    window_id = "client-metadata-window-#{label}"
    sentinel = "client-metadata-sentinel-#{label}"

    turn_metadata =
      Jason.encode!(%{
        "forked_from_thread_id" => forked_thread_id,
        "window_id" => window_id,
        "sentinel" => sentinel
      })

    %{
      turn_metadata: turn_metadata,
      forked_thread_id: forked_thread_id,
      window_id: window_id,
      sentinel: sentinel,
      client_metadata: %{
        "x-codex-turn-metadata" => turn_metadata,
        "existing_client_metadata" => "existing-client-metadata-#{label}"
      }
    }
  end

  defp additional_tools_item do
    %{
      "type" => "additional_tools",
      "role" => "developer",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_additional_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end

  defp put_setup_model_source_metadata!(setup, source_metadata) when is_map(source_metadata) do
    metadata =
      setup.model.metadata
      |> Map.put("source_assignment_models", %{setup.assignment.id => source_metadata})

    model =
      setup.model
      |> Ecto.Changeset.change(%{metadata: metadata})
      |> Repo.update!()

    %{setup | model: model}
  end

  defp lineage_request_headers(metadata) do
    [
      {"accept", "application/json; lineage-client-accept=1"},
      {"cookie", "lineage-client-cookie=secret"},
      {"idempotency-key", "lineage-client-idempotency-secret"},
      {"user-agent", "lineage-client-user-agent"},
      {"x-request-id", "task4-lineage-request-correlation"},
      {"x-codex-turn-metadata", metadata.turn_metadata},
      {"x-codex-window-id", metadata.window_id},
      {"x-codex-parent-thread-id", metadata.parent_thread_id},
      {"x-codex-installation-id", metadata.installation_id},
      {"x-openai-subagent", metadata.subagent},
      {"x-openai-internal-codex-responses-lite", "lineage-spoofed-lite"},
      {"x-codex-unapproved", "lineage-unapproved-codex"},
      {"x-openai-unapproved", "lineage-unapproved-openai"},
      {"x-unrelated-lineage", "lineage-unrelated"}
    ]
  end

  defp approved_lineage_header_names do
    [
      "x-codex-turn-metadata",
      "x-codex-window-id",
      "x-codex-parent-thread-id",
      "x-codex-installation-id",
      "x-openai-subagent"
    ]
  end

  defp assert_approved_lineage_headers_forwarded!(captured, metadata) do
    captured_headers = Map.new(captured.headers)

    assert captured_headers["x-codex-turn-metadata"] == metadata.turn_metadata
    assert captured_headers["x-codex-turn-metadata"] =~ ~s("request_kind")
    assert captured_headers["x-codex-turn-metadata"] =~ metadata.request_kind
    assert captured_headers["x-codex-turn-metadata"] =~ ~s("window_id")
    assert captured_headers["x-codex-turn-metadata"] =~ metadata.window_id
    assert captured_headers["x-codex-turn-metadata"] =~ ~s("compaction")
    assert captured_headers["x-codex-turn-metadata"] =~ metadata.compaction_source_window_id
    assert captured_headers["x-codex-turn-metadata"] =~ metadata.compaction_target_window_id
    assert captured_headers["x-codex-window-id"] == metadata.window_id
    assert captured_headers["x-codex-parent-thread-id"] == metadata.parent_thread_id
    assert captured_headers["x-codex-installation-id"] == metadata.installation_id
    assert captured_headers["x-openai-subagent"] == metadata.subagent
  end

  defp assert_disallowed_client_headers_not_forwarded!(captured, setup) do
    captured_headers = Map.new(captured.headers)
    codex_version = CodexClientIdentity.version()

    assert captured_headers["authorization"] == "Bearer upstream-token"
    assert captured_headers["accept"] in ["application/json", "text/event-stream"]
    assert captured_headers["content-type"] == "application/json"
    assert captured_headers["user-agent"] == "codex_cli_rs/#{codex_version}"
    assert captured_headers["originator"] == CodexClientIdentity.originator()
    assert captured_headers["version"] == codex_version

    refute Map.has_key?(captured_headers, "cookie")
    refute Map.has_key?(captured_headers, "idempotency-key")
    refute Map.has_key?(captured_headers, "x-openai-internal-codex-responses-lite")
    refute Map.has_key?(captured_headers, "x-codex-unapproved")
    refute Map.has_key?(captured_headers, "x-openai-unapproved")
    refute Map.has_key?(captured_headers, "x-unrelated-lineage")
    refute inspect(captured.headers) =~ setup.authorization
    refute inspect(captured.headers) =~ setup.raw_key
    refute inspect(captured.headers) =~ "lineage-client-cookie=secret"
    refute inspect(captured.headers) =~ "lineage-client-idempotency-secret"
    refute inspect(captured.headers) =~ "lineage-client-accept"
    refute inspect(captured.headers) =~ "lineage-spoofed-lite"
    refute inspect(captured.headers) =~ "lineage-unapproved-codex"
    refute inspect(captured.headers) =~ "lineage-unapproved-openai"
    refute inspect(captured.headers) =~ "lineage-unrelated"
  end

  defp hashed_window_session_key(raw_window_id) do
    digest =
      :crypto.hash(:sha256, raw_window_id)
      |> Base.encode16(case: :lower)

    "x-codex-window-id:" <> digest
  end

  defp assert_lineage_metadata_not_persisted!(setup, metadata) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: a.request_id == r.id,
          where: r.pool_id == ^setup.pool.id
        )
      )

    logs = RequestLogs.list(setup.pool.id, limit: 10)

    refute_lineage_text!(inspect(Enum.map(requests, & &1.request_metadata)), metadata)
    refute_lineage_text!(inspect(Enum.map(attempts, & &1.response_metadata)), metadata)
    refute_lineage_text!(inspect(logs.items), metadata)
  end

  defp assert_client_metadata_not_persisted!(setup, metadata) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: a.request_id == r.id,
          where: r.pool_id == ^setup.pool.id
        )
      )

    sessions = Repo.all(from(s in CodexSession))
    turns = Repo.all(from(t in CodexTurn))
    audit_events = Repo.all(from(e in AuditEvent))
    logs = RequestLogs.list(setup.pool.id, limit: 10)

    persistence_text =
      inspect({requests, attempts, sessions, turns, audit_events, logs.items})

    refute_client_metadata_text!(persistence_text, metadata)
  end

  defp assert_turn_state_not_persisted!(setup, turn_state) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: a.request_id == r.id,
          where: r.pool_id == ^setup.pool.id
        )
      )

    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    turns = Repo.all(from(t in CodexTurn))
    audit_events = Repo.all(from(e in AuditEvent))
    logs = RequestLogs.list(setup.pool.id, limit: 10)

    persistence_text =
      inspect({requests, attempts, sessions, turns, audit_events, logs.items})

    refute persistence_text =~ turn_state
  end

  defp refute_lineage_text!(text, metadata) do
    refute text =~ metadata.turn_metadata
    refute text =~ metadata.forked_thread_id
    refute text =~ metadata.request_kind
    refute text =~ metadata.window_id
    refute text =~ metadata.installation_id
    refute text =~ metadata.parent_thread_id
    refute text =~ metadata.subagent
    refute text =~ metadata.compaction_source_window_id
    refute text =~ metadata.compaction_target_window_id
    refute text =~ metadata.compaction_strategy
    refute text =~ metadata.compaction_trigger
  end

  defp refute_client_metadata_text!(text, metadata) do
    refute text =~ metadata.turn_metadata
    refute text =~ metadata.forked_thread_id
    refute text =~ metadata.window_id
    refute text =~ metadata.sentinel
    refute text =~ "existing-client-metadata"
  end

  defp pruned_control_plane_requests do
    [
      {"GET", "/backend-api/codex/thread/goal/get?thread_id=absent", nil},
      {"POST", "/backend-api/codex/thread/goal/get", "application/json"},
      {"POST", "/backend-api/codex/thread/goal/set", "application/json"},
      {"POST", "/backend-api/codex/thread/goal/clear", "application/json"},
      {"POST", "/backend-api/codex/analytics-events/events", "application/json"},
      {"POST", "/backend-api/codex/memories/trace_summarize", "application/json"},
      {"POST", "/backend-api/codex/alpha/search", "application/json"},
      {"POST", "/backend-api/codex/realtime/calls", "application/sdp"},
      {"POST", "/backend-api/codex/safety/arc", "application/json"},
      {"GET", "/backend-api/codex/agent-identities/jwks?kid=absent", nil},
      {"GET", "/backend-api/wham/agent-identities/jwks?kid=absent", nil}
    ]
  end

  defp dispatch_pruned_control_plane_request(conn, "GET", path, _content_type) do
    get(conn, path)
  end

  defp dispatch_pruned_control_plane_request(conn, "POST", path, "application/sdp") do
    post_raw_runtime(conn, path, "v=0\r\ns=codex-pooler-test\r\n", "application/sdp")
  end

  defp dispatch_pruned_control_plane_request(conn, "POST", path, _content_type) do
    post_raw_runtime(conn, path, ~s({"sentinel":"not parsed"}), "application/json")
  end

  defp post_json_runtime_with_headers(conn, path, payload, headers) do
    post_raw_runtime(conn, path, Jason.encode!(payload), "application/json", headers)
  end

  defp post_raw_runtime(conn, path, body, content_type, headers \\ []) do
    Plug.Test.conn("POST", path, body)
    |> Map.update!(:req_headers, fn headers ->
      headers
      |> Enum.reject(fn {name, _value} -> name in ["content-type", "authorization"] end)
      |> then(&[{"content-type", content_type} | &1])
    end)
    |> put_runtime_req_headers(headers)
    |> copy_auth_header(conn)
    |> @endpoint.call(@endpoint.init([]))
  end

  defp put_runtime_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp copy_auth_header(conn, source_conn) do
    case get_req_header(source_conn, "authorization") do
      [value | _rest] -> put_req_header(conn, "authorization", value)
      [] -> conn
    end
  end

  defp post_backend_response(setup, headers, payload) do
    payload = Map.put(payload, "model", setup.model.exposed_model_id)

    build_conn()
    |> auth(setup)
    |> put_request_headers(headers)
    |> post("/backend-api/codex/responses", payload)
  end

  defp put_request_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
  end

  defp register_previous_response_anchor!(auth, assignment, previous_response_id) do
    session = register_session_header_anchor!(auth, assignment, "previous-anchor-session")

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               Jason.encode!(%{"id" => previous_response_id})
             )

    session
  end

  defp register_session_header_anchor!(auth, assignment, session_header) do
    {:ok, session} = Gateway.start_codex_session(auth, %{session_header: session_header})
    pin_session_to_assignment!(session, assignment)
  end

  defp pin_session_to_assignment!(session, assignment) do
    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: assignment.id})
    |> Repo.update!()
  end

  defp assert_usage_probe_then_response(upstream) do
    assert [
             usage_request,
             response_request
           ] = FakeUpstream.requests(upstream)

    assert usage_request.path == "/backend-api/wham/usage"
    {usage_request, response_request}
  end

  defp assert_usage_probe_requests(upstream) do
    assert [usage_request] = FakeUpstream.requests(upstream)

    assert usage_request.path == "/backend-api/wham/usage"
    usage_request
  end

  defp mark_pinned_assignment_reauth_required!(setup) do
    setup.identity
    |> Ecto.Changeset.change(%{
      status: "reauth_required",
      metadata: %{
        "base_url" => setup.identity.metadata["base_url"],
        "token_refresh" => %{
          "status" => "reauth_required",
          "reason" => %{
            "code" => "refresh_token_revoked",
            "message" => "synthetic refresh state"
          }
        }
      }
    })
    |> Repo.update!()

    setup.assignment
    |> Ecto.Changeset.change(%{
      health_status: "disabled",
      eligibility_status: "ineligible"
    })
    |> Repo.update!()
  end

  defp assert_pinned_reauth_recovery_response!(conn) do
    assert get_resp_header(conn, "x-codex-recovery-kind") == ["restart_with_full_context"]

    assert %{
             "error" => %{
               "code" => "pinned_continuation_reauth_required",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = json_response(conn, 503)

    assert recovery["kind"] == "restart_with_full_context"
    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]

    assert recovery["anchor_removal"]["headers"] == [
             "x-codex-previous-response-id",
             "x-codex-turn-state",
             "x-codex-window-id",
             "x-codex-session-id",
             "session-id",
             "x-session-id",
             "x-session-affinity",
             "session_id",
             "x-codex-conversation-id"
           ]
  end

  defp assert_pinned_unavailable_recovery_response!(conn) do
    assert get_resp_header(conn, "x-codex-recovery-kind") == ["restart_with_full_context"]

    assert %{
             "error" => %{
               "code" => "pinned_continuation_unavailable",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = json_response(conn, 503)

    assert recovery["kind"] == "restart_with_full_context"
    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]
  end

  defp assert_pinned_unavailable_metadata!(
         request,
         assignment,
         identity,
         pin_reason,
         internal_reason
       ) do
    assert %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => ^pin_reason,
             "internal_reason" => ^internal_reason,
             "pool_upstream_assignment_id" => assignment_id,
             "upstream_identity_id" => identity_id,
             "operator_action" => operator_action
           } = request.request_metadata["continuity_denial"]

    assert assignment_id == assignment.id
    assert identity_id == identity.id
    assert is_binary(operator_action)
    assert operator_action != ""
  end

  defp assert_file_assignment_conflict_without_recovery!(conn) do
    assert get_resp_header(conn, "x-codex-recovery-kind") == []

    assert %{"error" => %{"code" => "file_assignment_conflict"} = error} =
             json_response(conn, 409)

    refute Map.has_key?(error, "requires_new_upstream_session")
    refute Map.has_key?(error, "recovery_kind")
    refute Map.has_key?(error, "recovery")
  end

  defp start_invalid_content_length_server! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()
    served_ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _request = read_raw_http_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: +0\r\n",
            "connection: close\r\n\r\n"
          ])

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(parent, {served_ref, :served})
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{base_url: "http://127.0.0.1:#{port}", served_ref: served_ref}
  end

  defp read_raw_http_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if raw_http_request_complete?(acc) do
          acc
        else
          read_raw_http_request(socket, acc)
        end

      {:error, _reason} ->
        acc
    end
  end

  defp raw_http_request_complete?(data) do
    case :binary.split(data, "\r\n\r\n") do
      [headers, body] ->
        case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers,
               capture: :all_but_first
             ) do
          [length] -> byte_size(body) >= String.to_integer(length)
          nil -> true
        end

      _incomplete ->
        false
    end
  end
end
