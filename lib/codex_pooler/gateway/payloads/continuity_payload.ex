defmodule CodexPooler.Gateway.Payloads.ContinuityPayload do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @backend_codex_agent_path ~r/\A(?:\/morpheus|\/root(?:\/[a-z0-9_]+)*)\z/

  @spec put_previous_response_id(RequestOptions.t(), map()) :: RequestOptions.t()
  def put_previous_response_id(%RequestOptions{} = request_options, payload)
      when is_map(payload) do
    case blank_to_nil(request_options.continuity.previous_response_id) do
      nil ->
        RequestOptions.put_continuity(request_options,
          previous_response_id: previous_response_id(payload)
        )

      _response_id ->
        request_options
    end
  end

  @spec previous_response_id(map()) :: String.t() | nil
  def previous_response_id(payload) when is_map(payload) do
    payload
    |> Map.get("previous_response_id")
    |> Kernel.||(Map.get(payload, :previous_response_id))
    |> blank_to_nil()
  end

  @spec current_encrypted_reasoning?(term()) :: boolean()
  def current_encrypted_reasoning?(%{
        "type" => "reasoning",
        "content" => nil,
        "encrypted_content" => encrypted_content
      })
      when is_binary(encrypted_content),
      do: String.trim(encrypted_content) != ""

  def current_encrypted_reasoning?(_item), do: false

  @spec v2_encrypted_handoff?(term()) :: boolean()
  def v2_encrypted_handoff?(%{
        "type" => "agent_message",
        "author" => author,
        "recipient" => recipient,
        "content" => [
          %{"type" => "input_text", "text" => text},
          %{"type" => "encrypted_content", "encrypted_content" => encrypted_content}
        ]
      })
      when is_binary(author) and is_binary(recipient) and is_binary(text) and
             is_binary(encrypted_content) do
    backend_codex_agent_path?(author) and backend_codex_agent_path?(recipient) and
      String.trim(encrypted_content) != "" and
      text in [
        "Message Type: NEW_TASK\nTask name: #{recipient}\nSender: #{author}\nPayload:\n",
        "Message Type: MESSAGE\nTask name: #{recipient}\nSender: #{author}\nPayload:\n"
      ]
  end

  def v2_encrypted_handoff?(_item), do: false

  defp backend_codex_agent_path?(path), do: Regex.match?(@backend_codex_agent_path, path)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
