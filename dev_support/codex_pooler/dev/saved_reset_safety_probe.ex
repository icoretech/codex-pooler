defmodule CodexPooler.Dev.SavedResetSafetyProbe do
  @moduledoc """
  Fail-closed local certification for the saved-reset sibling and recovery paths.

  The task is deliberately unavailable outside `MIX_ENV=dev`. It starts a
  loopback-only provider simulator, disables endpoint serving and Oban runners,
  and deletes only rows whose UUIDs were generated for its current run.
  """

  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias __MODULE__.Provider

  @scenarios ~w(sibling-barrier ambiguous-replay markerless-legacy)
  @database "codex_pooler_dev"
  @lock_namespace "codex-pooler:saved-reset-safety-probe"
  @receipt_root Path.join(["tmp", "saved-reset-safety-probe", "receipts"])
  @receipt_keys ~w(run_fingerprint scenarios status cleanup endpoint_isolated oban_isolated source_sha)
  @scenario_receipt_keys %{
    "sibling-barrier" =>
      ~w(consume_count distinct_backend_pids backend_pinned barrier winner_applied loser_code),
    "ambiguous-replay" =>
      ~w(target_reused request_reused scope_reused attempt_reused generation_reused scope_fingerprint),
    "markerless-legacy" =>
      ~w(legacy_recovery mode provider_requests snooze_seconds next_action_scheduled)
  }
  @probe_slug_prefix "dev-saved-reset-probe-"

  @type command :: %{required(:scenarios) => [String.t()]}

  @spec parse_args([String.t()]) :: {:ok, command()} | {:error, String.t()}
  def parse_args(["--scenario", scenario]), do: normalize_scenario(scenario)

  def parse_args(_args),
    do:
      {:error,
       "accepts exactly one --scenario sibling-barrier|ambiguous-replay|markerless-legacy|all"}

  @spec validate_environment(atom(), keyword()) :: :ok | {:error, String.t()}
  def validate_environment(environment \\ Mix.env(), repo_config \\ Repo.config()) do
    cond do
      environment != :dev ->
        {:error, "saved-reset safety probe runs only with MIX_ENV=dev"}

      Keyword.get(repo_config, :database) != @database ->
        {:error, "saved-reset safety probe requires database #{@database}"}

      true ->
        :ok
    end
  end

  @spec isolated_config(keyword(), keyword()) :: %{oban: keyword(), endpoint: keyword()}
  def isolated_config(oban_config, endpoint_config) do
    %{
      oban:
        oban_config
        |> Keyword.put(:testing, :manual)
        |> Keyword.put(:queues, false)
        |> Keyword.put(:plugins, false),
      endpoint:
        endpoint_config
        |> Keyword.put(:server, false)
        |> Keyword.put(:watchers, [])
        |> Keyword.delete(:live_reload)
        |> Keyword.put(:code_reloader, false)
    }
  end

  @spec validate_receipt(map()) :: :ok | {:error, String.t()}
  def validate_receipt(receipt) when is_map(receipt) do
    keys = receipt |> stringify_keys() |> Map.keys()

    with true <- Enum.sort(keys) == Enum.sort(@receipt_keys),
         true <- valid_fingerprint?(receipt[:run_fingerprint] || receipt["run_fingerprint"]),
         true <- (receipt[:status] || receipt["status"]) == "passed",
         true <- (receipt[:cleanup] || receipt["cleanup"]) == "exact_owned_rows_removed",
         true <- (receipt[:endpoint_isolated] || receipt["endpoint_isolated"]) == true,
         true <- (receipt[:oban_isolated] || receipt["oban_isolated"]) == true,
         true <- valid_source_sha?(receipt[:source_sha] || receipt["source_sha"]),
         true <- valid_scenario_receipts?(receipt[:scenarios] || receipt["scenarios"]) do
      :ok
    else
      _invalid -> {:error, "receipt contains a field outside the metadata allowlist"}
    end
  end

  @spec execute(command(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(command, opts \\ [])

  def execute(%{scenarios: scenarios}, opts) when is_list(scenarios) do
    with :ok <- validate_scenarios(scenarios) do
      execute_valid_scenarios(scenarios, opts)
    end
  end

  def execute(_command, _opts), do: {:error, "scenario command is invalid"}

  defp execute_valid_scenarios(scenarios, opts) do
    run_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Process.put({__MODULE__, :run_id}, run_id)
    Process.put({__MODULE__, :journal}, empty_journal())

    with :ok <-
           validate_environment(
             Keyword.get(opts, :environment, Mix.env()),
             Keyword.get(opts, :repo_config, Repo.config())
           ),
         {:ok, inspector} <- start_inspector(opts),
         :ok <- remember_resource(:inspector, inspector),
         :ok <- acquire_lock(inspector),
         :ok <- require_quiet_database(inspector),
         :ok <- require_application_stopped(),
         :ok <- require_endpoint_stopped(),
         {:ok, restore} <- start_isolated_application(),
         :ok <- remember_resource(:restore, restore),
         :ok <- suppress_debug_logging(),
         {:ok, provider} <- Provider.start_link(notify: self()),
         :ok <- remember_resource(:provider, provider),
         {:ok, results} <- run_scenarios(scenarios, provider, run_id),
         :ok <- cleanup_run(run_id),
         :ok <- stop_and_verify_quiet(restore, provider, inspector),
         {:ok, receipt} <- write_receipt(run_id, scenarios, results) do
      {:ok, receipt}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, "saved-reset safety probe failed: #{Exception.message(exception)}"}
  after
    cleanup_run_if_started(Process.get({__MODULE__, :run_id}))
    cleanup_provider_resource()
    cleanup_application_resource()
    cleanup_inspector_resource()
    restore_logger_level()
    Process.delete({__MODULE__, :run_id})
    Process.delete({__MODULE__, :journal})
  end

  defp normalize_scenario("all"), do: {:ok, %{scenarios: @scenarios}}

  defp normalize_scenario(scenario) when scenario in @scenarios,
    do: {:ok, %{scenarios: [scenario]}}

  defp normalize_scenario(_scenario),
    do: {:error, "scenario must be sibling-barrier, ambiguous-replay, markerless-legacy, or all"}

  defp validate_scenarios(scenarios) do
    if scenarios != [] and Enum.uniq(scenarios) == scenarios and
         Enum.all?(scenarios, &(&1 in @scenarios)),
       do: :ok,
       else: {:error, "scenario command is invalid"}
  end

  defp run_scenarios(scenarios, provider, run_id) do
    Enum.reduce_while(scenarios, {:ok, %{}}, fn scenario, {:ok, results} ->
      case run_scenario(scenario, provider, run_id) do
        {:ok, result} ->
          {:cont, {:ok, Map.put(results, scenario, result)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_scenario("sibling-barrier", provider, run_id), do: sibling_barrier(provider, run_id)
  defp run_scenario("ambiguous-replay", provider, run_id), do: ambiguous_replay(provider, run_id)

  defp run_scenario("markerless-legacy", provider, run_id),
    do: markerless_legacy(provider, run_id)

  defp sibling_barrier(provider, run_id) do
    Provider.configure(provider, :sibling)
    now = now()
    {_pool, entries} = provision_entries(run_id, provider.url, :codex, 2, now)
    [first, second] = entries
    cohort_ids = Enum.map(entries, & &1.identity.id)
    parent = self()

    winner = Task.async(fn -> redeem_gateway_auto(parent, :winner, first, cohort_ids, now) end)
    loser = Task.async(fn -> redeem_gateway_auto(parent, :loser, second, cohort_ids, now) end)

    with {:probe_ready, :winner, winner_backend_pid} <- receive_probe_ready(:winner),
         {:probe_ready, :loser, loser_backend_pid} <- receive_probe_ready(:loser),
         true <- winner_backend_pid != loser_backend_pid,
         :ok <- send_start(winner.pid),
         {:provider_barrier, provider_pid, :sibling} <- receive_provider_barrier(),
         :ok <- send_start(loser.pid),
         :ok <- Provider.release(provider_pid),
         {:winner, %{before: ^winner_backend_pid} = winner_pin,
          {:ok, %{status: :succeeded, applied?: true}}} <-
           Task.await(winner, 15_000),
         {:loser, %{before: ^loser_backend_pid} = loser_pin,
          {:ok, %{status: :noop, code: "gateway_auto_sibling_consume_barrier"}}} <-
           Task.await(loser, 15_000),
         true <- distinct_pinned_backends?(winner_pin, loser_pin),
         1 <- Provider.consume_count(provider) do
      {:ok,
       %{
         consume_count: 1,
         distinct_backend_pids: true,
         backend_pinned: true,
         barrier: true,
         winner_applied: true,
         loser_code: "gateway_auto_sibling_consume_barrier"
       }}
    else
      _other -> {:error, "sibling-barrier contract was not satisfied"}
    end
  end

  @doc """
  True only when each caller kept one pinned database backend for its entire
  redemption (`before == after`) and the two callers used distinct backends.
  """
  @spec distinct_pinned_backends?(map(), map()) :: boolean()
  def distinct_pinned_backends?(
        %{before: winner_pid, after: winner_pid},
        %{before: loser_pid, after: loser_pid}
      )
      when is_integer(winner_pid) and is_integer(loser_pid),
      do: winner_pid != loser_pid

  def distinct_pinned_backends?(_winner_pin, _loser_pin), do: false

  defp ambiguous_replay(provider, run_id) do
    Provider.configure(provider, :ambiguous)
    now = now()

    {_pool, [entry]} =
      provision_entries(run_id, provider.url, :chatgpt, 1, DateTime.add(now, -10, :minute))

    with {:error, :saved_reset_consume_outcome_ambiguous} <-
           SavedResetRedemption.redeem(entry.assignment,
             started_at: DateTime.add(now, -10, :minute),
             receive_timeout: 5_000
           ),
         [first_request] <- Provider.consume_requests(provider),
         identity <- Repo.reload!(entry.identity),
         redemption <- identity.metadata["saved_reset_redemption"],
         replay <- redemption["provider_replay"],
         attempt_id <- redemption["attempt_id"],
         generation <- redemption["generation"],
         {:ok, dispatched_at, 0} <- DateTime.from_iso8601(replay["last_provider_dispatched_at"]),
         recovery_now <- DateTime.add(dispatched_at, 60, :second),
         {:ok, %{status: :succeeded, applied?: true}} <-
           SavedResetRedemption.resume_stale_consuming(
             entry.assignment,
             identity.id,
             redemption["attempt_id"],
             redemption["generation"],
             now: recovery_now,
             receive_timeout: 1_000
           ),
         [^first_request, second_request] <- Provider.consume_requests(provider),
         true <- replay_request_reused?(first_request, second_request),
         recovered <- Repo.reload!(identity).metadata["saved_reset_redemption"],
         recovered_replay <- recovered["provider_replay"],
         true <- replay["scope_fingerprint"] == recovered_replay["scope_fingerprint"],
         true <- attempt_id == recovered["attempt_id"],
         true <- generation == recovered["generation"] do
      {:ok,
       %{
         target_reused: true,
         request_reused: true,
         scope_reused: true,
         attempt_reused: true,
         generation_reused: true,
         scope_fingerprint: fingerprint(replay["scope_fingerprint"])
       }}
    else
      _other -> {:error, "ambiguous-replay contract was not satisfied"}
    end
  end

  defp markerless_legacy(provider, run_id) do
    Provider.configure(provider, :legacy)
    now = now()

    {_pool, [entry]} =
      provision_entries(run_id, provider.url, :codex, 1, DateTime.add(now, -10, :minute))

    attempt_id = Ecto.UUID.generate()

    redemption = %{
      "status" => "redeeming",
      "phase" => "consuming",
      "attempt_id" => attempt_id,
      "generation" => 1,
      "trigger_kind" => "admin_manual",
      "started_at" => DateTime.to_iso8601(DateTime.add(now, -10, :minute)),
      "finished_at" => nil,
      "result" => nil
    }

    identity = update_identity_metadata(entry.identity, "saved_reset_redemption", redemption)

    with {:snooze, seconds} when seconds >= 6 * 60 * 60 <-
           SavedResetRedemption.resume_stale_consuming(
             entry.assignment,
             identity.id,
             attempt_id,
             1,
             now: now,
             receive_timeout: 0
           ),
         persisted <- Repo.reload!(identity).metadata["saved_reset_redemption"],
         %{"version" => 1, "state" => "unresolved"} <- persisted["legacy_recovery"],
         "legacy_unresolved" <- persisted["legacy_recovery_last_code"],
         next_action_at when is_binary(next_action_at) <-
           persisted["legacy_recovery_next_action_at"],
         {:ok, next_action_at, 0} <- DateTime.from_iso8601(next_action_at),
         true <- DateTime.diff(next_action_at, now, :second) >= 6 * 60 * 60,
         "observe_only" <- legacy_observe_only_mode(persisted),
         0 <- Provider.request_count(provider) do
      {:ok,
       %{
         legacy_recovery: "v1_unresolved",
         mode: legacy_observe_only_mode(persisted),
         provider_requests: 0,
         snooze_seconds: seconds,
         next_action_scheduled: true
       }}
    else
      _other -> {:error, "markerless-legacy contract was not satisfied"}
    end
  end

  @doc """
  Derives the legacy recovery mode from the persisted record instead of
  asserting it: a still-consuming record that carries the v1 unresolved marker
  and no `provider_replay` contract is observe-only by definition.
  """
  @spec legacy_observe_only_mode(map()) :: String.t()
  def legacy_observe_only_mode(
        %{
          "status" => "redeeming",
          "phase" => "consuming",
          "legacy_recovery" => %{"version" => 1, "state" => "unresolved"}
        } = persisted
      ) do
    if Map.has_key?(persisted, "provider_replay"), do: "unexpected", else: "observe_only"
  end

  def legacy_observe_only_mode(_persisted), do: "unexpected"

  defp provision_entries(run_id, provider_url, family, count, started_at) do
    run_suffix = "#{run_id}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

    pool =
      Repo.insert!(%Pool{
        slug: "#{@probe_slug_prefix}#{run_suffix}",
        name: "Dev saved reset #{run_suffix}",
        status: "active"
      })

    journal_pool(pool)

    entries =
      Enum.map(1..count, fn index ->
        identity =
          Repo.insert!(%UpstreamIdentity{
            chatgpt_account_id: "dev-reset-#{run_suffix}-#{index}",
            account_label: "dev-saved-reset-#{run_suffix}-#{index}",
            onboarding_method: "import",
            status: "active",
            headers_profile_version: 1,
            saved_reset_auto_redeem_enabled: true,
            saved_reset_auto_redeem_min_blocked_minutes: 60,
            saved_reset_auto_redeem_keep_credits: 0,
            saved_reset_auto_redeem_trigger_mode: "blocked",
            metadata: saved_reset_metadata(provider_url, family, started_at)
          })

        journal_identity(identity)

        {:ok, _secret} =
          Upstreams.store_encrypted_secret(identity, %{
            secret_kind: "access_token",
            plaintext: "dev-loopback-token-#{run_suffix}-#{index}"
          })

        assignment =
          Repo.insert!(%PoolUpstreamAssignment{
            pool_id: pool.id,
            upstream_identity_id: identity.id,
            assignment_label: "dev-saved-reset-#{run_suffix}-#{index}",
            status: "active",
            health_status: "active",
            eligibility_status: "eligible",
            metadata: %{}
          })

        journal_assignment(assignment)

        {:ok, [_window]} =
          Windows.upsert_quota_windows(identity, [weekly_exhausted_window(started_at)])

        %{identity: identity, assignment: assignment}
      end)

    {pool, entries}
  end

  # The caller holds one checked-out database connection for its entire
  # redemption, so the backend pid measured before and after is provably the
  # backend that executed its claim and reservation transactions.
  defp redeem_gateway_auto(parent, role, entry, cohort_ids, started_at) do
    Repo.checkout(
      fn ->
        backend_pid = current_backend_pid()
        send(parent, {:probe_ready, role, backend_pid})

        receive do
          :saved_reset_probe_start -> :ok
        after
          10_000 -> raise "saved-reset caller was not started"
        end

        result =
          SavedResetRedemption.redeem(entry.assignment,
            trigger_kind: "gateway_auto",
            gateway_auto_context: %{
              trigger: :blocked_weekly_exhaustion,
              pool_upstream_assignment_id: entry.assignment.id,
              upstream_identity_id: entry.identity.id,
              candidate_assignment_ids: [entry.assignment.id],
              candidate_identity_ids: [entry.identity.id],
              cohort_identity_ids: cohort_ids,
              routable_identity_ids: cohort_ids,
              route_class: "proxy_http",
              quota_scope: quota_scope(),
              hard_pinned_continuity?: false
            },
            started_at: started_at,
            receive_timeout: 10_000
          )

        {role, %{before: backend_pid, after: current_backend_pid()}, result}
      end,
      timeout: 60_000
    )
  end

  defp current_backend_pid do
    Repo.query!("SELECT pg_backend_pid()", []).rows |> List.first() |> List.first()
  end

  @doc """
  Waits for the loopback provider's sibling barrier signal; a missing signal
  resolves to `:timeout` so the orchestration fails closed instead of hanging.
  """
  @spec receive_provider_barrier(non_neg_integer()) ::
          {:provider_barrier, pid(), :sibling} | :timeout
  def receive_provider_barrier(timeout \\ 10_000) do
    receive do
      {:saved_reset_probe_provider_barrier, provider_pid, :sibling} ->
        {:provider_barrier, provider_pid, :sibling}
    after
      timeout -> :timeout
    end
  end

  defp receive_probe_ready(role) do
    receive do
      {:probe_ready, ^role, backend_pid} -> {:probe_ready, role, backend_pid}
    after
      10_000 -> :timeout
    end
  end

  defp send_start(pid) when is_pid(pid) do
    send(pid, :saved_reset_probe_start)
    :ok
  end

  defp saved_reset_metadata(provider_url, :codex, started_at) do
    %{
      "usage_base_url" => provider_url,
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => DateTime.to_iso8601(started_at),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      }
    }
  end

  defp saved_reset_metadata(provider_url, :chatgpt, started_at) do
    %{
      "usage_base_url" => provider_url,
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 2,
        "source" => "codex_usage_api",
        "path_style" => "chatgpt_api",
        "observed_at" => DateTime.to_iso8601(started_at),
        "usage_path" => "/backend-api/wham/usage",
        "reason" => nil
      }
    }
  end

  defp weekly_exhausted_window(now) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(now, 2, :hour),
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  defp quota_scope do
    %{
      requested_model: "dev-model",
      catalog_model: "dev-model",
      exposed_model_id: "dev-model",
      upstream_model: "dev-model",
      upstream_model_id: "dev-model"
    }
  end

  defp update_identity_metadata(identity, key, value) do
    identity = Repo.reload!(identity)

    identity
    |> UpstreamIdentity.changeset(%{metadata: Map.put(identity.metadata || %{}, key, value)})
    |> Repo.update!()
  end

  defp cleanup_run(_run_id) do
    cleanup_owned!(Process.get({__MODULE__, :journal}, empty_journal()))
  end

  @doc """
  Deletes exactly the journaled run-owned rows and raises when any of them
  survives; rows outside the journal are never touched.
  """
  @spec cleanup_owned!(%{
          required(:pool_ids) => [Ecto.UUID.t()],
          required(:identity_ids) => [Ecto.UUID.t()],
          required(:assignment_ids) => [Ecto.UUID.t()]
        }) :: :ok
  def cleanup_owned!(journal) do
    Repo.delete_all(
      from assignment in PoolUpstreamAssignment, where: assignment.id in ^journal.assignment_ids
    )

    Repo.delete_all(
      from identity in UpstreamIdentity, where: identity.id in ^journal.identity_ids
    )

    Repo.delete_all(from pool in Pool, where: pool.id in ^journal.pool_ids)

    if owned_resources_removed?(journal),
      do: :ok,
      else: raise("run-owned resources remain after cleanup")
  end

  defp journal_pool(pool) do
    journal = Process.get({__MODULE__, :journal}, empty_journal())

    Process.put({__MODULE__, :journal}, %{
      pool_ids: Enum.uniq([pool.id | journal.pool_ids]),
      identity_ids: journal.identity_ids,
      assignment_ids: journal.assignment_ids
    })
  end

  defp journal_identity(identity) do
    journal = Process.get({__MODULE__, :journal}, empty_journal())

    Process.put({__MODULE__, :journal}, %{
      pool_ids: journal.pool_ids,
      identity_ids: Enum.uniq([identity.id | journal.identity_ids]),
      assignment_ids: journal.assignment_ids
    })
  end

  defp journal_assignment(assignment) do
    journal = Process.get({__MODULE__, :journal}, empty_journal())

    Process.put({__MODULE__, :journal}, %{
      pool_ids: journal.pool_ids,
      identity_ids: journal.identity_ids,
      assignment_ids: Enum.uniq([assignment.id | journal.assignment_ids])
    })
  end

  defp empty_journal, do: %{pool_ids: [], identity_ids: [], assignment_ids: []}

  @doc """
  True only when no journaled run-owned row remains in the database.
  """
  @spec owned_resources_removed?(map()) :: boolean()
  def owned_resources_removed?(journal) do
    Repo.aggregate(from(pool in Pool, where: pool.id in ^journal.pool_ids), :count) == 0 and
      Repo.aggregate(
        from(identity in UpstreamIdentity, where: identity.id in ^journal.identity_ids),
        :count
      ) == 0 and
      Repo.aggregate(
        from(assignment in PoolUpstreamAssignment,
          where: assignment.id in ^journal.assignment_ids
        ),
        :count
      ) == 0
  end

  defp cleanup_run_if_started(run_id) when is_binary(run_id) do
    if Process.whereis(Repo), do: cleanup_run(run_id)
  end

  defp cleanup_run_if_started(_run_id), do: :ok

  defp require_endpoint_stopped do
    if Process.whereis(CodexPoolerWeb.Endpoint),
      do: {:error, "endpoint server must be stopped before the safety probe starts"},
      else: :ok
  end

  defp require_application_stopped do
    if Application.started_applications()
       |> Enum.any?(fn {application, _, _} -> application == :codex_pooler end),
       do: {:error, "codex_pooler application must be stopped before the safety probe starts"},
       else: :ok
  end

  defp start_isolated_application do
    previous_oban = Application.get_env(:codex_pooler, Oban)
    previous_endpoint = Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint)
    config = isolated_config(previous_oban, previous_endpoint)
    Application.put_env(:codex_pooler, Oban, config.oban)
    Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, config.endpoint)

    if Keyword.get(config.oban, :queues) == false and Keyword.get(config.oban, :plugins) == false do
      case Application.ensure_all_started(:codex_pooler) do
        {:ok, _apps} ->
          {:ok, %{oban: previous_oban, endpoint: previous_endpoint}}

        {:error, reason} ->
          restore_application_config(%{oban: previous_oban, endpoint: previous_endpoint})
          {:error, "isolated application could not start: #{inspect(reason)}"}
      end
    else
      {:error, "Oban could not be forced into manual no-runner mode"}
    end
  end

  defp stop_and_verify_quiet(restore, provider, inspector) do
    Provider.stop(provider)
    forget_resource(:provider)
    Application.stop(:codex_pooler)
    restore_application_config(restore)
    forget_resource(:restore)
    require_quiet_database(inspector)
  end

  defp restore_application_config(%{oban: oban, endpoint: endpoint}) do
    Application.put_env(:codex_pooler, Oban, oban)
    Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, endpoint)
  end

  defp start_inspector(opts) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    config =
      Keyword.get(opts, :repo_config, Repo.config())
      |> Keyword.take([
        :username,
        :password,
        :hostname,
        :port,
        :database,
        :socket_dir,
        :ssl,
        :ssl_opts
      ])
      |> Keyword.put(:parameters, application_name: "saved_reset_safety_probe_inspector")

    case Postgrex.start_link(config) do
      {:ok, inspector} -> {:ok, inspector}
      {:error, _reason} -> {:error, "standalone database inspector could not connect"}
    end
  end

  defp stop_inspector(inspector) when is_pid(inspector) do
    if Process.alive?(inspector), do: GenServer.stop(inspector)
  end

  defp stop_inspector(_inspector), do: :ok

  defp acquire_lock(inspector) do
    %{rows: [[locked?]]} =
      Postgrex.query!(inspector, "SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))", [
        @lock_namespace,
        @database
      ])

    if locked?,
      do: :ok,
      else: {:error, "another saved-reset safety probe holds the database lock"}
  end

  defp release_lock(inspector) when is_pid(inspector) do
    if Process.alive?(inspector),
      do: Postgrex.query(inspector, "SELECT pg_advisory_unlock_all()", [])
  end

  defp release_lock(_inspector), do: :ok

  defp require_quiet_database(inspector) do
    %{rows: rows} =
      Postgrex.query!(
        inspector,
        "SELECT application_name FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'",
        []
      )

    if rows == [],
      do: :ok,
      else: {:error, "database has a client backend outside this safety probe"}
  end

  defp write_receipt(run_id, scenarios, results) do
    receipt = %{
      run_fingerprint: fingerprint(run_id),
      scenarios: Map.new(scenarios, &{&1, Map.fetch!(results, &1)}),
      status: "passed",
      cleanup: "exact_owned_rows_removed",
      endpoint_isolated: true,
      oban_isolated: true,
      source_sha: source_sha()
    }

    with :ok <- validate_receipt(receipt) do
      File.mkdir_p!(@receipt_root)
      File.chmod!(@receipt_root, 0o700)
      path = Path.join(@receipt_root, "#{run_id}.json")
      File.write!(path, Jason.encode!(receipt))
      File.chmod!(path, 0o600)
      {:ok, receipt}
    end
  end

  defp source_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unavailable"
    end
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp valid_fingerprint?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{12}\z/
  defp valid_fingerprint?(_value), do: false
  defp valid_source_sha?("unavailable"), do: true
  defp valid_source_sha?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{40}\z/
  defp valid_source_sha?(_value), do: false

  defp valid_scenario_receipts?(receipts) when is_map(receipts) do
    map_size(receipts) > 0 and
      Enum.all?(receipts, fn {scenario, receipt} ->
        allowed_keys = Map.get(@scenario_receipt_keys, to_string(scenario))

        is_list(allowed_keys) and is_map(receipt) and
          Enum.sort(Map.keys(stringify_keys(receipt))) == Enum.sort(allowed_keys) and
          valid_scenario_receipt?(to_string(scenario), stringify_keys(receipt))
      end)
  end

  defp valid_scenario_receipts?(_receipts), do: false

  defp valid_scenario_receipt?("sibling-barrier", receipt),
    do:
      receipt["consume_count"] == 1 and receipt["distinct_backend_pids"] == true and
        receipt["backend_pinned"] == true and receipt["barrier"] == true and
        receipt["winner_applied"] == true and
        receipt["loser_code"] == "gateway_auto_sibling_consume_barrier"

  defp valid_scenario_receipt?("ambiguous-replay", receipt),
    do:
      Enum.all?(
        ~w(target_reused request_reused scope_reused attempt_reused generation_reused),
        &receipt[&1]
      ) and
        is_binary(receipt["scope_fingerprint"]) and
        receipt["scope_fingerprint"] =~ ~r/\A[0-9a-f]{12}\z/

  defp valid_scenario_receipt?("markerless-legacy", receipt),
    do:
      receipt["legacy_recovery"] == "v1_unresolved" and receipt["mode"] == "observe_only" and
        receipt["provider_requests"] == 0 and is_integer(receipt["snooze_seconds"]) and
        receipt["snooze_seconds"] >= 6 * 60 * 60 and
        receipt["next_action_scheduled"] == true

  defp valid_scenario_receipt?(_scenario, _receipt), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc """
  True only when the recovery consume request replays the original pinned
  credit target and derived idempotent request id byte-for-byte.
  """
  @spec replay_request_reused?(map(), map()) :: boolean()
  def replay_request_reused?(first_request, second_request)
      when is_map(first_request) and is_map(second_request) do
    same_nonempty_binary?(first_request["credit_id"], second_request["credit_id"]) and
      same_nonempty_binary?(
        first_request["redeem_request_id"],
        second_request["redeem_request_id"]
      )
  end

  def replay_request_reused?(_first_request, _second_request), do: false

  defp same_nonempty_binary?(left, right),
    do: is_binary(left) and byte_size(left) > 0 and left == right

  defp remember_resource(name, value) do
    Process.put({__MODULE__, name}, value)
    :ok
  end

  defp forget_resource(name), do: Process.delete({__MODULE__, name})

  defp cleanup_provider_resource do
    case forget_resource(:provider) do
      nil -> :ok
      provider -> Provider.stop(provider)
    end
  end

  defp cleanup_application_resource do
    case forget_resource(:restore) do
      nil ->
        :ok

      restore ->
        Application.stop(:codex_pooler)
        restore_application_config(restore)
    end
  end

  defp cleanup_inspector_resource do
    case forget_resource(:inspector) do
      nil ->
        :ok

      inspector ->
        release_lock(inspector)
        stop_inspector(inspector)
    end
  end

  defp suppress_debug_logging do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    remember_resource(:logger_level, previous_level)
  end

  defp restore_logger_level do
    case forget_resource(:logger_level) do
      nil -> :ok
      level -> Logger.configure(level: level)
    end
  end

  defmodule Provider do
    @moduledoc false
    use Plug.Router

    @type t :: %{agent: pid(), provider_key: pos_integer(), server: pid(), url: String.t()}

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug :match
    plug :dispatch

    def init(provider_key), do: :persistent_term.get({__MODULE__, provider_key})

    def call(conn, agent) do
      conn
      |> Plug.Conn.put_private(:saved_reset_probe_provider, agent)
      |> super(agent)
    end

    match _ do
      request = %{method: conn.method, path: conn.request_path, json: conn.body_params}

      {response, state} =
        Agent.get_and_update(conn.private.saved_reset_probe_provider, fn state ->
          {response, next_state} = response_for(state, request)
          {{response, next_state}, next_state}
        end)

      maybe_notify_barrier(response, state)
      respond(conn, response)
    end

    @spec start_link(keyword()) :: {:ok, t()} | {:error, term()}
    def start_link(opts) do
      notify = Keyword.fetch!(opts, :notify)

      case Agent.start_link(fn ->
             %{mode: :legacy, requests: [], list_calls: 0, consume_calls: 0, notify: notify}
           end) do
        {:ok, agent} ->
          provider_key = System.unique_integer([:positive])
          :persistent_term.put({__MODULE__, provider_key}, agent)
          start_server(agent, provider_key)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp start_server(agent, provider_key) do
      with {:ok, server} <-
             Bandit.start_link(
               plug: {__MODULE__, provider_key},
               ip: {127, 0, 0, 1},
               port: 0,
               startup_log: false
             ),
           {:ok, {_ip, port}} <- ThousandIsland.listener_info(server) do
        {:ok,
         %{
           agent: agent,
           provider_key: provider_key,
           server: server,
           url: "http://127.0.0.1:#{port}"
         }}
      else
        {:error, reason} -> stop_partial_provider(agent, provider_key, reason)
        :error -> stop_partial_provider(agent, provider_key, :listener_unavailable)
      end
    end

    defp stop_partial_provider(agent, provider_key, reason) do
      :persistent_term.erase({__MODULE__, provider_key})
      safe_stop(fn -> Agent.stop(agent) end)
      {:error, reason}
    end

    def stop(%{agent: agent, provider_key: provider_key, server: server}) do
      safe_stop(fn -> ThousandIsland.stop(server) end)
      :persistent_term.erase({__MODULE__, provider_key})
      safe_stop(fn -> Agent.stop(agent) end)
      :ok
    end

    def configure(%{agent: agent}, mode),
      do: Agent.update(agent, &%{&1 | mode: mode, requests: [], list_calls: 0, consume_calls: 0})

    def release(provider_pid) do
      send(provider_pid, :saved_reset_probe_release)
      :ok
    end

    def request_count(%{agent: agent}), do: Agent.get(agent, &length(&1.requests))
    def consume_count(%{agent: agent}), do: Agent.get(agent, & &1.consume_calls)

    def consume_requests(%{agent: agent}) do
      Agent.get(agent, fn state ->
        state.requests
        |> Enum.filter(fn request -> request.path =~ "consume" end)
        |> Enum.reverse()
        |> Enum.map(fn request -> request.json end)
      end)
    end

    defp response_for(%{mode: :sibling} = state, %{path: path} = request) do
      state = %{state | requests: [request | state.requests]}

      case path do
        "/api/codex/rate-limit-reset-credits/consume" when state.consume_calls == 0 ->
          {{:barrier, %{code: "reset"}}, %{state | consume_calls: 1}}

        "/api/codex/rate-limit-reset-credits/consume" ->
          {{:json, 500, %{code: "unexpected_second_consume"}},
           %{state | consume_calls: state.consume_calls + 1}}

        "/api/codex/usage" ->
          {{:json, 200, usage_payload(0)}, state}

        _other ->
          {{:json, 404, %{}}, state}
      end
    end

    defp response_for(%{mode: :ambiguous} = state, %{path: path} = request) do
      state = %{state | requests: [request | state.requests]}

      case path do
        "/backend-api/wham/rate-limit-reset-credits" ->
          credits =
            if state.list_calls == 0,
              do: [credit("a"), credit("b")],
              else: [credit("b"), credit("a")]

          {{:json, 200, %{credits: credits}}, %{state | list_calls: state.list_calls + 1}}

        "/backend-api/wham/rate-limit-reset-credits/consume" when state.consume_calls == 0 ->
          {:close, %{state | consume_calls: 1}}

        "/backend-api/wham/rate-limit-reset-credits/consume" ->
          {{:json, 200, %{code: "reset"}}, %{state | consume_calls: state.consume_calls + 1}}

        "/backend-api/wham/usage" ->
          {{:json, 200, usage_payload(0)}, state}

        _other ->
          {{:json, 404, %{}}, state}
      end
    end

    defp response_for(state, request),
      do:
        {{:json, 500, %{code: "legacy_provider_called"}},
         %{state | requests: [request | state.requests]}}

    defp maybe_notify_barrier({:barrier, _payload}, state) do
      send(state.notify, {:saved_reset_probe_provider_barrier, self(), :sibling})

      receive do
        :saved_reset_probe_release -> :ok
      after
        15_000 -> raise "saved-reset provider barrier was not released"
      end
    end

    defp maybe_notify_barrier(_response, _state), do: :ok

    defp respond(conn, {:json, status, payload}),
      do:
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(payload))

    defp respond(conn, {:barrier, payload}),
      do:
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(payload))

    defp respond(_conn, :close), do: Process.exit(self(), :kill)
    defp credit(suffix), do: %{"id" => "dev-credit-#{suffix}", "status" => "available"}

    defp usage_payload(available_count),
      do: %{
        "rate_limit_reset_credits" => %{"available_count" => available_count},
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 10,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          }
        }
      }

    defp safe_stop(fun) do
      fun.()
    catch
      :exit, _reason -> :ok
    end
  end
end
