defmodule CodexPooler.Gateway.Payloads.ContinuityPayload do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

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

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
