defmodule CodexPooler.Gateway.Persistence.HttpOwnerLeaseTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexTurn,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Runtime.HttpOwnerLease

  setup do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    auth = %{pool: pool, api_key: api_key}

    opts =
      RequestOptions.from_conn_metadata(
        %{session_key: Ecto.UUID.generate(), bridge_owner_lease_ttl_seconds: 1},
        "/backend-api/codex/responses",
        %{}
      )

    {:ok, session} = SessionContinuity.start_codex_session(auth, opts)
    opts = RequestOptions.put_continuity(opts, codex_session: session)
    %{auth: auth, session: session, opts: opts}
  end

  test "HTTP completion renews both deadlines and next same-key turn retains its session and assignment",
       ctx do
    %{assignment: assignment} = active_upstream_assignment_fixture(ctx.auth.pool)
    opts = RequestOptions.put_file_bridge(ctx.opts, pool_upstream_assignment_id: assignment.id)
    set_expiry(ctx.session, DateTime.add(DateTime.utc_now(), 200, :millisecond))

    assert :ok = SessionContinuity.register_codex_session_continuity(ctx.session, %{}, %{}, opts)
    renewed = Repo.reload!(ctx.session)
    assert renewed.owner_lease_expires_at == lease(ctx.session).expires_at
    Process.sleep(250)
    assert {:ok, attached} = SessionContinuity.start_codex_session(ctx.auth, ctx.opts)
    assert attached.id == ctx.session.id
    assert attached.pool_upstream_assignment_id == assignment.id
  end

  test "expired completion cannot resurrect either deadline or register aliases", ctx do
    set_expiry(ctx.session, DateTime.add(DateTime.utc_now(), -1, :second))
    before = Repo.reload!(ctx.session)
    before_lease = lease(ctx.session)

    assert {:error, :owner_unavailable} =
             SessionContinuity.register_codex_session_continuity(
               ctx.session,
               %{},
               %{"id" => "late-response"},
               ctx.opts
             )

    assert Repo.reload!(ctx.session) == before
    assert lease(ctx.session) == before_lease

    refute Repo.exists?(
             from a in BridgeSessionAlias, where: a.alias_kind == "previous_response_id"
           )
  end

  test "old completion cannot bind or renew the replacement owner's session", ctx do
    %{assignment: assignment} = active_upstream_assignment_fixture(ctx.auth.pool)
    opts = RequestOptions.put_file_bridge(ctx.opts, pool_upstream_assignment_id: assignment.id)

    {:ok, replacement} =
      SessionContinuity.replace_unavailable_owner_lease(
        ctx.session,
        RequestOptions.put_continuity(ctx.opts, owner_instance_id: "replacement")
      )

    before_lease = lease(ctx.session)

    assert {:error, :stale_owner} =
             SessionContinuity.register_codex_session_continuity(
               ctx.session,
               %{},
               %{"id" => "old-response"},
               opts
             )

    assert Repo.reload!(ctx.session) == replacement
    assert lease(ctx.session) == before_lease

    refute Repo.exists?(
             from a in BridgeSessionAlias, where: a.alias_kind == "previous_response_id"
           )
  end

  test "silent dispatch outlives the TTL and active attach retains ownership", ctx do
    result =
      HttpOwnerLease.run(ctx.opts, fn ->
        Process.sleep(1_250)

        assert :ok =
                 SessionContinuity.validate_owner_token(
                   ctx.session,
                   ctx.session.owner_lease_token
                 )

        assert {:ok, attached} = SessionContinuity.start_codex_session(ctx.auth, ctx.opts)
        assert attached.id == ctx.session.id
        assert attached.owner_lease_token == ctx.session.owner_lease_token
        {:ok, :complete}
      end)

    assert result == {:ok, :complete}
    assert_eventually_expired(ctx.session)
  end

  test "heartbeat spans deferred SSE silence and stops after cancellation", ctx do
    assert {:ok, %{stream: stream}} =
             HttpOwnerLease.run(ctx.opts, fn ->
               Process.sleep(700)

               {:ok,
                %{
                  stream: fn _conn ->
                    Process.sleep(700)

                    assert :ok =
                             SessionContinuity.validate_owner_token(
                               ctx.session,
                               ctx.session.owner_lease_token
                             )

                    {:error, :client_disconnected}
                  end
                }}
             end)

    Process.sleep(400)
    assert {:error, :client_disconnected} = stream.(:conn)
    assert_eventually_expired(ctx.session)
  end

  test "dispatch and stream exceptions stop their heartbeat", ctx do
    assert_raise RuntimeError, "dispatch failed", fn ->
      HttpOwnerLease.run(ctx.opts, fn -> raise "dispatch failed" end)
    end

    assert_eventually_expired(ctx.session)

    {:ok, session} = SessionContinuity.start_codex_session(ctx.auth, ctx.opts)
    opts = RequestOptions.put_continuity(ctx.opts, codex_session: session)

    {:ok, %{stream: stream}} =
      HttpOwnerLease.run(opts, fn ->
        {:ok, %{stream: fn _conn -> raise "stream failed" end}}
      end)

    assert_raise RuntimeError, "stream failed", fn -> stream.(:conn) end
    assert_eventually_expired(session)
  end

  test "request process death stops renewal even if a stream was never consumed", ctx do
    parent = self()

    pid =
      spawn(fn ->
        HttpOwnerLease.run(ctx.opts, fn ->
          {:ok, %{stream: fn _conn -> :ok end}}
        end)

        send(parent, :stream_abandoned)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :stream_abandoned
    Process.exit(pid, :kill)
    assert_eventually_expired(ctx.session)
  end

  test "heartbeat does not renew or acquire a new token after takeover", ctx do
    {:ok, %{stream: stream}} =
      HttpOwnerLease.run(ctx.opts, fn ->
        {:ok, %{stream: fn _conn -> :ok end}}
      end)

    {:ok, replacement} =
      SessionContinuity.replace_unavailable_owner_lease(
        ctx.session,
        RequestOptions.put_continuity(ctx.opts, owner_instance_id: "replacement")
      )

    before_lease = lease(ctx.session)
    Process.sleep(450)
    assert Repo.reload!(ctx.session) == replacement
    assert lease(ctx.session) == before_lease
    assert :ok = stream.(:conn)
  end

  test "stale HTTP turn start cannot adopt a replacement token", ctx do
    {:ok, _replacement} = SessionContinuity.replace_unavailable_owner_lease(ctx.session, ctx.opts)
    request = request_fixture(ctx.auth, %{status: "in_progress", completed_at: nil})

    assert {:error, :stale_owner} =
             SessionContinuity.start_codex_turn(ctx.session, request, ctx.opts)

    refute Repo.exists?(CodexTurn)
  end

  test "old HTTP attempt settlement cannot overwrite a replacement assignment", ctx do
    %{assignment: assignment} = active_upstream_assignment_fixture(ctx.auth.pool)
    request = request_fixture(ctx.auth, %{status: "in_progress", completed_at: nil})
    {:ok, turn} = SessionContinuity.start_codex_turn(ctx.session, request, ctx.opts)
    attempt = attempt_fixture(request, assignment)
    {:ok, replacement} = SessionContinuity.replace_unavailable_owner_lease(ctx.session, ctx.opts)
    before_lease = lease(ctx.session)
    result = {:ok, %{request: request, attempt: attempt}}
    assert ^result = SessionContinuity.complete_codex_turn(result, "succeeded", nil)
    assert Repo.reload!(turn).status == "succeeded"
    assert Repo.reload!(ctx.session) == replacement
    assert lease(ctx.session) == before_lease
    refute inspect(Repo.reload!(request).request_metadata) =~ ctx.session.owner_lease_token
  end

  test "current HTTP attempt binds its account and preserves newer request metadata", ctx do
    %{assignment: assignment} = active_upstream_assignment_fixture(ctx.auth.pool)
    request = request_fixture(ctx.auth, %{status: "in_progress", completed_at: nil})

    request
    |> Ecto.Changeset.change(request_metadata: %{"concurrent_key" => "retained"})
    |> Repo.update!()

    {:ok, _turn} = SessionContinuity.start_codex_turn(ctx.session, request, ctx.opts)
    attempt = attempt_fixture(request, assignment)
    result = {:ok, %{request: request, attempt: attempt}}
    assert ^result = SessionContinuity.complete_codex_turn(result, "succeeded", nil)
    assert Repo.reload!(ctx.session).pool_upstream_assignment_id == assignment.id
    assert lease(ctx.session).pool_upstream_assignment_id == assignment.id
    assert Repo.reload!(request).request_metadata["concurrent_key"] == "retained"
  end

  test "explicit HTTP snapshot cannot adopt a replacement owner during attach", ctx do
    {:ok, replacement} = SessionContinuity.replace_unavailable_owner_lease(ctx.session, ctx.opts)

    assert {:error, %{code: "stale_owner"}} =
             CodexPooler.Gateway.Routing.SessionContinuity.attach_codex_session(
               ctx.auth,
               %{},
               ctx.opts
             )

    assert Repo.reload!(ctx.session) == replacement
  end

  test "late consumption preserves native delivery without resurrecting abandoned ownership",
       ctx do
    {:ok, %{stream: stream}} =
      HttpOwnerLease.run(ctx.opts, fn ->
        {:ok,
         %{
           stream: fn _conn ->
             assert {:error, :owner_unavailable} =
                      SessionContinuity.register_codex_session_continuity(
                        ctx.session,
                        %{},
                        %{},
                        ctx.opts
                      )

             {:ok, :already_generated_response}
           end
         }}
      end)

    Process.sleep(1_150)
    assert_eventually_expired(ctx.session)
    before = Repo.reload!(ctx.session)
    assert {:ok, :already_generated_response} = stream.(:conn)
    assert Repo.reload!(ctx.session) == before
  end

  defp lease(session),
    do: Repo.get_by!(BridgeOwnerLease, codex_session_id: session.id, status: "active")

  defp set_expiry(session, expiry) do
    expiry = DateTime.truncate(expiry, :microsecond)
    session |> Ecto.Changeset.change(owner_lease_expires_at: expiry) |> Repo.update!()
    lease(session) |> Ecto.Changeset.change(expires_at: expiry) |> Repo.update!()
  end

  defp assert_eventually_expired(session) do
    before = Repo.reload!(session)
    Process.sleep(1_100)
    assert Repo.reload!(session) == before

    assert {:error, :owner_unavailable} =
             SessionContinuity.validate_owner_token(session, session.owner_lease_token)
  end
end
