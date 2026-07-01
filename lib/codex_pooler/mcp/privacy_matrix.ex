defmodule CodexPooler.MCP.PrivacyMatrix do
  @moduledoc """
  Machine-checkable MCP privacy policy for metadata presenters.

  This module is the allowlist future MCP tools must use before returning
  structured content. MCP is an admin metadata surface, but it is still stricter
  than the browser admin UI for PII-heavy fields.
  """

  @type entity_family ::
          :operators
          | :invites
          | :request_logs
          | :audit_logs
          | :upstreams
          | :upstream_quotas
          | :upstream_quota_windows
          | :pools
          | :pool_api_keys
  @type policy_class :: :allowed | :masked | :omitted | :summarized
  @type field_name :: atom()
  @type policy :: %{required(policy_class()) => [field_name()]}

  @entity_families [
    :operators,
    :invites,
    :request_logs,
    :audit_logs,
    :upstreams,
    :upstream_quotas,
    :upstream_quota_windows,
    :pools,
    :pool_api_keys
  ]

  @policies %{
    operators: %{
      allowed: [
        :id,
        :display_name,
        :status,
        :password_change_required,
        :totp_status,
        :created_at,
        :updated_at,
        :deleted_at
      ],
      masked: [:email, :operator_email],
      summarized: [:mcp_enabled, :mcp_key_count, :last_login_at],
      omitted: [
        :password,
        :password_hash,
        :temporary_password,
        :session_token,
        :session_token_hash,
        :totp_secret,
        :totp_secret_ciphertext,
        :recovery_secret,
        :recovery_code,
        :recovery_code_hash,
        :raw_mcp_token,
        :mcp_token_hash,
        :key_hash
      ]
    },
    invites: %{
      allowed: [
        :id,
        :pool_id,
        :pool_name,
        :pool_slug,
        :status,
        :expires_at,
        :created_at,
        :accepted_at,
        :email_sent_at,
        :revoked_at
      ],
      masked: [:invited_email, :invite_recipient, :accepted_by_email],
      summarized: [:created_by_user_id, :creator_summary],
      omitted: [
        :token_hash,
        :invite_url,
        :invite_token,
        :temporary_password,
        :raw_pool_api_key,
        :raw_mcp_token
      ]
    },
    request_logs: %{
      allowed: [
        :id,
        :pool_id,
        :pool_name,
        :pool_slug,
        :api_key_id,
        :api_key_display_name,
        :api_key_prefix,
        :key_prefix,
        :requested_model,
        :transport,
        :status,
        :usage_status,
        :correlation_id,
        :response_status_code,
        :retry_count,
        :denial_reason,
        :latency_ms,
        :token_counts,
        :cost,
        :errors,
        :debug,
        :admitted_at,
        :completed_at,
        :upstream_account_label,
        :upstream_account_plan_label,
        :upstream_account_plan_family,
        :upstream_identity_id,
        :upstream_identity_label,
        :pool_upstream_assignment_id,
        :assignment_label,
        :reasoning_effort,
        :applied_reasoning_effort,
        :effective_reasoning_effort,
        :reasoning_effort_source,
        :reasoning_effort_rewrite,
        :service_tier,
        :requested_service_tier,
        :actual_service_tier,
        :metadata
      ],
      masked: [:upstream_account_email, :client_ip, :ip_address],
      summarized: [:endpoint, :path, :user_agent],
      omitted: [
        :query,
        :idempotency_key,
        :raw_idempotency_key,
        :raw_headers,
        :headers,
        :cookies,
        :cookie,
        :upload_url,
        :download_url,
        :filename,
        :prompt,
        :request_body,
        :response_body,
        :multipart_body,
        :websocket_frame,
        :raw_request,
        :raw_response,
        :authorization,
        :raw_pool_api_key,
        :pool_api_key_hash,
        :raw_mcp_token,
        :mcp_token_hash,
        :upstream_auth_json,
        :access_token,
        :refresh_token,
        :upstream_secret,
        :pii_sentinel
      ]
    },
    audit_logs: %{
      allowed: [
        :id,
        :occurred_at,
        :actor_type,
        :actor_user_id,
        :pool_id,
        :pool_name,
        :pool_slug,
        :request_id,
        :action,
        :target_type,
        :target_id,
        :outcome,
        :correlation_id,
        :details
      ],
      masked: [:actor_user_email, :email, :ip_address, :client_ip],
      summarized: [:actor_summary, :target_summary, :details_summary],
      omitted: [
        :audit_before_blob,
        :audit_after_blob,
        :before,
        :after,
        :raw_before,
        :raw_after,
        :raw_headers,
        :cookies,
        :prompt,
        :request_body,
        :response_body,
        :multipart_body,
        :websocket_frame,
        :raw_idempotency_key,
        :session_token,
        :totp_secret,
        :recovery_secret,
        :temporary_password,
        :smtp_secret,
        :metrics_hmac,
        :metrics_fingerprint
      ]
    },
    upstreams: %{
      allowed: [
        :id,
        :chatgpt_account_id,
        :account_label,
        :workspace_ref,
        :workspace_label,
        :onboarding_method,
        :status,
        :plan_family,
        :plan_label,
        :auth_fresh_at,
        :auth_verified_at,
        :headers_profile_version,
        :last_successful_refresh_at,
        :last_successful_sync_at,
        :disabled_at,
        :created_by_user_id,
        :created_at,
        :updated_at
      ],
      masked: [:account_email, :upstream_account_email],
      summarized: [:quota_summary, :assignment_summary, :metadata],
      omitted: [
        :workspace_id,
        :upstream_auth_json,
        :auth_json,
        :access_token,
        :refresh_token,
        :upstream_secret,
        :encrypted_secret,
        :secret_ciphertext,
        :secret_nonce,
        :secret_aad,
        :cookies,
        :raw_headers,
        :filename,
        :local_path,
        :pii_sentinel
      ]
    },
    upstream_quotas: %{
      allowed: [
        :id,
        :label,
        :stored_account_id,
        :workspace_ref,
        :workspace_label,
        :status,
        :plan_family,
        :assignment_summary,
        :quota_summary,
        :quota_windows
      ],
      masked: [],
      summarized: [],
      omitted: [
        :account_email,
        :upstream_account_email,
        :workspace_id,
        :metadata,
        :raw_metadata,
        :evidence,
        :raw_evidence,
        :provider_payload,
        :provider_json,
        :upstream_auth_json,
        :auth_json,
        :access_token,
        :refresh_token,
        :upstream_secret,
        :encrypted_secret,
        :secret_ciphertext,
        :secret_nonce,
        :secret_aad,
        :cookies,
        :raw_headers,
        :pii_sentinel
      ]
    },
    upstream_quota_windows: %{
      allowed: [
        :quota_kind,
        :quota_scope,
        :quota_family,
        :model,
        :upstream_model,
        :window_minutes,
        :active_limit,
        :remaining_value,
        :credits,
        :used_percent,
        :reset_at,
        :observed_at,
        :freshness_status,
        :routing_usable,
        :routing_unusable_reason,
        :source_precision
      ],
      masked: [],
      summarized: [],
      omitted: [
        :metadata,
        :raw_metadata,
        :evidence,
        :raw_evidence,
        :provider_payload,
        :provider_json,
        :upstream_auth_json,
        :auth_json,
        :access_token,
        :refresh_token,
        :upstream_secret,
        :cookies,
        :raw_headers,
        :pii_sentinel
      ]
    },
    pools: %{
      allowed: [:id, :slug, :name, :status, :created_at, :updated_at, :disabled_at],
      masked: [],
      summarized: [
        :created_by_user_id,
        :operator_count,
        :upstream_count,
        :api_key_count,
        :request_summary,
        :routing_summary
      ],
      omitted: [
        :raw_pool_api_key,
        :pool_api_key_hash,
        :raw_mcp_token,
        :mcp_token_hash,
        :invite_token,
        :invite_url
      ]
    },
    pool_api_keys: %{
      allowed: [
        :id,
        :pool_id,
        :pool_name,
        :pool_slug,
        :display_name,
        :label,
        :key_prefix,
        :api_key_prefix,
        :status,
        :expires_at,
        :last_used_at,
        :allowed_model_identifiers,
        :enforced_model_identifier,
        :enforced_reasoning_effort,
        :enforced_service_tier,
        :created_by_user_id,
        :created_at,
        :revoked_at
      ],
      masked: [],
      summarized: [:metadata, :policy_summary, :usage_summary],
      omitted: [
        :raw_pool_api_key,
        :key_hash,
        :pool_api_key_hash,
        :raw_mcp_token,
        :mcp_token_hash,
        :raw_headers,
        :cookies,
        :prompt,
        :request_body,
        :response_body,
        :pii_sentinel
      ]
    }
  }

  @sentinel_terms [
    :raw_mcp_token,
    :mcp_token_hash,
    :raw_pool_api_key,
    :pool_api_key_hash,
    :invite_url,
    :invite_token,
    :temporary_password,
    :session_token,
    :totp_secret,
    :recovery_secret,
    :upstream_auth_json,
    :access_token,
    :refresh_token,
    :upstream_secret,
    :smtp_secret,
    :metrics_hmac,
    :metrics_fingerprint,
    :raw_headers,
    :cookies,
    :upload_url,
    :filename,
    :prompt,
    :request_body,
    :response_body,
    :multipart_body,
    :websocket_frame,
    :raw_idempotency_key,
    :audit_before_blob,
    :audit_after_blob,
    :pii_sentinel,
    :raw_metadata,
    :evidence,
    :raw_evidence,
    :provider_payload,
    :provider_json,
    :user_agent,
    :endpoint,
    :path,
    :query,
    :invite_recipient,
    :actor_summary,
    :ip_address,
    :correlation_id,
    :api_key_prefix,
    :label,
    :upstream_account_email,
    :email
  ]

  @spec entity_families() :: [entity_family()]
  def entity_families, do: @entity_families

  @spec policy_for!(entity_family()) :: policy()
  def policy_for!(entity) do
    Map.fetch!(@policies, entity)
  end

  @spec field_policy!(entity_family(), field_name()) :: policy_class()
  def field_policy!(entity, field) do
    policy_for!(entity)
    |> Enum.find_value(fn {policy_class, fields} ->
      if field in fields, do: policy_class
    end)
    |> case do
      nil -> raise ArgumentError, "field #{inspect(field)} is not covered for #{inspect(entity)}"
      policy_class -> policy_class
    end
  end

  @spec covered_terms() :: [field_name()]
  def covered_terms do
    policy_terms =
      @policies
      |> Map.values()
      |> Enum.flat_map(fn policy -> Enum.flat_map(policy, fn {_class, fields} -> fields end) end)

    (policy_terms ++ @sentinel_terms)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec project!(entity_family(), map()) :: map()
  def project!(entity, attrs) when is_map(attrs) do
    if raw_struct?(attrs) do
      raise ArgumentError, "raw domain structs are not MCP-safe; pass an explicit presenter map"
    end

    policy = policy_for!(entity)

    [:allowed, :masked, :summarized]
    |> Enum.flat_map(fn policy_class ->
      Enum.map(policy[policy_class], fn field -> {field, policy_class} end)
    end)
    |> Enum.reduce(%{}, fn {field, policy_class}, acc ->
      case fetch_field(attrs, field) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, field, transform(policy_class, field, value))
        :error -> acc
      end
    end)
  end

  def project!(_entity, _attrs) do
    raise ArgumentError, "MCP privacy projection requires an explicit map"
  end

  defp transform(:allowed, _field, value), do: value
  defp transform(:masked, field, value), do: mask(field, value)
  defp transform(:summarized, field, value), do: summarize(field, value)

  defp mask(field, value)
       when field in [
              :email,
              :operator_email,
              :invited_email,
              :invite_recipient,
              :accepted_by_email,
              :actor_user_email,
              :account_email,
              :upstream_account_email
            ] do
    mask_email(value)
  end

  defp mask(field, value) when field in [:client_ip, :ip_address], do: mask_ip(value)
  defp mask(_field, _value), do: "[MASKED]"

  defp summarize(field, value) when field in [:endpoint, :path],
    do: value |> to_string() |> strip_query()

  defp summarize(:user_agent, value) do
    value
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]+/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  defp summarize(_field, value) when is_map(value), do: Map.take(value, safe_summary_keys(value))
  defp summarize(_field, value), do: value

  defp fetch_field(attrs, field) do
    cond do
      Map.has_key?(attrs, field) ->
        {:ok, Map.fetch!(attrs, field)}

      Map.has_key?(attrs, Atom.to_string(field)) ->
        {:ok, Map.fetch!(attrs, Atom.to_string(field))}

      true ->
        :error
    end
  end

  defp raw_struct?(%{__struct__: _}), do: true
  defp raw_struct?(_value), do: false

  defp mask_email(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        visible = local |> String.slice(0, min(2, String.length(local)))
        visible <> "***@" <> domain

      _other ->
        "[MASKED]"
    end
  end

  defp mask_email(_value), do: "[MASKED]"

  defp mask_ip(value) when is_binary(value) do
    cond do
      match = Regex.run(~r/^((?:\d{1,3}\.){3})\d{1,3}$/, value) ->
        Enum.at(match, 1) <> "xxx"

      match = Regex.run(~r/^([0-9a-fA-F:]+):[0-9a-fA-F]+$/, value) ->
        Enum.at(match, 1) <> ":xxxx"

      true ->
        "[MASKED]"
    end
  end

  defp mask_ip(value), do: value |> to_string() |> mask_ip()

  defp strip_query(value) do
    value
    |> String.split("?", parts: 2)
    |> List.first()
  end

  defp safe_summary_keys(map) do
    map
    |> Map.keys()
    |> Enum.filter(fn key -> key in [:count, :status, :summary, "count", "status", "summary"] end)
  end
end
