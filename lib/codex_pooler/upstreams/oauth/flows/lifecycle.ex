defmodule CodexPooler.Upstreams.OAuthFlows.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.{CodexAuth, OAuthCallback}
  alias CodexPooler.Upstreams.Schemas.OAuthFlow
  alias CodexPooler.Upstreams.SecretBox

  @terminal_retention_days 7
  @browser_flow_ttl_seconds 600
  @device_flow_ttl_seconds 600
  @manual_callback_state_bytes 32
  @safe_start_metadata_keys MapSet.new(["source", "initiated_from", "ui_surface", "flow_label"])

  @type lifecycle_error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }
  @type flow_result :: {:ok, OAuthFlow.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type start_result ::
          {:ok, %{required(:flow) => OAuthFlow.t(), optional(:authorization_url) => String.t()}}
          | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type cleanup_result :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
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

  @spec cancel_oauth_flow(Scope.t(), Ecto.UUID.t()) :: flow_result()
  def cancel_oauth_flow(%Scope{} = scope, flow_id) when is_binary(flow_id) do
    Repo.transaction(fn ->
      case locked_operable_flow(scope, flow_id) do
        {:ok, flow} -> cancel_flow_state(flow)
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

  @spec locked_operable_flow(Scope.t(), Ecto.UUID.t()) ::
          {:ok, OAuthFlow.t()} | {:error, lifecycle_error()}
  def locked_operable_flow(%Scope{} = scope, flow_id) when is_binary(flow_id) do
    case lock_oauth_flow(flow_id) do
      %OAuthFlow{} = flow -> authorize_locked_flow(scope, flow)
      nil -> {:error, OAuthCallback.safe_error(:flow_not_pending)}
    end
  end

  @spec lock_oauth_flow(Ecto.UUID.t()) :: OAuthFlow.t() | nil
  def lock_oauth_flow(flow_id) do
    Repo.one(
      from(flow in OAuthFlow,
        where: flow.id == ^flow_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp authorize_locked_flow(%Scope{} = scope, %OAuthFlow{} = flow) do
    case require_pool_operate(scope, flow.pool_id) do
      :ok -> {:ok, flow}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec require_pool_operate(Scope.t(), Pool.t() | Ecto.UUID.t() | term()) ::
          :ok | {:error, lifecycle_error()}
  def require_pool_operate(%Scope{} = scope, %Pool{} = pool),
    do: require_pool_operate(scope, pool.id)

  def require_pool_operate(%Scope{} = scope, pool_id) when is_binary(pool_id) do
    case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id) do
      {:ok, _decision} -> :ok
      {:error, _reason} -> {:error, OAuthCallback.safe_error(:unauthorized_pool)}
    end
  end

  def require_pool_operate(_scope, _pool_id),
    do: {:error, OAuthCallback.safe_error(:unauthorized_pool)}

  @spec expire_locked_flow!(OAuthFlow.t()) :: OAuthFlow.t()
  def expire_locked_flow!(%OAuthFlow{} = flow) do
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

  @spec update_device_poll!(OAuthFlow.t(), term()) :: OAuthFlow.t()
  def update_device_poll!(%OAuthFlow{} = flow, retry_after_seconds) do
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

  @spec fail_oauth_flow!(OAuthFlow.t(), lifecycle_error()) :: OAuthFlow.t()
  def fail_oauth_flow!(%OAuthFlow{} = flow, reason) do
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

  @spec positive_integer(term(), pos_integer()) :: pos_integer()
  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  def positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> default
    end
  end

  def positive_integer(_value, default), do: default

  @spec invalid_request_error() :: lifecycle_error()
  def invalid_request_error do
    %{code: :invalid_request, message: "OAuth flow request is invalid"}
  end

  @spec unwrap_transaction({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def unwrap_transaction({:ok, {:oauth_error, reason}}), do: {:error, reason}
  def unwrap_transaction({:ok, result}), do: {:ok, result}
  def unwrap_transaction({:error, reason}), do: {:error, reason}

  @spec now() :: DateTime.t()
  def now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  @spec oauth_error(lifecycle_error()) :: {:oauth_error, lifecycle_error()}
  def oauth_error(reason), do: {:oauth_error, reason}

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

  defp generate_state_token do
    @manual_callback_state_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
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
end
