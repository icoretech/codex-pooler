defmodule CodexPooler.Gateway do
  @moduledoc """
  Controller-facing runtime gateway entrypoints for external protocol requests.

  Gateway subdomain capabilities such as websocket lifecycle, admission leases,
  cleanup, session read models, and routing circuit state live in their narrower
  owner modules under `CodexPooler.Gateway`.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service

  @type auth :: CodexPooler.Access.auth_context()
  @type payload :: map()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}

  @spec backend_transcription_model() :: String.t()
  defdelegate backend_transcription_model, to: Service

  @spec create_upstream_file(auth(), map(), RequestOptions.t()) ::
          CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate create_upstream_file(auth, params, opts), to: Service

  @spec create_v1_file(
          auth(),
          %{required(:purpose) => String.t(), required(:file) => map()},
          RequestOptions.t()
        ) :: CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate create_v1_file(auth, params, opts), to: Service

  @spec mark_uploaded(auth(), String.t(), RequestOptions.t()) ::
          CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate mark_uploaded(auth, file_id, opts), to: Service

  @spec execute(auth(), String.t(), payload(), RequestOptions.t()) :: gateway_call_result()
  defdelegate execute(auth, endpoint, payload, opts), to: Service

  @spec execute_multipart(auth(), String.t(), payload(), RequestOptions.t()) ::
          gateway_call_result()
  defdelegate execute_multipart(auth, endpoint, payload, opts), to: Service

  @spec execute_websocket_response(auth(), binary(), RequestOptions.t(), (binary() -> any())) ::
          :ok | {:error, Contracts.gateway_error()}
  defdelegate execute_websocket_response(auth, raw_payload, opts, push_frame), to: Service
end
