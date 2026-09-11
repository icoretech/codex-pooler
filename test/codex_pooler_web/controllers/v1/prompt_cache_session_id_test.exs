defmodule CodexPoolerWeb.V1.PromptCacheSessionIdTest do
  @moduledoc """
  Public `/v1` requests that carry `prompt_cache_key` send the provider a
  Pooler-derived `session-id` (UUID v5 over the fixed Pooler namespace and the
  raw key) so consecutive HTTP turns of one conversation reach the replica that
  holds the warm prompt cache. The client's own continuity headers stay local.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Repo

  @cache_key "fixture-conversation-cache-key"
  @other_cache_key "fixture-other-conversation-cache-key"

  describe "POST /v1/responses" do
    test "sends the same synthesized session-id for every request with the same prompt_cache_key",
         %{conn: conn} do
      expected = TransportEnvelope.prompt_cache_session_id(@cache_key)
      other = TransportEnvelope.prompt_cache_session_id(@other_cache_key)
      assert expected != other

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            synthesized_session_expectation(expected, "resp_cache_session_1"),
            synthesized_session_expectation(expected, "resp_cache_session_2"),
            synthesized_session_expectation(other, "resp_cache_session_3")
          ])
        )

      setup = gateway_setup(upstream)

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

    test "sends no session-id without a usable prompt_cache_key", %{conn: conn} do
      upstream =
        start_upstream(
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
      expected = TransportEnvelope.prompt_cache_session_id(@cache_key)
      other = TransportEnvelope.prompt_cache_session_id(@other_cache_key)

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            synthesized_session_expectation(expected, "resp_chat_cache_session_1"),
            synthesized_session_expectation(expected, "resp_chat_cache_session_2"),
            synthesized_session_expectation(other, "resp_chat_cache_session_3"),
            no_session_expectation("resp_chat_no_cache_key")
          ])
        )

      setup = gateway_setup(upstream)

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
