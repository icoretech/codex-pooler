defmodule CodexPooler.Gateway.OpenAICompatibility.Error do
  @moduledoc false

  @type reason :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil
        }

  @spec reason(pos_integer(), String.t() | atom(), String.t(), String.t() | nil) :: reason()
  def reason(status, code, message, param \\ nil) do
    %{status: status, code: to_string(code), message: message, param: param}
  end

  @spec unsupported_parameter(String.t()) :: reason()
  def unsupported_parameter(param) do
    reason(400, "unsupported_parameter", "Unsupported parameter: #{param}", param)
  end

  @spec invalid_request(String.t(), String.t() | nil) :: reason()
  def invalid_request(message, param \\ nil) do
    reason(400, "invalid_request", message, param)
  end

  @previous_response_not_found_message "Previous response not found on this request's upstream connection: previous_response_id is resolved only on the websocket connection that produced the response, so it works on the Responses websocket, or on stream: true requests that all send the same session-id header from the first request of the chain on a deployment with websocket owner forwarding. Send the full input without previous_response_id."

  @doc """
  The OpenAI `previous_response_not_found` error a public `/v1/responses`
  request anchored on `previous_response_id` receives when the anchor cannot be
  served on the upstream websocket connection that produced it (findings#232
  row 232-277). The provider refuses `previous_response_id` over HTTP and on
  any other connection, so the request is answered before it spends a provider
  call, with a message that names what makes an anchor usable. SDK fallbacks
  that recognise the code resend the complete input.
  """
  @spec previous_response_not_found() :: reason()
  def previous_response_not_found do
    reason(400, "previous_response_not_found", @previous_response_not_found_message, "previous_response_id")
  end

  @spec invalid_model(String.t()) :: reason()
  def invalid_model(message \\ "model is not supported by this compatibility adapter") do
    reason(400, "invalid_model", message, "model")
  end
end
