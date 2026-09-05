defmodule CodexPooler.Gateway.Runtime.ReliabilityComposedPostgresTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.{Access, Accounting, FakeUpstream, Repo, Upstreams}
  alias CodexPooler.Accounting.{Attempt, Request, RequestClientRetryLink}
  alias CodexPooler.ReliabilityComposedFixture, as: Fixture
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  test "composed cleanup removes its pricing while preserving another fixture" do
    {:ok, fake} = FakeUpstream.start_link({:json, 200, %{"code" => "reset"}})

    Sandbox.unboxed_run(Repo, fn ->
      fixture = Fixture.fixture!(fake)
      other = Fixture.fixture!(fake)
      on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> Fixture.cleanup!(other) end) end)
      Fixture.cleanup!(fixture)
      refute Repo.get(CodexPooler.Catalog.PricingSnapshot, fixture.pricing.id)
      assert Repo.get!(CodexPooler.Catalog.PricingSnapshot, other.pricing.id)
      assert Repo.get!(UpstreamIdentity, other.identity.id)
      Fixture.cleanup!(fixture)
    end)
  end

  test "capacity, credential lifecycle and retry authorization converge after their shared writer commits" do
    {:ok, fake} = FakeUpstream.start_link({:json, 200, %{"code" => "reset"}})
    setup = Sandbox.unboxed_run(Repo, fn -> Fixture.fixture!(fake) end)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> Fixture.cleanup!(setup) end) end)
    predecessor = Sandbox.unboxed_run(Repo, fn -> Fixture.predecessor!(setup) end)
    old_credential_epoch = setup.sibling.metadata["credential_epoch"]
    parent = self()
    barrier = make_ref()

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            # The ordinary operator services own their row locks. Both operations
            # precede the claimers; neither claimer holds a row needed by this writer.
            {:ok, paused_key} = Access.pause_api_key(setup.scope, setup.api_key)
            {:ok, _} = Access.resume_api_key(setup.scope, paused_key)
            {:ok, _} = Upstreams.pause_account_for_scope(setup.scope, setup.sibling, %{})
            {:ok, _} = Upstreams.reactivate_account_for_scope(setup.scope, setup.sibling.id, %{})
            Fixture.put_quota!(Repo.get!(UpstreamIdentity, setup.sibling.id), "75")
            send(parent, {barrier, :writer, backend_pid!()})

            receive do
              {^barrier, :release} -> :released
            after
              @detection_budget -> raise "composed writer release was not delivered"
            end
          end)
        end)
      end)

    assert_receive {^barrier, :writer, writer_backend}, @detection_budget

    capacity =
      claimer(parent, barrier, :capacity, fn ->
        SavedResetRedemption.redeem(setup.assignment,
          trigger_kind: "gateway_auto",
          gateway_auto_context: setup.context
        )
      end)

    retry = claimer(parent, barrier, :retry, fn -> Fixture.retry(setup, predecessor) end)
    assert_receive {^barrier, :capacity, capacity_backend}, @detection_budget
    assert_receive {^barrier, :retry, retry_backend}, @detection_budget
    assert length(Enum.uniq([writer_backend, capacity_backend, retry_backend])) == 3
    await_blocked!(capacity_backend, writer_backend)
    await_blocked!(retry_backend, writer_backend)
    send(writer.pid, {barrier, :release})
    assert {:ok, :released} = Task.await(writer, @detection_budget)

    assert {:ok, %{applied?: false, code: "gateway_auto_sibling_usable_capacity"}} =
             Task.await(capacity, @detection_budget)

    assert {:error, :authorization_changed} = Task.await(retry, @detection_budget)
    assert FakeUpstream.requests(fake) == []

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(Request, predecessor.predecessor.id) == predecessor.predecessor

      assert Repo.aggregate(
               from(l in RequestClientRetryLink,
                 where: l.predecessor_request_id == ^predecessor.predecessor.id
               ),
               :count
             ) == 0

      sibling = Repo.get!(UpstreamIdentity, setup.sibling.id)
      assert sibling.metadata["credential_epoch"] == old_credential_epoch + 2

      assert get_in(sibling.metadata, ["token_refresh", "access_token_expiry", "credential_epoch"]) ==
               old_credential_epoch + 2

      assert %{state: :unknown} =
               TokenRefreshMetadata.project_access_token_expiry(sibling.metadata)

      assert Upstreams.Secrets.secret_status(sibling) == :present

      assert AutoEligibility.locked_sibling_usable_capacity?(
               sibling,
               setup.context,
               DateTime.utc_now()
             )

      Fixture.put_quota!(sibling, "100")

      refute AutoEligibility.locked_sibling_usable_capacity?(
               sibling,
               setup.context,
               DateTime.utc_now()
             )

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      current = %{setup | auth: auth, api_key: auth.api_key}
      fresh = Fixture.predecessor!(current)
      assert {:ok, claim} = Fixture.retry(current, fresh)
      attrs = %{model: current.model, upstream_identity: current.identity}

      assert {:ok, %Attempt{attempt_number: 1, replay_generation: 0}} =
               Accounting.create_client_retry_dispatch_attempt(
                 claim.request,
                 current.assignment,
                 claim.dispatch_authority,
                 attrs
               )

      assert {:error, %{code: :client_retry_dispatch_claimed}} =
               Accounting.create_client_retry_dispatch_attempt(
                 claim.request,
                 current.assignment,
                 claim.dispatch_authority,
                 attrs
               )

      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
               1

      assert Repo.get!(Request, fresh.predecessor.id) == fresh.predecessor
    end)
  end

  defp claimer(parent, barrier, lane, action) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        send(parent, {barrier, lane, backend_pid!()})
        action.()
      end)
    end)
  end

  defp backend_pid! do
    [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    pid
  end

  defp await_blocked!(pid, writer) do
    deadline = System.monotonic_time(:millisecond) + @detection_budget
    await_blocked!(pid, writer, deadline)
  end

  defp await_blocked!(pid, writer, deadline) do
    rows =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [pid]
        ).rows
      end)

    if Enum.any?(rows, fn [blockers, state] -> state == "Lock" and writer in blockers end) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "composed claim did not block on writer"

      :erlang.yield()
      await_blocked!(pid, writer, deadline)
    end
  end
end
