defmodule CodexPooler.Gateway.Metadata.Accounting do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type gateway_error :: FailureResponse.gateway_error()
  @type request_result ::
          {:ok, %{required(:request) => Request.t(), optional(atom()) => term()}}
          | {:error, term()}

  @spec record_required(atom(), request_result()) :: :ok | {:error, gateway_error()}
  def record_required(_operation, {:ok, %{request: %Request{}}}), do: :ok

  def record_required(operation, {:error, reason}) do
    FailureResponse.accounting_failure(operation, nil, nil, reason)
  end

  @spec record_optional(atom(), request_result()) :: :ok
  def record_optional(_operation, {:ok, %{request: %Request{}}}), do: :ok

  def record_optional(operation, {:error, reason}) do
    Logger.info([
      "gateway metadata accounting skipped",
      " operation=#{operation}",
      " reason=#{safe_failure_reason(reason)}"
    ])

    :ok
  end

  @spec record_metadata_request(atom(), Accounting.auth(), map()) ::
          :ok | {:error, gateway_error()}
  def record_metadata_request(operation, auth, attrs) do
    operation
    |> record_required(Accounting.record_metadata_request(auth, attrs))
  end

  @spec record_upstream_identity_metadata_request(atom(), UpstreamIdentity.t(), map()) ::
          :ok | {:error, gateway_error()}
  def record_upstream_identity_metadata_request(operation, identity, attrs) do
    operation
    |> record_required(Accounting.record_upstream_identity_metadata_request(identity, attrs))
  end

  @spec record_optional_upstream_identity_metadata_request(atom(), UpstreamIdentity.t(), map()) ::
          :ok
  def record_optional_upstream_identity_metadata_request(operation, identity, attrs) do
    operation
    |> record_optional(Accounting.record_upstream_identity_metadata_request(identity, attrs))
  end

  defp safe_failure_reason(reason), do: FailureResponse.safe_failure_reason(reason)
end
