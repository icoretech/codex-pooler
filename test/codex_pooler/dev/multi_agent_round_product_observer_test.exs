defmodule CodexPooler.Dev.MultiAgentRoundProductObserverTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias CodexPooler.Dev.MultiAgentRoundProductObserver
  alias CodexPooler.Dev.MultiAgentRoundProductObserver.Plug, as: ObserverPlug

  @event [:codex_pooler, :gateway, :multi_agent_round, :product_stage]

  setup do
    on_exit(fn -> MultiAgentRoundProductObserver.disarm() end)
    :ok
  end

  test "correlates bounded upstream and delivered facts without retaining raw content" do
    :ok = MultiAgentRoundProductObserver.arm()

    emit(:provider_to_pooler, "response.output_text.delta")
    emit(:pooler_to_codex, "response.output_text.delta")
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    emit(:pooler_to_codex, "response.completed", response_fingerprint: "a1b2c3d4e5f6")

    assert %{
             "request-1" => %{
               "clientRequestId" => "client-1",
               "requestId" => "request-1",
               "attemptId" => "attempt-1",
               "route" => "backend_websocket",
               "mode" => "full",
               "providerDeltaCount" => 1,
               "downstreamDeltaCount" => 1,
               "responses" => [
                 %{
                   "downstreamStatus" => "delivered",
                   "providerStatus" => "completed",
                   "responseFingerprint" => "a1b2c3d4e5f6"
                 }
               ]
             }
           } = MultiAgentRoundProductObserver.captures()

    served = conn(:get, "/") |> ObserverPlug.call([])
    assert served.status == 200

    assert Plug.Conn.get_resp_header(served, "x-multi-agent-round-product-observer") == [
             "pooler-product-stage-v1"
           ]

    refute served.resp_body =~ "forbidden prompt"
    refute served.resp_body =~ "secret-token"
  end

  test "keeps terminal directions scoped to their response fingerprints" do
    :ok = MultiAgentRoundProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    emit(:pooler_to_codex, "response.completed", response_fingerprint: "f6e5d4c3b2a1")

    assert %{"request-1" => entry} = MultiAgentRoundProductObserver.captures()

    assert entry["responses"] == [
             %{"providerStatus" => "completed", "responseFingerprint" => "a1b2c3d4e5f6"},
             %{"downstreamStatus" => "delivered", "responseFingerprint" => "f6e5d4c3b2a1"}
           ]

    :ok = MultiAgentRoundProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    assert %{"request-1" => unmatched} = MultiAgentRoundProductObserver.captures()

    assert unmatched["responses"] == [
             %{"providerStatus" => "completed", "responseFingerprint" => "a1b2c3d4e5f6"}
           ]
  end

  test "poisons a terminal fingerprint joined across different attempts" do
    :ok = MultiAgentRoundProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")

    emit(:pooler_to_codex, "response.completed",
      attempt_id: "attempt-2",
      response_fingerprint: "a1b2c3d4e5f6"
    )

    assert %{"request-1" => crossed} = MultiAgentRoundProductObserver.captures()
    assert crossed["attemptId"] == nil

    assert crossed["responses"] == [
             %{
               "downstreamStatus" => "delivered",
               "providerStatus" => "completed",
               "responseFingerprint" => "a1b2c3d4e5f6"
             }
           ]
  end

  test "retains every terminal response of one gateway request" do
    :ok = MultiAgentRoundProductObserver.arm()

    for response_fingerprint <- ["a1b2c3d4e5f6", "f6e5d4c3b2a1"] do
      emit(:provider_to_pooler, "response.completed", response_fingerprint: response_fingerprint)
      emit(:pooler_to_codex, "response.completed", response_fingerprint: response_fingerprint)
    end

    assert %{"request-1" => entry} = MultiAgentRoundProductObserver.captures()

    assert entry["responses"] == [
             %{
               "downstreamStatus" => "delivered",
               "providerStatus" => "completed",
               "responseFingerprint" => "a1b2c3d4e5f6"
             },
             %{
               "downstreamStatus" => "delivered",
               "providerStatus" => "completed",
               "responseFingerprint" => "f6e5d4c3b2a1"
             }
           ]
  end

  test "records Pooler-generated request identity when the client sent no x-request-id" do
    :ok = MultiAgentRoundProductObserver.arm()

    emit(:provider_to_pooler, "response.completed",
      client_request_id: nil,
      response_fingerprint: "a1b2c3d4e5f6"
    )

    assert %{
             "request-1" => %{
               "clientRequestId" => nil,
               "requestId" => "request-1",
               "attemptId" => "attempt-1"
             }
           } = MultiAgentRoundProductObserver.captures()
  end

  test "reports bounded accepted and rejected observation counts after disarm" do
    :ok = MultiAgentRoundProductObserver.arm()

    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")

    :telemetry.execute(@event, %{count: 1}, %{
      request_id: "request-1",
      client_request_id: "client-1",
      attempt_id: "attempt-1",
      direction: :provider_to_pooler,
      event_type: "response.completed",
      response_fingerprint: "not-a-fingerprint",
      route: "backend_websocket",
      mode: "full"
    })

    assert %{
             "eventReceipts" => 2,
             "acceptedObservations" => 1,
             "rejectedObservations" => 1
           } = MultiAgentRoundProductObserver.status()

    :ok = MultiAgentRoundProductObserver.disarm()

    assert %{
             "armed" => false,
             "captureEntries" => 0,
             "eventReceipts" => 2,
             "acceptedObservations" => 1,
             "rejectedObservations" => 1
           } = MultiAgentRoundProductObserver.status()
  end

  test "retains every request of a real multi-turn round and still bounds the window" do
    :ok = MultiAgentRoundProductObserver.arm()

    # The shape of the 2026-08-12 round: two Pooler lanes, each a root thread
    # and a child thread, every thread taking several turns.
    round_requests = for index <- 1..14, do: "round-request-#{index}"

    for request_id <- round_requests do
      emit(:provider_to_pooler, "response.completed",
        request_id: request_id,
        response_fingerprint: "a1b2c3d4e5f6"
      )
    end

    captures = MultiAgentRoundProductObserver.captures()
    assert map_size(captures) == 14
    assert Enum.all?(round_requests, &Map.has_key?(captures, &1))

    for index <- 15..80 do
      emit(:provider_to_pooler, "response.completed",
        request_id: "overflow-request-#{index}",
        response_fingerprint: "a1b2c3d4e5f6"
      )
    end

    bounded = MultiAgentRoundProductObserver.captures()
    assert map_size(bounded) == 64
    # The window drops arrivals it cannot hold; it never evicts what it already
    # correlated, so a consumer sees a truthful prefix instead of a shuffled one.
    assert Enum.all?(round_requests, &Map.has_key?(bounded, &1))

    emit(:pooler_to_codex, "response.completed",
      request_id: "round-request-1",
      response_fingerprint: "a1b2c3d4e5f6"
    )

    assert bounded |> Map.fetch!("round-request-1") |> Map.get("responses") == [
             %{"providerStatus" => "completed", "responseFingerprint" => "a1b2c3d4e5f6"}
           ]

    assert MultiAgentRoundProductObserver.captures()["round-request-1"]["responses"] == [
             %{
               "downstreamStatus" => "delivered",
               "providerStatus" => "completed",
               "responseFingerprint" => "a1b2c3d4e5f6"
             }
           ]
  end

  test "is disabled by default and disarm clears the store" do
    refute MultiAgentRoundProductObserver.armed?()
    emit(:provider_to_pooler, "response.output_text.delta")
    assert MultiAgentRoundProductObserver.captures() == %{}

    :ok = MultiAgentRoundProductObserver.arm()
    emit(:provider_to_pooler, "response.output_text.delta")
    assert map_size(MultiAgentRoundProductObserver.captures()) == 1
    :ok = MultiAgentRoundProductObserver.disarm()
    assert MultiAgentRoundProductObserver.captures() == %{}
  end

  defp emit(direction, event_type, opts \\ []) do
    :telemetry.execute(@event, %{count: 1}, %{
      request_id: Keyword.get(opts, :request_id, "request-1"),
      client_request_id: Keyword.get(opts, :client_request_id, "client-1"),
      attempt_id: Keyword.get(opts, :attempt_id, "attempt-1"),
      direction: direction,
      event_type: event_type,
      response_fingerprint: Keyword.get(opts, :response_fingerprint),
      route: "backend_websocket",
      mode: "full"
    })
  end
end
