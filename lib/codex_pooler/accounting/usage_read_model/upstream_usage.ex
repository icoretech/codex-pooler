defmodule CodexPooler.Accounting.UsageReadModel.UpstreamUsage do
  @moduledoc """
  Upstream Codex usage read-model selection and formatting.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_eligible PoolUpstreamAssignment.eligible_status()
  @assignment_health_active PoolUpstreamAssignment.active_health_status()
  @identity_active UpstreamIdentity.active_status()

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
    windows = quota_windows_for_identity(identity.id)

    build_codex_usage_for_identity(identity, windows, opts)
  end

  defp build_codex_usage_for_identity(%UpstreamIdentity{} = identity, windows, opts) do
    as_of = Keyword.get(opts, :as_of, now())
    {primary, secondary} = UsageResponses.account_usage_windows(windows, as_of)
    additional_rate_limits = UsageResponses.additional_codex_rate_limits(windows, as_of)

    {:ok,
     %{
       plan_type: identity.plan_family || "unknown",
       rate_limit: UsageResponses.codex_rate_limit(primary, secondary),
       credits: UsageResponses.codex_credits(primary, secondary),
       additional_rate_limits: additional_rate_limits
     }}
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
    candidates = codex_usage_candidates(pool_id)
    windows_by_identity_id = quota_windows_by_identity_id(Enum.map(candidates, &elem(&1, 0).id))

    candidates
    |> Enum.map(fn {%UpstreamIdentity{} = identity, assignment} ->
      {identity, assignment, Map.get(windows_by_identity_id, identity.id, [])}
    end)
    |> Enum.filter(&codex_usage_candidate_has_quota?/1)
    |> Enum.max_by(&codex_usage_candidate_rank(&1, opts), fn -> nil end)
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
         {%UpstreamIdentity{} = identity, %PoolUpstreamAssignment{}, windows},
         opts
       ) do
    as_of = Keyword.get(opts, :as_of, now())
    {primary, secondary} = UsageResponses.account_usage_windows(windows, as_of)
    rate_limit = UsageResponses.codex_rate_limit(primary, secondary)

    {
      if(rate_limit.allowed, do: 1, else: 0),
      usage_routing_state_rank(windows, as_of),
      plan_rank(identity),
      usage_remaining_score(primary, secondary),
      usage_percent_score(primary, secondary)
    }
  end

  defp codex_usage_candidate_has_quota?({%UpstreamIdentity{}, %PoolUpstreamAssignment{}, windows}) do
    Enum.any?(windows, &(&1.quota_key == "account"))
  end

  defp quota_windows_by_identity_id([]), do: %{}

  defp quota_windows_by_identity_id(identity_ids) do
    Quota.AccountQuotaWindow
    |> where([w], w.upstream_identity_id in ^Enum.uniq(identity_ids))
    |> order_by([w], asc: w.upstream_identity_id, asc: w.quota_key, asc: w.window_kind)
    |> Repo.all()
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp quota_windows_for_identity(identity_id) do
    Repo.all(
      from w in Quota.AccountQuotaWindow,
        where: w.upstream_identity_id == ^identity_id,
        order_by: [asc: w.quota_key, asc: w.window_kind]
    )
  end

  defp usage_routing_state_rank(windows, as_of) do
    case QuotaWindows.routing_quota_eligibility_from_windows(windows,
           at: as_of
         ) do
      %{routing_state: :precise} -> 3
      %{routing_state: :credit_backed_probe} -> 2
      %{routing_state: :weekly_only_probe} -> 1
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
  defp plan_label(nil), do: "unknown"
  defp plan_label(label), do: label |> String.downcase() |> String.replace(" ", "_")
  defp accounting_error(code, message), do: %{code: code, message: message}
end
