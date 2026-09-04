defmodule CodexPooler.Gateway.Runtime.Streaming.CollectorRateLimitTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.RequestReplayFixtures, only: [replay_fixture: 1, arm_input: 1]

  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.{CompactionResultCollector, OpenAIStreamCollector}
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @timeout 15_000

  for collector <- [:compaction, :openai], stale? <- [false, true] do
    test "#{collector} retains early quota through large multi-chunk SSE, stale=#{stale?}" do
      assert_collected_quota(unquote(collector), unquote(stale?))
    end
  end

  defp assert_collected_quota(collector, stale?) do
    fixture = replay_fixture(reservation?: true)
    context = context(fixture)
    parent = self()
    release = make_ref()
    handler = "collector-quota-#{System.unique_integer([:positive])}"

    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.barrier_sse_stream(events(collector),
          notify: parent,
          release_ref: release,
          barrier_after: 1
        )
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:source] == "account_quota_windows" and
               String.starts_with?(metadata.query, "INSERT") do
            send(parent, {handler, :quota_write})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        response = observed_response(upstream, parent, release)
        collect(collector, response, context)
      end)

    assert_receive {:fake_upstream_chunk_barrier, 1, server, ^release}, @timeout
    assert_receive {^release, :chunk_read}, @timeout
    refute_received {^handler, :quota_write}
    assert QuotaWindows.list_quota_windows(fixture.identity) == []
    if stale?, do: assert({:ok, _} = RequestReplay.arm(arm_input(fixture)))
    send(server, {:fake_upstream_release_chunk, release})
    assert {:ok, _} = Task.await(task, @timeout)
    assert FakeUpstream.count(upstream) == 1

    if stale? do
      assert QuotaWindows.list_quota_windows(fixture.identity) == []
      refute_received {^handler, :quota_write}
      assert Repo.reload!(fixture.request).status == "in_progress"
    else
      assert [window] = QuotaWindows.list_quota_windows(fixture.identity)
      assert window.source == "codex_rate_limit_event"
      assert Decimal.equal?(window.used_percent, Decimal.new(47))
      assert_receive {^handler, :quota_write}
      refute_received {^handler, :quota_write}
      assert Repo.reload!(fixture.request).status == "succeeded"
    end
  end

  test "pending quota survives oversized unrelated partial frames and retains bounded latest windows" do
    state =
      Enum.reduce(1..1_000, RateLimitObserver.event_state(), fn value, state ->
        {:ok, state} = RateLimitObserver.collect_events(sse(quota_event(rem(value, 100))), state)
        state
      end)

    assert :erlang.external_size(state) < 8_192

    {:ok, state} =
      RateLimitObserver.collect_events(
        "event: response.output_text.delta\ndata: " <> String.duplicate("x", 96_000),
        state
      )

    assert :erlang.external_size(state) < 8_192
    fixture = replay_fixture(reservation?: true)
    assert :ok = RateLimitObserver.commit_events(fixture.identity, state)
    assert [window] = QuotaWindows.list_quota_windows(fixture.identity)
    assert Decimal.equal?(window.used_percent, Decimal.new(0))
  end

  defp observed_response(upstream, parent, release) do
    response =
      Req.get!(FakeUpstream.url(upstream), into: :self, retry: false, receive_timeout: @timeout)

    parser = response.body.stream_fun

    observed_parser = fn ref, message ->
      parsed = parser.(ref, message)
      if match?({:ok, [data: _]}, parsed), do: send(parent, {release, :chunk_read})
      parsed
    end

    %{response | body: %{response.body | stream_fun: observed_parser}}
  end

  test "pending scopes are capped and the latest partial windows survive together" do
    state =
      Enum.reduce(1..100, RateLimitObserver.event_state(), fn scope, state ->
        event = Map.put(quota_event(12), "metered_limit_name", "sample-feature-#{scope}")
        {:ok, state} = RateLimitObserver.collect_events(sse(event), state)
        state
      end)

    assert length(state.pending_events) == 32
    assert :erlang.external_size(state) < 32 * 16_384 + 16_384

    {:ok, state} = RateLimitObserver.collect_events(sse(quota_event(13)), state)
    secondary = quota_event(14)

    secondary =
      put_in(secondary["rate_limits"], %{"secondary" => secondary["rate_limits"]["primary"]})

    {:ok, state} = RateLimitObserver.collect_events(sse(secondary), state)
    {:ok, state} = RateLimitObserver.collect_events(sse(quota_event(15)), state)

    {:ok, state} =
      RateLimitObserver.collect_events(
        sse(Map.put(quota_event(99), "extra", String.duplicate("x", 20_000))),
        state
      )

    assert length(state.pending_events) == 32
    fixture = replay_fixture(reservation?: true)
    assert :ok = RateLimitObserver.commit_events(fixture.identity, state)

    account =
      Enum.filter(QuotaWindows.list_quota_windows(fixture.identity), &(&1.quota_key == "account"))

    assert Enum.sort(Enum.map(account, &Decimal.to_integer(&1.used_percent))) == [14, 15]
  end

  defp context(fixture) do
    options = RequestOptions.for_websocket(%{})
    candidates = [{fixture.assignment, fixture.identity}]

    %SelectedCandidateContext{
      auth: fixture.auth,
      endpoint: fixture.request.endpoint,
      payload: %{},
      model: fixture.model,
      reserved: %{request: fixture.request},
      request_options: options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: fixture.auth,
          model: fixture.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: fixture.request}),
          request_options: options
        }),
      assignment: fixture.assignment,
      identity: fixture.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: options.transport.route_class,
      attempt: fixture.attempt,
      started: System.monotonic_time(:millisecond)
    }
  end

  defp collect(:compaction, response, context),
    do: CompactionResultCollector.collect(response, context, callbacks())

  defp collect(:openai, response, context),
    do: OpenAIStreamCollector.collect_response(response, context, callbacks())

  defp callbacks do
    %{register_continuity: fn _, _, _ -> :ok end, stream_result: fn _, _ -> :ok end}
  end

  defp events(collector) do
    middle =
      if collector == :compaction,
        do: [
          %{
            "type" => "response.output_item.done",
            "item" => %{"type" => "compaction", "encrypted_content" => "synthetic_ciphertext"}
          }
        ],
        else: []

    ([
       quota_event(47),
       %{"type" => "response.output_text.delta", "delta" => String.duplicate("x", 96_000)}
     ] ++
       middle ++
       [
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => "resp_sample",
             "status" => "completed",
             "output" => [],
             "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
           }
         }
       ])
    |> Enum.map(&{&1["type"], &1})
  end

  defp quota_event(used) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(DateTime.add(DateTime.utc_now(), 900, :second))
        }
      }
    }
  end

  defp sse(event), do: "event: codex.rate_limits\ndata: #{Jason.encode!(event)}\n\n"
end
