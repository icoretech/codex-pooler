defmodule CodexPooler.Upstreams.OAuthFlows.Summary do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.OAuthFlows.Lifecycle
  alias CodexPooler.Upstreams.Schemas.{OAuthFlow, UpstreamIdentity}

  @type result_identity_summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:label) => String.t(),
          required(:status) => String.t(),
          required(:workspace_id) => String.t() | nil
        }
  @type device_summary :: %{
          required(:user_code) => String.t() | nil,
          required(:verification_uri) => String.t() | nil,
          required(:interval_seconds) => pos_integer() | nil,
          required(:poll_after_at) => DateTime.t() | nil
        }
  @type error_summary :: %{
          required(:code) => String.t() | nil,
          required(:message) => String.t() | nil
        }
  @type safe_flow_summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t() | nil,
          required(:result_upstream_identity_id) => Ecto.UUID.t() | nil,
          required(:flow_kind) => String.t(),
          required(:purpose) => String.t(),
          required(:status) => String.t(),
          required(:status_label) => String.t(),
          required(:authorization_url) => nil,
          required(:device) => device_summary() | nil,
          required(:error) => error_summary() | nil,
          required(:result_identity) => result_identity_summary() | nil,
          required(:expires_at) => DateTime.t(),
          required(:poll_after_at) => DateTime.t() | nil,
          required(:completed_at) => DateTime.t() | nil,
          required(:cancelled_at) => DateTime.t() | nil,
          required(:last_polled_at) => DateTime.t() | nil,
          required(:inserted_at) => DateTime.t()
        }

  @spec list_visible_oauth_flow_summaries(Scope.t(), keyword()) :: [safe_flow_summary()]
  def list_visible_oauth_flow_summaries(scope, opts \\ [])

  def list_visible_oauth_flow_summaries(%Scope{} = scope, opts) when is_list(opts) do
    scope
    |> visible_pool_ids(opts)
    |> list_visible_oauth_flow_summaries_for_pool_ids(opts)
  end

  def list_visible_oauth_flow_summaries(_scope, _opts), do: []

  defp list_visible_oauth_flow_summaries_for_pool_ids([], _opts), do: []

  defp list_visible_oauth_flow_summaries_for_pool_ids(pool_ids, opts) do
    flows =
      OAuthFlow
      |> where([flow], flow.pool_id in ^pool_ids)
      |> maybe_where_statuses(Keyword.get(opts, :statuses))
      |> maybe_where_upstream_identity_ids(Keyword.get(opts, :upstream_identity_ids))
      |> order_by([flow], desc: flow.inserted_at, desc: flow.id)
      |> limit(^oauth_flow_limit(opts))
      |> Repo.all()

    result_identity_lookup = result_identity_lookup(flows)

    Enum.map(flows, &safe_flow_summary(&1, result_identity_lookup))
  end

  defp visible_pool_ids(%Scope{} = scope, opts) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)

    case normalize_id_filter(Keyword.get(opts, :pool_ids)) do
      :all ->
        visible_pool_ids

      requested_pool_ids ->
        Enum.filter(requested_pool_ids, &(&1 in visible_pool_ids))
    end
  end

  defp maybe_where_statuses(query, statuses) do
    case normalize_string_filter(statuses) do
      [] -> query
      statuses -> where(query, [flow], flow.status in ^statuses)
    end
  end

  defp maybe_where_upstream_identity_ids(query, upstream_identity_ids) do
    case normalize_id_filter(upstream_identity_ids) do
      :all ->
        query

      [] ->
        empty_oauth_flow_query(query)

      upstream_identity_ids ->
        where(query, [flow], flow.upstream_identity_id in ^upstream_identity_ids)
    end
  end

  defp empty_oauth_flow_query(query), do: where(query, [flow], false)

  defp result_identity_lookup(flows) do
    result_identity_ids =
      flows
      |> Enum.map(& &1.result_upstream_identity_id)
      |> Enum.filter(&is_binary/1)

    case result_identity_ids do
      [] ->
        %{}

      ids ->
        UpstreamIdentity
        |> where([identity], identity.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  defp safe_flow_summary(%OAuthFlow{} = flow, result_identity_lookup) do
    %{
      id: flow.id,
      pool_id: flow.pool_id,
      upstream_identity_id: flow.upstream_identity_id,
      result_upstream_identity_id: flow.result_upstream_identity_id,
      flow_kind: flow.flow_kind,
      purpose: flow.purpose,
      status: flow.status,
      status_label: flow_status_label(flow),
      authorization_url: nil,
      device: device_summary(flow),
      error: error_summary(flow),
      result_identity: result_identity_summary(flow, result_identity_lookup),
      expires_at: flow.expires_at,
      poll_after_at: flow.poll_after_at,
      completed_at: flow.completed_at,
      cancelled_at: flow.cancelled_at,
      last_polled_at: flow.last_polled_at,
      inserted_at: flow.inserted_at
    }
  end

  defp device_summary(%OAuthFlow{flow_kind: "device", status: "pending"} = flow) do
    %{
      user_code: flow.device_user_code,
      verification_uri: flow.verification_uri,
      interval_seconds: flow.interval_seconds,
      poll_after_at: flow.poll_after_at
    }
  end

  defp device_summary(%OAuthFlow{}), do: nil

  defp error_summary(%OAuthFlow{error_code: nil, error_message: nil}), do: nil

  defp error_summary(%OAuthFlow{} = flow) do
    %{
      code: flow.error_code,
      message: flow.error_message
    }
  end

  defp result_identity_summary(
         %OAuthFlow{result_upstream_identity_id: result_upstream_identity_id},
         result_identity_lookup
       )
       when is_binary(result_upstream_identity_id) do
    case Map.get(result_identity_lookup, result_upstream_identity_id) do
      %UpstreamIdentity{} = identity ->
        %{
          id: identity.id,
          label: identity.account_label || identity.chatgpt_account_id || "Upstream account",
          status: identity.status,
          workspace_id: identity.workspace_id
        }

      nil ->
        nil
    end
  end

  defp result_identity_summary(%OAuthFlow{}, _result_identity_lookup), do: nil

  defp flow_status_label(%OAuthFlow{status: "pending", flow_kind: "browser"}),
    do: "Browser authorization pending"

  defp flow_status_label(%OAuthFlow{status: "pending", flow_kind: "device"}),
    do: "Device authorization pending"

  defp flow_status_label(%OAuthFlow{status: "completed"}), do: "OAuth link completed"

  defp flow_status_label(%OAuthFlow{status: "failed", error_message: message})
       when is_binary(message),
       do: message

  defp flow_status_label(%OAuthFlow{status: "failed"}), do: "OAuth link failed"
  defp flow_status_label(%OAuthFlow{status: "cancelled"}), do: "OAuth flow cancelled"
  defp flow_status_label(%OAuthFlow{status: "expired"}), do: "OAuth flow expired"

  defp flow_status_label(%OAuthFlow{status: status}) when is_binary(status),
    do: String.replace(status, "_", " ")

  defp oauth_flow_limit(opts) do
    opts
    |> Keyword.get(:limit, 50)
    |> Lifecycle.positive_integer(50)
    |> min(100)
  end

  defp normalize_id_filter(nil), do: :all

  defp normalize_id_filter(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_id_filter(id) when is_binary(id) do
    id = String.trim(id)
    if id == "", do: [], else: [id]
  end

  defp normalize_id_filter(_ids), do: []

  defp normalize_string_filter(nil), do: []

  defp normalize_string_filter(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_filter(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: [], else: [value]
  end

  defp normalize_string_filter(_value), do: []
end
