defmodule CodexPooler.Accounting.UsageReadModel.UpstreamUsage do
  @moduledoc """
  Upstream Codex usage read-model selection and formatting.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @assignment_active AssignmentStatus.active_status()
  @assignment_eligible AssignmentStatus.eligible_status()
  @assignment_health_active AssignmentStatus.active_health_status()
  @identity_active IdentityStatus.active_status()

  @type accounting_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec build_codex_usage_for_pool(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_codex_usage_for_pool(pool_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)

    case best_codex_usage_identity_for_pool(pool_id, opts) do
      {%UpstreamIdentity{} = identity, _assignment, windows} ->
        build_codex_usage_for_identity(identity, windows, opts)

      nil ->
        {:error, accounting_error(:no_upstream_usage, "no upstream usage is available")}
    end
  end

  @spec build_codex_usage_for_chatgpt_account(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_codex_usage_for_chatgpt_account(chatgpt_account_id, opts \\ [])

  def build_codex_usage_for_chatgpt_account(chatgpt_account_id, opts)
      when is_binary(chatgpt_account_id) do
    accounts =
      Repo.all(
        from identity in UpstreamIdentity,
          join: assignment in PoolUpstreamAssignment,
          on: assignment.upstream_identity_id == identity.id,
          where:
            identity.chatgpt_account_id == ^String.trim(chatgpt_account_id) and
              identity.status == ^@identity_active and
              assignment.status == ^@assignment_active,
          distinct: true,
          order_by: [asc: identity.id],
          limit: 2,
          select: identity
      )

    case accounts do
      [%UpstreamIdentity{} = identity] ->
        build_codex_usage_for_upstream_identity(identity, opts)

      [] ->
        {:error,
         accounting_error(:invalid_chatgpt_account, "unknown or inactive chatgpt-account-id")}

      [_first, _second | _rest] ->
        {:error,
         accounting_error(
           :ambiguous_chatgpt_account,
           "chatgpt-account-id matches multiple upstream workspaces"
         )}
    end
  end

  def build_codex_usage_for_chatgpt_account(_chatgpt_account_id, _opts),
    do:
      {:error,
       accounting_error(:invalid_chatgpt_account, "unknown or inactive chatgpt-account-id")}

  @spec build_codex_usage_for_upstream_identity(UpstreamIdentity.t(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  def build_codex_usage_for_upstream_identity(%UpstreamIdentity{} = identity, opts \\ []) do
    if active_assigned_identity?(identity) do
      build_codex_usage_for_identity(identity, opts)
    else
      {:error,
       accounting_error(:invalid_chatgpt_account, "unknown or inactive chatgpt-account-id")}
    end
  end

  @spec v1_upstream_limits_for_pool(term(), DateTime.t(), keyword()) :: [map()]
  def v1_upstream_limits_for_pool(pool_id, as_of, opts) when is_binary(pool_id) do
    case best_codex_usage_identity_for_pool(pool_id, Keyword.put(opts, :as_of, as_of)) do
      {%UpstreamIdentity{}, %PoolUpstreamAssignment{}, windows} ->
        {primary, secondary} = UsageResponses.account_usage_windows(windows, as_of)

        [primary, secondary]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&normalize_v1_upstream_limit/1)

      nil ->
        []
    end
  end

  def v1_upstream_limits_for_pool(_pool_id, _as_of, _opts), do: []

  defp build_codex_usage_for_identity(%UpstreamIdentity{} = identity, opts) do
    as_of = Keyword.get(opts, :as_of, now())

    snapshot =
      [identity.id]
      |> RoutingQuotaSnapshot.load_by_identity_ids(as_of)
      |> Map.fetch!(identity.id)

    if explicit_usage_snapshot_available?(snapshot) do
      windows = RoutingQuotaSnapshot.effective_windows(snapshot)
      build_codex_usage_for_identity(identity, windows, Keyword.put(opts, :as_of, as_of))
    else
      {:error, accounting_error(:no_upstream_usage, "no upstream usage is available")}
    end
  end

  defp build_codex_usage_for_identity(%UpstreamIdentity{} = identity, windows, opts) do
    as_of = Keyword.get(opts, :as_of, now())
    {primary, secondary} = UsageResponses.account_usage_windows(windows, as_of)
    additional_rate_limits = UsageResponses.additional_codex_rate_limits(windows, as_of)
    credits = UsageResponses.codex_credits(primary, secondary)

    usage =
      %{
        plan_type: public_plan_type(identity),
        rate_limit: UsageResponses.codex_rate_limit(primary, secondary),
        additional_rate_limits: additional_rate_limits
      }

    {:ok, if(is_nil(credits), do: usage, else: Map.put(usage, :credits, credits))}
  end

  defp active_assigned_identity?(%UpstreamIdentity{id: identity_id, status: @identity_active}) do
    Repo.exists?(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status == ^@assignment_active
    )
  end

  defp active_assigned_identity?(%UpstreamIdentity{}), do: false

  defp best_codex_usage_identity_for_pool(pool_id, opts) when is_binary(pool_id) do
    as_of = Keyword.get(opts, :as_of, now())
    candidates = codex_usage_candidates(pool_id)

    snapshots_by_identity_id =
      candidates
      |> Enum.map(&elem(&1, 0).id)
      |> RoutingQuotaSnapshot.load_by_identity_ids(as_of)

    candidates
    |> Enum.map(fn {%UpstreamIdentity{} = identity, assignment} ->
      {identity, assignment, Map.get(snapshots_by_identity_id, identity.id)}
    end)
    |> Enum.filter(&codex_usage_candidate_has_quota?/1)
    |> Enum.max_by(&codex_usage_candidate_rank(&1, opts), fn -> nil end)
    |> case do
      {identity, assignment, snapshot} ->
        {identity, assignment, RoutingQuotaSnapshot.effective_windows(snapshot)}

      nil ->
        nil
    end
  end

  defp best_codex_usage_identity_for_pool(_pool_id, _opts), do: nil

  defp codex_usage_candidates(pool_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where:
          assignment.pool_id == ^pool_id and assignment.status == ^@assignment_active and
            assignment.eligibility_status == ^@assignment_eligible and
            assignment.health_status == ^@assignment_health_active and
            identity.status == ^@identity_active,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        select: {identity, assignment}
    )
  end

  defp codex_usage_candidate_rank(
         {%UpstreamIdentity{} = identity, %PoolUpstreamAssignment{}, snapshot},
         opts
       ) do
    as_of = Keyword.get(opts, :as_of, now())
    windows = RoutingQuotaSnapshot.effective_windows(snapshot)
    {primary, secondary} = UsageResponses.account_usage_windows(windows, as_of)
    rate_limit = UsageResponses.codex_rate_limit(primary, secondary)

    {
      if(rate_limit.allowed, do: 1, else: 0),
      usage_routing_state_rank(snapshot),
      plan_rank(identity),
      usage_remaining_score(primary, secondary),
      usage_percent_score(primary, secondary)
    }
  end

  defp codex_usage_candidate_has_quota?(
         {%UpstreamIdentity{}, %PoolUpstreamAssignment{}, snapshot}
       ) do
    Enum.any?(RoutingQuotaSnapshot.time_visible_raw_windows(snapshot), fn window ->
      window.quota_scope == "account"
    end) or
      QuotaWindows.routing_quota_eligibility_from_snapshot(snapshot, account_only: true).eligible?
  end

  defp explicit_usage_snapshot_available?(snapshot) do
    Enum.any?(RoutingQuotaSnapshot.time_visible_raw_windows(snapshot), fn window ->
      window.quota_scope == "account"
    end) or
      QuotaWindows.routing_quota_eligibility_from_snapshot(snapshot, account_only: true).eligible?
  end

  defp usage_routing_state_rank(snapshot) do
    case QuotaWindows.routing_quota_eligibility_from_snapshot(snapshot, account_only: true) do
      %{routing_state: :precise} -> 3
      %{routing_state: :credit_backed_probe} -> 2
      %{routing_state: :weekly_only_probe} -> 1
      %{routing_state: :windowless_provider_available} -> 1
      _state -> 0
    end
  end

  defp plan_rank(%UpstreamIdentity{} = identity) do
    plan = identity.plan_family || plan_label(identity.plan_label) || ""

    cond do
      plan =~ ~r/enterprise|team/i -> 4
      plan =~ ~r/pro/i -> 3
      plan =~ ~r/plus/i -> 2
      plan =~ ~r/free/i -> 1
      true -> 0
    end
  end

  defp usage_remaining_score(primary, secondary) do
    [primary, secondary]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(&1.remaining_value || 0))
    |> Enum.max(fn -> 0 end)
  end

  defp usage_percent_score(primary, secondary) do
    [primary, secondary]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(100 - (&1.used_percent || 0)))
    |> Enum.max(fn -> 0 end)
  end

  defp normalize_v1_upstream_limit(limit) when is_map(limit) do
    %{
      limit_type: Map.get(limit, :limit_type),
      limit_window: Map.get(limit, :limit_window),
      max_value: Map.get(limit, :max_value),
      current_value: Map.get(limit, :current_value),
      remaining_value: Map.get(limit, :remaining_value),
      model_filter: nil,
      reset_at: Map.get(limit, :reset_at),
      source: "upstream_usage"
    }
  end

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp public_plan_type(%UpstreamIdentity{plan_family: plan_family, plan_label: plan_label})
       when is_binary(plan_family),
       do: plan_label || plan_family

  defp public_plan_type(%UpstreamIdentity{}), do: "unknown"

  defp plan_label(nil), do: "unknown"
  defp plan_label(label), do: label |> String.downcase() |> String.replace(" ", "_")
  defp accounting_error(code, message), do: %{code: code, message: message}
end
