defmodule CodexPooler.Upstreams.OAuthFlows do
  @moduledoc """
  Persistence lifecycle for OpenAI OAuth upstream-linking flow state.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.{CodexAuth, OAuthCallback}
  alias CodexPooler.Upstreams.Schemas.{OAuthFlow, UpstreamIdentity}
  alias CodexPooler.Upstreams.SecretBox
  alias CodexPooler.Upstreams.TokenLinking

  @terminal_retention_days 7
  @browser_flow_ttl_seconds 600
  @device_flow_ttl_seconds 600
  @manual_callback_state_bytes 32
  @safe_start_metadata_keys MapSet.new(["source", "initiated_from", "ui_surface", "flow_label"])

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type flow_result :: {:ok, OAuthFlow.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type start_result ::
          {:ok, %{required(:flow) => OAuthFlow.t(), optional(:authorization_url) => String.t()}}
          | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type completion_result ::
          {:ok,
           %{
             required(:status) => atom(),
             required(:flow) => OAuthFlow.t(),
             optional(:callback) => map()
           }}
          | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type cleanup_result :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
        }
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

  @spec start_browser_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  def start_browser_oauth(scope, pool, opts \\ [])

  def start_browser_oauth(%Scope{} = scope, %Pool{} = pool, opts) when is_list(opts) do
    with :ok <- require_pool_operate(scope, pool) do
      state_token = generate_state_token()
      pkce = CodexAuth.generate_pkce_pair()
      timestamp = now()

      attrs = %{
        pool_id: pool.id,
        upstream_identity_id: upstream_identity_id(opts),
        requested_by_user_id: scope.user.id,
        flow_kind: "browser",
        purpose: flow_purpose(opts),
        status: OAuthFlow.pending_status(),
        state_token: state_token,
        redirect_uri: CodexAuth.browser_redirect_uri(),
        code_verifier: pkce.code_verifier,
        expires_at:
          Keyword.get(opts, :expires_at, DateTime.add(timestamp, @browser_flow_ttl_seconds)),
        metadata: safe_start_metadata(scope, opts)
      }

      with {:ok, flow} <- start_oauth_flow(pool, attrs, timestamp) do
        {:ok,
         %{
           flow: flow,
           authorization_url:
             CodexAuth.build_browser_authorization_url(state_token, pkce.code_challenge)
         }}
      end
    end
  end

  def start_browser_oauth(_scope, _pool, _opts), do: {:error, invalid_request_error()}

  @spec start_device_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  def start_device_oauth(scope, pool, opts \\ [])

  def start_device_oauth(%Scope{} = scope, %Pool{} = pool, opts) when is_list(opts) do
    with :ok <- require_pool_operate(scope, pool),
         {:ok, device_code} <- CodexAuth.request_device_code() do
      timestamp = now()

      poll_interval =
        positive_integer(device_code["poll_interval_seconds"] || device_code["interval"], 5)

      attrs = %{
        pool_id: pool.id,
        upstream_identity_id: upstream_identity_id(opts),
        requested_by_user_id: scope.user.id,
        flow_kind: "device",
        purpose: flow_purpose(opts),
        status: OAuthFlow.pending_status(),
        device_auth_id: device_code["device_auth_id"],
        device_user_code: device_code["user_code"],
        verification_uri: device_code["verification_uri"] || device_code["verification_url"],
        interval_seconds: poll_interval,
        poll_after_at: DateTime.add(timestamp, poll_interval),
        expires_at: device_expires_at(device_code, timestamp),
        metadata: safe_start_metadata(scope, opts)
      }

      with {:ok, flow} <- start_oauth_flow(pool, attrs, timestamp) do
        {:ok, %{flow: flow}}
      end
    end
  end

  def start_device_oauth(_scope, _pool, _opts), do: {:error, invalid_request_error()}

  @spec list_visible_oauth_flow_summaries(Scope.t(), keyword()) :: [safe_flow_summary()]
  def list_visible_oauth_flow_summaries(scope, opts \\ [])

  def list_visible_oauth_flow_summaries(%Scope{} = scope, opts) when is_list(opts) do
    scope
    |> visible_pool_ids(opts)
    |> list_visible_oauth_flow_summaries_for_pool_ids(opts)
  end

  def list_visible_oauth_flow_summaries(_scope, _opts), do: []

  @spec complete_browser_oauth(Scope.t(), Ecto.UUID.t(), String.t()) :: completion_result()
  def complete_browser_oauth(%Scope{} = scope, flow_id, callback_url)
      when is_binary(flow_id) and is_binary(callback_url) do
    Repo.transaction(fn ->
      with %OAuthFlow{} = flow <- lock_oauth_flow(flow_id),
           :ok <- require_pool_operate(scope, flow.pool_id),
           {:ok, callback_result} <- parse_authorized_browser_callback(flow, callback_url) do
        complete_browser_flow_state(scope, flow, callback_result)
      else
        nil -> oauth_error(OAuthCallback.safe_error(:flow_not_pending))
        {:error, reason} -> oauth_error(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def complete_browser_oauth(_scope, _flow_id, _callback_url),
    do: {:error, invalid_request_error()}

  @spec poll_device_oauth(Scope.t(), Ecto.UUID.t()) :: completion_result()
  def poll_device_oauth(%Scope{} = scope, flow_id) when is_binary(flow_id) do
    Repo.transaction(fn ->
      with %OAuthFlow{} = flow <- lock_oauth_flow(flow_id),
           :ok <- require_pool_operate(scope, flow.pool_id) do
        poll_device_flow_state(scope, flow)
      else
        nil -> Repo.rollback(OAuthCallback.safe_error(:flow_not_pending))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def poll_device_oauth(_scope, _flow_id), do: {:error, invalid_request_error()}

  @spec cancel_oauth_flow(Scope.t(), Ecto.UUID.t()) :: flow_result()
  def cancel_oauth_flow(%Scope{} = scope, flow_id) when is_binary(flow_id) do
    Repo.transaction(fn ->
      with %OAuthFlow{} = flow <- lock_oauth_flow(flow_id),
           :ok <- require_pool_operate(scope, flow.pool_id) do
        cancel_flow_state(flow)
      else
        nil -> Repo.rollback(OAuthCallback.safe_error(:flow_not_pending))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  def cancel_oauth_flow(_scope, _flow_id), do: {:error, invalid_request_error()}

  @spec expire_oauth_flows(DateTime.t()) :: cleanup_result()
  def expire_oauth_flows(%DateTime{} = now) do
    {expired, _rows} = expire_pending_oauth_flows(now)
    %{expired: expired, deleted: 0}
  end

  @spec create_oauth_flow(map()) :: flow_result()
  def create_oauth_flow(attrs) when is_map(attrs) do
    %OAuthFlow{}
    |> OAuthFlow.changeset(attrs)
    |> Repo.insert()
  end

  @spec hash_state_token(String.t()) :: binary()
  def hash_state_token(state_token) when is_binary(state_token) do
    state_token
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec decrypt_code_verifier(OAuthFlow.t()) :: {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_code_verifier(%OAuthFlow{} = flow) do
    decrypt_transient_secret(flow.code_verifier_ciphertext)
  end

  @spec decrypt_device_auth_id(OAuthFlow.t()) :: {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_device_auth_id(%OAuthFlow{} = flow) do
    decrypt_transient_secret(flow.device_auth_id_ciphertext)
  end

  @spec cleanup_oauth_flows(DateTime.t()) :: cleanup_result()
  def cleanup_oauth_flows(%DateTime{} = now) do
    {expired, _rows} = expire_pending_oauth_flows(now)
    {deleted, _rows} = delete_terminal_oauth_flows(now)
    %{expired: expired, deleted: deleted}
  end

  @spec expire_pending_oauth_flows(DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  def expire_pending_oauth_flows(%DateTime{} = now) do
    Repo.update_all(
      from(flow in OAuthFlow,
        where: flow.status == ^OAuthFlow.pending_status(),
        where: flow.expires_at <= ^now
      ),
      set: [
        status: OAuthFlow.expired_status(),
        error_code: "expired_flow",
        error_message: "OAuth flow expired",
        updated_at: now
      ]
    )
  end

  @spec delete_terminal_oauth_flows(DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  def delete_terminal_oauth_flows(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@terminal_retention_days, :day)

    Repo.delete_all(
      from(flow in OAuthFlow,
        where: flow.status in ^OAuthFlow.terminal_statuses(),
        where: flow.updated_at < ^cutoff
      )
    )
  end

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
    |> positive_integer(50)
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

  defp start_oauth_flow(%Pool{} = pool, attrs, %DateTime{} = timestamp) do
    Repo.transaction(fn ->
      lock_start_scope!(pool.id, attrs.upstream_identity_id, attrs.purpose)

      cancel_superseded_pending_flows!(
        pool.id,
        attrs.upstream_identity_id,
        attrs.purpose,
        timestamp
      )

      case create_oauth_flow(attrs) do
        {:ok, flow} -> flow
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp complete_browser_flow_state(_scope, %OAuthFlow{status: "completed"} = flow, _callback) do
    %{status: :completed, flow: flow}
  end

  defp complete_browser_flow_state(_scope, %OAuthFlow{status: "expired"}, _callback) do
    oauth_error(OAuthCallback.safe_error(:expired_flow))
  end

  defp complete_browser_flow_state(_scope, %OAuthFlow{status: "cancelled"}, _callback) do
    oauth_error(OAuthCallback.safe_error(:stale_flow))
  end

  defp complete_browser_flow_state(
         %Scope{} = scope,
         %OAuthFlow{status: "pending"} = flow,
         callback_result
       ) do
    cond do
      DateTime.compare(flow.expires_at, now()) != :gt ->
        expire_locked_flow!(flow)
        oauth_error(OAuthCallback.safe_error(:expired_flow))

      flow.flow_kind != "browser" ->
        oauth_error(OAuthCallback.safe_error(:flow_not_pending))

      true ->
        complete_pending_browser_flow(scope, flow, callback_result)
    end
  end

  defp complete_browser_flow_state(_scope, %OAuthFlow{}, _callback) do
    oauth_error(OAuthCallback.safe_error(:flow_not_pending))
  end

  defp poll_device_flow_state(_scope, %OAuthFlow{status: "completed"} = flow) do
    %{status: :completed, flow: flow}
  end

  defp poll_device_flow_state(_scope, %OAuthFlow{status: "expired"}) do
    Repo.rollback(OAuthCallback.safe_error(:expired_flow))
  end

  defp poll_device_flow_state(_scope, %OAuthFlow{status: "cancelled"}) do
    Repo.rollback(OAuthCallback.safe_error(:stale_flow))
  end

  defp poll_device_flow_state(%Scope{} = scope, %OAuthFlow{status: "pending"} = flow) do
    cond do
      DateTime.compare(flow.expires_at, now()) != :gt ->
        expire_locked_flow!(flow)
        Repo.rollback(OAuthCallback.safe_error(:expired_flow))

      flow.flow_kind != "device" ->
        Repo.rollback(OAuthCallback.safe_error(:flow_not_pending))

      true ->
        poll_pending_device_flow(scope, flow)
    end
  end

  defp poll_device_flow_state(_scope, %OAuthFlow{}) do
    Repo.rollback(OAuthCallback.safe_error(:flow_not_pending))
  end

  defp cancel_flow_state(%OAuthFlow{status: "pending"} = flow) do
    timestamp = now()

    flow
    |> OAuthFlow.changeset(%{
      status: "cancelled",
      cancelled_at: timestamp,
      error_code: "stale_flow",
      error_message: OAuthCallback.safe_error(:stale_flow).message,
      updated_at: timestamp
    })
    |> Repo.update()
    |> case do
      {:ok, flow} -> flow
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_flow_state(%OAuthFlow{status: "cancelled"} = flow), do: flow

  defp cancel_flow_state(%OAuthFlow{status: "expired"}) do
    Repo.rollback(OAuthCallback.safe_error(:expired_flow))
  end

  defp cancel_flow_state(%OAuthFlow{}) do
    Repo.rollback(OAuthCallback.safe_error(:flow_not_pending))
  end

  defp require_matching_state(%OAuthFlow{} = flow, state_token) when is_binary(state_token) do
    if flow.state_token_hash == hash_state_token(state_token) do
      :ok
    else
      {:error, OAuthCallback.safe_error(:invalid_state)}
    end
  end

  defp parse_authorized_browser_callback(%OAuthFlow{} = flow, callback_url) do
    case OAuthCallback.parse(callback_url) do
      {:ok, callback} ->
        with :ok <- require_matching_state(flow, callback.state) do
          {:ok, {:code, callback}}
        end

      {:error, %{code: :provider_denied, state: state} = reason} ->
        with :ok <- require_matching_state(flow, state) do
          {:ok, {:provider_denied, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_oauth_flow(flow_id) do
    Repo.one(
      from(flow in OAuthFlow,
        where: flow.id == ^flow_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_start_scope!(pool_id, upstream_identity_id, purpose) do
    key = :erlang.phash2({pool_id, upstream_identity_id, purpose}, 2_147_483_647)
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
  end

  defp cancel_superseded_pending_flows!(pool_id, upstream_identity_id, purpose, timestamp) do
    pending_start_scope_query(pool_id, upstream_identity_id, purpose)
    |> Repo.update_all(
      set: [
        status: "cancelled",
        cancelled_at: timestamp,
        error_code: "stale_flow",
        error_message: OAuthCallback.safe_error(:stale_flow).message,
        updated_at: timestamp
      ]
    )
  end

  defp pending_start_scope_query(pool_id, nil, purpose) do
    from(flow in OAuthFlow,
      where: flow.pool_id == ^pool_id,
      where: flow.purpose == ^purpose,
      where: flow.status == ^OAuthFlow.pending_status(),
      where: is_nil(flow.upstream_identity_id)
    )
  end

  defp pending_start_scope_query(pool_id, upstream_identity_id, purpose) do
    from(flow in OAuthFlow,
      where: flow.pool_id == ^pool_id,
      where: flow.purpose == ^purpose,
      where: flow.status == ^OAuthFlow.pending_status(),
      where: flow.upstream_identity_id == ^upstream_identity_id
    )
  end

  defp expire_locked_flow!(%OAuthFlow{} = flow) do
    timestamp = now()

    flow
    |> OAuthFlow.changeset(%{
      status: "expired",
      error_code: "expired_flow",
      error_message: OAuthCallback.safe_error(:expired_flow).message,
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp require_pool_operate(%Scope{} = scope, %Pool{} = pool),
    do: require_pool_operate(scope, pool.id)

  defp require_pool_operate(%Scope{} = scope, pool_id) when is_binary(pool_id) do
    case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id) do
      {:ok, _decision} -> :ok
      {:error, _reason} -> {:error, OAuthCallback.safe_error(:unauthorized_pool)}
    end
  end

  defp require_pool_operate(_scope, _pool_id),
    do: {:error, OAuthCallback.safe_error(:unauthorized_pool)}

  defp flow_purpose(opts) when is_list(opts) do
    case Keyword.get(opts, :purpose) do
      purpose when purpose in ["link", "relink"] ->
        purpose

      _purpose ->
        if upstream_identity_id(opts), do: "relink", else: "link"
    end
  end

  defp upstream_identity_id(opts) when is_list(opts) do
    cond do
      is_binary(Keyword.get(opts, :upstream_identity_id)) ->
        Keyword.fetch!(opts, :upstream_identity_id)

      match?(%{id: id} when is_binary(id), Keyword.get(opts, :upstream_identity)) ->
        Keyword.fetch!(opts, :upstream_identity).id

      true ->
        nil
    end
  end

  defp safe_start_metadata(%Scope{} = scope, opts) when is_list(opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> sanitize_metadata()
    |> Map.put("requested_by_user_id", scope.user.id)
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_atom(key) ->
        maybe_put_safe_metadata(acc, Atom.to_string(key), value)

      {key, value}, acc when is_binary(key) ->
        maybe_put_safe_metadata(acc, key, value)

      _entry, acc ->
        acc
    end)
  end

  defp sanitize_metadata(_metadata), do: %{}

  defp maybe_put_safe_metadata(acc, key, value) when is_binary(key) do
    key = String.trim(key)

    cond do
      not MapSet.member?(@safe_start_metadata_keys, key) ->
        acc

      is_binary(value) ->
        Map.put(acc, key, String.slice(value, 0, 256))

      is_boolean(value) or is_integer(value) ->
        Map.put(acc, key, value)

      true ->
        acc
    end
  end

  defp device_expires_at(device_code, timestamp) when is_map(device_code) do
    case DateTime.from_iso8601(to_string(device_code["expires_at"])) do
      {:ok, expires_at, _offset} -> DateTime.truncate(expires_at, :microsecond)
      _invalid -> DateTime.add(timestamp, @device_flow_ttl_seconds)
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp generate_state_token do
    @manual_callback_state_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp invalid_request_error do
    %{code: :invalid_request, message: "OAuth flow request is invalid"}
  end

  defp unwrap_transaction({:ok, {:oauth_error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp decrypt_transient_secret(ciphertext) when is_binary(ciphertext) do
    SecretBox.decrypt_envelope(ciphertext)
  end

  defp decrypt_transient_secret(_ciphertext) do
    {:error,
     %{
       code: :upstream_oauth_transient_secret_not_found,
       message: "OAuth flow transient secret was not found"
     }}
  end

  defp complete_pending_browser_flow(
         %Scope{} = _scope,
         %OAuthFlow{} = flow,
         {:provider_denied, reason}
       ) do
    fail_oauth_flow!(flow, reason)
    oauth_error(reason)
  end

  defp complete_pending_browser_flow(%Scope{} = scope, %OAuthFlow{} = flow, {:code, callback}) do
    with {:ok, verifier} <- decrypt_code_verifier(flow),
         {:ok, tokens} <-
           CodexAuth.exchange_authorization_code(callback.code, verifier, flow.redirect_uri),
         {:ok, token_info} <- CodexAuth.token_info(tokens.id_token),
         %Pool{} = pool <- Repo.get(Pool, flow.pool_id) do
      link_pending_browser_flow!(scope, pool, flow, tokens, token_info)
    else
      nil ->
        reason = OAuthCallback.safe_error(:flow_not_pending)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: code}}
      when code in [:upstream_oauth_transient_secret_not_found, :codex_id_token_invalid] ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: :codex_oauth_exchange_failed}} ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: :codex_auth_transient}} ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: :codex_auth_unavailable}} ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: code}} when code in [:identity_conflict, :identity_mismatch] ->
        reason = OAuthCallback.safe_error(code)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, _reason} ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)
    end
  end

  defp poll_pending_device_flow(%Scope{} = scope, %OAuthFlow{} = flow) do
    with {:ok, device_auth_id} <- decrypt_device_auth_id(flow),
         {:ok, tokens} <-
           CodexAuth.poll_device_authorization(%{
             "device_auth_id" => device_auth_id,
             "user_code" => flow.device_user_code,
             "poll_interval_seconds" => flow.interval_seconds
           }),
         {:ok, token_info} <- CodexAuth.token_info(tokens.id_token),
         %Pool{} = pool <- Repo.get(Pool, flow.pool_id) do
      link_pending_device_flow!(scope, pool, flow, tokens, token_info)
    else
      nil ->
        reason = OAuthCallback.safe_error(:flow_not_pending)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: code, retry_after_seconds: retry_after_seconds}}
      when code in [:codex_device_authorization_pending, :codex_device_authorization_slow_down] ->
        polled_flow = update_device_poll!(flow, retry_after_seconds)
        %{status: :pending, flow: polled_flow}

      {:error, %{code: :codex_device_code_expired}} ->
        expire_locked_flow!(flow)
        oauth_error(OAuthCallback.safe_error(:expired_flow))

      {:error, %{code: :codex_device_authorization_denied}} ->
        reason = OAuthCallback.safe_error(:provider_denied)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: code}}
      when code in [
             :upstream_oauth_transient_secret_not_found,
             :codex_id_token_invalid,
             :codex_oauth_exchange_failed,
             :codex_auth_transient,
             :codex_auth_unavailable,
             :codex_auth_malformed
           ] ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, %{code: code}} when code in [:identity_conflict, :identity_mismatch] ->
        reason = OAuthCallback.safe_error(code)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)

      {:error, _reason} ->
        reason = OAuthCallback.safe_error(:token_exchange_failed)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)
    end
  end

  defp link_pending_browser_flow!(
         %Scope{} = scope,
         %Pool{} = pool,
         %OAuthFlow{} = flow,
         tokens,
         token_info
       ) do
    case TokenLinking.link_tokens(scope, pool, browser_link_attrs(tokens, token_info),
           onboarding_method: "browser",
           actor_metadata_key: "oauth_linked_by_user_id",
           audit_action: "upstream_account.oauth_browser_link",
           broadcast_reason: "upstream_account_oauth_linked",
           quota_trigger_kind: "account_link",
           token_refresh_trigger_kind: "oauth_browser_link",
           target_identity_id: flow.upstream_identity_id
         ) do
      {:ok, link_result} ->
        case mark_browser_flow_completed(flow, scope, link_result) do
          {:ok, completed_flow} -> browser_completion_result(completed_flow, link_result)
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, link_error} ->
        reason = oauth_link_failure(link_error)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)
    end
  end

  defp link_pending_device_flow!(
         %Scope{} = scope,
         %Pool{} = pool,
         %OAuthFlow{} = flow,
         tokens,
         token_info
       ) do
    case TokenLinking.link_tokens(scope, pool, device_link_attrs(tokens, token_info),
           onboarding_method: "device",
           actor_metadata_key: "oauth_linked_by_user_id",
           audit_action: "upstream_account.oauth_device_link",
           broadcast_reason: "upstream_account_oauth_linked",
           quota_trigger_kind: "account_link",
           token_refresh_trigger_kind: "oauth_device_link",
           target_identity_id: flow.upstream_identity_id
         ) do
      {:ok, link_result} ->
        case mark_device_flow_completed(flow, scope, link_result) do
          {:ok, completed_flow} -> device_completion_result(completed_flow, link_result)
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, link_error} ->
        reason = oauth_link_failure(link_error)
        fail_oauth_flow!(flow, reason)
        oauth_error(reason)
    end
  end

  defp oauth_link_failure({:identity_conflict, _reason, _metadata}),
    do: OAuthCallback.safe_error(:identity_conflict)

  defp oauth_link_failure(%{code: code}) when code in [:identity_conflict, :identity_mismatch],
    do: OAuthCallback.safe_error(code)

  defp oauth_link_failure(_reason), do: OAuthCallback.safe_error(:token_exchange_failed)

  defp browser_link_attrs(tokens, token_info) do
    %{
      chatgpt_account_id: token_info.chatgpt_account_id,
      account_email: token_info.email,
      account_label: token_info.email || token_info.chatgpt_account_id || "Codex account",
      workspace_id: token_info.workspace_id,
      workspace_label: token_info.workspace_label,
      seat_type: token_info.seat_type,
      plan_label: token_info.plan_label,
      token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      identity_metadata: browser_identity_metadata(token_info)
    }
  end

  defp browser_identity_metadata(token_info) do
    %{
      "onboarding_method" => "browser_oauth",
      "auth_provider" => "openai"
    }
    |> maybe_put_metadata("account_email", token_info.email)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata

  defp maybe_put_metadata(metadata, key, value) when is_binary(value),
    do: Map.put(metadata, key, value)

  defp device_link_attrs(tokens, token_info) do
    %{
      chatgpt_account_id: token_info.chatgpt_account_id,
      account_email: token_info.email,
      account_label: token_info.email || token_info.chatgpt_account_id || "Codex account",
      workspace_id: token_info.workspace_id,
      workspace_label: token_info.workspace_label,
      seat_type: token_info.seat_type,
      plan_label: token_info.plan_label,
      token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      identity_metadata: device_identity_metadata(token_info)
    }
  end

  defp device_identity_metadata(token_info) do
    %{
      "onboarding_method" => "device_oauth",
      "auth_provider" => "openai"
    }
    |> maybe_put_metadata("account_email", token_info.email)
  end

  defp mark_browser_flow_completed(%OAuthFlow{} = flow, %Scope{} = scope, link_result) do
    timestamp = now()

    flow
    |> OAuthFlow.changeset(%{
      status: "completed",
      completed_at: timestamp,
      result_upstream_identity_id: link_result.identity.id,
      error_code: nil,
      error_message: nil,
      metadata: completed_flow_metadata(flow.metadata, scope),
      updated_at: timestamp
    })
    |> Repo.update()
  end

  defp mark_device_flow_completed(%OAuthFlow{} = flow, %Scope{} = scope, link_result) do
    timestamp = now()

    flow
    |> OAuthFlow.changeset(%{
      status: "completed",
      completed_at: timestamp,
      last_polled_at: timestamp,
      result_upstream_identity_id: link_result.identity.id,
      error_code: nil,
      error_message: nil,
      metadata: completed_device_flow_metadata(flow.metadata, scope),
      updated_at: timestamp
    })
    |> Repo.update()
  end

  defp completed_flow_metadata(metadata, %Scope{} = scope) do
    (metadata || %{})
    |> Map.put("completed_by_user_id", scope.user.id)
    |> Map.put("completion_method", "browser")
  end

  defp completed_device_flow_metadata(metadata, %Scope{} = scope) do
    (metadata || %{})
    |> Map.put("completed_by_user_id", scope.user.id)
    |> Map.put("completion_method", "device")
  end

  defp browser_completion_result(%OAuthFlow{} = flow, link_result) do
    %{
      status: :completed,
      link_status: link_result.status,
      flow: flow,
      identity: link_result.identity,
      assignment: link_result.assignment,
      secret_status: link_result.secret_status
    }
  end

  defp device_completion_result(%OAuthFlow{} = flow, link_result) do
    %{
      status: :completed,
      link_status: link_result.status,
      flow: flow,
      identity: link_result.identity,
      assignment: link_result.assignment,
      secret_status: link_result.secret_status
    }
  end

  defp update_device_poll!(%OAuthFlow{} = flow, retry_after_seconds) do
    timestamp = now()
    retry_after_seconds = positive_integer(retry_after_seconds, flow.interval_seconds || 5)

    flow
    |> OAuthFlow.changeset(%{
      interval_seconds: retry_after_seconds,
      poll_after_at: DateTime.add(timestamp, retry_after_seconds, :second),
      last_polled_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp fail_oauth_flow!(%OAuthFlow{} = flow, reason) do
    timestamp = now()

    flow
    |> OAuthFlow.changeset(%{
      status: "failed",
      error_code: Atom.to_string(reason.code),
      error_message: reason.message,
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp oauth_error(reason), do: {:oauth_error, reason}
end
