defmodule CodexPooler.Verification.ProviderResetInconsistency do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @pool_slug "provider-reset-proof"
  @account_ids [
    "provider-reset-proof-forward",
    "provider-reset-proof-equivalent",
    "provider-reset-proof-legacy",
    "provider-reset-proof-spark-anchored",
    "provider-reset-proof-spark-floating"
  ]
  @confirmation_key "__quota_cycle_confirmation_v1"
  @old_reset ~U[2026-07-25 03:24:36Z]
  @new_reset ~U[2026-07-28 17:04:16Z]

  @spec run([String.t()]) :: :ok
  def run(["--" | args]), do: run(args)

  def run(["seed"]) do
    cleanup()

    try do
      seed!()
      IO.puts("seed\tprovider-reset-fixtures\tpassed")
    rescue
      error ->
        cleanup()
        reraise error, __STACKTRACE__
    end
  end

  def run(["assert"]) do
    try do
      assert_convergence!()
      IO.puts("assert\tprovider-reset-convergence\tpassed")
    rescue
      error ->
        cleanup()
        reraise error, __STACKTRACE__
    end
  end

  def run(["cleanup"]), do: cleanup()

  def run(_args), do: raise("usage: provider_reset_inconsistency.exs -- seed|assert|cleanup")

  defp seed! do
    timestamp = ~U[2026-07-21 17:00:00Z]

    pool =
      %Pool{}
      |> Pool.changeset(%{
        slug: @pool_slug,
        name: "Provider reset proof",
        status: "active",
        created_at: timestamp,
        updated_at: timestamp
      })
      |> Repo.insert!()

    forward = create_identity!(pool, "provider-reset-proof-forward", "Forward cycle proof")

    equivalent =
      create_identity!(pool, "provider-reset-proof-equivalent", "Equivalent anchor proof")

    legacy = create_identity!(pool, "provider-reset-proof-legacy", "Legacy primary proof")

    anchored_spark =
      create_identity!(pool, "provider-reset-proof-spark-anchored", "Anchored Spark proof")

    floating_spark =
      create_identity!(pool, "provider-reset-proof-spark-floating", "Floating Spark proof")

    record_provider!(forward, timestamp, "54", @old_reset, timestamp)
    record_runtime!(forward, timestamp, "54", @old_reset)

    accepted_at = ~U[2026-07-21 17:06:00Z]
    accepted_reset = ~U[2026-07-28 17:06:01Z]
    record_provider!(equivalent, accepted_at, "0", accepted_reset, ~U[2026-07-21 17:06:01Z])

    as_of = ~U[2026-07-22 12:00:00Z]
    legacy_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)
    current_at = DateTime.add(legacy_at, Evidence.freshness_ttl_seconds(), :second)

    insert_window!(legacy, "primary", "codex_response_headers", legacy_at, @old_reset, "2")
    insert_window!(legacy, "secondary", "codex_usage_api", current_at, @new_reset, "0")

    anchored_spark_at = ~U[2026-07-21 17:00:00Z]

    record_spark!(anchored_spark, anchored_spark_at, @new_reset, %{"reset_state" => "anchored"})

    for offset <- [0, 60] do
      observed_at = DateTime.add(anchored_spark_at, offset, :second)
      record_spark!(floating_spark, observed_at, DateTime.add(observed_at, 7, :day), %{})
    end
  end

  defp assert_convergence! do
    forward = identity!("provider-reset-proof-forward")
    equivalent = identity!("provider-reset-proof-equivalent")
    legacy = identity!("provider-reset-proof-legacy")
    anchored_spark = identity!("provider-reset-proof-spark-anchored")
    floating_spark = identity!("provider-reset-proof-spark-floating")

    candidate_at = ~U[2026-07-21 17:04:00Z]
    confirmed_at = ~U[2026-07-21 17:08:00Z]
    record_provider!(forward, candidate_at, "0", @new_reset, candidate_at)

    candidate = provider_row!(forward)

    expect!(
      Decimal.equal?(candidate.used_percent, Decimal.new("54")),
      "candidate changed pressure"
    )

    expect!(
      match?({:ok, _candidate}, EvidenceStore.parse_candidate(candidate.metadata)),
      "candidate missing"
    )

    receipt("candidate", candidate)

    record_provider!(forward, confirmed_at, "0", @new_reset, confirmed_at)
    confirmed = provider_row!(forward)
    marker = confirmed.metadata[@confirmation_key]

    expect!(confirmed.metadata["reset_state"] == "anchored", "cycle not anchored")
    expect!(is_map(marker), "confirmation marker missing")
    expect!(marker["source_class"] == "provider_usage", "confirmation source mismatch")

    selection = Windows.quota_window_selection_data(forward, at: confirmed_at)
    expect!(selection.secondary.id == confirmed.id, "confirmed provider cycle not selected")
    receipt("confirmed", confirmed)

    runtime_at = ~U[2026-07-21 17:09:00Z]
    matching_runtime = record_runtime!(forward, runtime_at, "1", @new_reset)
    selection = Windows.quota_window_selection_data(forward, at: runtime_at)

    expect!(
      selection.secondary.id == matching_runtime.id,
      "same-cycle runtime precedence not restored"
    )

    receipt("same-cycle-runtime", matching_runtime)

    equivalent_at = ~U[2026-07-22 01:14:00Z]
    equivalent_reset = ~U[2026-07-28 17:09:00Z]
    record_provider!(equivalent, equivalent_at, "0", equivalent_reset, equivalent_at)
    maintained = provider_row!(equivalent)

    expect!(
      DateTime.compare(maintained.reset_at, equivalent_reset) == :eq,
      "equivalent reset not refreshed"
    )

    expect!(
      not Map.has_key?(maintained.metadata, "__quota_confirmed_candidate_v1"),
      "equivalent candidate persisted"
    )

    receipt("equivalent", maintained)

    as_of = ~U[2026-07-22 12:00:00Z]
    effective = Windows.list_quota_windows(legacy, as_of)
    expect!(length(effective) == 1, "legacy effective row count mismatch")
    [current] = effective
    expect!(current.window_kind == "secondary", "legacy primary survived")

    readiness = UpstreamQuotaReadiness.from_windows(effective, as_of)
    routing = Windows.routing_quota_eligibility(legacy, at: as_of)
    expect!(readiness.state == "weekly_only_probe", "legacy readiness mismatch")
    expect!(routing.eligible?, "legacy routing not ready")

    floating_spark_at = ~U[2026-07-21 17:05:00Z]

    record_spark!(
      floating_spark,
      floating_spark_at,
      DateTime.add(floating_spark_at, 7, :day),
      %{}
    )

    assert_spark_reset_presentation!(anchored_spark, ~U[2026-07-21 17:00:00Z], :anchored)
    assert_spark_reset_presentation!(floating_spark, floating_spark_at, :floating)

    IO.puts(
      Enum.join(
        [
          "selection",
          "legacy-rejected",
          current.window_kind,
          current.source,
          readiness.state,
          routing.eligible?
        ],
        "\t"
      )
    )
  end

  defp cleanup do
    identity_ids =
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.chatgpt_account_id in ^@account_ids,
          select: identity.id
      )

    Repo.delete_all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.upstream_identity_id in ^identity_ids
    )

    Repo.delete_all(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id in ^identity_ids
    )

    Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)
    Repo.delete_all(from pool in Pool, where: pool.slug == @pool_slug)
    IO.puts("cleanup\tprovider-reset-fixtures\tpassed")
    :ok
  end

  defp create_identity!(pool, account_id, label) do
    {:ok, identity} =
      IdentityLifecycle.create_upstream_identity(%{
        chatgpt_account_id: account_id,
        account_label: label,
        onboarding_method: "import",
        metadata: %{}
      })

    {:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)
    {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
    {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)
    identity
  end

  defp record_provider!(identity, observed_at, percent, reset_at, provider_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_usage_api", observed_at, percent, reset_at)
        |> put_in(
          [:metadata, "reset_after_seconds"],
          DateTime.diff(reset_at, provider_at, :second)
        ),
        observed_at,
        observed_at
      )

    row
  end

  defp record_runtime!(identity, observed_at, percent, reset_at) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        weekly_attrs("codex_rate_limit_event", observed_at, percent, reset_at),
        observed_at,
        observed_at
      )

    row
  end

  defp record_spark!(identity, observed_at, reset_at, metadata) do
    {:ok, row} =
      EvidenceStore.record_evidence(
        identity,
        %{
          quota_key: "codex_spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("0"),
          reset_at: reset_at,
          observed_at: observed_at,
          last_sync_at: observed_at,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          freshness_state: "fresh",
          metadata: Map.put(metadata, "reset_after_seconds", 604_800)
        },
        observed_at,
        observed_at
      )

    row
  end

  defp insert_window!(identity, kind, source, observed_at, reset_at, percent) do
    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      weekly_attrs(source, observed_at, percent, reset_at)
      |> Map.put(:upstream_identity_id, identity.id)
      |> Map.put(:window_kind, kind)
      |> Map.put(:created_at, observed_at)
      |> Map.put(:updated_at, observed_at)
    )
    |> Repo.insert!()
  end

  defp weekly_attrs(source, observed_at, percent, reset_at) do
    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: source,
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{}
    }
  end

  defp identity!(account_id), do: Repo.get_by!(UpstreamIdentity, chatgpt_account_id: account_id)

  defp provider_row!(identity) do
    Repo.one!(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity.id,
        where: window.source == "codex_usage_api",
        where: window.quota_key == "account",
        where: window.window_kind == "secondary"
    )
  end

  defp assert_spark_reset_presentation!(identity, at, semantics) do
    [spark] =
      identity
      |> Windows.list_quota_windows(at)
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.filter(&String.starts_with?(&1.label, "GPT-5.3-Codex-Spark"))

    case semantics do
      :anchored ->
        expect!(spark.reset_semantics == :anchored, "anchored Spark semantics mismatch")
        expect!(is_binary(spark.reset_label), "anchored Spark reset label missing")

        expect!(
          String.starts_with?(spark.reset_title, "resets "),
          "anchored Spark reset title missing"
        )

      :floating ->
        expect!(spark.reset_semantics == :floating, "floating Spark semantics mismatch")
        expect!(spark.reset_label == "starts on use", "floating Spark label mismatch")

        expect!(
          spark.reset_title == "provider reports a rolling seven-day window until use starts",
          "floating Spark reset title mismatch"
        )
    end

    IO.puts("presentation\t#{semantics}\t#{spark.reset_label}\t#{spark.reset_title}")
  end

  defp receipt(decision, row) do
    provider_observed_at = Map.get(row.metadata || %{}, "__quota_relative_liveness_v1")

    IO.puts(
      Enum.join(
        [
          "evidence",
          decision,
          row.source,
          Decimal.to_string(row.used_percent, :normal),
          DateTime.to_iso8601(row.reset_at),
          provider_observed_at || "none"
        ],
        "\t"
      )
    )
  end

  defp expect!(true, _message), do: :ok
  defp expect!(false, message), do: raise(message)
end

Logger.configure(level: :warning)
{:ok, _started} = Application.ensure_all_started(:codex_pooler)
CodexPooler.Verification.ProviderResetInconsistency.run(System.argv())
