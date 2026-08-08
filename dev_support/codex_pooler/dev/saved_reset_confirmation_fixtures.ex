defmodule CodexPooler.Dev.SavedResetConfirmationFixtures do
  @moduledoc """
  Run-scoped synthetic saved-reset states for local rendered confirmation.

  Every primary key is generated and journaled before insertion. Cleanup uses
  only those exact keys, so a crashed seed can be resumed without prefix scans.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @database "codex_pooler_dev"
  @lock_namespace "codex-pooler:saved-reset-confirmation-fixtures"
  @journal_root Path.join(["tmp", "saved-reset-confirmation-fixtures"])
  @scenarios ~w(absent exhausted candidate_progression blocker_sibling blocker_circuit confirmed not_applied expired circuit_recovery usage_unavailable)
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

    case Postgrex.start_link(config) do
      {:ok, inspector} ->
        try do
          case Postgrex.query(
                 inspector,
                 "SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))",
                 [@lock_namespace, Keyword.fetch!(repo_config, :database)]
               ) do
            {:ok, %{rows: [[true]]}} ->
              {:ok, function.()}

            {:ok, %{rows: [[false]]}} ->
              {:error, "another saved-reset confirmation fixture run is active"}

            _unavailable ->
              {:error, "saved-reset confirmation fixture lock could not connect"}
          end
        after
          if Process.alive?(inspector) do
            _ = Postgrex.query(inspector, "SELECT pg_advisory_unlock_all()", [])
            GenServer.stop(inspector)
          end
        end

      {:error, _reason} ->
        {:error, "saved-reset confirmation fixture lock could not connect"}
    end
  end

  @spec read_journal!(String.t()) :: map()
  def read_journal!(journal_path) do
    journal_path
    |> File.read!()
    |> Jason.decode!()
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
            metadata: scenario_metadata(scenario, now),
            created_at: now,
            updated_at: now
          })

        maybe_crash!(opts, :identity)

        case scenario_quota_windows(scenario, now) do
          [] ->
            :ok

          windows ->
            {:ok, _windows} =
              Windows.upsert_quota_windows(identity, windows,
                delete_missing?: false,
                broadcast?: false
              )
        end

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

      Repo.delete_all(
        from identity in UpstreamIdentity, where: identity.id in ^journal["identity_ids"]
      )

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
         {:ok, journal} <- Jason.decode(encoded) do
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

    File.write!(
      temporary,
      Jason.encode!(%{"email" => browser_auth.email, "password" => browser_auth.password})
    )

    File.chmod!(temporary, 0o600)
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
         {:ok, auth} <- Jason.decode(encoded),
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
    File.write!(temporary, Jason.encode!(journal))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end

  defp scenario_metadata("absent", _now), do: %{}

  defp scenario_metadata(scenario, now) do
    base = %{
      "saved_resets" => %{
        "status" => if(scenario == "usage_unavailable", do: "unavailable", else: "reported"),
        "available_count" => if(scenario in ["not_applied", "expired"], do: 0, else: 1),
        "source" => "synthetic_fixture",
        "observed_at" => DateTime.to_iso8601(now),
        "reason" => if(scenario == "usage_unavailable", do: "usage_unavailable", else: nil)
      },
      "fixture_scenario" => scenario
    }

    case scenario do
      "candidate_progression" -> put_lifecycle(base, "redeeming", "consumed_pending_probe", now)
      "confirmed" -> put_lifecycle(base, "succeeded", "confirmed_by_quota", now)
      "not_applied" -> put_lifecycle(base, "failed", "consume_not_applied", now)
      "expired" -> put_lifecycle(base, "failed", "expired", now)
      "blocker_sibling" -> put_lifecycle(base, "failed", "reblocked", now)
      "blocker_circuit" -> put_lifecycle(base, "failed", "reblocked", now)
      "circuit_recovery" -> Map.put(base, "saved_reset_recovery", "circuit_open")
      _other -> base
    end
  end

  defp scenario_quota_windows(scenario, now)
       when scenario in ["blocker_sibling", "blocker_circuit"] do
    [
      confirmation_quota_window("secondary", 10_080, now),
      confirmation_quota_window("primary", 300, now)
    ]
  end

  defp scenario_quota_windows(_scenario, _now), do: []

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
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "started_at" => DateTime.to_iso8601(now),
      "consumed_at" => DateTime.to_iso8601(now),
      "deadline_at" => now |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => DateTime.to_iso8601(now)
    })
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
