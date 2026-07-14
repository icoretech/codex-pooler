defmodule CodexPooler.Accounting do
  @moduledoc """
  Public accounting facade for request admission, settlement, usage reads, and
  request-log APIs.

  The context keeps the caller-facing contract stable while internal modules own
  the lifecycle, read-model, and metadata details.
  """

  alias CodexPooler.Accounting.{
    Attempt,
    LedgerReads,
    Metadata,
    Reporting,
    Request,
    RequestLifecycle,
    RequestLogs,
    Rollups,
    UsageReadModel
  }

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type auth :: CodexPooler.Access.auth_context()
  @type model_ref :: Model.t() | Ecto.UUID.t() | String.t() | nil
  @type accounting_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type request_result_row :: %{required(:request) => Request.t(), optional(atom()) => term()}
  @type request_result :: {:ok, request_result_row()} | {:error, accounting_error()}

  @spec reserve(auth(), model_ref(), map(), map()) :: request_result()
  defdelegate reserve(auth, model_or_id, payload, opts \\ %{}), to: RequestLifecycle

  @spec record_denied_request(auth(), model_ref(), map()) :: request_result()
  defdelegate record_denied_request(auth, model_or_id, opts \\ %{}), to: RequestLifecycle

  @spec record_metadata_request(auth(), map()) :: request_result()
  defdelegate record_metadata_request(auth, attrs \\ %{}), to: Metadata

  @spec record_upstream_identity_metadata_request(UpstreamIdentity.t(), map()) :: request_result()
  defdelegate record_upstream_identity_metadata_request(identity, attrs \\ %{}),
    to: Metadata

  @spec accumulate_request_metadata(Request.t(), map()) :: {:ok, Request.t()} | {:error, term()}
  defdelegate accumulate_request_metadata(request, metadata), to: Metadata

  @spec persist_request_metadata(Request.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  defdelegate persist_request_metadata(request, opts \\ []), to: Metadata

  @spec merge_request_metadata(Request.t(), map(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  defdelegate merge_request_metadata(request, metadata, opts \\ []), to: Metadata

  @spec latest_success_by_assignment_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => DateTime.t() | nil
        }
  defdelegate latest_success_by_assignment_ids(assignment_ids), to: LedgerReads

  @spec create_attempt(Request.t(), PoolUpstreamAssignment.t(), map()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | accounting_error()}
  defdelegate create_attempt(request, assignment, attrs \\ %{}), to: RequestLifecycle

  @spec record_retryable_attempt_failure(Attempt.t(), map()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | accounting_error()}
  defdelegate record_retryable_attempt_failure(attempt, attrs \\ %{}), to: RequestLifecycle

  @spec finalize_reserved_request_failure(Request.t(), map()) :: request_result()
  defdelegate finalize_reserved_request_failure(request, attrs \\ %{}), to: RequestLifecycle

  @spec recover_stale_reservations(DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate recover_stale_reservations(now \\ DateTime.utc_now(), opts \\ []),
    to: RequestLifecycle

  @spec finalize_request(Request.t(), Attempt.t(), map()) :: request_result()
  defdelegate finalize_request(request, attempt, attrs \\ %{}), to: RequestLifecycle

  @spec finalize_success(Request.t(), Attempt.t(), map(), map()) :: request_result()
  def finalize_success(%Request{} = request, %Attempt{} = attempt, usage, opts \\ %{}) do
    opts =
      opts
      |> Map.new()
      |> Map.merge(%{request_status: "succeeded", attempt_status: "succeeded", usage: usage})

    finalize_request(request, attempt, opts)
  end

  @spec finalize_reservation_failure(Request.t(), map()) :: request_result()
  def finalize_reservation_failure(%Request{} = request, opts \\ %{}) do
    opts = Map.new(opts)

    opts =
      Map.merge(opts, %{
        request_status: "failed",
        usage_status: Map.get(opts, :usage_status, "not_applicable")
      })

    finalize_reserved_request_failure(request, opts)
  end

  @spec finalize_failure(Request.t(), Attempt.t(), map()) :: request_result()
  def finalize_failure(%Request{} = request, %Attempt{} = attempt, opts \\ %{}) do
    opts = Map.new(opts)

    opts =
      Map.merge(opts, %{
        request_status: "failed",
        attempt_status: Map.get(opts, :attempt_status, "failed")
      })

    finalize_request(request, attempt, opts)
  end

  @spec finalize_partial_stream_failure(Request.t(), Attempt.t(), map(), map()) ::
          request_result()
  def finalize_partial_stream_failure(
        %Request{} = request,
        %Attempt{} = attempt,
        usage \\ %{},
        opts \\ %{}
      ) do
    opts = Map.new(opts)

    opts =
      Map.merge(opts, %{
        request_status: "failed",
        attempt_status: "failed",
        usage:
          Map.merge(%{status: "usage_unknown", source: "partial_stream_failure"}, Map.new(usage)),
        last_error_code: Map.get(opts, :last_error_code, "stream_interrupted")
      })

    finalize_request(request, attempt, opts)
  end

  @spec list_ledger_entries_for_request(Request.t() | Ecto.UUID.t()) :: [term()]
  defdelegate list_ledger_entries_for_request(request), to: LedgerReads

  @spec list_api_key_usage_summaries([term()]) :: map()
  defdelegate list_api_key_usage_summaries(api_key_ids), to: UsageReadModel

  @spec token_totals_by_upstream_identity_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  defdelegate token_totals_by_upstream_identity_ids(upstream_identity_ids, started_at, ended_at),
    to: Reporting

  @spec build_api_key_self_usage(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_api_key_self_usage(pool_or_id, api_key_or_id, opts \\ []),
    to: UsageReadModel

  @spec build_codex_usage_for_upstream_identity(
          CodexPooler.Upstreams.Schemas.UpstreamIdentity.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_upstream_identity(identity, opts \\ []), to: UsageReadModel

  @spec build_codex_usage_for_api_key(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_api_key(pool_or_id, api_key_or_id, opts \\ []),
    to: UsageReadModel

  @spec build_v1_usage_for_api_key(term(), term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_v1_usage_for_api_key(pool_or_id, api_key_or_id, opts \\ []),
    to: UsageReadModel

  @spec build_codex_usage_for_pool(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_pool(pool_or_id, opts \\ []), to: UsageReadModel

  @spec build_codex_usage_for_chatgpt_account(term(), keyword()) ::
          {:ok, map()} | {:error, accounting_error()}
  defdelegate build_codex_usage_for_chatgpt_account(chatgpt_account_id, opts \\ []),
    to: UsageReadModel

  @spec list_daily_rollups(term(), keyword()) :: [term()]
  defdelegate list_daily_rollups(pool_or_id, opts \\ []), to: Rollups, as: :list

  @spec list_request_logs(term(), keyword()) :: map()
  defdelegate list_request_logs(pool_or_id, opts \\ []), to: RequestLogs, as: :list

  @spec list_request_logs_for_scope(CodexPooler.Accounts.Scope.t(), keyword()) :: map()
  defdelegate list_request_logs_for_scope(scope, opts \\ []), to: RequestLogs, as: :list_for_scope

  @spec get_request_log_for_scope(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t()) :: map() | nil
  defdelegate get_request_log_for_scope(scope, request_id), to: RequestLogs, as: :get_for_scope

  @spec list_request_log_models(term(), keyword()) :: [String.t()]
  defdelegate list_request_log_models(pool_or_id, opts \\ []), to: RequestLogs, as: :list_models

  @spec list_request_log_models_for_scope(CodexPooler.Accounts.Scope.t()) :: [String.t()]
  defdelegate list_request_log_models_for_scope(scope),
    to: RequestLogs,
    as: :list_models_for_scope

  @spec rebuild_daily_rollups_for_date(Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate rebuild_daily_rollups_for_date(date), to: Rollups, as: :rebuild_for_date

  @spec sanitize_metadata(term()) :: term()
  defdelegate sanitize_metadata(value), to: Metadata

  @spec accounting_error(atom(), String.t()) :: accounting_error()
  defdelegate accounting_error(code, message), to: Metadata
end
