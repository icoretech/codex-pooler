defmodule CodexPooler.Upstreams.SavedResetRedemption do
  @moduledoc """
  Redeems Codex saved reset credits with metadata-only persistence.
  """

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @assignment_active PoolUpstreamAssignment.active_status()
  @identity_deleted UpstreamIdentity.deleted_status()
  @identity_disabled UpstreamIdentity.disabled_status()
  @default_receive_timeout 15_000
  @stale_grace_ms 60_000
  @known_noop_codes ~w(already_redeemed no_credit nothing_to_reset)

  @type trigger_kind :: String.t()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @type redeem_result :: %{
          required(:status) => :succeeded | :failed | :noop,
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:applied?) => boolean(),
          required(:code) => String.t(),
          optional(:available_count_before) => non_neg_integer(),
          optional(:available_count_after) => non_neg_integer(),
          optional(:http_status) => non_neg_integer(),
          optional(:reason) => String.t()
        }

  @spec ensure_manual_available(PoolUpstreamAssignment.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
          | {:error, lifecycle_error() | :redemption_in_progress}
  def ensure_manual_available(assignment_or_id, opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    timestamp = Keyword.get_lazy(opts, :started_at, &now/0)

    with {:ok, assignment, identity} <- load_assignment_identity(assignment_or_id),
         :ok <- ensure_identity_usable(identity),
         :ok <- ensure_credentials_usable(identity),
         :ok <- ensure_saved_reset_available(identity, timestamp, receive_timeout) do
      {:ok, assignment, identity}
    end
  end

  @type claim :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer(),
          required(:trigger_kind) => trigger_kind(),
          required(:started_at) => DateTime.t(),
          required(:receive_timeout) => non_neg_integer()
        }

  @spec redeem(PoolUpstreamAssignment.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, redeem_result()} | {:error, lifecycle_error() | :redemption_in_progress}
  def redeem(assignment_or_id, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, "admin_manual")
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    started_at = Keyword.get_lazy(opts, :started_at, &now/0)

    opts =
      opts
      |> Keyword.put(:trigger_kind, trigger_kind)
      |> Keyword.put(:receive_timeout, receive_timeout)

    with {:ok, assignment, identity} <- load_assignment_identity(assignment_or_id) do
      case normalize_gateway_auto_context(trigger_kind, Keyword.get(opts, :gateway_auto_context)) do
        {:ok, gateway_auto_context} ->
          assignment
          |> claim_attempt(
            identity,
            trigger_kind,
            receive_timeout,
            started_at,
            gateway_auto_context
          )
          |> redeem_claim(opts)

        {:noop, code} ->
          {:ok, noop_result(identity, assignment, code)}
      end
    end
  end

  @spec redeem_claim(
          {:ok, claim() | {:noop, redeem_result()}}
          | {:error, lifecycle_error() | :redemption_in_progress},
          keyword()
        ) :: {:ok, redeem_result()} | {:error, lifecycle_error() | :redemption_in_progress}
  defp redeem_claim({:ok, {:noop, result}}, _opts), do: {:ok, result}
  defp redeem_claim({:ok, claim}, opts), do: do_redeem(claim, opts)
  defp redeem_claim({:error, reason}, _opts), do: {:error, reason}

  defp load_assignment_identity(assignment_or_id) do
    assignment_or_id
    |> assignment_id()
    |> load_active_assignment()
  end

  defp load_active_assignment(assignment_id) when is_binary(assignment_id) do
    case Repo.get(PoolUpstreamAssignment, assignment_id) do
      %PoolUpstreamAssignment{status: @assignment_active} = assignment ->
        load_active_identity(assignment)

      _missing_or_inactive ->
        {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}
    end
  end

  defp load_active_assignment(_assignment_id),
    do: {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}

  defp load_active_identity(%PoolUpstreamAssignment{} = assignment) do
    case Repo.get(UpstreamIdentity, assignment.upstream_identity_id) do
      %UpstreamIdentity{status: @identity_deleted} ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      %UpstreamIdentity{status: @identity_disabled} ->
        {:error,
         lifecycle_error(:upstream_identity_unavailable, "upstream identity is not available")}

      %UpstreamIdentity{status: status} = identity
      when status not in [@identity_deleted, @identity_disabled] ->
        {:ok, assignment, identity}

      _missing_or_inactive ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp ensure_identity_usable(%UpstreamIdentity{status: @identity_deleted}),
    do: {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

  defp ensure_identity_usable(%UpstreamIdentity{status: @identity_disabled}),
    do:
      {:error,
       lifecycle_error(:upstream_identity_unavailable, "upstream identity is not available")}

  defp ensure_identity_usable(%UpstreamIdentity{}), do: :ok

  defp ensure_credentials_usable(%UpstreamIdentity{} = identity) do
    case Secrets.secret_status(identity) do
      :present ->
        :ok

      _status ->
        {:error,
         lifecycle_error(
           :upstream_secret_not_routable,
           "saved reset redemption requires usable credentials"
         )}
    end
  end

  defp ensure_saved_reset_available(%UpstreamIdentity{} = identity, timestamp, receive_timeout) do
    snapshot = SavedResets.snapshot(identity, timestamp)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    cond do
      RedemptionLifecycle.blocks_new_redemption?(redemption, timestamp) ->
        {:error, :redemption_in_progress}

      fresh_redemption?(redemption, timestamp, receive_timeout) ->
        {:error, :redemption_in_progress}

      snapshot.in_progress? ->
        {:error,
         lifecycle_error(
           :saved_reset_redemption_in_progress,
           "saved reset redemption is already in progress"
         )}

      snapshot.reported? != true or snapshot.available? != true ->
        {:error, lifecycle_error(:saved_reset_unavailable, "no saved resets are available")}

      true ->
        :ok
    end
  end

  defp normalize_gateway_auto_context("gateway_auto", context) do
    case AutoEligibility.normalize_context(context) do
      {:ok, context} -> {:ok, context}
      {:error, :invalid_gateway_auto_context} -> {:noop, "gateway_auto_context_invalid"}
    end
  end

  defp normalize_gateway_auto_context(_trigger_kind, _context), do: {:ok, nil}

  defp claim_attempt(
         assignment,
         identity,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context
       ) do
    Repo.transaction(fn ->
      identity.id
      |> lock_identity!()
      |> claim_locked_identity!(
        assignment,
        trigger_kind,
        receive_timeout,
        started_at,
        gateway_auto_context
      )
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, :redemption_in_progress} -> {:error, :redemption_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_locked_identity!(
         locked_identity,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context
       ) do
    metadata = locked_identity.metadata || %{}
    redemption = metadata["saved_reset_redemption"]

    cond do
      # A lifecycle that already consumed a credit (pending, in-flight, expired,
      # or unrecognized) can never be overridden into a second consumption, not
      # even by the stale-admin recovery path. Recovery is evidence-only.
      RedemptionLifecycle.blocks_new_redemption?(redemption, started_at) ->
        Repo.rollback(:redemption_in_progress)

      redemption_in_progress_for_trigger?(redemption, started_at, receive_timeout, trigger_kind) ->
        Repo.rollback(:redemption_in_progress)

      true ->
        claim_validated_identity!(
          locked_identity,
          assignment,
          trigger_kind,
          receive_timeout,
          started_at,
          gateway_auto_context,
          metadata,
          redemption
        )
    end
  end

  defp claim_validated_identity!(
         locked_identity,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context,
         metadata,
         redemption
       ) do
    case validate_locked_gateway_auto(
           locked_identity,
           assignment,
           gateway_auto_context,
           started_at
         ) do
      {:ok, current_assignment} ->
        locked_identity
        |> maybe_mark_stale_admin_redemption!(metadata, redemption, trigger_kind, started_at)
        |> build_redemption_claim!(
          locked_identity,
          current_assignment,
          trigger_kind,
          receive_timeout,
          started_at
        )

      {:noop, code} ->
        {:noop, noop_result(locked_identity, assignment, code)}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_locked_gateway_auto(_locked_identity, assignment, nil, _started_at),
    do: {:ok, assignment}

  defp validate_locked_gateway_auto(
         %UpstreamIdentity{} = locked_identity,
         %PoolUpstreamAssignment{} = assignment,
         gateway_auto_context,
         %DateTime{} = started_at
       ) do
    with {:ok, locked_assignment} <- lock_gateway_auto_assignment(assignment),
         :ok <-
           AutoEligibility.validate_locked_gateway_auto(
             locked_identity,
             locked_assignment,
             gateway_auto_context,
             started_at
           ) do
      {:ok, locked_assignment}
    end
  end

  defp lock_gateway_auto_assignment(%PoolUpstreamAssignment{id: assignment_id}) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             where: assignment.id == ^assignment_id,
             lock: "FOR UPDATE"
         ) do
      %PoolUpstreamAssignment{} = assignment -> {:ok, assignment}
      nil -> {:noop, "gateway_auto_assignment_unavailable"}
    end
  end

  defp redemption_in_progress_for_trigger?(redemption, started_at, receive_timeout, trigger_kind) do
    fresh_redemption?(redemption, started_at, receive_timeout) or
      (stale_redemption?(redemption) and trigger_kind == "gateway_auto")
  end

  defp maybe_mark_stale_admin_redemption!(
         locked_identity,
         metadata,
         redemption,
         "admin_manual",
         started_at
       ) do
    if stale_redemption?(redemption) do
      mark_stale_redemption_failed!(locked_identity, redemption, started_at).metadata || %{}
    else
      metadata
    end
  end

  defp maybe_mark_stale_admin_redemption!(
         _locked_identity,
         metadata,
         _redemption,
         _trigger_kind,
         _started_at
       ),
       do: metadata

  defp build_redemption_claim!(
         metadata,
         locked_identity,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at
       ) do
    attempt_id = Ecto.UUID.generate()
    generation = next_generation(metadata)

    claimed_identity =
      update_redemption_metadata!(locked_identity, metadata, %{
        "status" => "redeeming",
        "attempt_id" => attempt_id,
        "generation" => generation,
        "trigger_kind" => trigger_kind,
        "started_at" => DateTime.to_iso8601(started_at),
        "finished_at" => nil,
        "result" => nil
      })

    %{
      identity: claimed_identity,
      assignment: assignment,
      attempt_id: attempt_id,
      generation: generation,
      trigger_kind: trigger_kind,
      started_at: started_at,
      receive_timeout: receive_timeout
    }
  end

  defp do_redeem(%{identity: identity, assignment: assignment} = claim, opts) do
    case Secrets.decrypt_active_secret(identity, "access_token") do
      {:ok, access_token} ->
        identity
        |> SavedResets.snapshot()
        |> endpoint_family_result(identity, assignment, access_token, claim, opts)
        |> finalize_attempt(claim)

      {:error, _reason} ->
        finalize_attempt(
          %{
            status: :failed,
            applied?: false,
            code: "missing_access_token",
            reason: "active access token was not available"
          },
          claim
        )
    end
  end

  defp endpoint_family_result(
         %{path_style: "chatgpt_api"} = snapshot,
         identity,
         assignment,
         access_token,
         claim,
         _opts
       ) do
    with {:ok, list_url, consume_url} <- chatgpt_reset_urls(identity, assignment, snapshot),
         {:ok, list_result} <-
           list_chatgpt_credits(list_url, identity, access_token, claim.receive_timeout) do
      case list_result do
        %{credit_id: nil, available_count: available_count, http_status: http_status} ->
          update_saved_reset_count!(identity, snapshot, available_count, claim.started_at)

          %{
            status: :noop,
            applied?: false,
            code: "no_credit",
            available_count_before: available_count,
            available_count_after: 0,
            http_status: http_status
          }

        %{credit_id: credit_id, available_count: available_count} ->
          consume_credit(
            consume_url,
            identity,
            access_token,
            %{"credit_id" => credit_id, "redeem_request_id" => idempotency_key(claim)},
            available_count,
            claim,
            :chatgpt
          )
      end
    else
      {:error, result} -> result
    end
  end

  defp endpoint_family_result(
         %{path_style: "codex_api"} = snapshot,
         identity,
         assignment,
         access_token,
         claim,
         _opts
       ) do
    case codex_reset_url(identity, assignment, snapshot) do
      {:ok, consume_url} ->
        consume_credit(
          consume_url,
          identity,
          access_token,
          %{"redeem_request_id" => idempotency_key(claim)},
          snapshot.available_count,
          claim,
          :codex
        )

      {:error, result} ->
        result
    end
  end

  defp endpoint_family_result(_snapshot, _identity, _assignment, _access_token, _claim, _opts) do
    %{
      status: :noop,
      applied?: false,
      code: "saved_reset_endpoint_unknown"
    }
  end

  defp list_chatgpt_credits(url, identity, access_token, receive_timeout) do
    case Req.get(url,
           headers:
             CloudflareCookies.request_headers(
               url,
               request_headers(access_token, identity.chatgpt_account_id, :get)
             ),
           retry: false,
           receive_timeout: receive_timeout
         )
         |> store_cloudflare_cookies(url) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, parse_chatgpt_credit_list(body, status)}

      {:ok, %{status: status}} ->
        {:error, failed_result(http_code(status), status)}

      {:error, _reason} ->
        {:error, transport_failed_result()}
    end
  end

  defp parse_chatgpt_credit_list(body, http_status) do
    credits = Map.get(body, "credits")
    usable_credit = first_usable_credit(credits)

    available_count =
      case non_negative_truncated_integer(Map.get(body, "available_count")) do
        {:ok, count} -> count
        :error -> Enum.count(List.wrap(credits), &usable_credit?/1)
      end

    %{
      credit_id: usable_credit && usable_credit["id"],
      available_count: available_count,
      http_status: http_status
    }
  end

  defp first_usable_credit(credits) when is_list(credits),
    do: Enum.find(credits, &usable_credit?/1)

  defp first_usable_credit(_credits), do: nil

  defp usable_credit?(%{"id" => id} = credit) when is_binary(id) do
    not Map.has_key?(credit, "status") or credit["status"] == "available"
  end

  defp usable_credit?(_credit), do: false

  defp consume_credit(
         url,
         identity,
         access_token,
         body,
         available_count_before,
         claim,
         endpoint_kind
       ) do
    case Req.post(url,
           headers:
             CloudflareCookies.request_headers(
               url,
               request_headers(access_token, identity.chatgpt_account_id, :post)
             ),
           json: body,
           retry: false,
           receive_timeout: claim.receive_timeout
         )
         |> store_cloudflare_cookies(url) do
      {:ok, %{status: status, body: response_body}} ->
        response_code(response_body, status, endpoint_kind)
        |> result_from_response(status, available_count_before, identity, claim.assignment, claim)

      {:error, _reason} ->
        transport_failed_result()
    end
  end

  defp store_cloudflare_cookies(result, url) do
    CloudflareCookies.store_from_result(url, result)
    result
  end

  defp result_from_response(code, status, available_count_before, identity, assignment, claim) do
    cond do
      code == "reset" ->
        # The provider consumed a credit as of now; capture that before the
        # refresh so evidence is only accepted when observed at/after it.
        consumed_at = now()

        case PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               receive_timeout: claim.receive_timeout
             ) do
          {:ok, refreshed_identity} ->
            available_count_after = SavedResets.snapshot(refreshed_identity).available_count

            %{
              status: :succeeded,
              applied?: true,
              code: code,
              phase: post_reset_phase(refreshed_identity, consumed_at),
              consumed_at: consumed_at,
              available_count_before: available_count_before,
              available_count_after: available_count_after,
              http_status: status
            }

          {:error, _reason} ->
            # The provider returned `reset`: a credit was consumed. A failed or
            # partial usage refresh must not reverse that external side effect,
            # and must not report `applied=false` (which would let a later
            # request consume a second credit). Record the consumed credit as a
            # pending confirmation, fail-closed, so it converges only from fresh
            # provider evidence.
            %{
              status: :succeeded,
              applied?: true,
              code: code,
              phase: RedemptionLifecycle.consumed_pending_probe(),
              consumed_at: consumed_at,
              available_count_before: available_count_before,
              http_status: status,
              reason: "quota refresh after saved reset is pending confirmation"
            }
        end

      code in @known_noop_codes ->
        %{
          status: :noop,
          applied?: false,
          code: code,
          available_count_before: available_count_before,
          http_status: status
        }

      true ->
        %{
          status: :failed,
          applied?: false,
          code: code,
          available_count_before: available_count_before,
          http_status: status,
          reason: "saved reset redemption failed"
        }
    end
  end

  defp response_code(body, status, endpoint_kind) do
    cond do
      endpoint_kind == :codex and status == 404 ->
        "saved_reset_endpoint_unavailable"

      is_map(body) and is_binary(body["code"]) ->
        sanitize_result_code(body["code"])

      status in 200..299 ->
        "reset"

      true ->
        http_code(status)
    end
  end

  defp chatgpt_reset_urls(identity, assignment, snapshot) do
    base = reset_base_url(identity, assignment)

    case snapshot.usage_path do
      "/wham/usage" ->
        {:ok, base <> "/wham/rate-limit-reset-credits",
         base <> "/wham/rate-limit-reset-credits/consume"}

      "/backend-api/wham/usage" ->
        {:ok, base <> "/backend-api/wham/rate-limit-reset-credits",
         base <> "/backend-api/wham/rate-limit-reset-credits/consume"}

      nil ->
        {:ok, base <> "/backend-api/wham/rate-limit-reset-credits",
         base <> "/backend-api/wham/rate-limit-reset-credits/consume"}

      _usage_path ->
        {:error, %{status: :noop, applied?: false, code: "saved_reset_endpoint_unknown"}}
    end
  end

  defp codex_reset_url(identity, assignment, snapshot) do
    base = reset_base_url(identity, assignment)

    case snapshot.usage_path do
      "/api/codex/usage" ->
        {:ok, base <> "/api/codex/rate-limit-reset-credits/consume"}

      "/backend-api/codex/usage" ->
        {:ok, base <> "/backend-api/codex/rate-limit-reset-credits/consume"}

      nil ->
        {:ok, base <> "/api/codex/rate-limit-reset-credits/consume"}

      _usage_path ->
        {:error, %{status: :noop, applied?: false, code: "saved_reset_endpoint_unknown"}}
    end
  end

  defp reset_base_url(identity, assignment) do
    identity
    |> EndpointMetadata.usage_base_url(assignment)
    |> EndpointMetadata.normalize_base_url()
  end

  defp request_headers(access_token, chatgpt_account_id, request_kind) do
    headers = [
      {"authorization", "Bearer " <> String.trim(access_token)},
      {"accept", "application/json"}
    ]

    headers =
      if request_kind == :post do
        headers ++ [{"content-type", "application/json"}]
      else
        headers
      end

    if send_chatgpt_account_header?(chatgpt_account_id) do
      headers ++ [{"chatgpt-account-id", chatgpt_account_id}]
    else
      headers
    end
  end

  defp send_chatgpt_account_header?(chatgpt_account_id) when is_binary(chatgpt_account_id) do
    chatgpt_account_id = String.trim(chatgpt_account_id)

    chatgpt_account_id != "" and not String.starts_with?(chatgpt_account_id, "email_") and
      not String.starts_with?(chatgpt_account_id, "local_")
  end

  defp send_chatgpt_account_header?(_chatgpt_account_id), do: false

  defp finalize_attempt(result, claim) do
    Repo.transaction(fn ->
      identity = lock_identity!(claim.identity.id)
      metadata = identity.metadata || %{}
      redemption = metadata["saved_reset_redemption"] || %{}

      if redemption["attempt_id"] == claim.attempt_id and
           redemption["generation"] == claim.generation do
        finished_at = now()

        base = %{
          "attempt_id" => claim.attempt_id,
          "generation" => claim.generation,
          "trigger_kind" => claim.trigger_kind,
          "started_at" => DateTime.to_iso8601(claim.started_at),
          "finished_at" => DateTime.to_iso8601(finished_at),
          "result" => metadata_result(result)
        }

        updated_identity =
          update_redemption_metadata!(
            identity,
            metadata,
            Map.merge(base, redemption_lifecycle_fields(result))
          )

        updated_identity
      else
        identity
      end
    end)
    |> case do
      {:ok, updated_identity} ->
        broadcast_redemption(updated_identity)

        {:ok,
         result
         |> Map.put(:identity, updated_identity)
         |> Map.put(:assignment, claim.assignment)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp metadata_result(result) do
    %{
      "code" => result.code,
      "applied" => result.applied?,
      "available_count_before" => Map.get(result, :available_count_before),
      "available_count_after" => Map.get(result, :available_count_after),
      "http_status" => Map.get(result, :http_status)
    }
  end

  # A result carrying a lifecycle `:phase` records the phase-driven legacy status
  # plus the consume timestamp and bounded-window deadline. Every other result
  # keeps the legacy top-level status derived from the redemption outcome.
  defp redemption_lifecycle_fields(%{phase: phase, consumed_at: %DateTime{} = consumed_at})
       when is_binary(phase) do
    %{
      "status" => RedemptionLifecycle.legacy_status_for(phase),
      "phase" => phase,
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => DateTime.to_iso8601(RedemptionLifecycle.deadline_at(consumed_at))
    }
  end

  defp redemption_lifecycle_fields(result), do: %{"status" => Atom.to_string(result.status)}

  # After a consumed reset, only fresh usable account evidence observed at/after
  # the consume time confirms the identity. Anything else (the provider omitted
  # the account window, or it is still exhausted) stays pending and converges
  # later from real evidence — never a fabricated success.
  defp post_reset_phase(refreshed_identity, consumed_at) do
    case PostResetEvidence.classify(Windows.list_evidence(refreshed_identity), consumed_at, now()) do
      :confirmed -> RedemptionLifecycle.confirmed_by_quota()
      _pending_or_reblocked -> RedemptionLifecycle.consumed_pending_probe()
    end
  end

  # The provider idempotency key is derived deterministically from the persisted
  # attempt id and generation, so a retry of the same claim reproduces the same
  # key without persisting a raw secret. Different attempts derive distinct keys.
  defp idempotency_key(%{attempt_id: attempt_id, generation: generation}) do
    {:ok, uuid} =
      :sha256
      |> :crypto.hash("saved_reset_redeem:#{attempt_id}:#{generation}")
      |> binary_part(0, 16)
      |> Ecto.UUID.load()

    uuid
  end

  defp noop_result(identity, assignment, code) when is_binary(code) do
    %{
      status: :noop,
      applied?: false,
      code: code,
      identity: identity,
      assignment: assignment
    }
  end

  defp update_saved_reset_count!(identity, snapshot, available_count, observed_at) do
    metadata = identity.metadata || %{}

    saved_reset_metadata =
      %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_reset_credits_api",
        "path_style" => snapshot.path_style,
        "observed_at" => DateTime.to_iso8601(observed_at),
        "usage_path" => snapshot.usage_path,
        "reason" => nil
      }
      |> Map.merge(expiration_metadata_from_snapshot(snapshot))

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(metadata, "saved_resets", saved_reset_metadata),
      updated_at: observed_at
    })
    |> Repo.update!()
  end

  @spec expiration_metadata_from_snapshot(SavedResets.snapshot_projection()) :: map()
  defp expiration_metadata_from_snapshot(snapshot) do
    %{
      "available_expires_at" => snapshot.available_expires_at,
      "available_expirations" => stored_available_expiration_rows(snapshot.available_expirations),
      "next_expires_at" => snapshot.next_expires_at,
      "expires_observed_at" => snapshot.expires_observed_at,
      "expires_refresh_attempted_at" => snapshot.expires_refresh_attempted_at
    }
  end

  @spec stored_available_expiration_rows([SavedResets.available_expiration_row()]) :: [map()]
  defp stored_available_expiration_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      %{expires_at: expires_at, first_seen_at: first_seen_at}
      when is_binary(expires_at) and is_binary(first_seen_at) ->
        %{"expires_at" => expires_at, "first_seen_at" => first_seen_at}

      _row ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp mark_stale_redemption_failed!(identity, redemption, finished_at) do
    metadata = identity.metadata || %{}
    generation = next_generation(metadata)

    update_redemption_metadata!(identity, metadata, %{
      "status" => "failed",
      "attempt_id" => redemption["attempt_id"] || Ecto.UUID.generate(),
      "generation" => generation,
      "trigger_kind" => redemption["trigger_kind"] || "admin_manual",
      "started_at" => redemption["started_at"],
      "finished_at" => DateTime.to_iso8601(finished_at),
      "result" => %{
        "code" => "stale_redemption_unknown",
        "applied" => false,
        "available_count_before" => nil,
        "available_count_after" => nil,
        "http_status" => nil
      }
    })
  end

  defp update_redemption_metadata!(identity, metadata, redemption) do
    timestamp = now()

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(metadata || %{}, "saved_reset_redemption", redemption),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp broadcast_redemption(identity) do
    identity.id
    |> PoolAssignments.list_pool_assignments_for_identity()
    |> Enum.each(fn assignment ->
      Events.broadcast_upstreams(assignment.pool_id, "upstream_account_saved_reset_redeemed", %{
        assignment_id: assignment.id,
        upstream_identity_id: identity.id
      })
    end)
  end

  defp lock_identity!(identity_id) do
    Repo.one!(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE"
    )
  end

  defp fresh_redemption?(
         %{"status" => "redeeming", "started_at" => started_at},
         now,
         receive_timeout
       ) do
    case parse_datetime(started_at) do
      %DateTime{} = started_at ->
        DateTime.diff(now, started_at, :millisecond) < receive_timeout + @stale_grace_ms

      nil ->
        false
    end
  end

  defp fresh_redemption?(_redemption, _now, _receive_timeout), do: false

  defp stale_redemption?(%{"status" => "redeeming"}), do: true
  defp stale_redemption?(_redemption), do: false

  defp next_generation(metadata) do
    case get_in(metadata || %{}, ["saved_reset_redemption", "generation"]) do
      generation when is_integer(generation) and generation >= 0 -> generation + 1
      _generation -> 1
    end
  end

  defp non_negative_truncated_integer(value) when is_integer(value), do: {:ok, max(value, 0)}

  defp non_negative_truncated_integer(value) when is_float(value) do
    {:ok, value |> trunc() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(%Decimal{} = value) do
    {:ok, value |> Decimal.round(0, :down) |> Decimal.to_integer() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> non_negative_truncated_integer(decimal)
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(_value), do: :error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp failed_result(code, http_status) do
    %{
      status: :failed,
      applied?: false,
      code: code,
      http_status: http_status,
      reason: "saved reset redemption failed"
    }
  end

  defp transport_failed_result do
    %{
      status: :failed,
      applied?: false,
      code: "transport_error",
      reason: "saved reset redemption request failed"
    }
  end

  defp http_code(status) when is_integer(status), do: "http_#{status}"

  defp sanitize_result_code(code) when is_binary(code) do
    code =
      code
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 80)

    if code == "", do: "unknown_result", else: code
  end

  defp assignment_id(%PoolUpstreamAssignment{id: id}), do: id
  defp assignment_id(id) when is_binary(id), do: id
  defp assignment_id(_assignment_or_id), do: nil

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
