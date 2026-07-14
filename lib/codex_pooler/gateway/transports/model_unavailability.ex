defmodule CodexPooler.Gateway.Transports.ModelUnavailability do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam

  @type terminal_failure :: %{
          required(:code) => String.t(),
          required(:upstream_code) => String.t() | nil,
          required(:upstream_error_param) => String.t() | nil,
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil
        }

  @spec http_response?(integer(), binary(), boolean()) :: boolean()
  def http_response?(status, body, assignment_advertised?)
      when is_integer(status) and is_binary(body) and is_boolean(assignment_advertised?) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        unavailable_error?(
          ErrorCodes.structured_error_code(decoded),
          UpstreamErrorParam.extract(decoded),
          assignment_advertised?,
          status == 404
        )

      _result ->
        false
    end
  end

  def http_response?(_status, _body, _assignment_advertised?), do: false

  @spec terminal_failure?(terminal_failure(), boolean()) :: boolean()
  def terminal_failure?(failure, assignment_advertised?)
      when is_map(failure) and is_boolean(assignment_advertised?) do
    unavailable_error?(
      Map.get(failure, :upstream_code) || Map.get(failure, :code),
      Map.get(failure, :upstream_error_param),
      assignment_advertised?,
      true
    )
  end

  def terminal_failure?(_failure, _assignment_advertised?), do: false

  defp unavailable_error?("model_not_found", _param, _assignment_advertised?, _status_404?),
    do: true

  defp unavailable_error?("invalid_request_error", "model", true, true), do: true
  defp unavailable_error?(_code, _param, _assignment_advertised?, _status_404?), do: false
end
