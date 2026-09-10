defmodule CodexPooler.Metrics.AccountSnapshot do
  @moduledoc "Read-only, bounded account metadata snapshot. Never loads credentials."

  alias CodexPooler.Metrics.{AccountProjection, AccountPrometheus}
  alias CodexPooler.Repo

  @deadline_ms 5_000
  @window_fields ~w(id upstream_identity_id quota_key window_kind window_minutes active_limit credits reset_at used_percent limit_name metered_feature source source_precision quota_scope quota_family model upstream_model raw_limit_id raw_limit_name raw_metered_feature freshness_state last_sync_at observed_at merge_precedence updated_at)a

  @column_keys Map.new(
                 @window_fields ++
                   ~w(status disabled_at credential_provenance metadata pool_id health_status eligibility_status last_successful_refresh_at reconciliation_status reconciliation_finished_at row_count index_model index_upstream_model)a,
                 &{Atom.to_string(&1), &1}
               )

  @identities_sql """
  SELECT id::text, status, disabled_at, credential_provenance,
         jsonb_build_object('credential_epoch', metadata->'credential_epoch',
           'quota_account_availability', metadata->'quota_account_availability') AS metadata
  FROM upstream_identities WHERE status IS DISTINCT FROM 'deleted' ORDER BY id
  """

  @memberships_sql """
  SELECT upstream_identity_id::text, pool_id::text, status, health_status,
         eligibility_status, last_successful_refresh_at,
         reconciliation_status, reconciliation_finished_at, row_count
  FROM (
    SELECT a.upstream_identity_id, a.pool_id, a.status, a.health_status,
           a.eligibility_status, a.last_successful_refresh_at,
           CASE WHEN jsonb_typeof(a.metadata->'last_reconciliation'->'status') = 'string'
             THEN a.metadata->'last_reconciliation'->>'status' END AS reconciliation_status,
           CASE WHEN jsonb_typeof(a.metadata->'last_reconciliation'->'finished_at') = 'string'
             THEN a.metadata->'last_reconciliation'->>'finished_at' END AS reconciliation_finished_at,
           count(*) OVER (PARTITION BY a.upstream_identity_id) AS row_count,
           row_number() OVER (PARTITION BY a.upstream_identity_id ORDER BY a.pool_id) AS position
    FROM pool_upstream_assignments a
    JOIN upstream_identities i ON i.id = a.upstream_identity_id
    WHERE i.status IS DISTINCT FROM 'deleted' AND a.status IS DISTINCT FROM 'deleted'
  ) bounded WHERE position <= 65 ORDER BY upstream_identity_id, pool_id
  """

  @doc "Builds each response afresh; failures expose health only and no stale account cache."
  def scrape(loader \\ &load/0) do
    started = System.monotonic_time(:microsecond)
    result = collect(loader)
    elapsed = (System.monotonic_time(:microsecond) - started) / 1_000_000
    render(result, elapsed)
  end

  defp render(result, elapsed) do
    AccountPrometheus.render(result, elapsed)
  rescue
    _exception -> AccountPrometheus.render({:error, :collection_failed}, elapsed)
  end

  defp collect(loader) do
    with {:ok, snapshot} <- loader.(), do: {:ok, AccountProjection.project(snapshot)}
  rescue
    _exception -> {:error, :collection_failed}
  catch
    :exit, _reason -> {:error, :collection_failed}
  end

  @doc "Returns a fresh snapshot or a fixed error; database exception text is never exposed."
  def load(repo \\ Repo) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    # DBConnection arms its deadline only after checkout succeeds. A single
    # owned stream task also bounds a completely occupied connection pool.
    # The stream kills and awaits its worker on timeout or caller termination;
    # it never leaves a detached collector waiting to query after this return.
    [repo]
    |> Task.async_stream(&read_snapshot(&1, deadline),
      max_concurrency: 1,
      timeout: remaining(deadline),
      on_timeout: :kill_task
    )
    |> Enum.to_list()
    |> collection_result()
  rescue
    _exception -> {:error, :snapshot_unavailable}
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end

  defp collection_result([{:ok, result}]), do: normalize_result(result)
  defp collection_result(_result), do: {:error, :snapshot_unavailable}

  defp read_snapshot(repo, deadline) do
    repo.transaction(
      fn ->
        query(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", deadline)
        as_of = DateTime.utc_now()
        identities = query(repo, @identities_sql, deadline)
        memberships = query(repo, @memberships_sql, deadline)
        windows = query(repo, windows_sql(), deadline)
        %{as_of: as_of, identities: identities, memberships: memberships, windows: windows}
      end,
      timeout: remaining(deadline),
      log: false
    )
    |> normalize_result()
  rescue
    _exception -> {:error, :snapshot_unavailable}
  catch
    :exit, _reason -> {:error, :snapshot_unavailable}
  end

  defp normalize_result({:ok, snapshot}), do: {:ok, snapshot}
  defp normalize_result(_result), do: {:error, :snapshot_unavailable}

  defp query(repo, sql, deadline) do
    result = repo.query!(sql, [], timeout: remaining(deadline), log: false)

    Enum.map(result.rows || [], fn values ->
      result.columns
      |> Enum.zip(values)
      |> Map.new(fn {key, value} -> {Map.fetch!(@column_keys, key), value} end)
    end)
  end

  # The 513th/65th row is an overflow sentinel. Counts are per identity; no
  # global LIMIT can quietly omit accounts later in the ordering.
  defp windows_sql do
    columns = Enum.map_join(@window_fields, ", ", &"w.#{&1}")
    projected = Enum.map_join(@window_fields, ", ", &projected_column/1)

    """
    SELECT #{projected}, metadata, index_model, index_upstream_model, row_count
    FROM (
      SELECT #{columns},
             #{window_metadata_sql()} AS metadata,
             COALESCE(lower(w.model), '') AS index_model,
             COALESCE(lower(w.upstream_model), '') AS index_upstream_model,
             count(*) OVER (PARTITION BY w.upstream_identity_id) AS row_count,
             row_number() OVER (PARTITION BY w.upstream_identity_id ORDER BY w.id) AS position
      FROM account_quota_windows w
      JOIN upstream_identities i ON i.id = w.upstream_identity_id
      WHERE i.status IS DISTINCT FROM 'deleted'
    ) bounded WHERE position <= 513 ORDER BY upstream_identity_id, id
    """
  end

  defp window_metadata_sql do
    scalars = ~w(rate_limit_allowed rate_limit_reached reset_state)
    marker = "w.metadata->'__quota_cycle_confirmation_v1'"

    keys =
      ~w(version scope family key kind minutes model upstream_model reset_at provider_observed_at confirmed_at source_class)

    expected = Enum.map_join(keys, ",", &"'#{&1}'")
    fields = Enum.map_join(keys, ",", &"'#{&1}', #{marker}->'#{&1}'")

    types =
      Enum.map_join(keys, " AND ", fn key ->
        allowed =
          case key do
            numeric when numeric in ~w(version minutes) -> "'number'"
            optional when optional in ~w(model upstream_model) -> "'string','null'"
            _string -> "'string'"
          end

        "jsonb_typeof(#{marker}->'#{key}') IN (#{allowed})"
      end)

    ordinary =
      Enum.map_join(scalars, " || ", fn key ->
        allowed = if key == "reset_state", do: "'string','null'", else: "'boolean','null'"

        """
        CASE WHEN w.metadata ? '#{key}' THEN jsonb_build_object('#{key}',
          CASE WHEN jsonb_typeof(w.metadata->'#{key}') IN (#{allowed})
            THEN w.metadata->'#{key}' ELSE 'null'::jsonb END)
        ELSE '{}'::jsonb END
        """
      end)

    # Check the original marker before reconstruction: stripping unknown keys
    # must never make a rejected marker pass valid_marker's exact-size guard.
    ordinary <>
      """
       || CASE WHEN jsonb_typeof(#{marker}) = 'object' THEN
         CASE WHEN (SELECT count(*) FROM jsonb_object_keys(#{marker})) = 12
           AND (#{marker}) ?& ARRAY[#{expected}] AND #{types}
         THEN jsonb_build_object('__quota_cycle_confirmation_v1', jsonb_build_object(#{fields}))
         ELSE '{}'::jsonb END
       ELSE '{}'::jsonb END
      """
  end

  defp projected_column(field) when field in [:id, :upstream_identity_id], do: "#{field}::text"
  defp projected_column(field), do: to_string(field)

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      milliseconds when milliseconds > 0 -> milliseconds
      _elapsed -> raise "account snapshot deadline exceeded"
    end
  end
end
