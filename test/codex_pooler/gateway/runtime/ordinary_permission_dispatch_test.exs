defmodule CodexPooler.Gateway.Runtime.OrdinaryPermissionDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @endpoint_path "/backend-api/codex/responses"

  test "fresh permission keeps consecutive requests routable after percent-only response headers",
       %{conn: conn} do
    usage = usage_payload(:weekly_primary)
    {upstream, setup} = reconciled_setup(usage)
    reset_at = get_in(usage, ["rate_limit", "primary_window", "reset_at"])

    {:path_json, usage_routes} = routes(usage)

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       Map.put(
         usage_routes,
         @endpoint_path,
         FakeUpstream.json_response_with_headers(
           %{"id" => "resp_permission_headers", "object" => "response", "output" => []},
           [
             {"x-codex-secondary-used-percent", "100"},
             {"x-codex-secondary-window-minutes", "10080"},
             {"x-codex-secondary-reset-at", Integer.to_string(reset_at)}
           ]
         )
       )}
    )

    assert dispatch(conn, setup).status == 200
    assert generation_count(upstream) == 1
    identity = Repo.reload!(setup.identity)
    assert {:ok, %{state: :available}} = AccountAvailabilityStore.load(identity.metadata)
    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert generation_count(upstream) == 2
    assert Repo.aggregate(Attempt, :count) == 2

    FakeUpstream.set_mode(upstream, routes(denied_payload(:denied)))

    assert {:ok, _} =
             PoolReconciliation.refresh_quota_from_usage(
               Repo.reload!(setup.identity),
               setup.assignment
             )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 503
    assert generation_count(upstream) == 2
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "percent-only stream events preserve permission for the next dispatch" do
    usage = usage_payload(:weekly_primary)
    {upstream, setup} = reconciled_setup(usage)

    event = %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "secondary" => %{
          "used_percent" => 100,
          "window_minutes" => 10_080,
          "reset_at" => get_in(usage, ["rate_limit", "primary_window", "reset_at"])
        }
      }
    }

    state = RateLimitObserver.event_state()

    assert {:ok, state} =
             RateLimitObserver.collect_events(
               "data: " <> CodexPooler.JSON.encode!(event) <> "\n\n",
               state
             )

    assert :ok =
             RateLimitObserver.commit_events(
               Repo.reload!(setup.identity),
               state
             )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert generation_count(upstream) == 1
  end

  for shape <- [:weekly_primary, :five_hour_and_weekly] do
    test "full affirmative #{shape} usage at 100 percent reaches the provider" do
      {upstream, setup} = reconciled_setup(usage_payload(unquote(shape)))
      identity = Repo.reload!(setup.identity)
      assert {:ok, %{state: :available}} = AccountAvailabilityStore.load(identity.metadata)

      windows =
        Repo.all(from w in AccountQuotaWindow, where: w.upstream_identity_id == ^identity.id)

      assert windows != []
      assert Enum.all?(windows, &Decimal.equal?(&1.used_percent, Decimal.new(100)))

      assert {:ok, [{assignment, _identity}]} =
               CandidateEligibility.routable_candidates(setup.model)

      assert assignment.id == setup.assignment.id
      {auth, payload, options} = request_context(setup)

      assert {:ok, prepared} =
               PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model)

      snapshot = Map.fetch!(prepared.route_state.quota_snapshots, identity.id)
      assert snapshot.availability.state == :available

      for window <- snapshot.raw_windows do
        assert DateTime.compare(window.observed_at, snapshot.availability.observed_at) == :eq,
               inspect(%{
                 window_observed_at: window.observed_at,
                 availability_observed_at: snapshot.availability.observed_at
               })

        assert window.metadata["rate_limit_allowed"] == true
        assert window.metadata["rate_limit_reached"] == false
      end

      assert %{eligible?: true} =
               Windows.routing_quota_eligibility_from_snapshot(
                 snapshot,
                 model: setup.model.exposed_model_id,
                 requested_model: setup.model.exposed_model_id,
                 upstream_model: setup.model.upstream_model_id
               )

      assert {:ok, result} = Service.execute(auth, @endpoint_path, payload, options)
      assert result.status == 200
      assert Repo.aggregate(Attempt, :count) == 1
      assert generation_count(upstream) == 1
      [wire_request] = Enum.filter(FakeUpstream.requests(upstream), &(&1.method == "POST"))
      assert wire_request.path == @endpoint_path
      assert wire_request.json["model"] == setup.model.upstream_model_id
      assert %Accounting.Request{status: "succeeded"} = Repo.one!(Accounting.Request)
      entries = Map.new(Repo.all(Accounting.LedgerEntry), &{&1.entry_kind, &1})
      assert Enum.sort(Map.keys(entries)) == ["release", "reservation", "settlement"]
      assert Repo.aggregate(Accounting.LedgerEntry, :count) == 3
      assert entries["settlement"].request_count == 1
      assert entries["reservation"].request_count == entries["release"].request_count
      assert entries["reservation"].total_tokens == entries["release"].total_tokens

      assert Decimal.equal?(
               entries["reservation"].estimated_cost_micros,
               entries["release"].estimated_cost_micros
             )
    end
  end

  for denial <- [:denied, :spend_control, :conflicting_flags, :malformed_flags] do
    test "#{denial} usage never permits exhausted account dispatch", %{conn: conn} do
      payload = denied_payload(unquote(denial))
      {upstream, setup} = reconciled_setup(payload)
      conn = dispatch(conn, setup)
      assert conn.status == 503
      assert generation_count(upstream) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end
  end

  test "affirmative account permission does not bypass an exhausted model meter", %{conn: conn} do
    usage =
      usage_payload(:weekly_primary)
      |> Map.put("additional_rate_limits", [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "allowed" => false,
            "limit_reached" => true,
            "primary_window" => window(604_800)
          }
        }
      ])

    {upstream, setup} =
      reconciled_setup(usage,
        exposed_model_id: "gpt-5.3-codex-spark",
        upstream_model_id: "gpt-5.3-codex-spark"
      )

    assert dispatch(conn, setup).status == 503
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "affirmative usage does not bypass revoked API key authentication", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))

    setup.api_key
    |> Ecto.Changeset.change(status: "revoked", revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert dispatch(conn, setup).status == 401
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "unrelated model exhaustion does not block affirmative ordinary account dispatch" do
    usage =
      Map.put(usage_payload(:weekly_primary), "additional_rate_limits", [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "allowed" => true,
            "limit_reached" => false,
            "primary_window" => window(604_800)
          }
        }
      ])

    {upstream, setup} = reconciled_setup(usage)
    {auth, payload, options} = request_context(setup)
    assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint_path, payload, options)
    assert generation_count(upstream) == 1
    assert Repo.aggregate(Attempt, :count) == 1
  end

  test "affirmative usage does not bypass missing authentication", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))
    conn = post(conn, @endpoint_path, %{"model" => setup.model.exposed_model_id, "input" => []})
    assert conn.status == 401
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "affirmative usage does not bypass the API key model allowlist", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))

    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: ["sample-other-model"])
    |> Repo.update!()

    assert dispatch(conn, setup).status == 403
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "affirmative usage does not bypass the API key token budget", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))
    owner = Repo.get!(User, setup.api_key.created_by_user_id)
    scope = Scope.for_user(owner, ["instance_owner"])

    assert {:ok, _updated} =
             Access.update_api_key_with_policy(scope, setup.api_key, %{
               default_policy: %{max_tokens_per_day: 1}
             })

    assert {:ok, _auth} = Access.authenticate_authorization_header(setup.authorization)
    conn = dispatch(conn, setup)
    assert conn.status == 403

    assert %{"error" => %{"code" => "api_key_policy_limit_exceeded"}} =
             CodexPooler.JSON.decode!(conn.resp_body)

    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "affirmative usage does not bypass upstream reauthentication", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))

    setup.identity
    |> Ecto.Changeset.change(status: "reauth_required")
    |> Repo.update!()

    assert dispatch(conn, setup).status == 400
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "affirmative usage does not bypass a claimed saved reset probe", %{conn: conn} do
    {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))
    now = DateTime.utc_now()

    redemption = %{
      "status" => "succeeded",
      "phase" => "consumed_pending_probe",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 2,
      "trigger_kind" => "gateway_auto",
      "consumed_at" => DateTime.to_iso8601(now),
      "deadline_at" => now |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "result" => %{"code" => "reset", "applied" => true},
      "probe" => %{"token" => Ecto.UUID.generate()}
    }

    setup.identity
    |> Ecto.Changeset.change(
      metadata: Map.put(setup.identity.metadata, "saved_reset_redemption", redemption)
    )
    |> Repo.update!()

    assert dispatch(conn, setup).status == 503
    assert generation_count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  for change <- [:denial, :credential_epoch] do
    test "a newer #{change} after pre-dispatch selection prevents generation" do
      {upstream, setup} = reconciled_setup(usage_payload(:weekly_primary))
      {auth, payload, options} = request_context(setup)

      assert {:ok, prepared} =
               PreDispatch.prepare(auth, @endpoint_path, payload, options, setup.model)

      assert length(prepared.candidates) == 1
      snapshot = Map.fetch!(prepared.route_state.quota_snapshots, setup.identity.id)

      assert %{eligible?: true, routing_state: :provider_available} =
               Windows.routing_quota_eligibility_from_snapshot(
                 snapshot,
                 model: setup.model.exposed_model_id,
                 requested_model: setup.model.exposed_model_id,
                 upstream_model: setup.model.upstream_model_id
               )

      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, payload, %{
                 endpoint: @endpoint_path,
                 transport: "http_json",
                 correlation_id: "permission-race-#{System.unique_integer([:positive])}",
                 request_metadata: %{}
               })

      assert {:ok, context} =
               Context.new(%{
                 auth: auth,
                 endpoint: @endpoint_path,
                 payload: payload,
                 model: setup.model,
                 reserved: reserved,
                 candidates: prepared.candidates,
                 request_options: prepared.request_options,
                 route_state: prepared.route_state
               })

      invalidate_selected_identity!(unquote(change), upstream, setup)

      assert {:error, %{code: "no_eligible_backend"}} =
               CandidateDispatch.dispatch(context, fn _prepared_transport ->
                 flunk("a newly denied identity must not reach the transport boundary")
               end)

      assert generation_count(upstream) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      entries = Map.new(Repo.all(Accounting.LedgerEntry), &{&1.entry_kind, &1})
      assert Enum.sort(Map.keys(entries)) == ["release", "reservation"]
      assert Repo.aggregate(Accounting.LedgerEntry, :count) == 2
      assert entries["reservation"].total_tokens == entries["release"].total_tokens

      assert Decimal.equal?(
               entries["reservation"].estimated_cost_micros,
               entries["release"].estimated_cost_micros
             )
    end
  end

  defp invalidate_selected_identity!(:denial, upstream, setup) do
    FakeUpstream.set_mode(upstream, routes(denied_payload(:denied)))

    assert {:ok, _identity} =
             PoolReconciliation.refresh_quota_from_usage(
               Repo.reload!(setup.identity),
               setup.assignment
             )
  end

  defp invalidate_selected_identity!(:credential_epoch, _upstream, setup) do
    identity = Repo.reload!(setup.identity)

    metadata =
      CredentialFencing.advance_credential_epoch_preserving_expiry(identity)

    identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
  end

  defp reconciled_setup(usage, opts \\ []) do
    upstream = start_upstream(routes(usage))
    setup = gateway_setup(upstream, Keyword.put(opts, :quota?, false))

    identity =
      setup.identity
      |> Ecto.Changeset.change(
        metadata: Map.put(setup.identity.metadata, "usage_base_url", FakeUpstream.url(upstream))
      )
      |> Repo.update!()

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, setup.assignment)

    assert Enum.any?(FakeUpstream.requests(upstream), &String.ends_with?(&1.path, "/usage"))
    {upstream, %{setup | identity: identity}}
  end

  defp request_context(setup) do
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    assert {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    options = RequestOptions.build(%{api_key_policy: policy}, @endpoint_path, payload)
    {auth, payload, options}
  end

  defp dispatch(conn, setup) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> post(@endpoint_path, %{"model" => setup.model.exposed_model_id, "input" => []})
  end

  defp generation_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.method == "POST"))
  end

  defp routes(usage) do
    {:path_json,
     %{
       "/api/codex/usage" => {200, usage},
       "/backend-api/codex/usage" => {200, usage},
       "/wham/usage" => {200, usage},
       "/backend-api/wham/usage" => {200, usage},
       @endpoint_path =>
         {200, %{"id" => "resp_permission_fixture", "object" => "response", "output" => []}}
     }}
  end

  defp usage_payload(shape) do
    rate_limit = %{
      "allowed" => true,
      "limit_reached" => false,
      "primary_window" => window(if(shape == :weekly_primary, do: 604_800, else: 18_000)),
      "secondary_window" => if(shape == :weekly_primary, do: nil, else: window(604_800))
    }

    %{
      "plan_type" => "plus",
      "rate_limit" => rate_limit,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }
  end

  defp denied_payload(:denied) do
    usage_payload(:weekly_primary)
    |> put_in(["rate_limit", "allowed"], false)
    |> put_in(["rate_limit", "limit_reached"], true)
  end

  defp denied_payload(:spend_control),
    do: Map.put(usage_payload(:weekly_primary), "spend_control", %{"reached" => true})

  defp denied_payload(:conflicting_flags),
    do: put_in(usage_payload(:weekly_primary), ["rate_limit", "limit_reached"], true)

  defp denied_payload(:malformed_flags),
    do: put_in(usage_payload(:weekly_primary), ["rate_limit", "allowed"], "true")

  defp window(seconds) do
    %{
      "used_percent" => 100,
      "limit_window_seconds" => seconds,
      "reset_after_seconds" => seconds,
      "reset_at" => DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_unix()
    }
  end
end
