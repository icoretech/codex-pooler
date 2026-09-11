defmodule CodexPoolerWeb.V1.PromptCacheSessionIdTest do
  @moduledoc """
  Public `/v1` requests that carry `prompt_cache_key` send the provider a
  Pooler-derived `session-id` (UUID v5 over the fixed Pooler namespace, the
  authenticated Pool and API key ids, and the raw key) so consecutive HTTP turns
  of one conversation reach the replica that holds the warm prompt cache, while
  two API keys or Pools that send the same key never share a provider session.
  The client's own continuity headers stay local.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Repo

  @cache_key "fixture-conversation-cache-key"
  @other_cache_key "fixture-other-conversation-cache-key"
  @shared_generic_cache_key "default"

  describe "POST /v1/responses" do
    test "sends the same synthesized session-id for every request with the same prompt_cache_key",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      setup = gateway_setup(upstream)
      expected = session_id(setup, @cache_key)
      other = session_id(setup, @other_cache_key)
      assert is_binary(expected) and is_binary(other)
      assert expected != other

      # provenance: synthetic_adversarial (invented completed replies; the session-id header is the claim)
      scenario =
        FakeUpstream.strict_sequence([
          synthesized_session_expectation(expected, "resp_cache_session_1"),
          synthesized_session_expectation(expected, "resp_cache_session_2"),
          synthesized_session_expectation(other, "resp_cache_session_3")
        ])

      FakeUpstream.set_mode(upstream, scenario)

      {responses, logs} =
        with_log(fn ->
          first =
            conn
            |> auth(setup)
            # A client-sent session-id stays local on /v1: the synthesized
            # header is the only one that goes upstream.
            |> put_req_header("session-id", "client-session-id-fixture")
            |> put_req_header("x-session-id", "client-x-session-id-fixture")
            |> post("/v1/responses", responses_payload(setup, @cache_key, "first turn"))

          second =
            build_conn()
            |> auth(setup)
            |> post("/v1/responses", responses_payload(setup, @cache_key, "second turn"))

          third =
            build_conn()
            |> auth(setup)
            |> post("/v1/responses", responses_payload(setup, @other_cache_key, "other"))

          [first, second, third]
        end)

      assert [
               %{"id" => "resp_cache_session_1"},
               %{"id" => "resp_cache_session_2"},
               %{"id" => "resp_cache_session_3"}
             ] = Enum.map(responses, &json_response(&1, 200))

      FakeUpstream.verify!(upstream)
      assert_session_id_absent_from_evidence!(expected, responses, logs)
      assert_session_id_absent_from_evidence!(other, responses, logs)
    end

    test "never shares a synthesized session-id across API keys or Pools that send the same prompt_cache_key",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      tenant = gateway_setup(upstream)
      same_pool_other_key = active_api_key_fixture(tenant.pool)
      other_pool_tenant = gateway_setup(upstream)

      assert same_pool_other_key.pool.id == tenant.pool.id
      assert same_pool_other_key.api_key.id != tenant.api_key.id
      assert other_pool_tenant.pool.id != tenant.pool.id

      tenant_session = session_id(tenant, @shared_generic_cache_key)
      same_pool_other_key_session = session_id(same_pool_other_key, @shared_generic_cache_key)
      other_pool_session = session_id(other_pool_tenant, @shared_generic_cache_key)
      sessions = [tenant_session, same_pool_other_key_session, other_pool_session]

      assert Enum.all?(sessions, &is_binary/1)
      assert Enum.uniq(sessions) == sessions

      # provenance: synthetic_adversarial (invented completed replies; the per-tenant session-id header is the claim)
      scenario =
        FakeUpstream.strict_sequence([
          synthesized_session_expectation(tenant_session, "resp_tenant_session_1"),
          synthesized_session_expectation(same_pool_other_key_session, "resp_tenant_session_2"),
          synthesized_session_expectation(other_pool_session, "resp_tenant_session_3"),
          synthesized_session_expectation(tenant_session, "resp_tenant_session_4")
        ])

      FakeUpstream.set_mode(upstream, scenario)

      {responses, logs} =
        with_log(fn ->
          first =
            conn
            |> auth(tenant)
            |> post(
              "/v1/responses",
              responses_payload(tenant, @shared_generic_cache_key, "tenant turn")
            )

          # Same Pool (and so the same upstream account), different API key.
          second =
            build_conn()
            |> auth(same_pool_other_key)
            |> post(
              "/v1/responses",
              responses_payload(tenant, @shared_generic_cache_key, "same pool other key turn")
            )

          third =
            build_conn()
            |> auth(other_pool_tenant)
            |> post(
              "/v1/responses",
              responses_payload(other_pool_tenant, @shared_generic_cache_key, "other pool turn")
            )

          # The first tenant keeps its own session after the others interleave.
          fourth =
            build_conn()
            |> auth(tenant)
            |> post(
              "/v1/responses",
              responses_payload(tenant, @shared_generic_cache_key, "tenant second turn")
            )

          [first, second, third, fourth]
        end)

      assert [
               %{"id" => "resp_tenant_session_1"},
               %{"id" => "resp_tenant_session_2"},
               %{"id" => "resp_tenant_session_3"},
               %{"id" => "resp_tenant_session_4"}
             ] = Enum.map(responses, &json_response(&1, 200))

      FakeUpstream.verify!(upstream)

      for session <- sessions do
        assert_session_id_absent_from_evidence!(session, responses, logs)
      end
    end

    test "sends no session-id without a usable prompt_cache_key", %{conn: conn} do
      upstream =
        start_upstream(
          # provenance: synthetic_adversarial (invented completed replies; header absence is the claim)
          FakeUpstream.strict_sequence([
            no_session_expectation("resp_no_cache_key"),
            no_session_expectation("resp_overlong_cache_key")
          ])
        )

      setup = gateway_setup(upstream)

      without_key =
        conn
        |> auth(setup)
        |> put_req_header("session-id", "client-session-id-fixture")
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "no cache key"
        })

      overlong =
        build_conn()
        |> auth(setup)
        |> post(
          "/v1/responses",
          responses_payload(setup, String.duplicate("k", 513), "overlong cache key")
        )

      assert %{"id" => "resp_no_cache_key"} = json_response(without_key, 200)
      assert %{"id" => "resp_overlong_cache_key"} = json_response(overlong, 200)
      FakeUpstream.verify!(upstream)
    end
  end

  describe "POST /v1/chat/completions" do
    test "sends the same synthesized session-id for every request with the same prompt_cache_key",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      setup = gateway_setup(upstream)
      expected = session_id(setup, @cache_key)
      other = session_id(setup, @other_cache_key)
      assert is_binary(expected) and is_binary(other)
      assert expected != other

      # provenance: synthetic_adversarial (invented completed replies; the session-id header is the claim)
      scenario =
        FakeUpstream.strict_sequence([
          synthesized_session_expectation(expected, "resp_chat_cache_session_1"),
          synthesized_session_expectation(expected, "resp_chat_cache_session_2"),
          synthesized_session_expectation(other, "resp_chat_cache_session_3"),
          no_session_expectation("resp_chat_no_cache_key")
        ])

      FakeUpstream.set_mode(upstream, scenario)

      {responses, logs} =
        with_log(fn ->
          first =
            conn
            |> auth(setup)
            |> put_req_header("session-id", "client-session-id-fixture")
            |> put_req_header("x-session-id", "client-x-session-id-fixture")
            |> post("/v1/chat/completions", chat_payload(setup, @cache_key, "first turn"))

          second =
            build_conn()
            |> auth(setup)
            |> post("/v1/chat/completions", chat_payload(setup, @cache_key, "second turn"))

          third =
            build_conn()
            |> auth(setup)
            |> post("/v1/chat/completions", chat_payload(setup, @other_cache_key, "other"))

          fourth =
            build_conn()
            |> auth(setup)
            |> post("/v1/chat/completions", chat_payload(setup, nil, "no cache key"))

          [first, second, third, fourth]
        end)

      assert Enum.all?(
               responses,
               &match?(%{"object" => "chat.completion"}, json_response(&1, 200))
             )

      FakeUpstream.verify!(upstream)
      assert_session_id_absent_from_evidence!(expected, responses, logs)
      assert_session_id_absent_from_evidence!(other, responses, logs)
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

  defp synthesized_session_expectation(session_id, response_id) do
    FakeUpstream.expect_request(
      method: "POST",
      path: "/backend-api/codex/responses",
      headers: [
        required: [{"session-id", session_id}],
        forbidden: ["x-session-id", "x-session-affinity", "thread-id"]
      ],
      json: [valid: true, required: ["prompt_cache_key"]],
      respond: completed_response(response_id)
    )
  end

  defp no_session_expectation(response_id) do
    FakeUpstream.expect_request(
      method: "POST",
      path: "/backend-api/codex/responses",
      headers: [forbidden: ["session-id", "x-session-id", "x-session-affinity"]],
      json: [valid: true],
      respond: completed_response(response_id)
    )
  end

  defp completed_response(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
         }
       }}
    ])
  end

  defp responses_payload(setup, cache_key, text) do
    %{
      "model" => setup.model.exposed_model_id,
      "prompt_cache_key" => cache_key,
      "input" => text,
      "store" => false
    }
  end

  defp chat_payload(setup, cache_key, text) do
    %{
      "model" => setup.model.exposed_model_id,
      "messages" => [%{"role" => "user", "content" => text}]
    }
    |> maybe_put_cache_key(cache_key)
  end

  defp maybe_put_cache_key(payload, nil), do: payload
  defp maybe_put_cache_key(payload, key), do: Map.put(payload, "prompt_cache_key", key)

  # The synthesized value derives from a client-chosen key, so it is treated
  # like the key itself: never in accounting rows, logs, or public responses.
  defp assert_session_id_absent_from_evidence!(session_id, responses, logs) do
    refute logs =~ session_id

    for response <- responses do
      refute response.resp_body =~ session_id
    end

    refute inspect(Repo.all(Request), limit: :infinity, printable_limit: :infinity) =~
             session_id

    refute inspect(Repo.all(Attempt), limit: :infinity, printable_limit: :infinity) =~
             session_id
  end
end
