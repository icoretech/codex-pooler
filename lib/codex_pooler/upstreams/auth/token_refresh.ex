defmodule CodexPooler.Upstreams.Auth.TokenRefresh do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @active UpstreamIdentity.active_status()
  @paused UpstreamIdentity.paused_status()
  @refresh_due UpstreamIdentity.refresh_due_status()
  @refreshing UpstreamIdentity.refreshing_status()
  @refresh_failed UpstreamIdentity.refresh_failed_status()
  @reauth_required UpstreamIdentity.reauth_required_status()
  @deleted UpstreamIdentity.deleted_status()
  @assignment_deleted PoolUpstreamAssignment.deleted_status()
  @assignment_ineligible PoolUpstreamAssignment.ineligible_status()
  @assignment_disabled_health PoolUpstreamAssignment.disabled_health_status()
  @token_refresh_terminal_statuses [@paused, @deleted]
  @token_refresh_candidate_statuses [@active, @refresh_due, @refresh_failed, @refreshing]
  @default_receive_timeout_ms 30_000
  @stale_slack_ms 20_000

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type refresh_in_progress_metadata :: %{
          required(:attempt_id) => String.t(),
          required(:generation) => non_neg_integer(),
          required(:started_at) => String.t(),
          required(:stale_after_ms) => pos_integer()
        }
  @type lifecycle_result ::
          {:ok, map()} | {:error, lifecycle_error()} | {:error, :refresh_in_progress, map()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec token_refresh_status(identity_ref()) :: map()
  def token_refresh_status(identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity -> token_refresh_metadata(identity.metadata)
      nil -> %{"status" => "unknown"}
    end
  end

  @spec refresh_access_token(identity_ref(), keyword()) :: lifecycle_result()
  def refresh_access_token(identity_or_id, opts \\ []) do
    trigger_kind = opts |> Keyword.get(:trigger_kind, "manual") |> safe_trigger_kind()
    receive_timeout_ms = receive_timeout_ms(opts)
    stale_after_ms = stale_after_ms(receive_timeout_ms)

    with %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id),
         :ok <- IdentityLifecycle.guard_workspace_slot_mutation(identity, %{}),
         {:ok, refreshing_identity, refresh_token, attempt} <-
           begin_token_refresh(identity, trigger_kind, receive_timeout_ms, stale_after_ms) do
      refreshing_identity
      |> perform_token_refresh(refresh_token, receive_timeout_ms)
      |> finalize_token_refresh(refreshing_identity.id, trigger_kind, attempt)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      {:ok, %{status: _status}} = ok ->
        ok

      {:error, :refresh_in_progress, _metadata} = in_progress ->
        in_progress

      {:error, _reason} = error ->
        error
    end
  end

  # Reason: token refresh state machine keeps row locks and terminal statuses local.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp begin_token_refresh(
         %UpstreamIdentity{} = identity,
         trigger_kind,
         receive_timeout_ms,
         stale_after_ms
       ) do
    Repo.transaction(fn ->
      identity.id
      |> lock_upstream_identity_with_timestamp()
      |> begin_token_refresh_from_lock(trigger_kind, receive_timeout_ms, stale_after_ms)
    end)
    |> case do
      {:ok, {:refresh, identity, refresh_token, attempt}} ->
        {:ok, identity, refresh_token, attempt}

      {:ok, {:refresh_in_progress, metadata}} ->
        {:error, :refresh_in_progress, metadata}

      {:ok, %{status: _status} = result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp begin_token_refresh_from_lock(
         {%UpstreamIdentity{status: status} = locked, _timestamp},
         _trigger_kind,
         _receive_timeout_ms,
         _stale_after_ms
       )
       when status in @token_refresh_terminal_statuses do
    token_refresh_result(:noop, locked, retryable?: false, reason: "account is #{status}")
  end

  defp begin_token_refresh_from_lock(
         {%UpstreamIdentity{status: status} = locked, _timestamp},
         _trigger_kind,
         _receive_timeout_ms,
         _stale_after_ms
       )
       when status not in @token_refresh_candidate_statuses do
    token_refresh_result(:noop, locked, retryable?: false, reason: "account is #{status}")
  end

  defp begin_token_refresh_from_lock(
         {%UpstreamIdentity{} = locked, timestamp},
         trigger_kind,
         receive_timeout_ms,
         stale_after_ms
       ) do
    begin_refreshable_identity(
      locked,
      trigger_kind,
      receive_timeout_ms,
      stale_after_ms,
      timestamp
    )
  end

  defp begin_token_refresh_from_lock(nil, _trigger_kind, _receive_timeout_ms, _stale_after_ms) do
    Repo.rollback(
      lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")
    )
  end

  defp begin_refreshable_identity(
         %UpstreamIdentity{} = locked,
         trigger_kind,
         receive_timeout_ms,
         stale_after_ms,
         timestamp
       ) do
    case active_refresh_attempt_metadata(locked, timestamp) do
      {:ok, metadata} ->
        {:refresh_in_progress, metadata}

      :none ->
        claim_token_refresh!(locked, trigger_kind, receive_timeout_ms, stale_after_ms, timestamp)
    end
  end

  defp claim_token_refresh!(
         %UpstreamIdentity{} = locked,
         trigger_kind,
         receive_timeout_ms,
         stale_after_ms,
         timestamp
       ) do
    attempt =
      token_refresh_attempt(
        locked.metadata,
        trigger_kind,
        receive_timeout_ms,
        stale_after_ms,
        timestamp
      )

    case Secrets.decrypt_active_secret(locked, "refresh_token") do
      {:ok, refresh_token} ->
        refreshed_metadata =
          put_token_refresh_metadata(locked.metadata, in_progress_token_refresh_metadata(attempt))

        identity =
          locked
          |> UpstreamIdentity.changeset(%{
            status: @refreshing,
            updated_at: timestamp,
            metadata: refreshed_metadata
          })
          |> Repo.update!()

        {:refresh, identity, refresh_token, attempt}

      {:error, _reason} ->
        reauth =
          mark_token_refresh_reauth_required!(
            locked,
            trigger_kind,
            "missing_refresh_token",
            attempt
          )

        token_refresh_result(:reauth_required, reauth,
          retryable?: false,
          reason: "missing refresh token"
        )
    end
  end

  defp perform_token_refresh(%UpstreamIdentity{} = identity, refresh_token, receive_timeout_ms) do
    case refresh_codex_token(refresh_token, receive_timeout_ms, identity) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{code: :codex_refresh_token_revoked}} ->
        {:reauth_required, "refresh_token_revoked"}

      {:error, %{code: code}} ->
        {:transient_error, to_string(code)}

      {:error, _reason} ->
        {:transient_error, "provider refresh request failed"}
    end
  end

  defp refresh_codex_token(refresh_token, receive_timeout_ms, %UpstreamIdentity{} = identity) do
    CodexAuth.refresh_token(
      refresh_token,
      Keyword.put(codex_refresh_options(identity), :receive_timeout, receive_timeout_ms)
    )
  end

  defp codex_refresh_options(%UpstreamIdentity{} = identity) do
    case local_token_refresh_url(identity.metadata) do
      url when is_binary(url) -> [token_url: url]
      nil -> []
    end
  end

  defp local_token_refresh_url(metadata) when is_map(metadata) do
    token_url = present_string(metadata["refresh_token_url"] || metadata["token_url"])
    base_url = present_string(metadata["base_url"])
    url = token_url || if(base_url, do: String.trim_trailing(base_url, "/") <> "/oauth/token")

    if local_token_refresh_url?(url), do: url
  end

  defp local_token_refresh_url(_metadata), do: nil

  defp local_token_refresh_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    local_secret_key_fallback?() and uri.scheme in ["http", "https"] and local_host?(uri.host)
  end

  defp local_token_refresh_url?(_url), do: false

  defp local_secret_key_fallback? do
    # Reason: dev/test local refresh stubs share the same environment gate as local secret fallback.
    # credo:disable-for-lines:3 Credo.Check.Refactor.Apply
    Code.ensure_loaded?(Mix) and
      apply(Mix, :env, []) in [:dev, :test]
  end

  defp local_host?(host) when host in ["localhost", "127.0.0.1", "::1"], do: true
  defp local_host?(_host), do: false

  defp finalize_token_refresh(refresh_result, identity_id, trigger_kind, attempt) do
    Repo.transaction(fn ->
      identity_id
      |> lock_upstream_identity()
      |> finalize_token_refresh_from_lock(refresh_result, trigger_kind, attempt)
    end)
    |> case do
      {:ok, {:refresh_in_progress, metadata}} -> {:error, :refresh_in_progress, metadata}
      {:ok, result} -> tap_upstream_change({:ok, result}, "upstream_account_token_refreshed")
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_token_refresh_from_lock(
         %UpstreamIdentity{status: status} = identity,
         _refresh_result,
         _trigger_kind,
         _attempt
       )
       when status in @token_refresh_terminal_statuses do
    token_refresh_result(:noop, identity, retryable?: false, reason: "account is #{status}")
  end

  defp finalize_token_refresh_from_lock(
         %UpstreamIdentity{} = identity,
         refresh_result,
         trigger_kind,
         attempt
       ) do
    case token_refresh_metadata(identity.metadata) do
      %{
        "status" => "refreshing",
        "attempt_id" => attempt_id,
        "generation" => generation
      }
      when attempt_id == attempt.attempt_id and generation == attempt.generation ->
        do_finalize_token_refresh(refresh_result, identity, trigger_kind, attempt)

      _metadata ->
        superseded_finalize_result(identity)
    end
  end

  defp finalize_token_refresh_from_lock(nil, _refresh_result, _trigger_kind, _attempt) do
    Repo.rollback(
      lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")
    )
  end

  defp do_finalize_token_refresh(
         {:ok, token_attrs},
         %UpstreamIdentity{} = identity,
         trigger_kind,
         attempt
       ) do
    with {:ok, _secret} <-
           Secrets.store_encrypted_secret(identity, %{
             secret_kind: "access_token",
             plaintext: Map.fetch!(token_attrs, :access_token)
           }),
         {:ok, _refresh_secret} <- maybe_store_rotated_refresh_token(identity, token_attrs) do
      timestamp = now()

      active_identity =
        identity
        |> UpstreamIdentity.changeset(%{
          status: @active,
          auth_verified_at: timestamp,
          auth_fresh_at: timestamp,
          last_successful_refresh_at: timestamp,
          disabled_at: nil,
          updated_at: timestamp,
          metadata:
            identity.metadata
            |> maybe_put_access_token_expiry(token_attrs, timestamp)
            |> put_token_refresh_metadata(
              terminal_token_refresh_metadata(attempt, trigger_kind, timestamp, %{
                "status" => "succeeded",
                "rotated_refresh_token" => Map.has_key?(token_attrs, :refresh_token)
              })
            )
        })
        |> Repo.update!()

      token_refresh_result(:active, active_identity, retryable?: false, reason: nil)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp do_finalize_token_refresh(
         {:reauth_required, code},
         %UpstreamIdentity{} = identity,
         trigger_kind,
         attempt
       ) do
    identity = mark_token_refresh_reauth_required!(identity, trigger_kind, code, attempt)
    token_refresh_result(:reauth_required, identity, retryable?: false, reason: code)
  end

  defp do_finalize_token_refresh(
         {:transient_error, code},
         %UpstreamIdentity{} = identity,
         trigger_kind,
         attempt
       ) do
    timestamp = now()

    failed_identity =
      identity
      |> UpstreamIdentity.changeset(%{
        status: @refresh_failed,
        updated_at: timestamp,
        metadata:
          put_token_refresh_metadata(
            identity.metadata,
            terminal_token_refresh_metadata(attempt, trigger_kind, timestamp, %{
              "status" => "failed",
              "reason" => %{"code" => code, "message" => token_refresh_message(code)}
            })
          )
      })
      |> Repo.update!()

    token_refresh_result(:refresh_failed, failed_identity,
      retryable?: true,
      reason: token_refresh_message(code)
    )
  end

  defp mark_token_refresh_reauth_required!(
         %UpstreamIdentity{} = identity,
         trigger_kind,
         code,
         attempt
       ) do
    timestamp = now()

    reauth_identity =
      identity
      |> UpstreamIdentity.changeset(%{
        status: @reauth_required,
        disabled_at: timestamp,
        updated_at: timestamp,
        metadata:
          put_token_refresh_metadata(
            identity.metadata,
            terminal_token_refresh_metadata(attempt, trigger_kind, timestamp, %{
              "status" => "reauth_required",
              "reason" => %{"code" => code, "message" => token_refresh_message(code)}
            })
          )
      })
      |> Repo.update!()

    update_assignments_for_identity(identity.id, %{
      health_status: @assignment_disabled_health,
      eligibility_status: @assignment_ineligible,
      disabled_at: timestamp,
      updated_at: timestamp
    })

    reauth_identity
  end

  defp superseded_finalize_result(%UpstreamIdentity{} = identity) do
    metadata = token_refresh_metadata(identity.metadata)

    case metadata["status"] do
      "refreshing" ->
        {:refresh_in_progress, refresh_in_progress_metadata(metadata)}

      _status ->
        token_refresh_result(:noop, identity,
          retryable?: false,
          reason: "refresh attempt was superseded"
        )
    end
  end

  defp active_refresh_attempt_metadata(
         %UpstreamIdentity{status: @refreshing} = identity,
         timestamp
       ) do
    metadata = token_refresh_metadata(identity.metadata)

    if active_refresh_attempt?(metadata, timestamp) do
      {:ok, refresh_in_progress_metadata(metadata)}
    else
      :none
    end
  end

  defp active_refresh_attempt_metadata(_identity, _timestamp), do: :none

  defp active_refresh_attempt?(%{} = metadata, timestamp) do
    with "refreshing" <- metadata["status"],
         attempt_id when is_binary(attempt_id) <- metadata["attempt_id"],
         generation when is_integer(generation) and generation >= 0 <- metadata["generation"],
         started_at when is_binary(started_at) <- metadata["started_at"],
         stale_after_ms when is_integer(stale_after_ms) and stale_after_ms > 0 <-
           metadata["stale_after_ms"],
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at),
         true <- DateTime.diff(timestamp, started_at, :millisecond) < stale_after_ms do
      true
    else
      _value -> false
    end
  end

  defp refresh_in_progress_metadata(%UpstreamIdentity{} = identity),
    do: identity.metadata |> token_refresh_metadata() |> refresh_in_progress_metadata()

  defp refresh_in_progress_metadata(%{} = metadata) do
    %{
      attempt_id: metadata["attempt_id"],
      generation: metadata["generation"],
      started_at: metadata["started_at"],
      stale_after_ms: metadata["stale_after_ms"]
    }
  end

  defp token_refresh_attempt(
         metadata,
         trigger_kind,
         receive_timeout_ms,
         stale_after_ms,
         timestamp
       ) do
    generation =
      metadata
      |> token_refresh_metadata()
      |> Map.get("generation", 0)
      |> next_generation()

    %{
      attempt_id: Ecto.UUID.generate(),
      generation: generation,
      started_at: DateTime.to_iso8601(timestamp),
      trigger_kind: trigger_kind,
      receive_timeout_ms: receive_timeout_ms,
      stale_after_ms: stale_after_ms
    }
  end

  defp next_generation(generation) when is_integer(generation) and generation >= 0,
    do: generation + 1

  defp next_generation(_generation), do: 1

  defp in_progress_token_refresh_metadata(attempt) do
    %{
      "status" => "refreshing",
      "attempt_id" => attempt.attempt_id,
      "generation" => attempt.generation,
      "started_at" => attempt.started_at,
      "trigger_kind" => attempt.trigger_kind,
      "receive_timeout_ms" => attempt.receive_timeout_ms,
      "stale_after_ms" => attempt.stale_after_ms
    }
  end

  defp terminal_token_refresh_metadata(attempt, trigger_kind, timestamp, attrs) do
    attempt
    |> in_progress_token_refresh_metadata()
    |> Map.merge(%{
      "trigger_kind" => trigger_kind,
      "finished_at" => DateTime.to_iso8601(timestamp)
    })
    |> Map.merge(attrs)
  end

  defp receive_timeout_ms(opts) do
    opts
    |> Keyword.get(:receive_timeout, @default_receive_timeout_ms)
    |> positive_integer_or_default(@default_receive_timeout_ms)
  end

  defp stale_after_ms(receive_timeout_ms) do
    receive_timeout_ms + @stale_slack_ms
  end

  defp positive_integer_or_default(value, _default) when is_integer(value) and value > 0,
    do: value

  defp positive_integer_or_default(_value, default), do: default

  defp token_refresh_result(status, %UpstreamIdentity{} = identity, opts) do
    %{
      status: status,
      identity: Repo.reload!(identity),
      retryable?: Keyword.fetch!(opts, :retryable?),
      reason: Keyword.get(opts, :reason),
      secret_status: Secrets.secret_status(identity)
    }
  end

  defp maybe_store_rotated_refresh_token(identity, %{refresh_token: refresh_token})
       when is_binary(refresh_token) and refresh_token != "" do
    Secrets.store_encrypted_secret(identity, %{
      secret_kind: "refresh_token",
      plaintext: refresh_token
    })
  end

  defp maybe_store_rotated_refresh_token(_identity, _token_attrs), do: {:ok, nil}

  defp maybe_put_access_token_expiry(metadata, %{expires_in: expires_in}, timestamp) do
    case integer_seconds(expires_in) do
      seconds when is_integer(seconds) and seconds > 0 ->
        Map.put(
          metadata || %{},
          "access_token_expires_at",
          DateTime.to_iso8601(DateTime.add(timestamp, seconds, :second))
        )

      _value ->
        metadata || %{}
    end
  end

  defp maybe_put_access_token_expiry(metadata, _token_attrs, _timestamp), do: metadata || %{}

  defp integer_seconds(value) when is_integer(value), do: value

  defp integer_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _invalid -> nil
    end
  end

  defp integer_seconds(_value), do: nil

  defp put_token_refresh_metadata(metadata, attrs) do
    Map.put(metadata || %{}, "token_refresh", attrs)
  end

  defp token_refresh_metadata(%{} = metadata) do
    case Map.get(metadata, "token_refresh") do
      %{} = token_refresh -> token_refresh
      _value -> %{"status" => "not run"}
    end
  end

  defp token_refresh_metadata(_metadata), do: %{"status" => "not run"}

  defp token_refresh_message("missing_refresh_token"), do: "refresh token is missing"
  defp token_refresh_message("refresh_token_revoked"), do: "refresh token was revoked"

  defp token_refresh_message("invalid_refresh_response"),
    do: "upstream returned an invalid refresh response"

  defp token_refresh_message(code) when is_binary(code), do: "token refresh failed: #{code}"

  defp safe_trigger_kind(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.slice(0, 64)
    |> case do
      "" -> "manual"
      value -> value
    end
  end

  defp safe_trigger_kind(_value), do: "manual"

  defp lock_upstream_identity(identity_id) do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_upstream_identity_with_timestamp(identity_id) do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE",
        select: {identity, type(fragment("transaction_timestamp()"), :utc_datetime_usec)}
    )
  end

  defp update_assignments_for_identity(identity_id, set) do
    Repo.update_all(
      from(assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status != ^@assignment_deleted
      ),
      set: Map.to_list(set)
    )
  end

  defp tap_upstream_change({:ok, result} = ok, reason) do
    broadcast_upstream_change(result, reason)
    ok
  end

  defp broadcast_upstream_change(%{identity: %UpstreamIdentity{} = identity}, reason) do
    identity.id
    |> assignments_for_identity()
    |> Enum.each(&broadcast_upstream_assignment(&1, identity, reason))
  end

  defp broadcast_upstream_assignment(%PoolUpstreamAssignment{} = assignment, identity, reason) do
    Events.broadcast_upstreams(assignment.pool_id, reason, %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      upstream_status: identity.status,
      assignment_status: assignment.status
    })
  end

  defp assignments_for_identity(identity_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.upstream_identity_id == ^identity_id,
        order_by: [asc: assignment.created_at, asc: assignment.id]
    )
  end

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
