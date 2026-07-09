defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStore do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @runtime_quota_sources ~w(codex_rate_limit_event codex_response_headers)

  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec evidence_changeset(identity_ref(), map(), DateTime.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, Evidence.errors() | map()}
  def evidence_changeset(identity_or_id, attrs, observed_at) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      %Quota.AccountQuotaWindow{}
      |> Quota.AccountQuotaWindow.changeset(
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)
        |> put_timestamps()
      )
      |> then(&{:ok, &1})
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  @spec record_evidence(identity_ref(), map(), DateTime.t()) ::
          {:ok, Quota.AccountQuotaWindow.t()}
          | {:error, Ecto.Changeset.t() | Evidence.errors() | map()}
  def record_evidence(identity_or_id, attrs, observed_at) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      attrs =
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)

      existing = get_existing_evidence(identity_id, evidence)
      timestamped_attrs = merge_attrs(existing, attrs, evidence)

      existing
      |> Quota.AccountQuotaWindow.changeset(timestamped_attrs)
      |> Repo.insert_or_update()
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  @spec list_evidence(identity_ref()) :: [Quota.AccountQuotaWindow.t()]
  def list_evidence(identity_or_id) do
    case evidence_identity_id(identity_or_id, %{}) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from window in Quota.AccountQuotaWindow,
            where: window.upstream_identity_id == ^identity_id,
            order_by: [
              asc: window.quota_scope,
              asc: window.quota_family,
              asc: window.quota_key,
              asc: window.window_kind,
              desc: window.merge_precedence,
              desc: window.observed_at
            ]
        )

      nil ->
        []
    end
  end

  defp get_existing_evidence(identity_id, %Evidence{} = evidence) do
    exact_existing_evidence(identity_id, evidence) ||
      alias_existing_evidence(identity_id, evidence) ||
      fallback_existing_evidence(identity_id, evidence) ||
      %Quota.AccountQuotaWindow{}
  end

  defp exact_existing_evidence(identity_id, %Evidence{} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_scope == ^evidence.quota_scope,
        where: window.quota_family == ^evidence.quota_family,
        where: fragment("COALESCE(lower(?), '')", window.model) == ^lower_string(evidence.model),
        where:
          fragment("COALESCE(lower(?), '')", window.upstream_model) ==
            ^lower_string(evidence.upstream_model),
        where: window.quota_key == ^evidence.quota_key,
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp alias_existing_evidence(identity_id, %Evidence{quota_key: "codex_spark"} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_key in ["gpt_5_3_codex_spark", "codex_bengalfox", "codex_other"],
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        where: window.source == ^evidence.source,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp alias_existing_evidence(_identity_id, _evidence), do: nil

  defp fallback_existing_evidence(identity_id, %Evidence{} = evidence) do
    Repo.one(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_key == ^evidence.quota_key,
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        order_by: [desc: window.merge_precedence, desc: window.observed_at],
        limit: 1
    )
  end

  defp merge_attrs(%Quota.AccountQuotaWindow{id: nil} = existing, attrs, _evidence),
    do: put_timestamps(attrs, existing)

  defp merge_attrs(%Quota.AccountQuotaWindow{} = existing, attrs, %Evidence{} = evidence) do
    timestamp = now()

    cond do
      incoming_updates_usage_with_existing_capacity?(evidence, existing) ->
        merge_usage_with_existing_capacity_attrs(existing, attrs, timestamp)

      incoming_refreshes_existing?(evidence, existing, timestamp) ->
        refresh_existing_attrs(existing, attrs, timestamp)

      incoming_supersedes?(evidence, existing, timestamp) ->
        put_timestamps(attrs, existing)

      true ->
        existing
        |> window_attrs()
        |> Map.put(:updated_at, timestamp)
    end
  end

  defp incoming_supersedes?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    cond do
      usage_api_account_supersedes_runtime_rollback?(evidence, existing, timestamp) ->
        true

      runtime_account_percent_rollback?(evidence, existing, timestamp) ->
        false

      true ->
        case zero_percent_only_merge_decision(evidence, existing, timestamp) do
          {:ok, decision} ->
            decision

          :continue ->
            quality_supersedes?(evidence, existing, timestamp)
        end
    end
  end

  defp zero_percent_only_merge_decision(%Evidence{} = evidence, existing, timestamp) do
    cond do
      stronger_quota_information?(evidence) and weak_zero_percent_evidence?(existing) and
          not reset_bearing_rollback?(evidence, existing, timestamp) ->
        {:ok, same_evidence_identity?(evidence, existing)}

      weak_zero_percent_evidence?(evidence) and
        stronger_current_quota_information?(existing, timestamp) and
          not newer_usage_reset_supersedes?(evidence, existing) ->
        {:ok, false}

      true ->
        :continue
    end
  end

  defp usage_api_account_supersedes_runtime_rollback?(
         %Evidence{source: "codex_usage_api", used_percent: %Decimal{} = incoming_percent} =
           evidence,
         %Quota.AccountQuotaWindow{source: source, used_percent: %Decimal{} = existing_percent} =
           existing,
         timestamp
       )
       when source in @runtime_quota_sources do
    account_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      Decimal.compare(incoming_percent, existing_percent) != :lt
  end

  defp usage_api_account_supersedes_runtime_rollback?(_evidence, _existing, _timestamp),
    do: false

  defp runtime_account_percent_rollback?(
         %Evidence{source: source, used_percent: %Decimal{} = incoming_percent} = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_usage_api",
           used_percent: %Decimal{} = existing_percent
         } =
           existing,
         timestamp
       )
       when source in @runtime_quota_sources do
    account_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      weak_capacity?(evidence) and stronger_current_quota_information?(existing, timestamp) and
      Decimal.compare(incoming_percent, existing_percent) == :lt and
      not exhausted_by_used_percent?(evidence)
  end

  defp runtime_account_percent_rollback?(_evidence, _existing, _timestamp), do: false

  defp quality_supersedes?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    incoming_quality = quality_key(evidence, timestamp)
    existing_quality = quality_key(existing, timestamp)

    higher_precedence_rate_limit_event_supersedes?(evidence, existing) or
      (not reset_bearing_rollback?(evidence, existing, timestamp) and
         (resetless_weekly_rate_limit_supersedes?(evidence, existing) ||
            newer_usage_reset_supersedes?(evidence, existing) ||
            incoming_quality >= existing_quality))
  end

  defp higher_precedence_rate_limit_event_supersedes?(
         %Evidence{source: "codex_rate_limit_event", reset_at: %DateTime{}} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    same_evidence_identity?(evidence, existing) and
      merge_precedence(evidence) > merge_precedence(existing)
  end

  defp higher_precedence_rate_limit_event_supersedes?(_evidence, _existing), do: false

  defp reset_bearing_rollback?(
         %Evidence{reset_at: %DateTime{} = reset_at} = evidence,
         %Quota.AccountQuotaWindow{reset_at: %DateTime{} = existing_reset_at} = existing,
         timestamp
       ) do
    same_evidence_identity?(evidence, existing) and
      Evidence.current_freshness_state(existing, timestamp) == "fresh" and
      DateTime.compare(reset_at, existing_reset_at) == :lt and
      not same_source_weak_zero_to_stronger_evidence?(evidence, existing)
  end

  defp reset_bearing_rollback?(_evidence, _existing, _timestamp), do: false

  defp same_source_weak_zero_to_stronger_evidence?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    evidence.source == existing.source and weak_zero_percent_evidence?(existing) and
      stronger_quota_information?(evidence)
  end

  defp newer_usage_reset_supersedes?(
         %Evidence{
           source: "codex_usage_api",
           source_precision: source_precision,
           reset_at: %DateTime{} = reset_at,
           observed_at: %DateTime{} = observed_at
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_response_headers",
           reset_at: %DateTime{} = existing_reset_at,
           observed_at: %DateTime{} = existing_observed_at
         } = existing
       )
       when source_precision in ["observed", "authoritative"] do
    same_evidence_identity?(evidence, existing) and
      DateTime.compare(observed_at, existing_observed_at) == :gt and
      DateTime.compare(reset_at, existing_reset_at) == :gt
  end

  defp newer_usage_reset_supersedes?(_evidence, _existing), do: false

  defp resetless_weekly_rate_limit_supersedes?(
         %Evidence{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = observed_at
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = existing_observed_at
         } = existing
       ) do
    not Evidence.reset_bearing?(evidence) and
      DateTime.compare(observed_at, existing_observed_at) != :lt and
      same_evidence_identity?(evidence, existing)
  end

  defp resetless_weekly_rate_limit_supersedes?(_evidence, _existing), do: false

  defp same_evidence_identity?(%Evidence{} = evidence, %Quota.AccountQuotaWindow{} = existing) do
    evidence.quota_scope == existing.quota_scope and
      evidence.quota_family == existing.quota_family and
      evidence.quota_key == existing.quota_key and evidence.window_kind == existing.window_kind and
      lower_string(evidence.model) == lower_string(existing.model) and
      lower_string(evidence.upstream_model) == lower_string(existing.upstream_model)
  end

  defp account_quota_identity?(%{quota_key: "account", quota_scope: "account"}), do: true
  defp account_quota_identity?(_evidence_or_window), do: false

  defp incoming_refreshes_existing?(
         %Evidence{source: "codex_usage_api"} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    same_evidence_identity?(evidence, existing) and weak_zero_percent_evidence?(evidence) and
      stronger_current_quota_information?(existing, timestamp) and
      not exhausted_by_used_percent?(existing)
  end

  defp incoming_refreshes_existing?(_evidence, _existing, _timestamp), do: false

  defp incoming_updates_usage_with_existing_capacity?(
         %Evidence{used_percent: %Decimal{} = used_percent} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    same_evidence_identity?(evidence, existing) and positive_percent?(used_percent) and
      missing_active_limit?(evidence) and active_limit_bearing?(existing) and
      (weak_capacity?(evidence) or positive_credits?(evidence))
  end

  defp incoming_updates_usage_with_existing_capacity?(_evidence, _existing), do: false

  defp merge_usage_with_existing_capacity_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         timestamp
       ) do
    active_limit = preserved_active_limit(existing, Map.get(attrs, :active_limit))
    credits = preserved_credits(existing, Map.get(attrs, :credits))

    attrs
    |> Map.put(:active_limit, active_limit)
    |> Map.put(:credits, credits)
    |> Map.put(:reset_at, latest_reset_at(existing.reset_at, Map.get(attrs, :reset_at)))
    |> maybe_put_used_percent_from_credits(active_limit, credits, Map.get(attrs, :credits))
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp refresh_existing_attrs(%Quota.AccountQuotaWindow{} = existing, attrs, timestamp) do
    existing
    |> window_attrs()
    |> Map.merge(%{
      last_sync_at: latest_datetime(existing.last_sync_at, Map.get(attrs, :last_sync_at)),
      observed_at: latest_datetime(existing.observed_at, Map.get(attrs, :observed_at)),
      reset_at: latest_reset_at(existing.reset_at, Map.get(attrs, :reset_at)),
      freshness_state: Map.get(attrs, :freshness_state, existing.freshness_state),
      metadata: Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})),
      updated_at: timestamp
    })
  end

  defp latest_datetime(%DateTime{} = existing, %DateTime{} = incoming) do
    if DateTime.compare(incoming, existing) == :gt, do: incoming, else: existing
  end

  defp latest_datetime(nil, %DateTime{} = incoming), do: incoming
  defp latest_datetime(existing, _incoming), do: existing

  defp latest_reset_at(%DateTime{} = existing, %DateTime{} = incoming) do
    if DateTime.compare(incoming, existing) == :lt, do: existing, else: incoming
  end

  defp latest_reset_at(nil, %DateTime{} = incoming), do: incoming
  defp latest_reset_at(existing, _incoming), do: existing

  defp weak_zero_percent_evidence?(evidence_or_window) do
    zero_percent?(Map.get(evidence_or_window, :used_percent)) and
      weak_capacity?(evidence_or_window)
  end

  defp stronger_quota_information?(evidence_or_window),
    do: information_quality_rank(evidence_or_window) > 1

  defp stronger_current_quota_information?(evidence_or_window, timestamp) do
    stronger_quota_information?(evidence_or_window) and
      Evidence.current_freshness_state(evidence_or_window, timestamp) == "fresh"
  end

  defp weak_capacity?(evidence_or_window) do
    Map.get(evidence_or_window, :active_limit) in [nil, 0] and
      Map.get(evidence_or_window, :credits) in [nil, 0]
  end

  defp missing_active_limit?(evidence_or_window),
    do: Map.get(evidence_or_window, :active_limit) in [nil, 0]

  defp active_limit_bearing?(evidence_or_window) do
    active_limit = Map.get(evidence_or_window, :active_limit)
    is_integer(active_limit) and active_limit > 0
  end

  defp preserved_active_limit(%Quota.AccountQuotaWindow{active_limit: existing}, incoming)
       when incoming in [nil, 0] and is_integer(existing) and existing > 0,
       do: existing

  defp preserved_active_limit(_existing, incoming), do: incoming

  defp preserved_credits(%Quota.AccountQuotaWindow{credits: existing}, incoming)
       when incoming in [nil, 0] and is_integer(existing) and existing > 0,
       do: existing

  defp preserved_credits(_existing, incoming), do: incoming

  defp maybe_put_used_percent_from_credits(attrs, active_limit, credits, incoming_credits)
       when is_integer(active_limit) and active_limit > 0 and is_integer(credits) and credits >= 0 and
              is_integer(incoming_credits) and incoming_credits > 0 do
    Map.put(attrs, :used_percent, used_percent_from_remaining_credits(active_limit, credits))
  end

  defp maybe_put_used_percent_from_credits(attrs, _active_limit, _credits, _incoming_credits),
    do: attrs

  defp used_percent_from_remaining_credits(active_limit, credits) do
    active_limit
    |> Decimal.new()
    |> Decimal.sub(Decimal.new(credits))
    |> decimal_non_negative()
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.div(Decimal.new(active_limit))
    |> decimal_clamp_percent()
  end

  defp zero_percent?(%Decimal{} = percent), do: Decimal.compare(percent, Decimal.new(0)) == :eq
  defp zero_percent?(_percent), do: false

  defp positive_percent?(%Decimal{} = percent),
    do: Decimal.compare(percent, Decimal.new(0)) == :gt

  defp positive_credits?(%{credits: credits}) when is_integer(credits), do: credits > 0
  defp positive_credits?(_evidence_or_window), do: false

  defp exhausted_by_used_percent?(%{used_percent: %Decimal{} = percent}),
    do: Decimal.compare(percent, Decimal.new(100)) != :lt

  defp exhausted_by_used_percent?(_evidence_or_window), do: false

  defp quality_key(evidence_or_window, timestamp) do
    {
      freshness_rank(Evidence.current_freshness_state(evidence_or_window, timestamp)),
      reset_rank(Evidence.reset_bearing?(evidence_or_window)),
      information_quality_rank(evidence_or_window),
      merge_precedence(evidence_or_window),
      observed_rank(evidence_or_window)
    }
  end

  defp freshness_rank("fresh"), do: 2
  defp freshness_rank("stale"), do: 1
  defp freshness_rank(_state), do: 0

  defp reset_rank(true), do: 1
  defp reset_rank(false), do: 0

  defp merge_precedence(%Evidence{} = evidence), do: evidence.merge_precedence || 0

  defp merge_precedence(%Quota.AccountQuotaWindow{merge_precedence: precedence}),
    do: precedence || 0

  defp observed_rank(%Evidence{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(%Quota.AccountQuotaWindow{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(_evidence_or_window), do: 0

  defp information_quality_rank(%{active_limit: active_limit})
       when is_integer(active_limit) and active_limit > 0,
       do: 4

  defp information_quality_rank(%{credits: credits}) when is_integer(credits) and credits > 0,
    do: 3

  defp information_quality_rank(%{used_percent: %Decimal{} = used_percent}) do
    if positive_percent?(used_percent), do: 2, else: 1
  end

  defp information_quality_rank(_evidence_or_window), do: 0

  defp decimal_non_negative(%Decimal{} = value) do
    if Decimal.compare(value, Decimal.new(0)) == :lt, do: Decimal.new(0), else: value
  end

  defp decimal_clamp_percent(%Decimal{} = value) do
    cond do
      Decimal.compare(value, Decimal.new(0)) == :lt -> Decimal.new(0)
      Decimal.compare(value, Decimal.new(100)) == :gt -> Decimal.new(100)
      true -> value
    end
  end

  defp evidence_identity_id(%UpstreamIdentity{id: id}, _attrs), do: id
  defp evidence_identity_id(id, _attrs) when is_binary(id), do: id

  defp evidence_identity_id(_identity_or_id, attrs),
    do: Map.get(attrs, :upstream_identity_id) || Map.get(attrs, "upstream_identity_id")

  defp lower_string(value) when is_binary(value), do: String.downcase(value)
  defp lower_string(_value), do: ""

  defp put_timestamps(attrs, existing \\ %Quota.AccountQuotaWindow{}) do
    timestamp = now()

    attrs
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp window_attrs(%Quota.AccountQuotaWindow{} = window) do
    window
    |> Map.from_struct()
    |> Map.take(Quota.AccountQuotaWindow.__schema__(:fields))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
