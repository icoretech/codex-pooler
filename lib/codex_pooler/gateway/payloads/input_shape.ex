defmodule CodexPooler.Gateway.Payloads.InputShape do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @supported_input_image_data_mimes ~w(image/gif image/jpeg image/png image/webp)
  @supported_input_file_data_mimes ~w(application/pdf text/plain)
  @unsupported_input_image_message "Responses input_image values must use https image URLs or supported image data URLs; file_id and Codex sediment:// references are unsupported"

  @spec validate(term()) :: :ok | {:error, Error.reason()}
  def validate(payload) when is_map(payload) do
    case find_unsupported_media(payload) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  def validate(_payload), do: :ok

  defp find_unsupported_media(%{} = value) do
    value = Map.new(value, fn {key, item_value} -> {to_string(key), item_value} end)

    cond do
      unsupported_input_image_file_id?(value) ->
        unsupported_input_image_error()

      unsupported_input_image_url_reason(value) != nil ->
        unsupported_input_image_error()

      unsupported_input_file_data_reason(value) != nil ->
        unsupported_input_file_error()

      true ->
        Enum.find_value(Map.values(value), &find_unsupported_media/1)
    end
  end

  defp find_unsupported_media(values) when is_list(values) do
    Enum.find_value(values, &find_unsupported_media/1)
  end

  defp find_unsupported_media(_value), do: nil

  defp unsupported_input_image_file_id?(%{"type" => "input_image"} = value) do
    Map.has_key?(value, "file_id")
  end

  defp unsupported_input_image_file_id?(_value), do: false

  defp unsupported_input_image_url_reason(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url) do
    image_url
    |> String.trim()
    |> valid_image_reference?()
    |> case do
      true -> nil
      false -> :unsupported_input_image_format
    end
  end

  defp unsupported_input_image_url_reason(_value), do: nil

  defp unsupported_input_file_data_reason(%{"type" => "input_file", "file_data" => file_data})
       when is_binary(file_data) do
    file_data
    |> String.trim()
    |> valid_file_data_reference?()
    |> case do
      true -> nil
      false -> :unsupported_input_file_format
    end
  end

  defp unsupported_input_file_data_reason(_value), do: nil

  defp valid_image_reference?(""), do: false

  defp valid_image_reference?(reference) do
    normalized = String.downcase(reference)

    cond do
      String.starts_with?(normalized, "https://") ->
        true

      String.starts_with?(normalized, "data:") ->
        valid_data_url?(reference, @supported_input_image_data_mimes)

      true ->
        false
    end
  end

  defp valid_file_data_reference?(""), do: false

  defp valid_file_data_reference?(reference) do
    reference
    |> String.trim()
    |> valid_data_url?(@supported_input_file_data_mimes)
  end

  defp valid_data_url?("data:" <> data_url, supported_mimes) do
    with [metadata, encoded] <- String.split(data_url, ",", parts: 2),
         [mime, encoding] <- String.split(metadata, ";", parts: 2),
         true <- String.downcase(mime) in supported_mimes,
         true <- String.downcase(encoding) == "base64",
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      byte_size(bytes) > 0
    else
      _value -> false
    end
  end

  defp valid_data_url?(_reference, _supported_mimes), do: false

  defp unsupported_input_image_error do
    %{
      status: 400,
      code: "unsupported_input_image_format",
      message: @unsupported_input_image_message,
      param: "input"
    }
  end

  defp unsupported_input_file_error do
    %{
      status: 400,
      code: "unsupported_input_file_format",
      message: "Responses input_file file_data values must use supported PDF or text data URLs",
      param: "input"
    }
  end
end
