defmodule CodexPooler.Dev.SavedResetConfirmationFixtures do
  @moduledoc """
  Run-scoped synthetic saved-reset states for local rendered confirmation.

  Every primary key is generated and journaled before insertion. Cleanup uses
  only those exact keys, so a crashed seed can be resumed without prefix scans.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, Pool}
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore}
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @database "codex_pooler_dev"
  @lock_namespace "codex-pooler:saved-reset-confirmation-fixtures"
  @journal_root Path.join(["tmp", "saved-reset-confirmation-fixtures"])
  @scenarios ~w(absent exhausted candidate_progression blocker_sibling blocker_circuit confirmed not_applied expired circuit_recovery usage_unavailable queued processing request_completed request_ended unknown applied_pending provisional no_credit nothing_to_reset reblocked poll_paused)
  @controls ~w(visibility_loss visibility_restore source_removed source_restore)
  @journal_keys ~w(actor_membership_ids actor_operator_pool_assignment_ids actor_user_ids assignment_ids browser_auth_path identity_ids pool_ids run_fingerprint scenario status)

  @type receipt :: %{
          required(:journal_path) => String.t(),
          required(:browser_auth_path) => String.t() | nil,
          required(:run_fingerprint) => String.t(),
          required(:scenario_count) => pos_integer(),
          required(:status) => String.t()
        }

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios

  @spec validate_environment(atom(), keyword(), boolean()) :: :ok | {:error, String.t()}
  def validate_environment(environment, repo_config, allow_test_database \\ false) do
    cond do
      environment == :dev and Keyword.get(repo_config, :database) == @database ->
        :ok

      environment == :test and allow_test_database ->
        :ok

      environment != :dev ->
        {:error, "saved-reset confirmation fixtures run only with MIX_ENV=dev"}

      true ->
        {:error, "saved-reset confirmation fixtures require database #{@database}"}
    end
  end

  @spec seed(String.t(), keyword()) :: {:ok, receipt()} | {:error, String.t()}
  def seed(scenario, opts \\ []) do
    repo_config = Keyword.get(opts, :repo_config, Repo.config())

    with :ok <-
           validate_environment(
             Keyword.get(opts, :environment, Mix.env()),
             repo_config,
             Keyword.get(opts, :allow_test_database, false)
           ),
         {:ok, selected} <- select_scenarios(scenario) do
      with_advisory_lock(repo_config, fn -> seed_locked(selected, opts) end)
      |> flatten_lock_result()
    end
  end

  @doc "Changes one exact journaled identity in place; never selects a target by label."
  @spec transition(String.t(), Ecto.UUID.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def transition(journal_path, identity_id, scenario, opts \\ []) do
    repo_config = Keyword.get(opts, :repo_config, Repo.config())
    root = Keyword.get(opts, :journal_root, @journal_root)

    with :ok <- validate_environment(Keyword.get(opts, :environment, Mix.env()), repo_config, Keyword.get(opts, :allow_test_database, false)),
         true <- scenario in (@scenarios ++ @controls),
         true <- Path.dirname(Path.expand(journal_path)) == Path.expand(root),
         {:ok, journal} <- read_journal(journal_path),
         true <- journal["status"] == "ready",
         true <- control_allowed?(journal, scenario),
         true <- identity_id in journal["identity_ids"],
         true <- Keyword.get(opts, :expected_run_fingerprint, journal["run_fingerprint"]) == journal["run_fingerprint"] do
      with_advisory_lock(repo_config, fn -> transition_locked(journal, identity_id, scenario) end)
      |> flatten_lock_result()
    else
      _invalid -> {:error, "invalid or unowned saved-reset fixture transition"}
    end
  end

  defp control_allowed?(journal, scenario) when scenario in ["visibility_loss", "visibility_restore"], do: length(journal["actor_user_ids"]) == 1
  defp control_allowed?(_journal, _scenario), do: true

  defp transition_locked(journal, identity_id, scenario) do
    Repo.transaction(fn -> update_owned_identity(journal, identity_id, scenario) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_owned_identity(journal, identity_id, scenario) do
    index = Enum.find_index(journal["identity_ids"], &(&1 == identity_id))
    assignment_id = Enum.at(journal["assignment_ids"], index)
    identity = Repo.get!(UpstreamIdentity, identity_id)
    assignment = Repo.get!(PoolUpstreamAssignment, assignment_id)
    unless assignment.upstream_identity_id == identity_id and assignment.pool_id in journal["pool_ids"], do: Repo.rollback("fixture ownership mismatch")
    apply_owned_transition(journal, identity, assignment, scenario)
  end

  defp apply_owned_transition(journal, identity, assignment, scenario) when scenario in @controls do
    apply_control(journal, identity, scenario)
    broadcast_transition(assignment.pool_id, identity.id)
    {:ok, %{scenario: scenario, run_fingerprint: journal["run_fingerprint"]}}
  end

  defp apply_owned_transition(journal, identity, assignment, scenario) do
    identity_id = identity.id
    assignment_id = assignment.id
    clear_fixture_jobs([assignment_id])
    now = DateTime.utc_now()
    updated = identity |> Ecto.Changeset.change(metadata: scenario_metadata(scenario, now)) |> Repo.update!()

    write_scenario_windows!(updated, scenario, now)

    insert_scenario_request(scenario, updated.id, assignment_id)
    broadcast_transition(assignment.pool_id, identity_id)
    {:ok, %{scenario: scenario, run_fingerprint: journal["run_fingerprint"]}}
  end

  @spec cleanup(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def cleanup(journal_path, opts \\ []) do
    repo_config = Keyword.get(opts, :repo_config, Repo.config())
    journal_root = Keyword.get(opts, :journal_root, @journal_root)

    with :ok <-
           validate_environment(
             Keyword.get(opts, :environment, Mix.env()),
             repo_config,
             Keyword.get(opts, :allow_test_database, false)
           ) do
      with_advisory_lock(repo_config, fn -> cleanup_locked(journal_path, journal_root) end)
      |> flatten_lock_result()
    end
  end

  @spec with_advisory_lock(keyword(), (-> term())) ::
          {:ok, term()} | {:error, String.t()}
  def with_advisory_lock(repo_config, function) when is_function(function, 0) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    config =
      repo_config
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
      |> Keyword.put(:parameters, application_name: "saved_reset_confirmation_fixture_lock")
      # One-shot inspector: an unreachable database must fail in a fraction of
      # a second instead of waiting out the pool's default queue budget.
      |> Keyword.merge(queue_target: 100, queue_interval: 200)

    case Postgrex.start_link(config) do
      {:ok, inspector} ->
        lock_result =
          Postgrex.query(
            inspector,
            "SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))",
            [@lock_namespace, Keyword.fetch!(repo_config, :database)]
          )

        try do
          case lock_result do
            {:ok, %{rows: [[true]]}} ->
              {:ok, function.()}

            {:ok, %{rows: [[false]]}} ->
              {:error, "another saved-reset confirmation fixture run is active"}

            _unavailable ->
              {:error, "saved-reset confirmation fixture lock could not connect"}
          end
        after
          release_lock_inspector(inspector, lock_result)
        end

      {:error, _reason} ->
        {:error, "saved-reset confirmation fixture lock could not connect"}
    end
  end

  # Only a held lock needs releasing; a failed lock query means no
  # connection, and a second query would just wait out the budget again.
  defp release_lock_inspector(inspector, lock_result) do
    if Process.alive?(inspector) do
      if match?({:ok, %{rows: [[true]]}}, lock_result) do
        _ = Postgrex.query(inspector, "SELECT pg_advisory_unlock_all()", [])
      end

      GenServer.stop(inspector)
    end
  end

  @spec read_journal!(String.t()) :: map()
  def read_journal!(journal_path) do
    journal_path
    |> File.read!()
    |> CodexPooler.JSON.decode!()
    |> validate_journal!()
  end

  defp seed_locked(selected, opts) do
    root = Keyword.get(opts, :journal_root, @journal_root)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    case Path.wildcard(Path.join(root, "*.json")) do
      [] -> create_seed(selected, root, opts)
      _journals -> {:error, "an active saved-reset confirmation fixture journal requires cleanup"}
    end
  end

  defp create_seed(selected, root, opts) do
    run_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    pool_id = Ecto.UUID.generate()
    identity_ids = Enum.map(selected, fn _scenario -> Ecto.UUID.generate() end)
    assignment_ids = Enum.map(selected, fn _scenario -> Ecto.UUID.generate() end)
    journal_path = Path.join(root, "#{run_id}.json")
    browser_auth = browser_auth_fixture(run_id, opts)

    journal = %{
      "actor_membership_ids" => browser_auth.membership_ids,
      "actor_operator_pool_assignment_ids" => browser_auth.operator_pool_assignment_ids,
      "actor_user_ids" => browser_auth.user_ids,
      "run_fingerprint" => fingerprint(run_id),
      "scenario" => Enum.join(selected, ","),
      "status" => "seeding",
      "pool_ids" => [pool_id],
      "identity_ids" => identity_ids,
      "assignment_ids" => assignment_ids,
      "browser_auth_path" => browser_auth.path
    }

    write_journal!(journal_path, journal)

    try do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      write_browser_auth!(root, browser_auth)

      maybe_crash!(opts, :browser_auth_file)

      Repo.insert!(%Pool{
        id: pool_id,
        slug: "dev-saved-reset-#{fingerprint(run_id)}",
        name: "Dev saved-reset confirmation",
        status: "active",
        created_at: now,
        updated_at: now
      })

      maybe_crash!(opts, :pool)

      insert_browser_auth_actor!(browser_auth, pool_id, now)

      maybe_crash!(opts, :browser_auth_actor)

      Enum.zip([selected, identity_ids, assignment_ids])
      |> Enum.each(fn {scenario, identity_id, assignment_id} ->
        identity =
          Repo.insert!(%UpstreamIdentity{
            id: identity_id,
            chatgpt_account_id: "dev-saved-reset-#{fingerprint(identity_id)}",
            account_label: "Saved reset #{String.replace(scenario, "_", " ")}",
            onboarding_method: "import",
            status: "active",
            headers_profile_version: 1,
            auth_fresh_at: now,
            metadata: scenario_metadata(scenario, now),
            created_at: now,
            updated_at: now
          })

        maybe_crash!(opts, :identity)

        {:ok, _secret} = Upstreams.store_encrypted_secret(identity, %{secret_kind: "access_token", plaintext: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)})

        write_scenario_windows!(identity, scenario, now)

        Repo.insert!(%PoolUpstreamAssignment{
          id: assignment_id,
          pool_id: pool_id,
          upstream_identity_id: identity_id,
          assignment_label: "Saved reset #{String.replace(scenario, "_", " ")}",
          status: "active",
          health_status: "active",
          eligibility_status: "eligible",
          metadata: %{"fixture_scenario" => scenario},
          created_at: now,
          updated_at: now
        })

        maybe_crash!(opts, :assignment)
      end)

      Enum.zip([selected, identity_ids, assignment_ids]) |> Enum.each(fn {scenario, identity_id, assignment_id} -> insert_scenario_request(scenario, identity_id, assignment_id) end)

      ready = Map.put(journal, "status", "ready")
      write_journal!(journal_path, ready)

      {:ok,
       %{
         journal_path: journal_path,
         browser_auth_path: browser_auth_path(journal_path, journal),
         run_fingerprint: journal["run_fingerprint"],
         scenario_count: length(selected),
         status: "ready"
       }}
    rescue
      exception ->
        {:error, "fixture seed failed; cleanup journal retained: #{Exception.message(exception)}"}
    end
  end

  defp cleanup_locked(journal_path, journal_root) do
    expanded_root = Path.expand(journal_root)
    expanded_path = Path.expand(journal_path)

    if Path.dirname(expanded_path) != expanded_root do
      {:error, "fixture journal is outside the configured journal root"}
    else
      cleanup_journal(expanded_path)
    end
  end

  defp cleanup_journal(journal_path) do
    with {:ok, journal} <- read_journal(journal_path),
         {:ok, auth_path} <- validate_browser_auth_file(journal_path, journal) do
      clear_fixture_jobs(journal["assignment_ids"])

      Repo.delete_all(
        from assignment in OperatorPoolAssignment,
          where: assignment.id in ^journal["actor_operator_pool_assignment_ids"]
      )

      Repo.delete_all(
        from membership in Membership,
          where: membership.id in ^journal["actor_membership_ids"]
      )

      Repo.delete_all(
        from audit_event in AuditEvent,
          where: audit_event.actor_user_id in ^journal["actor_user_ids"]
      )

      Repo.delete_all(from user in User, where: user.id in ^journal["actor_user_ids"])

      Repo.delete_all(
        from assignment in PoolUpstreamAssignment,
          where: assignment.id in ^journal["assignment_ids"]
      )

      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^journal["identity_ids"])

      Repo.delete_all(from pool in Pool, where: pool.id in ^journal["pool_ids"])

      if owned_row_count(journal) == 0 do
        remove_browser_auth!(auth_path)
        File.rm!(journal_path)
        {:ok, %{cleanup: "exact_owned_rows_removed", run_fingerprint: journal["run_fingerprint"]}}
      else
        {:error, "journaled fixture rows remain after cleanup"}
      end
    end
  end

  defp validate_journal!(journal) do
    valid? =
      is_map(journal) and
        Enum.sort(Map.keys(journal)) == @journal_keys and
        journal["status"] in ["seeding", "ready"] and
        is_binary(journal["scenario"]) and
        journal["run_fingerprint"] =~ ~r/\A[0-9a-f]{12}\z/ and
        valid_ids?(journal, ~w(pool_ids identity_ids assignment_ids)) and
        valid_browser_auth_journal?(journal)

    if valid?, do: journal, else: raise("invalid saved-reset confirmation fixture journal")
  end

  defp valid_ids?(journal, keys) do
    Enum.all?(keys, fn key ->
      is_list(journal[key]) and Enum.all?(journal[key], &(Ecto.UUID.cast(&1) == {:ok, &1}))
    end)
  end

  defp valid_browser_auth_journal?(journal) do
    actor_keys = ~w(actor_user_ids actor_membership_ids actor_operator_pool_assignment_ids)
    actor_lengths = Enum.map(actor_keys, &(journal[&1] |> List.wrap() |> length()))

    case actor_lengths do
      [0, 0, 0] ->
        is_nil(journal["browser_auth_path"])

      [1, 1, 1] ->
        valid_ids?(journal, actor_keys) and
          is_binary(journal["browser_auth_path"]) and
          Path.basename(journal["browser_auth_path"]) == journal["browser_auth_path"] and
          String.ends_with?(journal["browser_auth_path"], ".browser-auth.json")

      _other ->
        false
    end
  end

  defp read_journal(journal_path) do
    with {:ok, encoded} <- File.read(journal_path),
         {:ok, journal} <- CodexPooler.JSON.decode(encoded) do
      try do
        {:ok, validate_journal!(journal)}
      rescue
        RuntimeError -> {:error, "invalid saved-reset confirmation fixture journal"}
      end
    else
      {:error, :enoent} -> {:error, "saved-reset confirmation fixture journal does not exist"}
      _error -> {:error, "invalid saved-reset confirmation fixture journal"}
    end
  end

  defp browser_auth_fixture(run_id, opts) do
    if Keyword.get(opts, :browser_auth, false) do
      %{
        email: "saved-reset-browser-#{fingerprint(run_id)}@fixture.invalid",
        membership_ids: [Ecto.UUID.generate()],
        operator_pool_assignment_ids: [Ecto.UUID.generate()],
        password: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        path: "#{run_id}.browser-auth.json",
        user_ids: [Ecto.UUID.generate()]
      }
    else
      %{
        email: nil,
        membership_ids: [],
        operator_pool_assignment_ids: [],
        password: nil,
        path: nil,
        user_ids: []
      }
    end
  end

  defp insert_browser_auth_actor!(%{user_ids: []}, _pool_id, _now), do: :ok

  defp insert_browser_auth_actor!(browser_auth, pool_id, now) do
    [user_id] = browser_auth.user_ids
    [membership_id] = browser_auth.membership_ids
    [operator_pool_assignment_id] = browser_auth.operator_pool_assignment_ids

    %User{id: user_id}
    |> User.operator_create_changeset(%{
      "display_name" => "Saved reset fixture browser",
      "email" => browser_auth.email,
      "password" => browser_auth.password,
      "password_change_required" => false
    })
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert!()

    Repo.insert!(%Membership{
      id: membership_id,
      user_id: user_id,
      role: "instance_admin",
      status: "active",
      created_by_user_id: user_id,
      created_at: now
    })

    Repo.insert!(%OperatorPoolAssignment{
      id: operator_pool_assignment_id,
      user_id: user_id,
      pool_id: pool_id,
      status: "active",
      created_by_user_id: user_id,
      created_at: now,
      updated_at: now
    })
  end

  defp write_browser_auth!(_root, %{path: nil}), do: :ok

  defp write_browser_auth!(root, browser_auth) do
    path = Path.join(root, browser_auth.path)
    temporary = "#{path}.tmp"

    {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive])
    File.chmod!(temporary, 0o600)

    :ok =
      :file.write(
        file,
        CodexPooler.JSON.encode!(%{
          "email" => browser_auth.email,
          "password" => browser_auth.password
        })
      )

    :ok = :file.close(file)
    File.rename!(temporary, path)
  end

  defp validate_browser_auth_file(_journal_path, %{"browser_auth_path" => nil}), do: {:ok, nil}

  defp validate_browser_auth_file(journal_path, journal) do
    path = browser_auth_path(journal_path, journal)

    with true <- path == Path.rootname(journal_path) <> ".browser-auth.json",
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600,
         {:ok, %{"email" => email, "password" => password}} <- read_browser_auth(path),
         true <- valid_browser_auth_pair?(email, password) do
      {:ok, path}
    else
      _invalid -> {:error, "invalid saved-reset confirmation fixture browser auth file"}
    end
  end

  defp read_browser_auth(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, auth} <- CodexPooler.JSON.decode(encoded),
         true <- Map.keys(auth) |> Enum.sort() == ["email", "password"] do
      {:ok, auth}
    else
      _invalid -> {:error, :invalid_browser_auth}
    end
  end

  defp valid_browser_auth_pair?(email, password) do
    is_binary(email) and
      Regex.match?(~r/\Asaved-reset-browser-[0-9a-f]{12}@fixture\.invalid\z/, email) and
      is_binary(password) and byte_size(password) >= 32
  end

  defp browser_auth_path(_journal_path, %{"browser_auth_path" => nil}), do: nil

  defp browser_auth_path(journal_path, %{"browser_auth_path" => path}) do
    Path.join(Path.dirname(journal_path), path)
  end

  defp remove_browser_auth!(nil), do: :ok
  defp remove_browser_auth!(path), do: File.rm!(path)

  defp owned_row_count(journal) do
    Repo.aggregate(
      from(assignment in OperatorPoolAssignment,
        where: assignment.id in ^journal["actor_operator_pool_assignment_ids"]
      ),
      :count
    ) +
      Repo.aggregate(
        from(membership in Membership, where: membership.id in ^journal["actor_membership_ids"]),
        :count
      ) +
      Repo.aggregate(from(user in User, where: user.id in ^journal["actor_user_ids"]), :count) +
      Repo.aggregate(from(pool in Pool, where: pool.id in ^journal["pool_ids"]), :count) +
      Repo.aggregate(
        from(identity in UpstreamIdentity, where: identity.id in ^journal["identity_ids"]),
        :count
      ) +
      Repo.aggregate(
        from(assignment in PoolUpstreamAssignment,
          where: assignment.id in ^journal["assignment_ids"]
        ),
        :count
      )
  end

  defp write_journal!(path, journal) do
    temporary = "#{path}.tmp"
    File.write!(temporary, CodexPooler.JSON.encode!(journal))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end

  defp scenario_metadata("absent", _now), do: %{}

  defp scenario_metadata(scenario, now) do
    %{"saved_resets" => scenario_saved_resets(scenario, now), "fixture_scenario" => scenario, "base_url" => "http://127.0.0.1:1"}
    |> TokenRefreshMetadata.build_imported(AccessTokenExpiry.known(DateTime.add(now, 1, :day), :explicit), 1, "synthetic_fixture", now)
    |> put_scenario_lifecycle(scenario, now)
  end

  defp scenario_saved_resets(scenario, now) do
    unavailable? = scenario == "usage_unavailable"

    %{
      "status" => if(unavailable?, do: "unavailable", else: "reported"),
      "available_count" => if(scenario in ["not_applied", "no_credit", "request_ended", "expired"], do: 0, else: 1),
      "source" => "synthetic_fixture",
      "observed_at" => DateTime.to_iso8601(now),
      "reason" => if(unavailable?, do: "usage_unavailable", else: nil)
    }
  end

  defp put_scenario_lifecycle(base, scenario, now) when scenario in ["candidate_progression", "applied_pending", "poll_paused", "request_completed"], do: put_lifecycle(base, "redeeming", "consumed_pending_probe", DateTime.add(now, -120, :second))
  defp put_scenario_lifecycle(base, "confirmed", now), do: put_lifecycle(base, "succeeded", "confirmed_by_quota", DateTime.add(now, -120, :second))
  defp put_scenario_lifecycle(base, "processing", now), do: put_lifecycle(base, "redeeming", "consuming", now)
  defp put_scenario_lifecycle(base, "unknown", now), do: put_lifecycle(base, "redeeming", "consuming", DateTime.add(now, -600, :second)) |> put_in(["saved_reset_redemption", "provider_replay"], %{"version" => 1, "provider_dispatches" => 1, "state" => "ambiguous"})
  defp put_scenario_lifecycle(base, "provisional", now), do: put_lifecycle(base, "succeeded", "confirmed_by_upstream", DateTime.add(now, -120, :second))
  defp put_scenario_lifecycle(base, scenario, now) when scenario in ["no_credit", "nothing_to_reset"], do: put_noop(base, scenario, now)
  defp put_scenario_lifecycle(base, "request_ended", now), do: put_noop(base, "no_credit", now)
  defp put_scenario_lifecycle(base, scenario, now) when scenario in ["reblocked", "blocker_sibling", "blocker_circuit"], do: put_lifecycle(base, "failed", "reblocked", now)
  defp put_scenario_lifecycle(base, "not_applied", now), do: put_noop(base, "consume_not_applied", now)
  defp put_scenario_lifecycle(base, "expired", now), do: put_lifecycle(base, "failed", "expired", DateTime.add(now, -1200, :second))
  defp put_scenario_lifecycle(base, "circuit_recovery", _now), do: Map.put(base, "saved_reset_recovery", "circuit_open")
  defp put_scenario_lifecycle(base, _scenario, _now), do: base

  defp scenario_quota_windows("absent", _now), do: []

  defp scenario_quota_windows(scenario, now) when scenario in ["blocker_sibling", "blocker_circuit"] do
    [confirmation_quota_window("secondary", 10_080, now), confirmation_quota_window("primary", 300, now)]
  end

  defp scenario_quota_windows(scenario, now) do
    observed = DateTime.add(now, -180, :second)
    base = confirmation_quota_window("secondary", 10_080, observed) |> Map.put(:reset_at, DateTime.add(now, 6, :day))
    base = if scenario == "confirmed", do: %{base | used_percent: 20, observed_at: DateTime.add(now, -60, :second), last_sync_at: DateTime.add(now, -60, :second)}, else: base
    [base, Map.put(base, :source, "codex_rate_limit_event")]
  end

  defp write_scenario_windows!(identity, scenario, now) do
    attrs = scenario_quota_windows(scenario, now)

    # These are explicitly synthetic presentation facts, not provider-acceptance proof.
    # Upsert resolves retained row identity; the owned row patch installs the chosen contract shape.
    case attrs do
      [] ->
        :ok

      _ ->
        {:ok, windows} = Windows.upsert_quota_windows(identity, attrs, delete_missing?: false, broadcast?: false)

        Enum.each(attrs, fn attrs ->
          window = Enum.find(windows, &(Evidence.identity_key(&1) == Evidence.identity_key(attrs)))
          attrs = seed_window_metadata(attrs, scenario, now)
          window |> AccountQuotaWindow.changeset(attrs) |> Repo.update!()
        end)
    end
  end

  defp seed_window_metadata(attrs, "candidate_progression", now) do
    {:ok, evidence} = Evidence.new(%{attrs | used_percent: 32, observed_at: DateTime.add(now, -60, :second), last_sync_at: DateTime.add(now, -60, :second)} |> Map.put(:metadata, %{"rate_limit_allowed" => true, "rate_limit_reached" => false}), DateTime.add(now, -60, :second))
    Map.put(attrs, :metadata, EvidenceStore.put_candidate(%{}, evidence))
  end

  defp seed_window_metadata(attrs, "confirmed", now) do
    attrs = Map.put(attrs, :metadata, %{"rate_limit_allowed" => true, "rate_limit_reached" => false, "reset_after_seconds" => DateTime.diff(attrs.reset_at, attrs.observed_at), "limit_window_seconds" => attrs.window_minutes * 60})
    {:ok, evidence} = Evidence.new(attrs, attrs.observed_at)
    CycleConfirmation.confirm(attrs, evidence, now)
  end

  defp seed_window_metadata(attrs, _scenario, _now), do: Map.put(attrs, :metadata, %{})

  defp apply_control(journal, identity, scenario) when scenario in ["visibility_loss", "visibility_restore"] do
    [user_id] = journal["actor_user_ids"]
    status = if scenario == "visibility_loss", do: "revoked", else: "active"
    revoked_at = if status == "revoked", do: DateTime.utc_now(), else: nil
    {1, _} = Repo.update_all(from(m in Membership, where: m.id in ^journal["actor_membership_ids"] and m.user_id == ^user_id), set: [status: status, revoked_at: revoked_at])
    {1, _} = Repo.update_all(from(a in OperatorPoolAssignment, where: a.id in ^journal["actor_operator_pool_assignment_ids"] and a.user_id == ^user_id and a.pool_id in ^journal["pool_ids"]), set: [status: status, revoked_at: revoked_at])
    identity
  end

  defp apply_control(_journal, identity, "source_removed") do
    window = Repo.one(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id and window.source == "codex_rate_limit_event" and window.quota_key == "account" and window.quota_scope == "account" and window.window_kind == "secondary" and window.window_minutes == 10_080)
    if window, do: Repo.delete!(window), else: Repo.rollback("owned quota source not found")
  end

  defp apply_control(_journal, identity, "source_restore") do
    scenario = identity.metadata["fixture_scenario"]
    unless scenario in @scenarios, do: Repo.rollback("fixture scenario missing")
    write_scenario_windows!(identity, scenario, DateTime.utc_now())
  end

  defp broadcast_transition(pool_id, identity_id), do: CodexPooler.Events.broadcast_upstreams_after_commit(pool_id, "upstream_account_saved_reset_redeemed", %{upstream_identity_id: identity_id})

  defp confirmation_quota_window(window_kind, window_minutes, now) do
    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: window_kind,
      window_minutes: window_minutes,
      used_percent: 100,
      reset_at: DateTime.add(now, window_minutes, :minute),
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh"
    }
  end

  defp put_lifecycle(metadata, status, phase, now) do
    Map.put(metadata, "saved_reset_redemption", %{
      "status" => status,
      "phase" => phase,
      "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}],
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "started_at" => DateTime.to_iso8601(now),
      "consumed_at" => DateTime.to_iso8601(now),
      "deadline_at" => now |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => if(phase in ["consuming", "consumed_pending_probe"], do: nil, else: DateTime.to_iso8601(now)),
      "result" => if(phase == "consuming", do: nil, else: %{"applied" => true, "code" => "reset"}),
      "provider_replay" => if(phase == "consume_not_applied", do: %{"version" => 1, "provider_dispatches" => 0}, else: nil)
    })
    |> then(fn metadata ->
      if phase == "consuming", do: update_in(metadata, ["saved_reset_redemption"], &Map.drop(&1, ["consumed_at", "deadline_at"])), else: metadata
    end)
  end

  defp put_noop(base, code, now) do
    base |> put_lifecycle("failed", "consume_not_applied", now) |> put_in(["saved_reset_redemption", "result"], %{"applied" => false, "code" => code}) |> update_in(["saved_reset_redemption"], &Map.drop(&1, ["consumed_at", "deadline_at"]))
  end

  defp insert_scenario_request(scenario, identity_id, assignment_id) when scenario in ["queued", "processing", "request_completed", "request_ended"] do
    assignment = Repo.get!(PoolUpstreamAssignment, assignment_id)
    unless assignment.upstream_identity_id == identity_id, do: raise("fixture request target mismatch")
    job = SavedResetRedemptionWorker.new(%{"pool_upstream_assignment_id" => assignment.id, "manual_request_target" => %{"upstream_identity_id" => assignment.upstream_identity_id, "pool_id" => assignment.pool_id}, "trigger_kind" => "admin_manual"}) |> Repo.insert!()
    now = DateTime.utc_now()

    # Finished requests carry the worker's own end states: `completed` after an applied reset, `discarded` after a no-op.
    case scenario do
      "queued" -> job
      "processing" -> job |> Ecto.Changeset.change(state: "executing", attempted_at: now) |> Repo.update!()
      "request_completed" -> job |> Ecto.Changeset.change(state: "completed", attempt: 1, attempted_at: now, completed_at: now) |> Repo.update!()
      "request_ended" -> job |> Ecto.Changeset.change(state: "discarded", attempt: 1, attempted_at: now, discarded_at: now) |> Repo.update!()
    end

    :ok
  end

  defp insert_scenario_request("poll_paused", identity_id, _assignment_id) do
    identity = Repo.get!(UpstreamIdentity, identity_id)
    now = DateTime.utc_now()
    {:ok, _} = UsagePollCooldown.record(identity_id, UsagePollCooldown.current_scope(identity), "http://127.0.0.1:1", 429, DateTime.add(now, 600, :second), now)
    :ok
  end

  defp insert_scenario_request(_scenario, _identity_id, _assignment_id), do: :ok

  defp clear_fixture_jobs(assignment_ids) do
    Repo.delete_all(from job in Oban.Job, where: job.worker == "CodexPooler.Jobs.SavedResetRedemptionWorker" and job.args["pool_upstream_assignment_id"] in ^assignment_ids)
  end

  defp select_scenarios("all"), do: {:ok, @scenarios}
  defp select_scenarios(scenario) when scenario in @scenarios, do: {:ok, [scenario]}

  defp select_scenarios(_scenario),
    do: {:error, "unknown saved-reset confirmation fixture scenario"}

  defp flatten_lock_result({:ok, {:ok, result}}), do: {:ok, result}
  defp flatten_lock_result({:ok, {:error, reason}}), do: {:error, reason}
  defp flatten_lock_result({:error, reason}), do: {:error, reason}

  defp maybe_crash!(opts, phase) do
    if Keyword.get(opts, :crash_after) == phase, do: raise("injected crash after #{phase}")
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
