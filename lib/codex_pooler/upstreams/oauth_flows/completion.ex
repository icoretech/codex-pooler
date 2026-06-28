defmodule CodexPooler.Upstreams.OAuthFlows.Completion do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.{CodexAuth, OAuthCallback}
  alias CodexPooler.Upstreams.OAuthFlows.Lifecycle
  alias CodexPooler.Upstreams.Schemas.OAuthFlow
  alias CodexPooler.Upstreams.TokenLinking

  @type lifecycle_error :: Lifecycle.lifecycle_error()
  @type completion_result ::
          {:ok,
           %{
             required(:status) => atom(),
             required(:flow) => OAuthFlow.t(),
             optional(:callback) => map()
           }}
          | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec complete_browser_oauth(Scope.t(), Ecto.UUID.t(), String.t()) :: completion_result()
  def complete_browser_oauth(%Scope{} = scope, flow_id, callback_url)
      when is_binary(flow_id) and is_binary(callback_url) do
    Repo.transaction(fn ->
      with %OAuthFlow{} = flow <- Lifecycle.lock_oauth_flow(flow_id),
           :ok <- Lifecycle.require_pool_operate(scope, flow.pool_id),
           {:ok, callback_result} <- parse_authorized_browser_callback(flow, callback_url) do
        complete_browser_flow_state(scope, flow, callback_result)
      else
        nil -> oauth_error(OAuthCallback.safe_error(:flow_not_pending))
        {:error, reason} -> oauth_error(reason)
      end
    end)
    |> Lifecycle.unwrap_transaction()
  end

  def complete_browser_oauth(_scope, _flow_id, _callback_url),
    do: {:error, Lifecycle.invalid_request_error()}

  @spec poll_device_oauth(Scope.t(), Ecto.UUID.t()) :: completion_result()
  def poll_device_oauth(%Scope{} = scope, flow_id) when is_binary(flow_id) do
    Repo.transaction(fn ->
      case Lifecycle.locked_operable_flow(scope, flow_id) do
        {:ok, flow} -> poll_device_flow_state(scope, flow)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Lifecycle.unwrap_transaction()
  end

  def poll_device_oauth(_scope, _flow_id), do: {:error, Lifecycle.invalid_request_error()}

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
      DateTime.compare(flow.expires_at, Lifecycle.now()) != :gt ->
        Lifecycle.expire_locked_flow!(flow)
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
      DateTime.compare(flow.expires_at, Lifecycle.now()) != :gt ->
        Lifecycle.expire_locked_flow!(flow)
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

  defp require_matching_state(%OAuthFlow{} = flow, state_token) when is_binary(state_token) do
    if flow.state_token_hash == Lifecycle.hash_state_token(state_token) do
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

  defp complete_pending_browser_flow(
         %Scope{} = _scope,
         %OAuthFlow{} = flow,
         {:provider_denied, reason}
       ) do
    Lifecycle.fail_oauth_flow!(flow, reason)
    oauth_error(reason)
  end

  defp complete_pending_browser_flow(%Scope{} = scope, %OAuthFlow{} = flow, {:code, callback}) do
    complete_pending_oauth_flow(
      scope,
      flow,
      fn ->
        with {:ok, verifier} <- Lifecycle.decrypt_code_verifier(flow) do
          CodexAuth.exchange_authorization_code(callback.code, verifier, flow.redirect_uri)
        end
      end,
      browser_completion_config()
    )
  end

  defp poll_pending_device_flow(%Scope{} = scope, %OAuthFlow{} = flow) do
    case poll_device_authorization_result(flow) do
      {:error, %{code: code, retry_after_seconds: retry_after_seconds}}
      when code in [:codex_device_authorization_pending, :codex_device_authorization_slow_down] ->
        polled_flow = Lifecycle.update_device_poll!(flow, retry_after_seconds)
        %{status: :pending, flow: polled_flow}

      {:error, %{code: :codex_device_code_expired}} ->
        Lifecycle.expire_locked_flow!(flow)
        oauth_error(OAuthCallback.safe_error(:expired_flow))

      token_result ->
        complete_pending_oauth_flow(
          scope,
          flow,
          fn -> token_result end,
          device_completion_config()
        )
    end
  end

  defp poll_device_authorization_result(%OAuthFlow{} = flow) do
    with {:ok, device_auth_id} <- Lifecycle.decrypt_device_auth_id(flow) do
      CodexAuth.poll_device_authorization(%{
        "device_auth_id" => device_auth_id,
        "user_code" => flow.device_user_code,
        "poll_interval_seconds" => flow.interval_seconds
      })
    end
  end

  defp complete_pending_oauth_flow(
         %Scope{} = scope,
         %OAuthFlow{} = flow,
         token_result_fun,
         config
       ) do
    with {:ok, tokens} <- token_result_fun.(),
         {:ok, token_info} <- CodexAuth.token_info(tokens.id_token),
         %Pool{} = pool <- Repo.get(Pool, flow.pool_id) do
      link_pending_oauth_flow!(scope, pool, flow, tokens, token_info, config)
    else
      error -> oauth_completion_error(flow, error, config)
    end
  end

  defp link_pending_oauth_flow!(
         %Scope{} = scope,
         %Pool{} = pool,
         %OAuthFlow{} = flow,
         tokens,
         token_info,
         config
       ) do
    case TokenLinking.link_tokens(scope, pool, oauth_link_attrs(tokens, token_info, config),
           onboarding_method: config.onboarding_method,
           actor_metadata_key: "oauth_linked_by_user_id",
           audit_action: config.audit_action,
           broadcast_reason: "upstream_account_oauth_linked",
           quota_trigger_kind: "account_link",
           token_refresh_trigger_kind: config.token_refresh_trigger_kind,
           target_identity_id: flow.upstream_identity_id
         ) do
      {:ok, link_result} ->
        case mark_oauth_flow_completed(flow, scope, link_result, config) do
          {:ok, completed_flow} -> oauth_completion_result(completed_flow, link_result)
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, link_error} ->
        reason = oauth_link_failure(link_error)
        Lifecycle.fail_oauth_flow!(flow, reason)
        oauth_error(reason)
    end
  end

  defp oauth_link_failure({:identity_conflict, _reason, _metadata}),
    do: OAuthCallback.safe_error(:identity_conflict)

  defp oauth_link_failure(%{code: code}) when code in [:identity_conflict, :identity_mismatch],
    do: OAuthCallback.safe_error(code)

  defp oauth_link_failure(_reason), do: OAuthCallback.safe_error(:token_exchange_failed)

  defp oauth_link_attrs(tokens, token_info, config) do
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
      identity_metadata: oauth_identity_metadata(token_info, config.identity_onboarding_method)
    }
  end

  defp oauth_identity_metadata(token_info, onboarding_method) do
    %{
      "onboarding_method" => onboarding_method,
      "auth_provider" => "openai"
    }
    |> maybe_put_metadata("account_email", token_info.email)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata

  defp maybe_put_metadata(metadata, key, value) when is_binary(value),
    do: Map.put(metadata, key, value)

  defp mark_oauth_flow_completed(%OAuthFlow{} = flow, %Scope{} = scope, link_result, config) do
    timestamp = Lifecycle.now()

    attrs =
      %{
        status: "completed",
        completed_at: timestamp,
        result_upstream_identity_id: link_result.identity.id,
        error_code: nil,
        error_message: nil,
        metadata: completed_flow_metadata(flow.metadata, scope, config.completion_method),
        updated_at: timestamp
      }
      |> maybe_put_last_polled_at(timestamp, config)

    flow
    |> OAuthFlow.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_put_last_polled_at(attrs, timestamp, %{touch_last_polled?: true}),
    do: Map.put(attrs, :last_polled_at, timestamp)

  defp maybe_put_last_polled_at(attrs, _timestamp, _config), do: attrs

  defp completed_flow_metadata(metadata, %Scope{} = scope, completion_method) do
    (metadata || %{})
    |> Map.put("completed_by_user_id", scope.user.id)
    |> Map.put("completion_method", completion_method)
  end

  defp oauth_completion_result(%OAuthFlow{} = flow, link_result) do
    %{
      status: :completed,
      link_status: link_result.status,
      flow: flow,
      identity: link_result.identity,
      assignment: link_result.assignment,
      secret_status: link_result.secret_status
    }
  end

  defp oauth_completion_error(%OAuthFlow{} = flow, nil, _config) do
    reason = OAuthCallback.safe_error(:flow_not_pending)
    Lifecycle.fail_oauth_flow!(flow, reason)
    oauth_error(reason)
  end

  defp oauth_completion_error(%OAuthFlow{} = flow, {:error, %{code: code}}, config) do
    reason =
      cond do
        code in config.provider_denied_codes ->
          OAuthCallback.safe_error(:provider_denied)

        code in config.token_exchange_failure_codes ->
          OAuthCallback.safe_error(:token_exchange_failed)

        code in [:identity_conflict, :identity_mismatch] ->
          OAuthCallback.safe_error(code)

        true ->
          OAuthCallback.safe_error(:token_exchange_failed)
      end

    Lifecycle.fail_oauth_flow!(flow, reason)
    oauth_error(reason)
  end

  defp oauth_completion_error(%OAuthFlow{} = flow, {:error, _reason}, _config) do
    reason = OAuthCallback.safe_error(:token_exchange_failed)
    Lifecycle.fail_oauth_flow!(flow, reason)
    oauth_error(reason)
  end

  defp browser_completion_config do
    %{
      onboarding_method: "browser",
      identity_onboarding_method: "browser_oauth",
      audit_action: "upstream_account.oauth_browser_link",
      token_refresh_trigger_kind: "oauth_browser_link",
      completion_method: "browser",
      touch_last_polled?: false,
      provider_denied_codes: [],
      token_exchange_failure_codes: [
        :upstream_oauth_transient_secret_not_found,
        :codex_id_token_invalid,
        :codex_oauth_exchange_failed,
        :codex_auth_transient,
        :codex_auth_unavailable
      ]
    }
  end

  defp device_completion_config do
    %{
      onboarding_method: "device",
      identity_onboarding_method: "device_oauth",
      audit_action: "upstream_account.oauth_device_link",
      token_refresh_trigger_kind: "oauth_device_link",
      completion_method: "device",
      touch_last_polled?: true,
      provider_denied_codes: [:codex_device_authorization_denied],
      token_exchange_failure_codes: [
        :upstream_oauth_transient_secret_not_found,
        :codex_id_token_invalid,
        :codex_oauth_exchange_failed,
        :codex_auth_transient,
        :codex_auth_unavailable,
        :codex_auth_malformed
      ]
    }
  end

  defp oauth_error(reason), do: Lifecycle.oauth_error(reason)
end
