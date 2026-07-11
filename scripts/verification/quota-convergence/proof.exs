alias CodexPooler.Repo
alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

import Ecto.Query

mode = System.fetch_env!("QUOTA_PROOF_MODE")

unless mode in ["equivalent", "changed-second"] do
  raise "unsupported proof mode"
end

{:ok, _started} = Application.ensure_all_started(:codex_pooler)

current_at = DateTime.utc_now() |> DateTime.truncate(:second)
now = DateTime.add(current_at, -30, :second)
reset_at = DateTime.add(current_at, 7_200, :second)

identity =
  %UpstreamIdentity{}
  |> UpstreamIdentity.changeset(%{
    account_label: "quota-proof",
    onboarding_method: "import",
    status: "active",
    headers_profile_version: 1,
    created_at: now,
    updated_at: now,
    metadata: %{"fixture" => "quota-proof"}
  })
  |> Repo.insert!()

metadata_fields =
  "quota_scope,quota_family,quota_key,window_kind,source,source_precision," <>
    "freshness_state,observed_at,reset_at,used_percent"

record = fn scope, percent, observed_at ->
  attrs =
    case scope do
      :account ->
        %{quota_scope: "account", quota_family: "account", quota_key: "account"}

      :model ->
        %{
          quota_scope: "model",
          quota_family: "codex_model",
          quota_key: "model-quota",
          model: "example-model",
          raw_limit_id: "model-limit",
          raw_limit_name: "Model limit",
          raw_metered_feature: "model-meter"
        }
    end
    |> Map.merge(%{
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      metadata: %{"fixture" => "quota-proof"}
    })

  {:ok, window} = QuotaWindows.record_evidence(identity, attrs, observed_at)
  Decimal.to_string(window.used_percent, :normal)
end

try do
  account_second = if mode == "equivalent", do: "14", else: "13"
  model_second = if mode == "equivalent", do: "1", else: "2"

  transitions = [
    {:account, "22", "14", account_second},
    {:model, "22", "1", model_second}
  ]

  Enum.each(transitions, fn {scope, initial, first_lower, second_lower} ->
    first = record.(scope, initial, now)
    second = record.(scope, first_lower, DateTime.add(now, 10, :second))
    third = record.(scope, second_lower, DateTime.add(now, 20, :second))

    expected = if mode == "equivalent", do: first_lower, else: initial

    passed =
      Decimal.equal?(Decimal.new(first), Decimal.new(initial)) and
        Decimal.equal?(Decimal.new(second), Decimal.new(initial)) and
        Decimal.equal?(Decimal.new(third), Decimal.new(expected))

    IO.puts(
      Enum.join(
        [
          "transition",
          mode,
          Atom.to_string(scope),
          first,
          second,
          third,
          if(passed, do: "passed", else: "failed")
        ],
        "\t"
      )
    )
  end)

  rows =
    Repo.query!(
      """
      SELECT quota_scope, quota_family, quota_key, window_kind, source,
             source_precision, freshness_state, observed_at, reset_at, used_percent::text
      FROM account_quota_windows
      WHERE upstream_identity_id::text = $1
      ORDER BY quota_scope
      """,
      [identity.id]
    ).rows

  unless length(rows) == 2 do
    raise "metadata projection row count mismatch"
  end

  Enum.each(rows, fn row ->
    [scope, family, key, kind, source, precision, freshness, observed, reset, percent] = row

    IO.puts(
      Enum.join(
        [
          "row",
          scope,
          family,
          key,
          kind,
          source,
          precision,
          freshness,
          DateTime.to_iso8601(observed),
          DateTime.to_iso8601(reset),
          percent
        ],
        "\t"
      )
    )
  end)

  IO.puts("projection\t#{metadata_fields}\tpassed")
after
  Repo.delete_all(
    from window in CodexPooler.Upstreams.Quota.AccountQuotaWindow,
      where: window.upstream_identity_id == ^identity.id
  )

  Repo.delete!(identity)
  IO.puts("cleanup\tproof-identity\tpassed")
end
