defmodule CodexPooler.Dev.Task14ProductObserverTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias CodexPooler.Dev.Task14ProductObserver
  alias CodexPooler.Dev.Task14ProductObserver.Plug, as: ObserverPlug

  @event [:codex_pooler, :gateway, :task14, :product_stage]

  setup do
    on_exit(fn -> Task14ProductObserver.disarm() end)
    :ok
  end

  test "correlates bounded upstream and delivered facts without retaining raw content" do
    :ok = Task14ProductObserver.arm()

    emit(:provider_to_pooler, "response.output_text.delta")
    emit(:pooler_to_codex, "response.output_text.delta")
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    emit(:pooler_to_codex, "response.completed", response_fingerprint: "a1b2c3d4e5f6")

    assert %{
             "request-1" => %{
               "clientRequestId" => "client-1",
               "requestId" => "request-1",
               "attemptId" => "attempt-1",
               "responseFingerprint" => "a1b2c3d4e5f6",
               "route" => "backend_websocket",
               "mode" => "full",
               "providerDeltaCount" => 1,
               "downstreamDeltaCount" => 1,
               "providerStatus" => "completed",
               "downstreamStatus" => "delivered"
             }
           } = Task14ProductObserver.captures()

    served = conn(:get, "/") |> ObserverPlug.call([])
    assert served.status == 200
    refute served.resp_body =~ "forbidden prompt"
    refute served.resp_body =~ "secret-token"
  end

  test "poisons mismatched response fingerprints and unmatched terminal directions" do
    :ok = Task14ProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    emit(:pooler_to_codex, "response.completed", response_fingerprint: "f6e5d4c3b2a1")

    assert %{"request-1" => entry} = Task14ProductObserver.captures()
    assert entry["responseFingerprint"] == nil
    assert entry["providerStatus"] == "completed"
    assert entry["downstreamStatus"] == "delivered"

    :ok = Task14ProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")
    assert %{"request-1" => unmatched} = Task14ProductObserver.captures()
    assert unmatched["providerStatus"] == "completed"
    refute Map.has_key?(unmatched, "downstreamStatus")
  end

  test "poisons a terminal fingerprint joined across different attempts" do
    :ok = Task14ProductObserver.arm()
    emit(:provider_to_pooler, "response.completed", response_fingerprint: "a1b2c3d4e5f6")

    emit(:pooler_to_codex, "response.completed",
      attempt_id: "attempt-2",
      response_fingerprint: "a1b2c3d4e5f6"
    )

    assert %{"request-1" => crossed} = Task14ProductObserver.captures()
    assert crossed["attemptId"] == nil
    assert crossed["responseFingerprint"] == "a1b2c3d4e5f6"
  end

  test "retains every request of a real multi-turn round and still bounds the window" do
    :ok = Task14ProductObserver.arm()

    # The shape of the 2026-08-12 round: two Pooler lanes, each a root thread
    # and a child thread, every thread taking several turns.
    round_requests = for index <- 1..14, do: "round-request-#{index}"

    for request_id <- round_requests do
      emit(:provider_to_pooler, "response.completed",
        request_id: request_id,
        response_fingerprint: "a1b2c3d4e5f6"
      )
    end

    captures = Task14ProductObserver.captures()
    assert map_size(captures) == 14
    assert Enum.all?(round_requests, &Map.has_key?(captures, &1))

    for index <- 15..80 do
      emit(:provider_to_pooler, "response.completed",
        request_id: "overflow-request-#{index}",
        response_fingerprint: "a1b2c3d4e5f6"
      )
    end

    bounded = Task14ProductObserver.captures()
    assert map_size(bounded) == 64
    # The window drops arrivals it cannot hold; it never evicts what it already
    # correlated, so a consumer sees a truthful prefix instead of a shuffled one.
    assert Enum.all?(round_requests, &Map.has_key?(bounded, &1))

    emit(:pooler_to_codex, "response.completed",
      request_id: "round-request-1",
      response_fingerprint: "a1b2c3d4e5f6"
    )

    assert bounded |> Map.fetch!("round-request-1") |> Map.get("downstreamStatus") == nil
    assert Task14ProductObserver.captures()["round-request-1"]["downstreamStatus"] == "delivered"
  end

  test "is disabled by default and disarm clears the store" do
    refute Task14ProductObserver.armed?()
    emit(:provider_to_pooler, "response.output_text.delta")
    assert Task14ProductObserver.captures() == %{}

    :ok = Task14ProductObserver.arm()
    emit(:provider_to_pooler, "response.output_text.delta")
    assert map_size(Task14ProductObserver.captures()) == 1
    :ok = Task14ProductObserver.disarm()
    assert Task14ProductObserver.captures() == %{}
  end

  defp emit(direction, event_type, opts \\ []) do
    :telemetry.execute(@event, %{count: 1}, %{
      request_id: Keyword.get(opts, :request_id, "request-1"),
      client_request_id: "client-1",
      attempt_id: Keyword.get(opts, :attempt_id, "attempt-1"),
      direction: direction,
      event_type: event_type,
      response_fingerprint: Keyword.get(opts, :response_fingerprint),
      route: "backend_websocket",
      mode: "full"
    })
  end
end
