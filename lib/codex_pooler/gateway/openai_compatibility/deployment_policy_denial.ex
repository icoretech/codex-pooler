defmodule CodexPooler.Gateway.OpenAICompatibility.DeploymentPolicyDenial do
  @moduledoc false

  @max_bytes 8_192
  @public_error %{
    "code" => "model_request_policy_denied",
    "type" => "invalid_request_error",
    "message" => "The deployment rejected this model request. Ask the administrator to check the model access policy and request settings."
  }

  @spec error() :: %{String.t() => String.t()}
  def error, do: @public_error

  # The native app-server's httpConnectionFailed tag is not a provider field.
  # Here the transport supplies the status and the complete diagnostic supplies
  # all three discriminator values. Never infer this refusal from prose or code.
  @spec matches?(integer() | nil, term()) :: boolean()
  def matches?(403, body) when is_binary(body) and byte_size(body) <= @max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, diagnostic} -> diagnostic?(diagnostic)
      _invalid -> false
    end
  end

  def matches?(403, %{} = diagnostic) do
    diagnostic?(diagnostic) and
      IO.iodata_length(CodexPooler.JSON.encode_to_iodata!(diagnostic)) <= @max_bytes
  end

  def matches?(_status, _diagnostic), do: false

  @spec mark_bridge_rejection(Req.Response.t()) :: Req.Response.t()
  def mark_bridge_rejection(%Req.Response{status: 403, body: body} = response) when is_binary(body) and byte_size(body) <= @max_bytes + 10 do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => diagnostic}} ->
        if matches?(403, diagnostic), do: Req.Response.put_private(response, :public_deployment_policy_denial, true), else: response

      _other ->
        response
    end
  end

  def mark_bridge_rejection(%Req.Response{} = response), do: response

  @spec bridge_rejection?(Req.Response.t()) :: boolean()
  def bridge_rejection?(%Req.Response{status: 403} = response),
    do: Req.Response.get_private(response, :public_deployment_policy_denial) == true

  def bridge_rejection?(%Req.Response{}), do: false

  @spec frame?(term()) :: boolean()
  def frame?(%{"type" => type} = event) when type in ["error", "response.failed"] do
    status = Map.get(event, "status", Map.get(event, "status_code"))

    nested =
      case Map.get(event, "response") do
        %{} = response -> Map.get(response, "error")
        _other -> nil
      end

    decoded_diagnostic?(status, Map.get(event, "error")) or decoded_diagnostic?(status, nested)
  end

  def frame?(_event), do: false

  defp decoded_diagnostic?(status, %{} = diagnostic), do: matches?(status, diagnostic)
  defp decoded_diagnostic?(_status, _diagnostic), do: false

  defp diagnostic?(%{"error" => "middleware_denied", "reason_code" => "request_credential_denied", "layer" => "l7"}), do: true
  defp diagnostic?(_diagnostic), do: false
end
