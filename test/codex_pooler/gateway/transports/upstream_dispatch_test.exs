defmodule CodexPooler.Gateway.Transports.UpstreamDispatchTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog
  import Ecto.Query

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession}
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.RejectionBody
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.RejectionDrain
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @receive_timeout_ms 25
  @websocket_idle_timeout_ms 1_000

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        upstream_receive_timeout_ms: @receive_timeout_ms,
        websocket_idle_timeout_ms: @websocket_idle_timeout_ms
      }
    )

    reset_bootstrap_state_fixture!()
    auth = auth_fixture()

    on_exit(fn ->
      restore_operational_settings(previous_settings)
      cleanup_local_owner_sessions()
    end)

    {:ok, auth: auth}
  end

  @tag :websocket_owner_submit_timeout
  test "owner submit uses the websocket session budget instead of the receive timeout", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@submit-timeout-owner.example"
    short_receive_budget_ms = @receive_timeout_ms + 1_000

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    downstream = %{pid: self(), epoch: 1, correlation_id: "corr-owner-submit-timeout"}

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    request_options =
      websocket_owner_request_options(session, lease_token, downstream, forwarder_opts)

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
               url: "https://upstream.example.test/backend-api/codex/responses",
               token: "redacted",
               upstream_payload: "{}",
               identity: upstream_identity(),
               accounting_request: nil,
               writer: fn _message -> :ok end,
               request_options: request_options
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request,
                      arity: 4,
                      timeout: observed_timeout_ms
                    }}

    assert observed_timeout_ms > short_receive_budget_ms,
           "expected remote submit timeout to exceed receive_timeout_ms + 1000 (#{short_receive_budget_ms}ms), got #{observed_timeout_ms}ms"
  end

  test "explicit owner forwarder timeout override is preserved for remote submit", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@explicit-submit-timeout-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    downstream = %{pid: self(), epoch: 1, correlation_id: "corr-explicit-owner-submit-timeout"}

    forwarder_opts =
      [remote_node]
      |> WebsocketOwnerNodeHarness.node_client_opts(calls: %{remote_node => :timeout})
      |> Keyword.put(:timeout, 25)

    request_options =
      websocket_owner_request_options(session, lease_token, downstream, forwarder_opts)

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
               url: "https://upstream.example.test/backend-api/codex/responses",
               token: "redacted",
               upstream_payload: "{}",
               identity: upstream_identity(),
               accounting_request: nil,
               writer: fn _message -> :ok end,
               request_options: request_options
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request,
                      arity: 4,
                      timeout: 25
                    }}
  end

  test "owner dispatch carries the same immutable response-control snapshot on retry", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@response-control-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    downstream = %{pid: self(), epoch: 1, correlation_id: "corr-response-control-owner"}
    snapshot = %TurnSnapshot{models_etag: ~s(W/"turn-etag")}

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout},
        capture_request_to: self()
      )

    request_options =
      websocket_owner_request_options(session, lease_token, downstream, forwarder_opts)

    request = %UpstreamDispatch.Request{
      url: "https://upstream.example.test/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: upstream_identity(),
      accounting_request: nil,
      writer: fn _message -> :ok end,
      native_codex_response_control: snapshot,
      request_options: request_options
    }

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(request)

    assert_receive {:websocket_owner_harness_request,
                    %UpstreamWebsocketSession.Request{
                      native_codex_response_control: ^snapshot
                    }}

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(request)

    assert_receive {:websocket_owner_harness_request,
                    %UpstreamWebsocketSession.Request{
                      native_codex_response_control: ^snapshot
                    }}

    assert request.native_codex_response_control == snapshot
    assert request.request_options.extra == %{}
  end

  test "http request does not reuse Cloudflare cookies for non-ChatGPT upstream origins" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    chatgpt_url =
      "https://dispatch-cookie-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/responses"

    assert CloudflareCookies.store_from_headers(chatgpt_url, [
             {"set-cookie", "__cf_bm=dispatch-token; Path=/; HttpOnly; Secure"}
           ])

    assert [{"cookie", "__cf_bm=dispatch-token"}] =
             CloudflareCookies.request_headers(chatgpt_url, [])

    payload = %{"model" => "example-model"}
    url = FakeUpstream.url(upstream) <> "/backend-api/codex/responses"

    request = %UpstreamDispatch.Request{
      url: url,
      token: "redacted",
      upstream_payload: Jason.encode!(payload),
      original_payload: payload,
      identity: upstream_identity(),
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 1_000},
          "/backend-api/codex/responses",
          payload
        )
    }

    assert {:ok, _response} = UpstreamDispatch.http_request(request)
    assert {:ok, _response} = UpstreamDispatch.http_request(request)

    [first_request, second_request] = FakeUpstream.requests(upstream)
    first_headers = Map.new(first_request.headers)
    second_headers = Map.new(second_request.headers)
    version = CodexClientIdentity.version()

    assert first_headers["user-agent"] == "codex_cli_rs/#{version}"
    assert first_headers["originator"] == CodexClientIdentity.originator()
    assert first_headers["version"] == version

    refute Map.has_key?(first_headers, "cookie")
    refute Map.has_key?(second_headers, "cookie")
  end

  test "native Responses HTTP and compact dispatch derive routing hints from normalized upstream payloads" do
    for {endpoint, path} <- [
          {"/backend-api/codex/responses", "/backend-api/codex/responses"},
          {"/backend-api/codex/responses/compact", "/backend-api/codex/responses/compact"}
        ] do
      {:ok, upstream} =
        FakeUpstream.start_link({:path_json, %{path => {200, %{"ok" => true}}}})

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      upstream_payload = %{
        "model" => "upstream-routing-model",
        "service_tier" => "priority",
        "input" => []
      }

      request = %UpstreamDispatch.Request{
        url: FakeUpstream.url(upstream) <> path,
        token: "redacted",
        upstream_payload: Jason.encode!(upstream_payload),
        original_payload: %{"model" => "public-model", "input" => []},
        identity: upstream_identity(),
        routing_hint_authorized?: true,
        request_options:
          RequestOptions.build(
            %{
              receive_timeout_ms: 1_000,
              forwarded_headers: [{"x-codex-routing-hint", "model=forged"}]
            },
            endpoint,
            %{
              "model" => "public-model",
              "input" => []
            }
          )
      }

      assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(request)
      assert [captured] = FakeUpstream.requests(upstream)

      assert Map.new(captured.headers)["x-codex-routing-hint"] ==
               "model=upstream-routing-model;tier=priority"
    end
  end

  test "native Responses dispatch omits malformed effective routing tiers" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload:
        Jason.encode!(%{
          "model" => "upstream-routing-model",
          "service_tier" => "priority\r\nforged",
          "input" => []
        }),
      original_payload: %{"model" => "public-model", "input" => []},
      identity: upstream_identity(),
      routing_hint_authorized?: true,
      request_options:
        RequestOptions.build(%{receive_timeout_ms: 1_000}, "/backend-api/codex/responses", %{
          "model" => "public-model",
          "input" => []
        })
    }

    assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(request)
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(Map.new(captured.headers), "x-codex-routing-hint")
  end

  test "flag-gated egress observation emits sanitized dispatch metadata and stays silent by default" do
    {:ok, http_upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    {:ok, websocket_upstream} =
      FakeUpstream.start_link({:sequence, [websocket_success("egress-observation")]})

    on_exit(fn -> FakeUpstream.stop(http_upstream) end)
    on_exit(fn -> FakeUpstream.stop(websocket_upstream) end)

    handler_id = "task10-egress-observation-test"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :upstream, :egress_observation],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:egress_observation, metadata})
        end,
        nil
      )

    Application.put_env(:codex_pooler, :task10_egress_observation_enabled, true)

    on_exit(fn ->
      Application.put_env(:codex_pooler, :task10_egress_observation_enabled, false)
      :telemetry.detach(handler_id)
    end)

    upstream_payload = %{"model" => "upstream-routing-model", "input" => []}

    http_request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(http_upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: Jason.encode!(upstream_payload),
      original_payload: upstream_payload,
      identity: upstream_identity(),
      routing_hint_authorized?: true,
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 1_000, client_request_id: "task10-egress-correlator"},
          "/backend-api/codex/responses",
          upstream_payload
        )
    }

    assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(http_request)

    assert_receive {:egress_observation, http_metadata}
    assert http_metadata.transport == :http
    assert http_metadata.client_request_id == "task10-egress-correlator"
    assert "authorization" in http_metadata.header_names
    assert http_metadata.websocket_client_metadata == :none
    # Names only: the credential value must never ride along.
    refute Enum.any?(http_metadata.header_names, &String.contains?(&1, "redacted"))

    websocket_request = %{
      websocket_dispatch_request(websocket_upstream, websocket_request_options())
      | upstream_payload:
          Jason.encode!(%{
            "type" => "response.create",
            "model" => "upstream-routing-model",
            "input" => [],
            "client_metadata" => %{
              "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
            }
          })
    }

    assert {:ok, _response} = UpstreamDispatch.websocket_request(websocket_request)

    assert_receive {:egress_observation, websocket_metadata}
    assert websocket_metadata.transport == :websocket

    assert websocket_metadata.websocket_client_metadata ==
             {:keys, ["ws_request_header_x_openai_internal_codex_responses_lite"]}

    Application.put_env(:codex_pooler, :task10_egress_observation_enabled, false)
    assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(http_request)
    refute_receive {:egress_observation, _silent}, 100
  end

  test "Task 14 product observation emits bounded websocket stage metadata only" do
    {:ok, websocket_upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{
               "type" => "response.output_text.delta",
               "delta" => "forbidden raw text"
             }),
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{"id" => "task14-product-observer"}
             })
           ])
         ]}
      )

    on_exit(fn -> FakeUpstream.stop(websocket_upstream) end)
    handler_id = "task14-product-observation-test"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :task14, :product_stage],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:task14_product_observation, metadata})
        end,
        nil
      )

    Application.put_env(:codex_pooler, :task14_product_observation_enabled, true)

    on_exit(fn ->
      Application.put_env(:codex_pooler, :task14_product_observation_enabled, false)
      :telemetry.detach(handler_id)
    end)

    request_options =
      RequestOptions.build(
        %{
          receive_timeout_ms: 1_000,
          request_id: "request-1",
          client_request_id: "client-1"
        },
        "/backend-api/codex/responses",
        %{"model" => "upstream-routing-model", "input" => []}
      )
      |> RequestOptions.put_model_serving_mode(%{
        configured_mode: "full",
        effective_mode: "full",
        source: "override"
      })

    request = websocket_dispatch_request(websocket_upstream, request_options)
    request = %{request | accounting_attempt: %Attempt{id: "attempt-1"}}
    assert {:ok, _response} = UpstreamDispatch.websocket_request(request)

    observations = collect_task14_observations([])
    assert length(observations) == 4

    assert Enum.frequencies_by(observations, &{&1.direction, &1.event_type}) == %{
             {:provider_to_pooler, "response.output_text.delta"} => 1,
             {:provider_to_pooler, "response.completed"} => 1,
             {:pooler_to_codex, "response.output_text.delta"} => 1,
             {:pooler_to_codex, "response.completed"} => 1
           }

    completed = Enum.filter(observations, &(&1.event_type == "response.completed"))
    assert Enum.uniq(Enum.map(completed, & &1.response_fingerprint)) |> length() == 1
    assert Enum.all?(completed, &Regex.match?(~r/^[0-9a-f]{12}$/, &1.response_fingerprint))
    assert Enum.all?(observations -- completed, &is_nil(&1.response_fingerprint))
    refute inspect(observations) =~ "forbidden raw text"

    for observation <- observations do
      assert observation.request_id == "request-1"
      assert observation.client_request_id == "client-1"
      assert observation.attempt_id == "attempt-1"
      assert observation.route == "backend_websocket"
      assert observation.mode == "full"
      assert observation.event_type in ["response.output_text.delta", "response.completed"]
      refute Map.has_key?(observation, :payload)
      refute Map.has_key?(observation, :frame)
      refute Map.has_key?(observation, :token)
    end
  end

  test "native Responses websocket dispatch derives the model-only routing hint, including prewarm payloads" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [websocket_success("routing-hint-response"), websocket_success("routing-hint-warmup")]}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    request_options = websocket_request_options()

    for upstream_payload <- [
          %{"type" => "response.create", "model" => "upstream-routing-model", "input" => []},
          %{"generate" => false, "model" => "upstream-routing-model"}
        ] do
      request = %{
        websocket_dispatch_request(upstream, request_options)
        | upstream_payload: Jason.encode!(upstream_payload)
      }

      assert {:ok, _response} = UpstreamDispatch.websocket_request(request)
    end

    assert [request, prewarm] = FakeUpstream.requests(upstream)

    for captured <- [request, prewarm] do
      assert Map.new(captured.headers)["x-codex-routing-hint"] ==
               "model=upstream-routing-model"
    end
  end

  test "native-shaped provider-specific and API-key paths omit routing hints on HTTP and websocket dispatch" do
    {:ok, http_upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    {:ok, websocket_upstream} =
      FakeUpstream.start_link({:sequence, [websocket_success("provider-routing-hint")]})

    on_exit(fn -> FakeUpstream.stop(http_upstream) end)
    on_exit(fn -> FakeUpstream.stop(websocket_upstream) end)

    upstream_payload = %{"model" => "upstream-routing-model", "input" => []}

    http_request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(http_upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: Jason.encode!(upstream_payload),
      original_payload: upstream_payload,
      # Provider-specific credentials are represented by a synthetic local
      # identity rather than a selected Codex OpenAI-auth identity.
      identity: %UpstreamIdentity{chatgpt_account_id: "local_provider_identity"},
      routing_hint_authorized?: false,
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 1_000},
          "/backend-api/codex/responses",
          upstream_payload
        )
    }

    websocket_request = %{
      websocket_dispatch_request(websocket_upstream, websocket_request_options())
      | # An API-key credential path has no trusted ChatGPT account provenance.
        identity: %UpstreamIdentity{},
        routing_hint_authorized?: false,
        upstream_payload:
          Jason.encode!(%{
            "type" => "response.create",
            "model" => "upstream-routing-model",
            "input" => []
          })
    }

    assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(http_request)
    assert {:ok, _response} = UpstreamDispatch.websocket_request(websocket_request)

    assert [http_capture] = FakeUpstream.requests(http_upstream)
    assert [websocket_capture] = FakeUpstream.requests(websocket_upstream)

    refute Map.has_key?(Map.new(http_capture.headers), "x-codex-routing-hint")
    refute Map.has_key?(Map.new(websocket_capture.headers), "x-codex-routing-hint")
  end

  test "custom non-prefixed credentials omit routing hints on HTTP and websocket dispatch" do
    {:ok, http_upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    {:ok, websocket_upstream} =
      FakeUpstream.start_link({:sequence, [websocket_success("custom-routing-hint")]})

    on_exit(fn -> FakeUpstream.stop(http_upstream) end)
    on_exit(fn -> FakeUpstream.stop(websocket_upstream) end)

    upstream_payload = %{"model" => "upstream-routing-model", "input" => []}
    custom_identity = %UpstreamIdentity{chatgpt_account_id: "unclassified_identity"}

    http_request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(http_upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: Jason.encode!(upstream_payload),
      original_payload: upstream_payload,
      identity: custom_identity,
      routing_hint_authorized?: false,
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 1_000},
          "/backend-api/codex/responses",
          upstream_payload
        )
    }

    websocket_request = %{
      websocket_dispatch_request(websocket_upstream, websocket_request_options())
      | identity: custom_identity,
        routing_hint_authorized?: false,
        upstream_payload:
          Jason.encode!(%{
            "type" => "response.create",
            "model" => "upstream-routing-model",
            "input" => []
          })
    }

    assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(http_request)
    assert {:ok, _response} = UpstreamDispatch.websocket_request(websocket_request)

    assert [http_capture] = FakeUpstream.requests(http_upstream)
    assert [websocket_capture] = FakeUpstream.requests(websocket_upstream)

    refute Map.has_key?(Map.new(http_capture.headers), "x-codex-routing-hint")
    refute Map.has_key?(Map.new(websocket_capture.headers), "x-codex-routing-hint")
  end

  test "public and translated Responses dispatch never forwards caller routing hints" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/v1/responses" => {200, %{"ok" => true}},
           "/backend-api/codex/responses" => {200, %{"ok" => true}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    upstream_payload = %{"model" => "upstream-routing-model", "input" => []}

    for {endpoint, path, opts} <- [
          {"/v1/responses", "/v1/responses", %{}},
          {"/backend-api/codex/responses", "/backend-api/codex/responses",
           %{openai_source_endpoint: "/v1/responses"}}
        ] do
      request_options =
        RequestOptions.build(
          Map.put(opts, :forwarded_headers, [{"x-codex-routing-hint", "model=forged"}]),
          endpoint,
          %{"model" => "public-model", "input" => []}
        )

      request = %UpstreamDispatch.Request{
        url: FakeUpstream.url(upstream) <> path,
        token: "redacted",
        upstream_payload: Jason.encode!(upstream_payload),
        original_payload: %{"model" => "public-model", "input" => []},
        identity: upstream_identity(),
        routing_hint_authorized?: true,
        request_options: request_options
      }

      assert {:ok, %Req.Response{status: 200}} = UpstreamDispatch.http_request(request)
    end

    for captured <- FakeUpstream.requests(upstream) do
      refute Map.has_key?(Map.new(captured.headers), "x-codex-routing-hint")
    end
  end

  test "streaming non-429 4xx drains the complete rejection body into response private" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "invalid_request_error",
          "message" => "synthetic rejection detail",
          "param" => "input[0].content",
          "type" => "invalid_request_error"
        }
      })

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.chunked_response(
          [binary_part(body, 0, 7), binary_part(body, 7, byte_size(body) - 7)],
          status: 400
        )
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    payload = %{"model" => "example-model", "stream" => true}

    request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: Jason.encode!(payload),
      original_payload: payload,
      identity: upstream_identity(),
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 5_000},
          "/backend-api/codex/responses",
          payload
        )
    }

    assert {:ok, response} = UpstreamDispatch.http_request(request)
    assert response.status == 400
    assert %Req.Response.Async{} = response.body
    assert RejectionBody.fetch(response) == body
    assert Metadata.response_body(response) == ""
  end

  test "streaming exact policy rejection attaches only its sanitized summary beside the private body" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "misalignment_policy_violation",
          "message" => "  exact provider wording  ",
          "param" => "input[0].content"
        },
        "sibling" => "must remain private"
      })

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.chunked_response(
          [binary_part(body, 0, 11), binary_part(body, 11, byte_size(body) - 11)],
          status: 403
        )
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    payload = %{"model" => "example-model", "stream" => true}

    request = %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: Jason.encode!(payload),
      original_payload: payload,
      identity: upstream_identity(),
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 5_000},
          "/backend-api/codex/responses",
          payload
        )
    }

    assert {:ok, response} = UpstreamDispatch.http_request(request)
    assert response.status == 403
    assert %Req.Response.Async{} = response.body
    assert RejectionBody.fetch(response) == body

    assert MisalignmentPolicyViolation.fetch_summary(response) == %{
             code: "misalignment_policy_violation",
             message: "  exact provider wording  "
           }

    assert Map.keys(MisalignmentPolicyViolation.fetch_summary(response)) |> Enum.sort() ==
             [:code, :message]

    assert Metadata.response_body(response) == ""
    refute inspect(MisalignmentPolicyViolation.fetch_summary(response)) =~ "input[0].content"
    refute inspect(MisalignmentPolicyViolation.fetch_summary(response)) =~ "must remain private"
  end

  test "rejection drain processes ordered multipart parsed parts, ignores trailers, and preserves foreign mailbox messages" do
    {response, ref} =
      async_response(self(), nil, fn stream_ref, message ->
        case message do
          {^stream_ref, :multipart} ->
            {:ok,
             [
               {:data, "first"},
               {:trailers, [{"x-test", "trailer"}]},
               {:data, "second"},
               :done
             ]}

          _message ->
            :unknown
        end
      end)

    other_ref = make_ref()
    send(self(), {other_ref, {:data, "foreign"}})
    send(self(), {ref, :multipart})

    assert RejectionDrain.drain(response) == "firstsecond"
    assert_receive {^other_ref, {:data, "foreign"}}
    refute_received {:rejection_cancelled, ^ref}
  end

  test "rejection drain applies the cap across multipart parsed parts and cancels" do
    {response, ref} =
      async_response(self(), nil, fn stream_ref, message ->
        case message do
          {^stream_ref, :multipart} ->
            {:ok, [{:data, String.duplicate("x", 65_536)}, {:data, "x"}]}

          _message ->
            :unknown
        end
      end)

    send(self(), {ref, :multipart})

    drained_body = RejectionDrain.drain(response)

    assert drained_body == ""
    assert_policy_not_classified(drained_body)
    assert_receive {:rejection_cancelled, ^ref}
  end

  test "rejection drain discards over-cap and error prefixes and cancels" do
    {cap_response, cap_ref} = async_response(self())
    send(self(), {cap_ref, {:data, String.duplicate("x", 65_537)}})
    cap_body = RejectionDrain.drain(cap_response)
    assert cap_body == ""
    assert_policy_not_classified(cap_body)
    assert_receive {:rejection_cancelled, ^cap_ref}

    {error_response, error_ref} = async_response(self())
    send(self(), {error_ref, {:data, "partial"}})
    send(self(), {error_ref, {:error, :closed}})
    error_body = RejectionDrain.drain(error_response)
    assert error_body == ""
    assert_policy_not_classified(error_body)
    assert_receive {:rejection_cancelled, ^error_ref}
  end

  @tag timeout: 5_000
  test "rejection drain uses one absolute deadline and discards a stalled partial prefix" do
    {response, ref} = async_response(self())
    send(self(), {ref, {:data, "partial"}})
    started_at = System.monotonic_time(:millisecond)

    drained_body = RejectionDrain.drain(response)

    assert drained_body == ""
    assert_policy_not_classified(drained_body)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms in 1_900..2_500
    assert_receive {:rejection_cancelled, ^ref}
  end

  test "rejection drain treats cancellation failure as nonfatal" do
    {response, ref} =
      async_response(self(), fn _ref ->
        raise "synthetic cancellation failure"
      end)

    send(self(), {ref, {:error, :closed}})
    drained_body = RejectionDrain.drain(response)

    assert drained_body == ""
    assert_policy_not_classified(drained_body)
  end

  test "regular runtime headers use only the effective serving-mode snapshot for Lite markers" do
    identity = upstream_identity()
    payload = %{"model" => "example-model"}
    residency = "synthetic-runtime-residency"
    token = synthetic_access_jwt(residency)

    for endpoint <- [
          "/backend-api/codex/responses",
          "/backend-api/codex/responses/compact"
        ] do
      lite_options = RequestOptions.build(serving_mode_opts("lite"), endpoint, payload)

      lite_headers =
        UpstreamDispatch.regular_runtime_headers(
          identity,
          token,
          lite_options,
          [{"X-OpenAI-Internal-Codex-Responses-Lite", "false"}]
        )

      assert [{"x-openai-internal-codex-responses-lite", "true"}] =
               header_entries(lite_headers, "x-openai-internal-codex-responses-lite")

      assert [{"x-openai-internal-codex-residency", ^residency}] =
               header_entries(lite_headers, "x-openai-internal-codex-residency")

      assert [{"chatgpt-account-id", "acct_owner_submit_timeout"}] =
               header_entries(lite_headers, "chatgpt-account-id")

      full_options = RequestOptions.build(serving_mode_opts("full"), endpoint, payload)

      full_headers =
        UpstreamDispatch.regular_runtime_headers(
          identity,
          token,
          full_options,
          [{"x-openai-internal-codex-responses-lite", "true"}]
        )

      assert header_entries(full_headers, "x-openai-internal-codex-responses-lite") == []

      assert [{"x-openai-internal-codex-residency", ^residency}] =
               header_entries(full_headers, "x-openai-internal-codex-residency")
    end
  end

  test "SSE mode and retry retargeting preserve the immutable Lite snapshot" do
    payload = %{"model" => "example-model", "stream" => true}

    options =
      serving_mode_opts("lite")
      |> Map.put(:transport, "http_sse")
      |> RequestOptions.build("/backend-api/codex/responses", payload)

    retried = RequestOptions.retarget(options, "/backend-api/codex/responses", payload)

    assert retried.transport.transport == "http_sse"

    assert RequestOptions.model_serving_mode_snapshot(retried) == %{
             configured_mode: "lite",
             effective_mode: "lite",
             source: "override"
           }

    headers =
      UpstreamDispatch.regular_runtime_headers(
        upstream_identity(),
        "redacted",
        retried,
        []
      )

    assert [{"x-openai-internal-codex-responses-lite", "true"}] =
             header_entries(headers, "x-openai-internal-codex-responses-lite")

    assert_raise ArgumentError, "model serving mode snapshot is immutable", fn ->
      RequestOptions.put_routing(retried,
        model_serving_mode_configured: "full",
        model_serving_mode: "full",
        model_serving_mode_source: "override",
        use_responses_lite?: false
      )
    end
  end

  test "direct websocket request preserves exact connection metadata through result recording" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [
           websocket_success("direct-initial"),
           websocket_success("direct-reused"),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success("direct-reconnected")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    on_exit(fn -> FakeUpstream.stop(upstream) end)

    request_options = websocket_request_options(session)
    request = websocket_dispatch_request(upstream, request_options)

    assert {:ok, initial} = UpstreamDispatch.websocket_request(request)
    initial_connection = Map.fetch!(initial, :upstream_websocket_connection)

    assert initial_connection == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 1,
             reused: false,
             reconnected: false
           }

    assert {:ok, reused} = UpstreamDispatch.websocket_request(request)

    assert Map.fetch!(reused, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 1,
             reused: true,
             reconnected: false
           }

    assert {:ok, reconnected} = UpstreamDispatch.websocket_request(request)

    assert Map.fetch!(reconnected, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 2,
             reused: false,
             reconnected: true
           }

    FakeUpstream.set_mode(
      upstream,
      {:sequence,
       [
         FakeUpstream.websocket_sse_then_close([]),
         FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "reconnect_rejected"}},
           status: 503
         )
       ]}
    )

    assert {:error, failed_reconnect} = UpstreamDispatch.websocket_request(request)
    assert %{body: "", reason: {:websocket_upgrade_failed, 503, _headers}} = failed_reconnect

    assert Map.fetch!(failed_reconnect, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 2,
             reused: true,
             reconnected: false
           }
  end

  test "one-shot websocket request preserves its structured response identity" do
    response_id = "one-shot-response-identity"
    {:ok, success_upstream} = FakeUpstream.start_link(websocket_success(response_id))
    on_exit(fn -> FakeUpstream.stop(success_upstream) end)

    success_request =
      websocket_dispatch_request(
        success_upstream,
        websocket_request_options()
      )

    assert {:ok, %{response_id: ^response_id} = success} =
             UpstreamDispatch.websocket_request(success_request)

    success_connection = Map.fetch!(success, :upstream_websocket_connection)

    assert success_connection == %{
             lifecycle_id: success_connection.lifecycle_id,
             generation: 1,
             reused: false,
             reconnected: false
           }
  end

  test "legacy remote bare ok stays identity-less and does not register an alias", %{auth: auth} do
    remote_node = :"codex_pooler@legacy-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, :ok}}
      )

    request_options =
      websocket_owner_request_options(
        session,
        lease_token,
        %{pid: self(), epoch: 1, correlation_id: "corr-legacy-owner-result"},
        forwarder_opts
      )
      |> RequestOptions.put_transport(
        websocket_owner_submission_observer: fn ->
          send(self(), :legacy_remote_owner_submission_observed)
        end
      )

    alias_ids_before =
      Repo.all(
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id == ^session.id,
          select: alias_record.id,
          order_by: [asc: alias_record.id]
        )
      )

    request = %UpstreamDispatch.Request{
      url: "https://upstream.example.test/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: upstream_identity(),
      routing_hint_authorized?: true,
      accounting_request: nil,
      accounting_attempt: nil,
      writer: fn _message -> :ok end,
      request_options: request_options
    }

    assert {:ok, %{body: "", terminal: "response.completed", status: 200, headers: []} = result} =
             UpstreamDispatch.websocket_request(request)

    assert result == %{body: "", terminal: "response.completed", status: 200, headers: []}
    refute Map.has_key?(result, :response_id)
    assert_received :legacy_remote_owner_submission_observed

    assert Repo.all(
             from(alias_record in BridgeSessionAlias,
               where: alias_record.codex_session_id == ^session.id,
               select: alias_record.id,
               order_by: [asc: alias_record.id]
             )
           ) == alias_ids_before

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request, arity: 4}}
  end

  test "accepted remote owner errors notify the socket before returning the error", %{auth: auth} do
    remote_node = :"codex_pooler@accepted-error-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{
          remote_node =>
            {:return, {:websocket_owner_submission_accepted, {:error, :owner_drained}}}
        }
      )

    test_pid = self()
    observer_release_ref = make_ref()

    observer_coordinator =
      spawn(fn ->
        receive do
          {:accepted_owner_error_observer_started, observer_pid, ^observer_release_ref} ->
            refute_received {:accepted_owner_error_call_returned, _result}
            send(observer_pid, {:release_accepted_owner_error_observer, observer_release_ref})

            receive do
              {:accepted_owner_error_call_returned, result} ->
                send(test_pid, {:accepted_owner_error_sequence, result})
            end
        end
      end)

    request_options =
      session
      |> websocket_owner_request_options(
        lease_token,
        %{pid: self(), epoch: 1, correlation_id: "corr-accepted-owner-error"},
        forwarder_opts
      )
      |> RequestOptions.put_transport(
        websocket_owner_submission_observer: fn ->
          send(
            observer_coordinator,
            {:accepted_owner_error_observer_started, self(), observer_release_ref}
          )

          receive do
            {:release_accepted_owner_error_observer, ^observer_release_ref} -> :ok
          end
        end
      )

    request = %UpstreamDispatch.Request{
      url: "https://upstream.example.test/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: upstream_identity(),
      accounting_request: nil,
      writer: fn _message -> :ok end,
      request_options: request_options
    }

    result = UpstreamDispatch.websocket_request(request)
    send(observer_coordinator, {:accepted_owner_error_call_returned, result})

    assert result == {:error, %{body: "", reason: :owner_drained, headers: [], started: false}}
    assert_receive {:accepted_owner_error_sequence, ^result}

    assert_receive {:websocket_owner_harness_node_call,
                    %{node: ^remote_node, function: :remote_submit_request, arity: 4}}
  end

  test "malformed owner replies settle as owner_crashed and register no alias", %{auth: auth} do
    remote_node = :"codex_pooler@malformed-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    alias_ids_before =
      Repo.all(
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id == ^session.id,
          select: alias_record.id,
          order_by: [asc: alias_record.id]
        )
      )

    malformed_replies = [
      {{:ok, :banana}, "not_a_map", "missing", "not_a_map"},
      {{:ok, %{body: "", status: 200, headers: [], response_id: "resp_owner_no_terminal"}},
       "map_missing_fields", "missing", "terminal"},
      {{:ok, %{terminal: "response.completed", status: 200, headers: []}}, "map_missing_fields",
       "missing", "body"},
      {{:ok, %{terminal: "response.completed", body: ""}}, "map_missing_fields", "missing",
       "status,headers"},
      {{:ok, %{}}, "map_missing_fields", "missing", "body,terminal,status,headers"},
      {{:ok, %{body: %{}, terminal: "response.completed", status: 200, headers: []}},
       "map_invalid_fields", "invalid", "body"},
      {{:ok, %{body: "", terminal: nil, status: 200, headers: []}}, "map_invalid_fields",
       "invalid", "terminal"},
      {{:ok, %{body: "", terminal: "response.failed", status: 502, headers: []}},
       "map_invalid_fields", "invalid", "status"},
      {{:ok, %{body: "", terminal: "response.failed", status: 200, headers: %{}}},
       "map_invalid_fields", "invalid", "headers"},
      {{:ok,
        %{
          body: "",
          terminal: "response.completed",
          status: 200,
          headers: [],
          websocket_frame_headers: []
        }}, "map_invalid_fields", "invalid", "websocket_frame_headers"}
    ]

    for {{malformed_reply, expected_shape, detail_key, expected_fields}, index} <-
          Enum.with_index(malformed_replies, 1) do
      forwarder_opts =
        WebsocketOwnerNodeHarness.node_client_opts([remote_node],
          calls: %{remote_node => {:return, malformed_reply}}
        )

      request_options =
        websocket_owner_request_options(
          session,
          lease_token,
          %{pid: self(), epoch: 1, correlation_id: "corr-malformed-owner-result-#{index}"},
          forwarder_opts
        )

      request = %UpstreamDispatch.Request{
        url: "https://upstream.example.test/backend-api/codex/responses",
        token: "redacted",
        upstream_payload: "{}",
        identity: upstream_identity(),
        accounting_request: nil,
        writer: fn _message -> :ok end,
        request_options: request_options
      }

      logs =
        capture_log([level: :warning], fn ->
          assert UpstreamDispatch.websocket_request(request) ==
                   {:error, %{body: "", reason: :owner_crashed, headers: [], started: false}}
        end)

      assert logs =~ "websocket owner reply malformed boundary=submit"
      assert logs =~ "reply_shape=#{expected_shape} "
      assert logs =~ "#{detail_key}=#{expected_fields} "
      assert logs =~ "canonical_error=owner_crashed"
      refute logs =~ "banana"
      refute logs =~ "resp_owner_no_terminal"

      assert_receive {:websocket_owner_harness_node_call,
                      %{node: ^remote_node, function: :remote_submit_request, arity: 4}}
    end

    assert Repo.all(
             from(alias_record in BridgeSessionAlias,
               where: alias_record.codex_session_id == ^session.id,
               select: alias_record.id,
               order_by: [asc: alias_record.id]
             )
           ) == alias_ids_before
  end

  test "one-shot websocket request omits connection metadata on initial upgrade failure" do
    {:ok, failed_upstream} =
      FakeUpstream.start_link(
        FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "initial_rejected"}},
          status: 401
        )
      )

    on_exit(fn -> FakeUpstream.stop(failed_upstream) end)

    failure_request = websocket_dispatch_request(failed_upstream, websocket_request_options())

    assert {:error, failure} = UpstreamDispatch.websocket_request(failure_request)
    assert %{body: "", reason: {:websocket_upgrade_failed, 401, _headers}} = failure
    refute Map.has_key?(failure, :upstream_websocket_connection)
  end

  defp websocket_request_options(session \\ nil) do
    opts = %{receive_timeout_ms: 1_000}
    opts = if is_pid(session), do: Map.put(opts, :upstream_websocket_session, session), else: opts
    RequestOptions.for_websocket(opts, %{"model" => "example-model"})
  end

  defp collect_task14_observations(observations) do
    receive do
      {:task14_product_observation, observation} ->
        collect_task14_observations([observation | observations])
    after
      0 -> Enum.reverse(observations)
    end
  end

  defp async_response(notify, cancel_fun \\ nil, stream_fun \\ nil) do
    ref = make_ref()

    stream_fun =
      stream_fun ||
        fn stream_ref, message ->
          case message do
            {^stream_ref, {:data, data}} -> {:ok, [data: data]}
            {^stream_ref, :done} -> {:ok, [:done]}
            {^stream_ref, {:trailers, trailers}} -> {:ok, [trailers: trailers]}
            {^stream_ref, {:error, reason}} -> {:error, reason}
            _message -> :unknown
          end
        end

    cancel_fun =
      cancel_fun ||
        fn cancel_ref ->
          send(notify, {:rejection_cancelled, cancel_ref})
          :ok
        end

    response = %Req.Response{
      status: 400,
      body: %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: stream_fun,
        cancel_fun: cancel_fun
      }
    }

    {response, ref}
  end

  defp serving_mode_opts(mode) when mode in ["lite", "full"] do
    %{
      model_serving_mode_configured: mode,
      model_serving_mode: mode,
      model_serving_mode_source: "override"
    }
  end

  defp header_entries(headers, name) do
    Enum.filter(headers, fn
      {header_name, _value} when is_binary(header_name) ->
        String.downcase(header_name) == name

      _header ->
        false
    end)
  end

  defp websocket_dispatch_request(upstream, request_options) do
    %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: upstream_identity(),
      routing_hint_authorized?: true,
      accounting_request: nil,
      writer: fn _message -> :ok end,
      assignment_advertised?: false,
      request_options: request_options
    }
  end

  defp websocket_success(id) do
    FakeUpstream.websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => id}
      })
    ])
  end

  defp websocket_owner_request_options(session, lease_token, downstream, forwarder_opts) do
    RequestOptions.for_websocket(
      %{
        codex_session: session,
        receive_timeout_ms: @receive_timeout_ms,
        websocket_owner_forwarding_enabled?: true,
        websocket_owner_session: session,
        websocket_owner_lease_token: lease_token,
        websocket_owner_downstream: downstream,
        websocket_owner_downstream_epoch: downstream.epoch,
        websocket_owner_proxy_instance_id: Atom.to_string(node()),
        websocket_owner_instance_id: session.owner_instance_id,
        websocket_owner_forwarder_opts: forwarder_opts
      },
      %{"model" => "example-model"}
    )
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture(auth, owner_instance_id) do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "owner-submit-timeout-#{System.unique_integer([:positive])}",
               owner_instance_id: owner_instance_id
             })

    session = Repo.get!(CodexSession, session.id)
    %{session: session, lease_token: session.owner_lease_token}
  end

  defp upstream_identity do
    %UpstreamIdentity{chatgpt_account_id: "acct_owner_submit_timeout"}
  end

  defp synthetic_access_jwt(residency) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)

    payload =
      Base.url_encode64(
        Jason.encode!(%{
          "https://api.openai.com/auth" => %{"chatgpt_compute_residency" => residency}
        }),
        padding: false
      )

    header <> "." <> payload <> ".synthetic-signature"
  end

  defp assert_policy_not_classified(body) do
    request_options =
      RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})

    assert MisalignmentPolicyViolation.classify_http(403, body, request_options) == :no_match
  end

  defp restore_operational_settings(nil) do
    Application.delete_env(:codex_pooler, OperationalSettings)
  end

  defp restore_operational_settings(previous_settings) do
    Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
  end

  defp cleanup_local_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn codex_session_id ->
        try do
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
            _result = GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        catch
          :exit, _reason -> :ok
        end
      end)
    end)

    :ok
  end
end
