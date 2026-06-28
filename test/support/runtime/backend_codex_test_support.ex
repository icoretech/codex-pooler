defmodule CodexPoolerWeb.Runtime.BackendCodexTestSupport do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Phoenix.ConnTest
  import Plug.Conn
  import CodexPooler.PoolerFixtures

  use Phoenix.VerifiedRoutes,
    endpoint: CodexPoolerWeb.Endpoint,
    router: CodexPoolerWeb.Router,
    statics: CodexPoolerWeb.static_paths()

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    RoutingCircuitState
  }

  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodexPoolerWeb.Endpoint
  @websocket_frame_timeout 1_000
  def stream_retry_setup(first_mode, second_mode \\ stream_success_sse()) do
    first_upstream = start_upstream(first_mode)
    second_upstream = start_upstream(second_mode)
    setup = gateway_setup(first_upstream)

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-stream-retry",
        compact?: false
      )

    prime_routing_quota!(second.identity)
    use_deterministic_rotation!(setup.pool, 2)

    setup =
      setup
      |> Map.put(:fallback_assignment, second.assignment)
      |> Map.put(:fallback_identity, second.identity)
      |> Map.put(
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    {setup, first_upstream, second_upstream}
  end

  def execute_backend_stream!(setup, _request_id) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(
               auth,
               "/backend-api/codex/responses",
               %{
                 "model" => setup.model.exposed_model_id,
                 "input" => "stream retry fixture",
                 "stream" => true
               },
               RequestOptions.build(
                 %{
                   request_id: deterministic_rotation_seed(2, 0),
                   upstream_endpoint: "/backend-api/codex/responses"
                 },
                 "/backend-api/codex/responses",
                 %{
                   "model" => setup.model.exposed_model_id,
                   "input" => "stream retry fixture",
                   "stream" => true
                 }
               )
             )

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    assert {:ok, _stream_conn} = stream.(stream_conn)
  end

  def assert_stream_retry_success!(setup, code) do
    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == code
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"
    assert first_attempt.response_metadata["stream_error_code"] == code
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"

    if health_neutral_retry_code?(code) do
      refute get_in(request.request_metadata || %{}, ["routing", "demotion_reason"])

      assert Repo.all(from(d in BridgeDemotion)) == []
      assert Repo.all(from(c in RoutingCircuitState)) == []
    end

    assert_safe_stream_metadata!(request, [first_attempt, second_attempt])
  end

  defp health_neutral_retry_code?(code) do
    code in ["server_error", "overloaded_error", "server_is_overloaded"]
  end

  def assert_stream_terminal_failure!(setup, code) do
    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == code

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == code
    assert_safe_stream_metadata!(request, [attempt])
  end

  def assert_pre_first_stream_idle_timeout!(setup) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.retry_count == 0
    assert request.last_error_code == "stream_idle_timeout"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_idle_timeout"
    assert attempt.error_message == "upstream stream idle timeout"
    assert attempt.response_metadata["error_kind"] == "stream_interrupted"

    refute Map.has_key?(attempt.response_metadata, "stream_failure_stage")
    refute Map.has_key?(attempt.response_metadata, "stream_terminal_type")
    refute Map.has_key?(attempt.response_metadata, "stream_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "response.created"
    refute metadata_text =~ "response.failed"
    refute metadata_text =~ "[DONE]"
    refute metadata_text =~ "data:"
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "authorization"
    refute metadata_text =~ "cookie"
    refute metadata_text =~ "upstream-token"
    refute metadata_text =~ "auth.json"
  end

  def assert_safe_stream_metadata!(request, attempts) do
    metadata_text =
      inspect({request.request_metadata, Enum.map(attempts, & &1.response_metadata)})

    refute metadata_text =~ "data:"
    refute metadata_text =~ "visible"
    refute metadata_text =~ "call_fixture"
  end

  def stream_success_sse do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_stream_retry_success",
           "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
         }
       }}
    ])
  end

  def first_event_terminal_sse(event_type, code) do
    FakeUpstream.sse_stream([first_event_terminal_payload(event_type, code)], done: false)
  end

  def first_event_terminal_payload(event_type, code) do
    {event_type,
     %{
       "type" => event_type,
       "response" => %{
         "id" => "resp_first_event_failure",
         "error" => %{"code" => code},
         "incomplete_details" => %{"reason" => code},
         "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
       }
     }}
  end

  def use_deterministic_rotation!(pool, ring_size) do
    use_routing_strategy!(pool, "deterministic_rotation", ring_size)
  end

  def use_routing_strategy!(pool, strategy, ring_size) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      routing_strategy: strategy,
      bridge_ring_size: ring_size,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  def half_open_circuit!(setup, assignment) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: setup.model.exposed_model_id,
      route_class: "proxy_http",
      status: "half_open",
      reason_code: "test_probe",
      failure_count: 1,
      success_count: 0,
      opened_at: DateTime.add(now, -60, :second),
      half_opened_at: now,
      metadata: %{"probe_in_flight_count" => 0},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  def lock_circuit_probe!(%RoutingCircuitState{} = state) do
    parent = self()
    state_id = state.id

    task = Task.async(fn -> lock_circuit_probe_task(parent, state_id) end)

    assert_receive {:circuit_probe_locked, locked_id} when locked_id == state_id, 5_000
    task
  end

  def release_circuit_probe!(%Task{} = task, %RoutingCircuitState{} = state) do
    send(task.pid, {:release_circuit_probe, state.id})
    assert {:ok, :ok} = Task.await(task, 5_000)
  end

  def assert_request_reserved! do
    assert_receive {CodexPooler.Events,
                    %{reason: "request_reserved", payload: %{"request_id" => request_id}}},
                   5_000

    request_id
  end

  def ledger_entry_kinds(request) do
    Repo.all(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request.id,
        order_by: [asc: entry.entry_kind],
        select: entry.entry_kind
      )
    )
  end

  def register_unboxed_pool_cleanup!(pool) do
    pool_id = pool.id

    on_exit(fn ->
      unboxed_run(fn ->
        cleanup_unboxed_pool!(pool_id)
      end)
    end)
  end

  def unboxed_run(fun) when is_function(fun, 0) do
    Sandbox.unboxed_run(Repo, fun)
  end

  def lock_circuit_probe_task(parent, state_id) do
    unboxed_run(fn ->
      Repo.transaction(fn ->
        lock_and_hold_circuit_probe!(parent, state_id)
      end)
    end)
  end

  def lock_and_hold_circuit_probe!(parent, state_id) do
    locked_state =
      Repo.one!(
        from(circuit in RoutingCircuitState,
          where: circuit.id == ^state_id,
          lock: "FOR UPDATE"
        )
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    locked_state
    |> RoutingCircuitState.changeset(%{
      metadata: %{"probe_in_flight_count" => 1},
      updated_at: now
    })
    |> Repo.update!()

    send(parent, {:circuit_probe_locked, state_id})

    receive do
      {:release_circuit_probe, ^state_id} -> :ok
    after
      5_000 -> Repo.rollback(:circuit_probe_lock_timeout)
    end
  end

  def cleanup_unboxed_pool!(pool_id) do
    request_ids =
      Repo.all(from(request in Request, where: request.pool_id == ^pool_id, select: request.id))

    identity_ids =
      Repo.all(
        from(assignment in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
          where: assignment.pool_id == ^pool_id,
          select: assignment.upstream_identity_id
        )
      )

    model_refs =
      Repo.all(
        from(model in CodexPooler.Catalog.Model,
          where: model.pool_id == ^pool_id,
          select: model.upstream_model_id
        )
      )

    api_key_ids =
      Repo.all(
        from(api_key in CodexPooler.Access.APIKey,
          where: api_key.pool_id == ^pool_id,
          select: api_key.id
        )
      )

    Repo.delete_all(
      from(entry in LedgerEntry,
        where: entry.pool_id == ^pool_id or entry.request_id in ^request_ids
      )
    )

    Repo.delete_all(
      from(rollup in CodexPooler.Accounting.DailyRollup, where: rollup.pool_id == ^pool_id)
    )

    Repo.delete_all(from(attempt in Attempt, where: attempt.request_id in ^request_ids))
    Repo.delete_all(from(request in Request, where: request.pool_id == ^pool_id))
    Repo.delete_all(from(circuit in RoutingCircuitState, where: circuit.pool_id == ^pool_id))
    Repo.delete_all(from(demotion in BridgeDemotion, where: demotion.pool_id == ^pool_id))
    Repo.delete_all(from(affinity in BridgeAffinity, where: affinity.pool_id == ^pool_id))

    Repo.delete_all(
      from(window in CodexPooler.Upstreams.Quota.AccountQuotaWindow,
        where: window.upstream_identity_id in ^identity_ids
      )
    )

    Repo.delete_all(
      from(secret in CodexPooler.Upstreams.Schemas.EncryptedSecret,
        where: secret.upstream_identity_id in ^identity_ids
      )
    )

    Repo.delete_all(
      from(assignment in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment,
        where: assignment.pool_id == ^pool_id
      )
    )

    Repo.delete_all(
      from(identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
        where: identity.id in ^identity_ids
      )
    )

    Repo.delete_all(
      from(snapshot in PricingSnapshot,
        where:
          snapshot.model_identifier in ^model_refs and
            snapshot.price_version == "backend-codex-test-v1"
      )
    )

    Repo.delete_all(from(model in CodexPooler.Catalog.Model, where: model.pool_id == ^pool_id))

    Repo.delete_all(
      from(binding in CodexPooler.Access.APIKeyPolicyBinding,
        where: binding.api_key_id in ^api_key_ids
      )
    )

    Repo.delete_all(
      from(api_key in CodexPooler.Access.APIKey, where: api_key.pool_id == ^pool_id)
    )

    Repo.delete_all(
      from(settings in CodexPooler.Pools.RoutingSettings, where: settings.pool_id == ^pool_id)
    )

    Repo.delete_all(from(pool in CodexPooler.Pools.Pool, where: pool.id == ^pool_id))
  end

  def gateway_setup(upstream, opts \\ []) do
    key = active_api_key_fixture()
    pool = key.pool
    compact? = Keyword.get(opts, :compact?, false)
    upstream = gateway_upstream(pool, upstream, "upstream-token", compact?: compact?)

    if Keyword.get(opts, :quota?, true) do
      prime_routing_quota!(upstream.identity)
    end

    model_metadata =
      %{"source_assignment_ids" => [upstream.assignment.id]}
      |> Map.merge(Keyword.get(opts, :model_metadata, %{}))

    exposed_model_id = Keyword.get(opts, :exposed_model_id, "gpt-test-model")
    upstream_model_id = Keyword.get(opts, :upstream_model_id, "provider-gpt-test-model")

    model =
      model_fixture(pool, %{
        exposed_model_id: exposed_model_id,
        upstream_model_id: upstream_model_id,
        pricing_ref: Keyword.get(opts, :pricing_ref, upstream_model_id),
        metadata: model_metadata,
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)
    Map.merge(key, %{identity: upstream.identity, assignment: upstream.assignment, model: model})
  end

  def strict_text_format_payload(schema, strict \\ true) do
    %{
      "model" => "gpt-test-model",
      "input" => "answer in json",
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "structured_answer",
          "strict" => strict,
          "schema" => schema
        }
      }
    }
  end

  def prime_routing_quota!(identity, overrides \\ %{}) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(Map.merge(%{reset_at: reset_at}, overrides))
             ])
  end

  def prime_weekly_probe_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("12"),
                 reset_at: reset_at,
                 source: "codex_usage_api",
                 source_precision: "inferred",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  def prime_exhausted_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{reset_at: reset_at, used_percent: Decimal.new("100")})
             ])
  end

  def prime_stale_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{reset_at: reset_at, freshness_state: "stale"})
             ])
  end

  def prime_expired_stale_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{reset_at: reset_at, freshness_state: "stale"})
             ])
  end

  def prime_expired_stale_known_quota_windows!(identity, model) do
    reset_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:second)

    assert {:ok, windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{reset_at: reset_at, freshness_state: "stale"}),
               weekly_quota_window_attrs(%{reset_at: reset_at, freshness_state: "stale"}),
               model_quota_window_attrs(model, "primary", %{
                 reset_at: reset_at,
                 freshness_state: "stale"
               }),
               model_quota_window_attrs(model, "secondary", %{
                 reset_at: reset_at,
                 freshness_state: "stale"
               })
             ])

    assert length(windows) == 4
  end

  def prime_resetless_routing_quota!(identity) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{reset_at: nil})
             ])
  end

  def primary_quota_window_attrs(overrides) do
    Map.merge(
      %{
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("1"),
        reset_at: DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second),
        source: "codex_response_headers",
        source_precision: "observed",
        freshness_state: "fresh"
      },
      overrides
    )
  end

  def weekly_quota_window_attrs(overrides) do
    Map.merge(
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("1"),
        reset_at: DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second),
        source: "codex_response_headers",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      },
      overrides
    )
  end

  def monthly_only_account_primary_quota_window_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        quota_key: "account",
        window_kind: "primary",
        window_minutes: 43_200,
        used_percent: Decimal.new("42.5"),
        reset_at: DateTime.add(DateTime.utc_now(), 30, :day) |> DateTime.truncate(:second),
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      },
      overrides
    )
  end

  def monthly_only_account_primary_quota_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 42.5,
            "limit_window_seconds" => 2_592_000
          }
        }
      },
      overrides
    )
  end

  def model_quota_window_attrs(model, window_kind, overrides)
      when window_kind in ["primary", "secondary"] do
    window_minutes = if window_kind == "primary", do: 300, else: 10_080
    reset_at_seconds = if window_kind == "primary", do: 900, else: 7 * 24 * 60 * 60

    Map.merge(
      %{
        quota_key: "gpt_test_model",
        window_kind: window_kind,
        window_minutes: window_minutes,
        used_percent: Decimal.new("1"),
        reset_at:
          DateTime.add(DateTime.utc_now(), reset_at_seconds, :second)
          |> DateTime.truncate(:second),
        source: "codex_response_headers",
        source_precision: "observed",
        quota_scope: "model",
        quota_family: "codex_model",
        model: model.exposed_model_id,
        upstream_model: model.upstream_model_id,
        freshness_state: "fresh"
      },
      overrides
    )
  end

  def put_model_source_assignments!(model, assignments) do
    assignment_ids = Enum.map(assignments, & &1.id)

    model
    |> Ecto.Changeset.change(%{
      source_assignment_count: length(assignment_ids),
      metadata: %{"source_assignment_ids" => assignment_ids}
    })
    |> Repo.update!()
  end

  def deterministic_rotation_seed(modulus, target) do
    Enum.find_value(1..500, fn index ->
      seed = "deterministic-rotation-seed-#{index}"

      if :erlang.phash2(seed, modulus) == target do
        seed
      end
    end) || raise "missing deterministic rotation seed for #{modulus}/#{target}"
  end

  def seed_preferring_assignment(assignment_ids, desired_assignment_id) do
    Enum.find_value(1..500, fn index ->
      seed = "bridge-ring-seed-#{index}"

      preferred =
        assignment_ids
        |> Enum.max_by(&rendezvous_score(seed, &1))

      if preferred == desired_assignment_id, do: seed
    end) || raise "missing bridge ring seed for #{desired_assignment_id}"
  end

  def rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [seed, ?:, assignment_id])
    |> :binary.decode_unsigned()
  end

  def gateway_upstream(pool, upstream, token, opts) do
    compact? = Keyword.get(opts, :compact?, false)
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    metadata =
      if compact?, do: Map.put(metadata, "supports_compact_responses", true), else: metadata

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Gateway upstream",
               onboarding_method: "import",
               metadata: metadata
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Gateway assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    %{identity: identity, assignment: assignment}
  end

  def pricing_snapshot!(model, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: model.upstream_model_id,
      price_version: Map.get(attrs, :price_version, "backend-codex-test-#{unique_suffix()}"),
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Map.get(attrs, :input_token_micros, Decimal.new(10)),
      cached_input_token_micros: Map.get(attrs, :cached_input_token_micros, Decimal.new(1)),
      output_token_micros: Map.get(attrs, :output_token_micros, Decimal.new(20)),
      reasoning_token_micros: Map.get(attrs, :reasoning_token_micros, Decimal.new(30)),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: Map.get(attrs, :config, pricing_config(%{}))
    }
    |> Repo.insert!()
  end

  def pricing_config(overrides) do
    Map.merge(
      %{
        "service_tier" => "standard",
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens"
      },
      overrides
    )
  end

  def unique_suffix do
    "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  def start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  def auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  def start_public_endpoint! do
    {:ok, server} =
      Bandit.start_link(
        plug: CodexPoolerWeb.Endpoint,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  def public_websocket_connect!(port, setup, turn_state, path \\ "/backend-api/codex/responses") do
    {conn, websocket, ref, _response_headers} =
      public_websocket_connect_with_headers!(port, setup, turn_state, path)

    {conn, websocket, ref}
  end

  def public_websocket_connect_with_headers!(
        port,
        setup,
        turn_state,
        path \\ "/backend-api/codex/responses"
      ) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", turn_state}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)

    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref, response_headers}
  end

  def mint_websocket_new!(conn, ref, status, response_headers) do
    new_websocket = &Mint.WebSocket.new/4

    case new_websocket.(conn, ref, status, response_headers) do
      {:ok, conn, websocket} ->
        {conn, websocket}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        flunk("websocket upgrade failed: #{inspect(reason)}")
    end
  end

  def await_public_websocket_upgrade(conn, ref) do
    await_public_websocket_upgrade(conn, ref, nil, nil)
  end

  def await_public_websocket_upgrade(conn, ref, status, response_headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = websocket_status_part(responses, ref) || status
            response_headers = websocket_headers_part(responses, ref) || response_headers

            if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
              complete_public_websocket_upgrade(conn, status, response_headers)
            else
              await_public_websocket_upgrade(conn, ref, status, response_headers)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket upgrade failed: #{inspect(reason)}")

          :unknown ->
            await_public_websocket_upgrade(conn, ref, status, response_headers)
        end
    after
      @websocket_frame_timeout -> flunk("timed out waiting for websocket upgrade")
    end
  end

  def complete_public_websocket_upgrade(conn, 101, response_headers)
      when is_list(response_headers) do
    {:ok, conn, 101, response_headers}
  end

  def complete_public_websocket_upgrade(_conn, status, _response_headers)
      when is_integer(status) do
    flunk("websocket upgrade returned status #{status}")
  end

  def complete_public_websocket_upgrade(_conn, _status, _response_headers) do
    flunk("websocket upgrade did not include a status")
  end

  def websocket_status_part(responses, ref) do
    Enum.find_value(responses, fn
      {:status, ^ref, status} when is_integer(status) -> status
      _part -> nil
    end)
  end

  def websocket_headers_part(responses, ref) do
    Enum.find_value(responses, fn
      {:headers, ^ref, headers} when is_list(headers) -> headers
      _part -> nil
    end)
  end

  def public_websocket_send_text!(conn, websocket, ref, text) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  def public_websocket_receive_text!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case decode_public_websocket_text(websocket, ref, responses) do
              {:ok, websocket, text} -> {conn, websocket, text}
              {:cont, websocket} -> public_websocket_receive_text!(conn, websocket, ref)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            public_websocket_receive_text!(conn, websocket, ref)
        end
    after
      @websocket_frame_timeout -> flunk("timed out waiting for websocket frame")
    end
  end

  def decode_public_websocket_text(websocket, ref, responses) do
    Enum.reduce_while(responses, {:cont, websocket}, fn
      {:data, ^ref, data}, {:cont, websocket} ->
        decode_public_websocket_data!(websocket, data)

      {:done, ^ref}, _acc ->
        flunk("websocket closed before a response frame")

      _part, acc ->
        {:cont, acc}
    end)
  end

  def decode_public_websocket_data!(websocket, data) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        case decoded_public_websocket_text(websocket, frames) do
          {:ok, websocket, text} -> {:halt, {:ok, websocket, text}}
          {:cont, websocket} -> {:cont, {:cont, websocket}}
        end

      {:error, _websocket, reason} ->
        flunk("websocket decode failed: #{inspect(reason)}")
    end
  end

  def decoded_public_websocket_text(websocket, frames) do
    Enum.reduce_while(frames, {:cont, websocket}, fn
      {:text, text}, _acc -> {:halt, {:ok, websocket, text}}
      {:close, code, reason}, _acc -> flunk("websocket closed: #{inspect({code, reason})}")
      _frame, acc -> {:cont, acc}
    end)
  end

  def receive_websocket_frames_by_type(required_types, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    collect_websocket_frames_by_type(
      required_types,
      MapSet.new(required_types),
      %{},
      [],
      deadline
    )
  end

  def collect_websocket_frames_by_type(
        required_types,
        required_type_set,
        frames,
        collected_types,
        deadline
      ) do
    if MapSet.subset?(required_type_set, MapSet.new(Map.keys(frames))) do
      frames
    else
      remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:websocket_frame, frame} ->
          decoded_frame = Jason.decode!(frame)
          decoded_type = decoded_frame["type"]
          collected_types = [decoded_type | collected_types]

          frames =
            if MapSet.member?(required_type_set, decoded_type) do
              Map.put(frames, decoded_type, decoded_frame)
            else
              frames
            end

          collect_websocket_frames_by_type(
            required_types,
            required_type_set,
            frames,
            collected_types,
            deadline
          )
      after
        remaining_ms ->
          missing_types = Enum.reject(required_types, &Map.has_key?(frames, &1))

          flunk("""
          missing websocket event types: #{inspect(missing_types)}
          collected websocket event types: #{inspect(Enum.reverse(collected_types))}
          """)
      end
    end
  end

  def receive_socket_push(state) do
    receive do
      {:codex_response_chunk, frame} ->
        CodexResponsesSocket.handle_info({:codex_response_chunk, frame}, state)
    after
      1_000 -> flunk("expected websocket response chunk")
    end
  end

  def receive_socket_done(state, timeout_ms \\ 1_000) do
    receive do
      {:codex_response_done, pid, result} ->
        CodexResponsesSocket.handle_info({:codex_response_done, pid, result}, state)
    after
      timeout_ms -> flunk("expected websocket response completion")
    end
  end

  def assignment_for_response("resp_ws_first", first_assignment, _second_assignment),
    do: first_assignment

  def assignment_for_response("resp_ws_second", _first_assignment, second_assignment),
    do: second_assignment

  def create_backend_file!(setup, file_name, file_size) do
    conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => file_name,
        "file_size" => file_size,
        "use_case" => "codex"
      })

    assert %{"file_id" => file_id} = json_response(conn, 200)
    file_id
  end

  def create_and_finalize_backend_file!(setup, file_name, file_size) do
    file_id = create_backend_file!(setup, file_name, file_size)

    conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{"status" => "success"} = json_response(conn, 200)
    file_id
  end

  def swap_upstream_base_url!(setup, upstream) do
    base_url = FakeUpstream.url(upstream)

    identity =
      setup.identity
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    assignment =
      setup.assignment
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    %{setup | identity: identity, assignment: assignment}
  end

  def response_affinity_file_fixture(setup, assignment, identity, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = Keyword.get(attrs, :expires_at, DateTime.add(now, 3600, :second))

    %FileRecord{}
    |> FileRecord.changeset(%{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      file_id: Keyword.fetch!(attrs, :file_id),
      purpose: "user_data",
      filename: Keyword.get(attrs, :filename, "sample.txt"),
      byte_size: Keyword.get(attrs, :byte_size, 12),
      status: Keyword.get(attrs, :status, "pending_upload"),
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      finalize_status: Keyword.get(attrs, :finalize_status, "pending"),
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end
end
