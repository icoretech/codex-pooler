defmodule CodexPoolerWeb.Runtime.BackendCodexPromptCacheSessionIdTest do
  @moduledoc """
  Native `/backend-api/codex` HTTP requests (SSE, JSON and compact) whose
  client sent no usable provider `session-id` send the provider the same
  Pool- and key-scoped `session-id` that `/v1` derives from the body
  `prompt_cache_key`, so consecutive full-history HTTP turns of a client that
  names its conversation only through a Pooler-local alias (`session_id`,
  `x-session-id` and the like) reach the replica holding the warm prompt
  cache. When the request carries no usable `prompt_cache_key` either (cline's
  `openai-codex` provider sends none), the provider `session-id` derives from
  the alias itself under its own Pool- and key-scoped namespace (findings#206
  row 206-606). A client `session-id` is forwarded unchanged, the alias still keys
  the local CodexSession, the native websocket handshake keeps forwarding only
  what the upgrade carried, and the derived value is never stored or logged
  (findings#206 row 206-557).
  """

  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 2,
      native_text_input: 1,
      public_websocket_connect_with_request_headers!: 5,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  @cache_key "fixture-native-conversation-cache-key"
  @lite_header "x-openai-internal-codex-responses-lite"

  for mode <- ["full", "lite"] do
    @tag :provider_session_headers
    test "native SSE, JSON and compact requests with only a local alias send the /v1-derived session-id in #{mode}",
         %{conn: conn} do
      # provenance: synthetic_adversarial (invented replies; the upstream session-id header is the claim)
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            completed_sse("resp_native_alias_sse"),
            FakeUpstream.json_response(json_response_body("resp_native_alias_json")),
            FakeUpstream.json_response(compaction_body()),
            completed_sse("resp_v1_same_key")
          ])
        )

      setup = gateway_setup(upstream, compact?: true)

      BackendCodexWebsocketSupport.set_model_serving_mode!(
        BackendCodexWebsocketSupport.model_serving_scope(),
        setup,
        unquote(mode)
      )

      expected = session_id(setup, @cache_key)
      assert is_binary(expected)
      underscore_alias = "native_underscore_alias_fixture"
      x_session_alias = "native-x-session-id-fixture"

      {responses, logs} =
        with_log(fn ->
          sse =
            conn
            |> auth(setup)
            |> put_req_header("session_id", underscore_alias)
            |> post("/backend-api/codex/responses", native_payload(setup, @cache_key, stream: true))

          json =
            build_conn()
            |> auth(setup)
            |> put_req_header("x-session-id", x_session_alias)
            |> post("/backend-api/codex/responses", native_payload(setup, @cache_key))

          compact =
            build_conn()
            |> auth(setup)
            |> put_req_header("session_id", underscore_alias)
            |> post("/backend-api/codex/responses/compact", native_payload(setup, @cache_key))

          v1 =
            build_conn()
            |> auth(setup)
            |> post("/v1/responses", %{
              "model" => setup.model.exposed_model_id,
              "prompt_cache_key" => @cache_key,
              "input" => "same conversation over /v1",
              "store" => false
            })

          [sse, json, compact, v1]
        end)

      [sse, json, compact, v1] = responses
      assert sse.status == 200
      assert sse.resp_body =~ "resp_native_alias_sse"
      assert %{"id" => "resp_native_alias_json"} = json_response(json, 200)
      assert %{"object" => "response.compaction"} = json_response(compact, 200)
      assert %{"id" => "resp_v1_same_key"} = json_response(v1, 200)

      assert [sse_upstream, json_upstream, compact_upstream, v1_upstream] =
               FakeUpstream.requests(upstream)

      assert compact_upstream.path == "/backend-api/codex/responses/compact"

      # One value for the Pool, the key and the prompt_cache_key, whichever
      # route and transport carried it.
      for captured <- [sse_upstream, json_upstream, compact_upstream, v1_upstream] do
        headers = Map.new(captured.headers)
        assert headers["session-id"] == expected
        refute Map.has_key?(headers, "session_id")
        refute Map.has_key?(headers, "x-session-id")
      end

      for captured <- [sse_upstream, json_upstream] do
        assert Map.new(captured.headers)[@lite_header] ==
                 if(unquote(mode) == "lite", do: "true", else: nil)
      end

      # The local continuity key is still the client's alias, never the
      # derived provider value.
      assert %CodexSession{} = underscore_session = Repo.get_by(CodexSession, session_key: underscore_alias)
      assert %CodexSession{} = x_session = Repo.get_by(CodexSession, session_key: x_session_alias)
      refute Repo.get_by(CodexSession, session_key: expected)

      native_requests =
        Repo.all(
          from(r in Request,
            where: r.pool_id == ^setup.pool.id and r.endpoint != "/v1/responses",
            order_by: [asc: r.admitted_at]
          )
        )

      assert Enum.map(native_requests, & &1.request_metadata["codex_session_key"]) |> Enum.take(3) ==
               [underscore_alias, x_session_alias, underscore_alias]

      assert Enum.map(native_requests, & &1.request_metadata["codex_session_id"]) |> Enum.take(3) ==
               [underscore_session.id, x_session.id, underscore_session.id]

      assert_session_id_absent_from_evidence!(expected, responses, logs)
    end
  end

  @tag :provider_session_headers
  test "a usable client session-id is forwarded unchanged, an unusable one is replaced by the derived value",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(json_response_body("resp_client_session_id")),
          FakeUpstream.json_response(compaction_body()),
          FakeUpstream.json_response(json_response_body("resp_overlong_client_session_id"))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    client_session_id = "client-session-id-fixture"

    responses = [
      conn
      |> auth(setup)
      |> put_req_header("session-id", client_session_id)
      |> put_req_header("session_id", "underscore-alias-fixture")
      |> post("/backend-api/codex/responses", native_payload(setup, @cache_key)),
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", client_session_id)
      |> post("/backend-api/codex/responses/compact", native_payload(setup, @cache_key)),
      # Over the 128-byte provider bound, so it is never forwarded: without
      # the derivation the provider would get no session-id at all.
      build_conn()
      |> auth(setup)
      |> put_req_header("session-id", String.duplicate("s", 129))
      |> post("/backend-api/codex/responses", native_payload(setup, @cache_key))
    ]

    assert Enum.all?(responses, &(&1.status == 200))

    assert Enum.map(FakeUpstream.requests(upstream), &Map.new(&1.headers)["session-id"]) == [
             client_session_id,
             client_session_id,
             session_id(setup, @cache_key)
           ]
  end

  @tag :provider_session_headers
  test "without a usable prompt_cache_key the alias is the source, without either nothing is sent, and two API keys never share one",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(json_response_body("resp_native_key_scope")))
    setup = gateway_setup(upstream, compact?: true)
    other_key = active_api_key_fixture(setup.pool)
    assert other_key.api_key.id != setup.api_key.id

    responses = [
      conn
      |> auth(setup)
      |> put_req_header("session_id", "alias-without-cache-key")
      |> post("/backend-api/codex/responses", Map.delete(native_payload(setup, @cache_key), "prompt_cache_key")),
      build_conn()
      |> auth(setup)
      |> put_req_header("x-session-id", "alias-with-overlong-cache-key")
      |> post("/backend-api/codex/responses/compact", native_payload(setup, String.duplicate("k", 513))),
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", Map.delete(native_payload(setup, @cache_key), "prompt_cache_key")),
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", native_payload(setup, "default")),
      build_conn()
      |> auth(other_key)
      |> post("/backend-api/codex/responses", native_payload(setup, "default")),
      build_conn()
      |> auth(other_key)
      |> put_req_header("session_id", "alias-without-cache-key")
      |> post("/backend-api/codex/responses", Map.delete(native_payload(setup, @cache_key), "prompt_cache_key"))
    ]

    assert Enum.all?(responses, &(&1.status == 200))

    this_key = session_id(setup, "default")
    that_key = session_id(other_key, "default")
    this_alias = alias_session_id(setup, "alias-without-cache-key")
    that_alias = alias_session_id(other_key, "alias-without-cache-key")
    derived = [this_key, that_key, this_alias, that_alias, alias_session_id(setup, "alias-with-overlong-cache-key")]
    assert Enum.all?(derived, &is_binary/1)
    assert Enum.uniq(derived) == derived

    assert Enum.map(FakeUpstream.requests(upstream), &Map.new(&1.headers)["session-id"]) == [
             this_alias,
             alias_session_id(setup, "alias-with-overlong-cache-key"),
             nil,
             this_key,
             that_key,
             that_alias
           ]
  end

  for mode <- ["full", "lite"] do
    @tag :provider_session_headers
    test "a cline-shaped client with only a session_id alias and no prompt_cache_key sends one alias-derived session-id on both turns in #{mode}",
         %{conn: conn} do
      # provenance: cline `openai-codex` provider (sdk/packages/llms/src/providers/request-headers.ts
      # buildOpenAICodexRequestHeaders; recorded request body in its provider VCR): headers
      # originator, session_id (the task id), User-Agent; body without prompt_cache_key. Values invented.
      upstream =
        start_upstream(FakeUpstream.strict_sequence([completed_sse("resp_cline_turn_1"), completed_sse("resp_cline_turn_2")]))

      setup = gateway_setup(upstream, compact?: false)

      BackendCodexWebsocketSupport.set_model_serving_mode!(
        BackendCodexWebsocketSupport.model_serving_scope(),
        setup,
        unquote(mode)
      )

      task_id = "cline-task-fixture-#{System.unique_integer([:positive])}"
      expected = alias_session_id(setup, task_id)
      assert is_binary(expected)
      # A distinct namespace: the same text as a prompt_cache_key never gives the same id.
      refute expected == session_id(setup, task_id)

      {responses, logs} =
        with_log(fn ->
          for {text, c} <- [{"cline turn one", conn}, {"cline turn two", build_conn()}] do
            c
            |> auth(setup)
            |> put_req_header("originator", "cline")
            |> put_req_header("session_id", task_id)
            |> put_req_header("user-agent", "Cline/1.0.0")
            |> post("/backend-api/codex/responses", %{
              "model" => setup.model.exposed_model_id,
              "instructions" => "You are a concise assistant.",
              "input" => native_text_input(text),
              "include" => ["reasoning.encrypted_content"],
              "store" => false,
              "stream" => true
            })
          end
        end)

      assert Enum.all?(responses, &(&1.status == 200))
      assert [turn_1, turn_2] = FakeUpstream.requests(upstream)

      for captured <- [turn_1, turn_2] do
        headers = Map.new(captured.headers)
        assert headers["session-id"] == expected
        refute Map.has_key?(headers, "session_id")
        refute Enum.any?(captured.headers, fn {_name, value} -> value == task_id end)
        refute Map.has_key?(captured.json, "prompt_cache_key")

        assert headers[@lite_header] == if(unquote(mode) == "lite", do: "true", else: nil)
      end

      assert %CodexSession{} = Repo.get_by(CodexSession, session_key: task_id)
      refute Repo.get_by(CodexSession, session_key: expected)
      assert_session_id_absent_from_evidence!(expected, responses, logs)
    end
  end

  @tag :provider_session_headers
  test "the native websocket handshake still forwards only the session headers the upgrade carried" do
    provider_payload = json_response_body("resp_native_ws_alias_only")
    upstream = start_upstream(FakeUpstream.json_response(provider_payload))
    setup = gateway_setup(upstream, compact?: false)
    port = start_public_endpoint!()
    turn_state = "native-ws-alias-only-#{System.unique_integer([:positive])}"

    # provenance: synthetic_adversarial (an upgrade naming its conversation only
    # through the underscore alias, as some third-party native clients do)
    {conn, websocket, ref, _response_headers} =
      public_websocket_connect_with_request_headers!(
        port,
        setup,
        turn_state,
        "/backend-api/codex/responses",
        [{"session_id", "native-ws-underscore-alias"}]
      )

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "prompt_cache_key" => @cache_key,
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert frame == CodexPooler.JSON.encode!(provider_payload)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.json["prompt_cache_key"] == @cache_key

      refute Enum.any?(captured.headers, fn {name, _value} ->
               String.downcase(name) in ["session-id", "session_id", "thread-id", "x-client-request-id"]
             end)

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  # Mirrors the production derivation with the trusted ids of the fixture
  # tenant the request authenticates as.
  defp session_id(tenant, cache_key) do
    TransportEnvelope.prompt_cache_session_id(
      %{pool_id: tenant.pool.id, api_key_id: tenant.api_key.id},
      cache_key
    )
  end

  defp alias_session_id(tenant, alias) do
    TransportEnvelope.continuity_alias_session_id(
      %{pool_id: tenant.pool.id, api_key_id: tenant.api_key.id},
      alias
    )
  end

  defp native_payload(setup, cache_key, opts \\ []) do
    %{
      "model" => setup.model.exposed_model_id,
      "prompt_cache_key" => cache_key,
      "input" => native_text_input("native prompt cache session fixture"),
      "store" => false
    }
    |> then(fn payload -> if opts[:stream], do: Map.put(payload, "stream", true), else: payload end)
  end

  defp json_response_body(response_id) do
    %{
      "id" => response_id,
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp compaction_body do
    %{
      "object" => "response.compaction",
      "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
    }
  end

  defp completed_sse(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => json_response_body(response_id)
       }}
    ])
  end

  # The derived value comes from a client-chosen key, so it is treated like the
  # key itself: never in accounting rows, logs or client responses.
  defp assert_session_id_absent_from_evidence!(session_id, responses, logs) do
    refute logs =~ session_id

    for response <- responses do
      refute response.resp_body =~ session_id
    end

    refute inspect(Repo.all(Request), limit: :infinity, printable_limit: :infinity) =~ session_id
    refute inspect(Repo.all(Attempt), limit: :infinity, printable_limit: :infinity) =~ session_id
    refute inspect(Repo.all(CodexSession), limit: :infinity, printable_limit: :infinity) =~ session_id
  end
end
