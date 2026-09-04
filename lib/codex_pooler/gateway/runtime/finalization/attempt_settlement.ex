defmodule CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement do
  @moduledoc """
  Final accounting boundary for routed gateway attempts.

  Runtime gateway dispatch decides transport flow and route health side effects; this
  module owns the terminal attempt/reservation accounting calls and their
  sanitized failure logging.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.SessionContinuity

  @type attrs :: %{optional(atom()) => term()}
  @type usage :: %{optional(atom()) => term()} | %{optional(String.t()) => term()}
  @type gateway_error :: Contracts.gateway_error()
  @type finalization_result ::
          {:ok, Accounting.internal_request_result_row()}
          | {:stale_generation, Accounting.internal_request_result_row()}
          | {:error, gateway_error()}
  @type settlement_result ::
          finalization_result()
          | {:ok, Accounting.request_result_row() | Attempt.t()}

  @spec stale_generation?(term()) :: boolean()
  def stale_generation?({:stale_generation, _result}), do: true
  def stale_generation?(_result), do: false

  @doc false
  @spec first_settlement?(
          Accounting.internal_request_result_row()
          | Accounting.finalization_disposition()
        ) :: boolean()
  def first_settlement?(%{finalization_disposition: disposition}),
    do: first_settlement?(disposition)

  def first_settlement?(:inserted), do: true
  def first_settlement?(disposition) when disposition in [:replaced, :reused], do: false

  @spec finalize_success(Request.t(), Attempt.t(), usage(), attrs()) :: finalization_result()
  def finalize_success(request, attempt, usage, attrs) do
    Accounting.finalize_success_with_disposition(request, attempt, usage, attrs)
    |> complete_current_codex_turn(CodexTurn.succeeded_status(), nil, attempt)
    |> accounting_result(:finalize_success, request, attempt)
  end

  @spec finalize_failure(Request.t(), Attempt.t(), attrs()) :: finalization_result()
  def finalize_failure(request, attempt, attrs) do
    attrs = Map.new(attrs)

    Accounting.finalize_failure_with_disposition(request, attempt, attrs)
    |> complete_current_codex_turn(
      CodexTurn.failed_status(),
      Map.get(attrs, :last_error_code),
      attempt
    )
    |> accounting_result(:finalize_failure, request, attempt)
  end

  @spec finalize_partial_stream_failure(Request.t(), Attempt.t(), usage(), attrs()) ::
          finalization_result()
  def finalize_partial_stream_failure(request, attempt, usage, attrs) do
    attrs = Map.new(attrs)
    error_code = Map.get(attrs, :last_error_code)

    Accounting.finalize_partial_stream_failure_with_disposition(request, attempt, usage, attrs)
    |> complete_current_codex_turn(
      partial_stream_turn_status(error_code),
      error_code,
      attempt
    )
    |> accounting_result(:finalize_partial_stream_failure, request, attempt)
  end

  @spec record_retryable_failure(Request.t(), Attempt.t(), attrs()) :: settlement_result()
  def record_retryable_failure(request, attempt, attrs) do
    attempt
    |> Accounting.record_retryable_attempt_failure(attrs)
    |> accounting_result(:record_retryable_failure, request, attempt)
  end

  @spec finalize_reservation_failure(Request.t(), attrs()) :: settlement_result()
  def finalize_reservation_failure(request, attrs) do
    attrs = Map.new(attrs)

    Accounting.finalize_reservation_failure(request, attrs)
    |> SessionContinuity.complete_codex_turn(
      CodexTurn.failed_status(),
      Map.get(attrs, :last_error_code)
    )
    |> accounting_result(:finalize_reservation_failure, request)
  end

  defp complete_current_codex_turn(
         {:ok, %{stale_generation?: true}} = result,
         _status,
         _error_code,
         _attempt
       ),
       do: result

  defp complete_current_codex_turn(result, status, error_code, attempt),
    do: SessionContinuity.complete_codex_turn(result, status, error_code, attempt)

  defp accounting_result(result, operation, request, attempt \\ nil)

  defp accounting_result(
         {:ok, %{stale_generation?: true} = value},
         _operation,
         _request,
         _attempt
       ),
       do: {:stale_generation, value}

  defp accounting_result({:ok, value}, _operation, _request, _attempt), do: {:ok, value}

  defp accounting_result(
         {:error, %{code: code}},
         _operation,
         _request,
         _attempt
       )
       when code in [:request_already_finalized, :attempt_already_finalized] do
    {:error,
     %{
       status: 499,
       code: Atom.to_string(code),
       message: "request lifecycle already completed"
     }}
  end

  defp accounting_result({:error, reason}, operation, request, attempt) do
    FailureResponse.accounting_failure(operation, request, attempt, reason)
  end

  defp partial_stream_turn_status("client_disconnected"), do: CodexTurn.interrupted_status()
  defp partial_stream_turn_status(:client_disconnected), do: CodexTurn.interrupted_status()
  defp partial_stream_turn_status(_error_code), do: CodexTurn.failed_status()
end
