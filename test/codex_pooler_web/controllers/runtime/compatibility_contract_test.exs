defmodule CodexPoolerWeb.Runtime.CompatibilityContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.ControlPlaneRoutes
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle

  @expected_features ~w(
    files
    backend_transcription
    backend_image_proxy_surface
    responses_chat
    backend_v1_alias_surface
    websocket_continuity
    reasoning_minimal
    unsupported_upstream_fields
    firewall
    decompression
    bulkheads
    degraded_routing
    strict_schema_validation
    unsupported_input_image_reference
    first_event_stream_retry
    control_plane_surface
    backend_alpha_search
    v1_supported_surface
    v1_unsupported_public_surface
  )a

  setup do
    old_config = Application.get_env(:codex_pooler, Files, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 64,
      file_ttl_seconds: 60
    )

    on_exit(fn -> Application.put_env(:codex_pooler, Files, old_config) end)

    :ok
  end

  describe "compatibility matrix" do
    test "lists every in-scope Codex compatibility feature with sanitized fixtures" do
      assert CompatibilityMatrix.feature_slugs() == @expected_features

      for feature <- CompatibilityMatrix.features() do
        assert feature.status == :supported
        assert feature.current
        assert is_binary(feature.contract)
        assert feature.categories != []
        assert CompatibilityMatrix.fixture!(feature.fixture)
      end
    end

    test "covers baseline regression categories for later task promotion" do
      covered_categories =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.categories)
        |> Enum.uniq()
        |> Enum.sort()

      assert covered_categories == Enum.sort(CompatibilityMatrix.required_categories())
    end

    test "has no pending compatibility gaps" do
      assert CompatibilityMatrix.pending_gaps() == []
    end

    test "documents control-plane route support as explicit proxy routes" do
      feature = CompatibilityMatrix.by_slug!(:control_plane_surface)
      fixture = CompatibilityMatrix.fixture!(:control_plane_surface)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_proxy_routes
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :degraded in feature.categories

      assert Enum.map(feature.routes, &{&1.method, &1.path}) ==
               Enum.map(ControlPlaneRoutes.all(), &{&1.method, &1.local_path})

      assert feature.contract =~ "explicit authenticated proxy routes"
      assert feature.contract =~ "proxy_control"
      assert feature.contract =~ "metadata-only"
      refute feature.contract =~ "placeholder"
      refute feature.contract =~ "not implemented"
      assert fixture.route_class == "proxy_control"
      assert fixture.analytics_forwarding_disabled == %{status: 204, upstream_call: false}
      assert "location" in fixture.response_header_allowlist
      assert fixture.privacy == "metadata_only"
    end

    test "documents backend alpha search as scoped metadata-only control-plane compatibility" do
      feature = CompatibilityMatrix.by_slug!(:backend_alpha_search)
      fixture = CompatibilityMatrix.fixture!(:backend_alpha_search)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_control_plane_route
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert :degraded in feature.categories

      assert feature.routes == [%{method: :post, path: "/backend-api/codex/alpha/search"}]
      assert feature.contract =~ "Codex backend compatibility control-plane route"
      assert feature.contract =~ "proxy_control"
      assert feature.contract =~ "metadata-only"
      assert feature.contract =~ "upstream /alpha/search"
      refute feature.contract =~ "/v1/alpha"
      refute feature.contract =~ "product search UI"
      refute feature.contract =~ "generic search API"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.route_class == "proxy_control"
      assert fixture.privacy == "metadata_only"
      assert fixture.routes == ["/backend-api/codex/alpha/search"]
      assert fixture.upstream_path == "/alpha/search"
    end

    test "documents reject versus strip behavior for unsupported OpenAI controls" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      unsupported_upstream_fields = CompatibilityMatrix.by_slug!(:unsupported_upstream_fields)

      assert responses_chat.contract =~ "SDK-control rejection"
      assert unsupported_upstream_fields.current == :rejected_or_stripped_by_scope
      assert unsupported_upstream_fields.contract =~ "rejects known SDK request controls"

      assert unsupported_upstream_fields.contract =~
               "strips backend-only upstream-unsupported controls"
    end

    test "documents narrow chat input fallback and non-executable additional_tools" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      responses_fixture = CompatibilityMatrix.fixture!(:responses_chat)
      v1_fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert responses_chat.contract =~ "messages when present"
      assert responses_chat.contract =~ "top-level input only when messages is absent or empty"

      assert responses_chat.contract =~
               "omitted fallback instructions defaulting to a blank string"

      assert responses_chat.contract =~ "request-shaped additional_tools input items"
      assert responses_chat.contract =~ "non-executable input"
      assert responses_chat.contract =~ "never merged into executable tools"
      assert responses_chat.contract =~ "never used to satisfy tool_choice"
      assert responses_chat.contract =~ "truncation accepts auto and disabled locally"
      assert responses_chat.contract =~ "not forwarded upstream"

      assert responses_chat.contract =~
               "Hermes assistant replay may include safe assistant status metadata"

      assert responses_chat.contract =~
               "OpenClaw assistant replay drops thinking metadata and normalizes text"

      refute responses_chat.contract =~ "Responses-to-chat parity"
      refute responses_chat.contract =~ "top-level additional_tools"

      expected_chat_fallback = %{
        messages_precedence: "non_empty_messages",
        fallback_when: ["messages_absent", "messages_empty"],
        fallback_source: "input",
        default_instructions: "blank_string"
      }

      expected_additional_tools = %{
        shape: "request_input_item",
        required: ["type", "role", "tools"],
        optional: ["id"],
        role: "developer",
        executable: false,
        merges_into_tools: false,
        satisfies_tool_choice: false
      }

      assert responses_fixture.chat_input_fallback == expected_chat_fallback
      assert v1_fixture.chat_input_fallback == expected_chat_fallback
      assert responses_fixture.additional_tools_input_item == expected_additional_tools
      assert v1_fixture.additional_tools_input_item == expected_additional_tools

      assert responses_fixture.responses_truncation == %{
               accepted_values: ["auto", "disabled"],
               forwarded_upstream: false
             }

      assert v1_fixture.responses_truncation == responses_fixture.responses_truncation
    end

    test "documents compaction trigger bridge and context-overflow recovery boundary" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert responses_chat.contract =~ "terminal compaction_trigger backend payloads bridge"
      assert responses_chat.contract =~ "/backend-api/codex/responses/compact"
      assert responses_chat.contract =~ "malformed trigger placement is rejected before dispatch"
      assert responses_chat.contract =~ "context-overflow recovery stays client/upstream-owned"
      assert responses_chat.contract =~ "no server-side hidden replay"
      assert responses_chat.contract =~ "stored prompt/frame reconstruction"

      assert fixture.compaction_recovery_boundary == %{
               backend_compaction_trigger: %{
                 routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
                 behavior: "terminal_trigger_bridges_to_compact",
                 compact_endpoint: "/backend-api/codex/responses/compact",
                 route_class: "proxy_compact",
                 transport: "http_compact_json",
                 valid_trigger: "exactly_one_final_input_item",
                 malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
                 strips: ["compaction_trigger", "stream", "include"],
                 preserves: [
                   "model",
                   "instructions",
                   "input",
                   "reasoning",
                   "store",
                   "service_tier",
                   "prompt_cache_key",
                   "previous_response_id",
                   "conversation"
                 ],
                 output_events: ["response.output_item.done", "response.completed", "[DONE]"],
                 output_item: %{
                   "type" => "compaction",
                   "encrypted_content" => "encrypted_content"
                 },
                 websocket_bridge: false,
                 hidden_replay: false
               },
               context_overflow: %{
                 recovery_owner: "client_or_upstream",
                 server_side_compaction: false,
                 hidden_replay: false,
                 stores_prompt_bodies: false,
                 stores_websocket_frames: false,
                 client_action: "restart_with_full_context"
               }
             }
    end

    test "documents v1 supported surface as authenticated OpenAI compatibility" do
      feature = CompatibilityMatrix.by_slug!(:v1_supported_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert feature.status == :supported
      assert feature.current == :authenticated_openai_compatibility
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :multipart in feature.categories
      assert :streaming in feature.categories
      assert :ownership in feature.categories

      assert Enum.any?(feature.routes, &(&1.method == :get and &1.path == "/v1/models"))
      assert Enum.any?(feature.routes, &(&1.method == :get and &1.path == "/v1/responses"))
      assert Enum.any?(feature.routes, &(&1.method == :post and &1.path == "/v1/responses"))
      assert feature.contract =~ "OpenAI-compatible /v1 routes"
      assert feature.contract =~ "narrow GET /v1/responses Responses websocket compatibility only"
      assert feature.contract =~ "exclude broad /v1/realtime routes"
      assert feature.contract =~ "documented local precedence"

      assert feature.contract =~
               "without forwarding session-id, x-session-id, or x-session-affinity"

      assert feature.contract =~ "pinned /v1/responses continuations"
      assert feature.contract =~ "restart_with_full_context recovery guidance"
      assert feature.contract =~ "accept Responses truncation auto and disabled locally"
      assert feature.contract =~ "without forwarding it upstream"
      assert feature.contract =~ "lift Responses system/developer input-message text"
      assert feature.contract =~ "early public streaming terminal errors"
      assert feature.contract =~ "accept safe Hermes assistant replay status values"
      assert feature.contract =~ "translate OpenClaw assistant thinking replays before validation"
      assert feature.contract =~ "chat input fallback"
      assert feature.contract =~ "Responses additional_tools support narrow and non-executable"
      refute feature.contract =~ "metadata"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true
      assert fixture.websocket_route == %{method: :get, path: "/v1/responses"}
      assert fixture.websocket_contract == "narrow_responses_websocket_only"

      assert fixture.continuity_precedence == [
               "x-codex-window-id",
               "x-codex-session-id",
               "session-id",
               "x-session-id",
               "x-session-affinity",
               "session_id",
               "x-codex-conversation-id"
             ]

      assert fixture.local_continuity_headers_not_forwarded == [
               "session-id",
               "x-session-id",
               "x-session-affinity"
             ]

      assert fixture.pinned_continuation_reauth == %{
               routes: [
                 %{method: :post, path: "/v1/responses"},
                 %{method: :get, path: "/v1/responses", transport: "websocket"}
               ],
               status: 503,
               error_code: "pinned_continuation_reauth_required",
               recovery_kind: "restart_with_full_context",
               anchor_removal: %{
                 body: ["previous_response_id"],
                 headers: [
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
               }
             }

      assert fixture.timeout_contract == %{
               route_specific_defaults_added: false,
               progress_receive_timeout_ms: 250,
               progress_interval_ms: 100,
               idle_receive_timeout_ms: 150,
               idle_silent_gap_min_ms: 250,
               idle_error_code: "stream_idle_timeout"
             }

      assert fixture.instruction_lifting == %{
               roles: ["system", "developer"],
               destination: "instructions",
               merge_order: ["existing_instructions", "input_order_instruction_text"],
               residual_non_text_role: "user",
               blank_text: "omitted",
               malformed_content: "sanitized_invalid_request"
             }

      assert fixture.early_stream_errors == %{
               responses_first_events: ["response.failed", "error"],
               responses_suppresses_synthetic_success_prefix_before_output: true,
               chat_first_chunk: "data_error_object",
               chat_omits_assistant_role_before_output: true,
               chat_omits_done_before_output: true,
               late_failures_retry: false,
               non_stream_errors: "json_error"
             }

      assert fixture.hermes_assistant_tool_call_replay.ordinary_replay_status_values == [
               "completed",
               "incomplete",
               "in_progress"
             ]

      assert fixture.openclaw_assistant_thinking_replay == %{
               input_role: "assistant",
               dropped_content_part_type: "thinking",
               normalized_content_part_type: "output_text",
               source_text_part_type: "text",
               requires_previous_response_id: false,
               metadata_only: true
             }

      assert fixture.unsupported_realtime_routes == [
               %{method: :get, path: "/v1/realtime"},
               %{method: :post, path: "/v1/realtime"}
             ]

      refute Map.has_key?(fixture, :metadata)

      assert fixture.routes |> Enum.sort() == [
               "/v1/audio/transcriptions",
               "/v1/chat/completions",
               "/v1/files",
               "/v1/images/edits",
               "/v1/images/generations",
               "/v1/models",
               "/v1/responses",
               "/v1/responses/compact",
               "/v1/usage"
             ]
    end

    test "keeps broad public realtime routes outside the router surface" do
      route_set =
        CodexPoolerWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(&{&1.verb, &1.path})
        |> MapSet.new()

      feature = CompatibilityMatrix.by_slug!(:v1_supported_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert feature.contract =~ "exclude broad /v1/realtime routes"

      for route <- fixture.unsupported_realtime_routes do
        refute MapSet.member?(route_set, {route.method, route.path})
      end
    end

    test "keeps app-server, remote-control, and permission-profile routes outside supported surfaces" do
      route_set =
        CodexPoolerWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(&{router_method(&1.verb), &1.path})
        |> MapSet.new()

      matrix_route_set =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.routes)
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      control_plane_route_set =
        ControlPlaneRoutes.all()
        |> Enum.map(&{&1.method, &1.local_path})
        |> MapSet.new()

      unsupported_routes = [
        %{method: :post, path: "/backend-api/codex/thread/start", family: :app_server},
        %{method: :post, path: "/backend-api/codex/thread/resume", family: :app_server},
        %{method: :post, path: "/backend-api/codex/thread/fork", family: :app_server},
        %{method: :post, path: "/backend-api/codex/turn/start", family: :app_server},
        %{method: :post, path: "/backend-api/codex/configRequirements/read", family: :app_server},
        %{
          method: :get,
          path: "/backend-api/codex/remote-control/pairing/status",
          family: :remote_control
        },
        %{
          method: :post,
          path: "/backend-api/codex/remote-control/pairing/status",
          family: :remote_control
        },
        %{
          method: :post,
          path: "/backend-api/codex/permission-profiles/validate",
          family: :permission_profile
        },
        %{method: :post, path: "/v1/remote-control/pairing/status", family: :remote_control},
        %{method: :post, path: "/v1/permission-profiles/validate", family: :permission_profile}
      ]

      assert unsupported_routes |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort() ==
               [:app_server, :permission_profile, :remote_control]

      for route <- unsupported_routes do
        refute MapSet.member?(route_set, {route.method, route.path})
        refute MapSet.member?(matrix_route_set, {route.method, route.path})
        refute MapSet.member?(control_plane_route_set, {route.method, route.path})
      end
    end

    test "documents unsupported v1 public surface with exact OpenAI-shaped error contract" do
      feature = CompatibilityMatrix.by_slug!(:v1_unsupported_public_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_unsupported_public_surface)

      expected_routes = [
        %{method: :post, path: "/v1/images/variations"},
        %{method: :post, path: "/v1/embeddings"},
        %{method: :post, path: "/v1/batches"},
        %{method: :post, path: "/v1/moderations"},
        %{method: :post, path: "/v1/fine_tuning/jobs"},
        %{method: :get, path: "/v1/responses/:response_id"},
        %{method: :post, path: "/v1/responses/:response_id/cancel"},
        %{method: :delete, path: "/v1/responses/:response_id"}
      ]

      assert feature.status == :supported
      assert feature.current == :openai_shaped_unsupported_route_contract
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert feature.routes == expected_routes
      assert feature.contract =~ "deterministic OpenAI-shaped 404 errors"

      assert fixture.status == 404
      assert fixture.error_code == "unsupported_endpoint"

      assert fixture.routes == [
               %{method: :post, path: "/v1/images/variations"},
               %{method: :post, path: "/v1/embeddings"},
               %{method: :post, path: "/v1/batches"},
               %{method: :post, path: "/v1/moderations"},
               %{method: :post, path: "/v1/fine_tuning/jobs"},
               %{method: :get, path: "/v1/responses/resp_fixture"},
               %{method: :post, path: "/v1/responses/resp_fixture/cancel"},
               %{method: :delete, path: "/v1/responses/resp_fixture"}
             ]
    end

    test "documents backend v1 alias surface as explicit authenticated backend aliases" do
      feature = CompatibilityMatrix.by_slug!(:backend_v1_alias_surface)
      fixture = CompatibilityMatrix.fixture!(:backend_v1_alias_surface)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_backend_alias_routes
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :streaming in feature.categories
      assert :ownership in feature.categories

      assert Enum.map(feature.routes, &{&1.method, &1.path}) == [
               {:get, "/backend-api/codex/v1/models"},
               {:get, "/backend-api/codex/v1/responses"},
               {:post, "/backend-api/codex/v1/responses"},
               {:post, "/backend-api/codex/v1/responses/compact"},
               {:post, "/backend-api/codex/v1/chat/completions"}
             ]

      assert feature.contract =~ "explicit authenticated backend routes"
      assert feature.contract =~ "chat alias fallback limited to top-level input"
      assert feature.contract =~ "messages is absent or empty"
      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true

      assert fixture.routes == [
               "/backend-api/codex/v1/models",
               "/backend-api/codex/v1/responses",
               "/backend-api/codex/v1/responses/compact",
               "/backend-api/codex/v1/chat/completions"
             ]

      assert fixture.chat_input_fallback == %{
               messages_precedence: "non_empty_messages",
               fallback_when: ["messages_absent", "messages_empty"],
               fallback_source: "input"
             }
    end

    test "keeps prompt cache routing input limited to the exact POST route contract" do
      allowed_routes = [
        "/v1/responses",
        "/v1/chat/completions",
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/chat/completions"
      ]

      excluded_routes = [
        {"GET", "/backend-api/codex/responses", %{transport: "websocket"}},
        {"POST", "/backend-api/codex/responses/compact", %{}},
        {"POST", "/backend-api/codex/v1/responses/compact", %{}},
        {"POST", "/v1/responses/compact", %{}},
        {"POST", "/backend-api/files", %{}},
        {"POST", "/backend-api/transcribe", %{}},
        {"POST", "/v1/audio/transcriptions", %{}},
        {"POST", "/v1/images/generations", %{}},
        {"POST", "/v1/images/edits", %{}},
        {"POST", "/backend-api/codex/images/generations", %{}},
        {"POST", "/backend-api/codex/images/edits", %{}}
      ]

      for endpoint <- allowed_routes do
        raw_prompt_cache_key = "fixture-cache-key"

        request_options =
          RequestOptions.build(%{request_method: "POST"}, endpoint, %{
            "model" => "gpt-fixture-text",
            "prompt_cache_key" => raw_prompt_cache_key
          })

        assert request_options.routing.prompt_cache_key =~ ~r/\A[0-9a-f]{64}\z/
        refute request_options.routing.prompt_cache_key == raw_prompt_cache_key
      end

      for {method, endpoint, opts} <- excluded_routes do
        request_options =
          opts
          |> Map.put(:request_method, method)
          |> RequestOptions.build(endpoint, %{
            "model" => "gpt-fixture-text",
            "prompt_cache_key" => "fixture-cache-key"
          })

        assert request_options.routing.prompt_cache_key == nil
      end
    end

    test "documents backend image proxy surface as explicit authenticated JSON proxy routes" do
      feature = CompatibilityMatrix.by_slug!(:backend_image_proxy_surface)
      fixture = CompatibilityMatrix.fixture!(:backend_image_proxy_surface)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_backend_image_proxy_routes
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert :ownership in feature.categories

      assert Enum.map(feature.routes, &{&1.method, &1.path}) == [
               {:post, "/backend-api/codex/images/generations"},
               {:post, "/backend-api/codex/images/edits"}
             ]

      assert feature.contract =~ "JSON proxy routes"
      assert feature.contract =~ "public /v1 image translator surface"
      refute feature.contract =~ "placeholder"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true
      assert fixture.route_class == "proxy_http"

      assert fixture.routes == [
               "/backend-api/codex/images/generations",
               "/backend-api/codex/images/edits"
             ]
    end
  end

  describe "baseline route and gap contracts" do
    test "supported files contract requires API-key auth before JSON shape validation", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/files", %{"file_size" => 12})

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"

      finalize_conn = post(build_conn(), "/backend-api/files/file_fixture/uploaded", %{})
      assert json_response(finalize_conn, 401)["error"]["code"] == "api_key_missing"
    end

    test "supported files contract bridges JSON create and finalize without local payload storage",
         %{
           conn: conn
         } do
      setup = active_api_key_fixture()

      upstream =
        start_upstream(
          FakeUpstream.file_protocol_success(
            file_id: "file_contract_bridge",
            file_name: "contract.txt",
            mime_type: "text/plain"
          )
        )

      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_contract_bridge",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-contract-bridge-token"
      })

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/backend-api/files", %{
          "file_name" => "contract.txt",
          "file_size" => 13
        })

      assert %{
               "file_id" => file_id,
               "upload_url" => upload_url
             } = json_response(conn, 200)

      assert upload_url =~ "fake-upload.invalid"

      file = Repo.get_by!(FileRecord, file_id: file_id)
      assert file.metadata["source"] == "backend-api/files/upstream"
      assert file.purpose == "codex"
      refute is_nil(file.pool_upstream_assignment_id)

      finalize_conn =
        build_conn()
        |> auth(setup)
        |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

      assert %{"status" => "success", "download_url" => download_url} =
               json_response(finalize_conn, 200)

      assert download_url =~ "fake-download.invalid"

      request =
        Repo.one!(
          from request in Request,
            where: request.pool_id == ^setup.pool.id and request.endpoint == "/backend-api/files",
            order_by: [desc: request.admitted_at],
            limit: 1
        )

      assert request.status == "succeeded"
      refute inspect(request.request_metadata) =~ "contract.txt"
    end

    test "supported backend files contract rejects multipart create without local side effects",
         %{
           conn: _conn
         } do
      setup = active_api_key_fixture()
      file_count_before = Repo.aggregate(FileRecord, :count)
      request_count_before = Repo.aggregate(Request, :count)

      conn =
        Plug.Test.conn(
          "POST",
          "/backend-api/files",
          multipart_body("private-contract-name.txt", "contract body")
        )
        |> put_req_header("content-type", "multipart/form-data; boundary=#{multipart_boundary()}")
        |> auth(setup)
        |> @endpoint.call(@endpoint.init([]))

      response = json_response(conn, 400)
      assert response["error"]["code"] == "unsupported_multipart_file_create"
      refute Map.has_key?(response, "upload_url")
      refute inspect(response) =~ "private-contract-name.txt"
      assert Repo.aggregate(FileRecord, :count) == file_count_before
      assert Repo.aggregate(Request, :count) == request_count_before
    end

    test "supported responses contract records weekly probe upstream 400 as upstream error", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          {:json_error, 400,
           %{
             "error" => %{
               "code" => "invalid_request_error",
               "message" => "synthetic upstream validation failure"
             }
           }}
        )

      setup = gateway_setup(upstream, quota?: false)
      prime_weekly_probe_quota!(setup.identity)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "upstream validation secret text",
          "stream" => true
        })

      assert response(conn, 400) == ""
      refute response(conn, 400) =~ "quota_evidence_unavailable"

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"

      assert [request] =
               Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400

      assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) ==
               "weekly_only_probe"

      assert [attempt] =
               Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)

      assert attempt.status == "failed"
      assert attempt.network_error_code == "upstream_status"
      assert attempt.upstream_status_code == 400

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ "upstream validation secret text"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.upstream_token
      refute metadata_text =~ "synthetic upstream validation failure"
    end

    test "supported responses contract does not server-compact context-overflow failures", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          {:json_error, 400,
           %{
             "error" => %{
               "code" => "context_length_exceeded",
               "message" => "synthetic context overflow failure"
             }
           }}
        )

      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic oversized context request",
          "stream" => false
        })

      assert json_response(conn, 400)["error"]["code"] == "context_length_exceeded"

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"

      assert [request] =
               Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400

      assert [attempt] =
               Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)

      assert attempt.status == "failed"
      assert attempt.network_error_code == "upstream_status"
      assert attempt.upstream_status_code == 400

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ "synthetic oversized context request"
      refute metadata_text =~ "synthetic context overflow failure"
      refute metadata_text =~ "compacted"
      refute metadata_text =~ "server_side_compaction"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.upstream_token
    end

    test "supported responses contract keeps safe OpenAI responses fields and strips auto controls",
         %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_tolerance_safe_fields",
            "object" => "response",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
          })
        )

      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic safe field request",
          "text" => %{"format" => %{"type" => "json_object"}},
          "store" => false,
          "include" => ["message.input_image.image_url"],
          "parallel_tool_calls" => true,
          "prompt_cache_key" => "synthetic-cache-key",
          "metadata" => %{"purpose" => "synthetic"},
          "previous_response_id" => "resp_previous_alias",
          "service_tier" => "auto"
        })

      assert %{"id" => "resp_tolerance_safe_fields"} = json_response(conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["text"]["format"]["type"] == "json_object"
      assert captured.json["store"] == false
      assert captured.json["include"] == ["message.input_image.image_url"]
      assert captured.json["parallel_tool_calls"] == true
      assert captured.json["prompt_cache_key"] == "synthetic-cache-key"
      assert captured.json["metadata"] == %{"purpose" => "synthetic"}
      refute Map.has_key?(captured.json, "previous_response_id")
      refute Map.has_key?(captured.json, "service_tier")
    end

    test "supported backend transcription contract requires API-key auth before multipart dispatch",
         %{
           conn: conn
         } do
      upload = upload_fixture("fixture-audio.wav", "audio/wav", "synthetic wav bytes")

      conn =
        post(conn, "/backend-api/transcribe", %{
          "file" => upload,
          "prompt" => "synthetic glossary"
        })

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
    end

    test "supported chat streaming contract keeps terminal SSE marker", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.sse_stream([%{"choices" => [%{"delta" => %{}}]}]))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic chat",
          "stream" => true
        })

      assert response(conn, 200) =~ "data: [DONE]"
    end

    test "supported reasoning minimal contract rewrites minimal to low before dispatch",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_minimal"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic reasoning request",
          "reasoning" => %{"effort" => "minimal"}
        })

      assert %{"id" => "resp_reasoning_minimal"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "low"}
    end

    test "supported reasoning contract preserves non-minimal efforts", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_medium"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic reasoning request",
          "reasoning" => %{"effort" => "medium"}
        })

      assert %{"id" => "resp_reasoning_medium"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "medium"}
    end
  end

  defp gateway_setup(upstream, opts \\ []) do
    key = active_api_key_fixture()
    pool = key.pool
    upstream_token = generated_secret("upstream")
    upstream = gateway_upstream(pool, upstream, upstream_token)

    if Keyword.get(opts, :quota?, true) do
      prime_routing_quota!(upstream.identity)
    end

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-contract-model",
        upstream_model_id: "provider-gpt-contract-model",
        pricing_ref: "provider-gpt-contract-model",
        metadata: %{"source_assignment_ids" => [upstream.assignment.id]},
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)

    Map.merge(key, %{
      identity: upstream.identity,
      assignment: upstream.assignment,
      model: model,
      upstream_token: upstream_token
    })
  end

  defp gateway_upstream(pool, upstream, token) do
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Gateway upstream",
               onboarding_method: "import",
               metadata: metadata
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: Enum.join(["access", "token"], "_"),
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Gateway assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    %{identity: identity, assignment: assignment}
  end

  defp prime_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])
  end

  defp prime_weekly_probe_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("12"),
                 reset_at: reset_at,
                 source: "codex_usage_api",
                 source_precision: "inferred",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  defp pricing_snapshot!(model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: model.upstream_model_id,
      price_version: "compatibility-contract-test-v1",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: %{}
    }
    |> Repo.insert!()
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-compat-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp multipart_boundary, do: "codex-pooler-compat-boundary"

  defp multipart_body(filename, contents) do
    [
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n",
      "user_data\r\n",
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
      "Content-Type: text/plain\r\n\r\n",
      contents,
      "\r\n--#{multipart_boundary()}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp router_method(verb) when is_atom(verb), do: verb

  defp router_method(verb) when is_binary(verb) do
    verb
    |> String.downcase()
    |> String.to_atom()
  end

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp generated_secret(label),
    do: "fixture-secret-#{label}-#{System.unique_integer([:positive])}"
end
