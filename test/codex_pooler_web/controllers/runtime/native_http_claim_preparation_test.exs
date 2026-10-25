defmodule CodexPoolerWeb.Runtime.NativeHttpClaimPreparationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 2, register_unboxed_pool_cleanup!: 1, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.NativeHttpTurnIdentity
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true
  @claim_function {NativeHttpTurnIdentity, :request_claim, 2}
  @coordinator {CodexPooler.Gateway.Persistence.SessionContinuity.MailboxAdmissionLocks, :transaction, 3}

  @tag slow: "two real native HTTP requests carry 28 MiB of retained mailbox history"
  test "large native HTTP mailbox history derives one immutable claim per request", context do
    CodexPooler.DataCase.stop_sandbox(context.sandbox_owner, context.sandbox_settings_cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok = Sandbox.mode(Repo, :auto)
    CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()

    completed = %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_claim_preparation", "status" => "completed", "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}}}
    upstream = start_upstream(FakeUpstream.sse_stream([completed]))
    fixture = gateway_setup(upstream, model_metadata: %{"input_modalities" => ["text", "image"], "supported_input_modalities" => ["text", "image"]})
    register_unboxed_pool_cleanup!(fixture)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: fixture.pool.id, exposed_model_id: fixture.model.exposed_model_id, mode: "full", created_at: timestamp, updated_at: timestamp})
    port = start_public_endpoint!()
    thread = Ecto.UUID.generate()
    input = mailbox_input()

    Code.ensure_loaded!(NativeHttpTurnIdentity)
    trace = :trace.session_create(__MODULE__, self(), [])
    :trace.function(trace, @claim_function, [{:_, [], [{:return_trace}]}], [:local])
    :trace.function(trace, @coordinator, true, [:local])
    :trace.process(trace, :all, true, [:call, :arity, :monotonic_timestamp])

    try do
      for turn <- 1..2 do
        metadata = CodexPooler.JSON.encode!(%{"session_id" => thread, "thread_id" => thread, "turn_id" => "synthetic-#{turn}", "request_kind" => "turn", "agent_name" => "synthetic-worker", "workspaces" => [%{"root" => "/synthetic-workspace"}]})
        payload = %{"model" => fixture.model.exposed_model_id, "input" => input, "stream" => true, "store" => false, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
        response = Req.post!("http://127.0.0.1:#{port}/backend-api/codex/responses", body: CodexPooler.JSON.encode!(payload), headers: [{"authorization", fixture.authorization}, {"content-type", "application/json"}, {"x-codex-window-id", "#{thread}:0"}], retry: false, receive_timeout: 15_000)

        assert response.status == 200
        assert FakeUpstream.count(upstream) == turn
        delivered = :trace.delivered(trace, :all)
        assert_receive {:trace_delivered, :all, ^delivered}
        assert_prepared_before_checkout!(claim_events([]))
        request = Repo.one!(from r in Request, where: r.pool_id == ^fixture.pool.id, order_by: [desc: r.admitted_at], limit: 1)
        assert request.status == "succeeded"
        assert request.transport == "http_sse"
        assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
        assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id and t.status == "succeeded"), :count) == 1
        assert Repo.all(from l in LedgerEntry, where: l.request_id == ^request.id, order_by: l.entry_kind, select: l.entry_kind) == ["release", "reservation", "settlement"]
      end
    after
      :trace.session_destroy(trace)
    end
  end

  defp claim_events(events) do
    receive do
      {:trace_ts, pid, :call, function, timestamp} -> claim_events([{:call, pid, function, timestamp} | events])
      {:trace_ts, pid, :return_from, function, _claim, timestamp} -> claim_events([{:returned, pid, function, timestamp} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp assert_prepared_before_checkout!(events) do
    assert [{:call, caller, @claim_function, _started}] = Enum.filter(events, &match?({:call, _, @claim_function, _}, &1))
    assert [{:returned, ^caller, @claim_function, prepared_at}] = Enum.filter(events, &match?({:returned, _, @claim_function, _}, &1))
    coordinator_times = for {:call, ^caller, @coordinator, timestamp} <- events, do: timestamp
    assert coordinator_times != []
    assert prepared_at < Enum.min(coordinator_times)
  end

  defp mailbox_input do
    locator = "data:image/png;base64," <> String.duplicate("A", div(div(28 * 1024 * 1024, 57) + 3, 4) * 4)
    prefix = %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic startup"}] ++ List.duplicate(%{"type" => "input_image", "image_url" => locator}, 57)}
    output = for n <- 1..4, do: %{"type" => "message", "id" => "msg_synthetic_#{n}", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic completed output"}]}
    incoming = %{"type" => "agent_message", "author" => "synthetic-peer", "recipient" => "synthetic-worker", "content" => [%{"type" => "input_text", "text" => "synthetic mailbox delivery"}]}
    [prefix | output] ++ [incoming]
  end
end
