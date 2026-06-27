defmodule CodexPooler.Gateway.Service do
  @moduledoc """
  Backward-compatible facade for runtime gateway execution.

  New runtime orchestration code belongs in `CodexPooler.Gateway.Runtime.Service`.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service, as: RuntimeService

  @type auth :: CodexPooler.Access.auth_context()
  @type payload :: map()
  @type opts :: RequestOptions.t()
  @type gateway_error :: CodexPooler.Gateway.Contracts.gateway_error()
  @type gateway_result :: CodexPooler.Gateway.Contracts.gateway_result()

  @spec backend_transcription_model() :: String.t()
  defdelegate backend_transcription_model, to: RuntimeService

  @spec create_upstream_file(auth(), map(), opts()) ::
          CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate create_upstream_file(auth, params, opts), to: RuntimeService

  @spec create_v1_file(
          auth(),
          %{required(:purpose) => String.t(), required(:file) => map()},
          opts()
        ) :: CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate create_v1_file(auth, params, opts), to: RuntimeService

  @spec mark_uploaded(auth(), String.t(), opts()) ::
          CodexPooler.Gateway.Runtime.Dispatch.FileDispatch.file_result()
  defdelegate mark_uploaded(auth, file_id, opts), to: RuntimeService

  @spec execute(auth(), String.t(), payload(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  defdelegate execute(auth, endpoint, payload, opts), to: RuntimeService

  @spec execute_multipart(auth(), String.t(), payload(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  defdelegate execute_multipart(auth, endpoint, payload, opts), to: RuntimeService

  @spec execute_websocket_response(auth(), binary(), opts(), (binary() -> any())) ::
          :ok | {:error, gateway_error()}
  defdelegate execute_websocket_response(auth, raw_payload, opts, push_frame), to: RuntimeService
end
