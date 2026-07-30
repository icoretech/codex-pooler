defmodule CodexPooler.Gateway.Payloads.InputShape do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  @supported_input_image_data_mimes ~w(image/gif image/jpeg image/png image/webp)
  @supported_input_file_data_mimes ~w(application/pdf text/plain)
  @base64_whitespace [" ", "\t", "\r", "\n"]
  @base64_invalid_bytes (
                          allowed =
                            MapSet.new(
                              Enum.to_list(?A..?Z) ++
                                Enum.to_list(?a..?z) ++
                                Enum.to_list(?0..?9) ++ ~c"+/="
                            )

                          for byte <- 0..255,
                              not MapSet.member?(allowed, byte),
                              do: <<byte>>
                        )
  @unsupported_input_image_message "Responses input_image values must use https image URLs or supported image data URLs, or nonblank file_id references; Codex sediment:// references are unsupported"

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

    searchable_value =
      if ToolResultShape.tool_result?(value),
        do: Map.drop(value, ["output", "result"]),
        else: value

    cond do
      unsupported_input_image_file_id?(searchable_value) ->
        unsupported_input_image_error()

      unsupported_input_image_url_reason(searchable_value) != nil ->
        unsupported_input_image_error()

      unsupported_input_file_data_reason(searchable_value) != nil ->
        unsupported_input_file_error()

      true ->
        searchable_value |> Map.values() |> Enum.find_value(&find_unsupported_media/1)
    end
  end

  defp find_unsupported_media(values) when is_list(values) do
    Enum.find_value(values, &find_unsupported_media/1)
  end

  defp find_unsupported_media(_value), do: nil

  defp unsupported_input_image_file_id?(%{"type" => "input_image", "file_id" => file_id})
       when is_binary(file_id),
       do: String.trim(file_id) == ""

  defp unsupported_input_image_file_id?(%{"type" => "input_image"} = value),
    do: Map.has_key?(value, "file_id")

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
    cond do
      https_reference?(reference) ->
        true

      String.starts_with?(reference, "data:") ->
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
         true <- valid_nonempty_base64?(encoded) do
      true
    else
      _value -> false
    end
  end

  defp valid_data_url?(_reference, _supported_mimes), do: false

  defp https_reference?(reference) when byte_size(reference) >= 8 do
    reference |> binary_part(0, 8) |> String.downcase() == "https://"
  end

  defp https_reference?(_reference), do: false

  defp valid_nonempty_base64?(encoded) do
    case :binary.match(encoded, @base64_whitespace) do
      :nomatch ->
        valid_unspaced_base64?(encoded)

      {_position, _length} ->
        case scan_base64(encoded, 0, 0) do
          {count, padding} when count >= 4 and rem(count, 4) == 0 and padding <= 2 -> true
          _result -> false
        end
    end
  end

  defp valid_unspaced_base64?(encoded) do
    size = byte_size(encoded)

    size >= 4 and rem(size, 4) == 0 and
      :binary.match(encoded, @base64_invalid_bytes) == :nomatch and
      valid_unspaced_padding?(encoded, size)
  end

  defp valid_unspaced_padding?(encoded, size) do
    case :binary.match(encoded, "=") do
      :nomatch ->
        true

      {position, 1} when position == size - 1 ->
        true

      {position, 1} when position == size - 2 ->
        binary_part(encoded, size - 1, 1) == "="

      {_position, 1} ->
        false
    end
  end

  defp scan_base64(<<>>, count, padding), do: {count, padding}

  defp scan_base64(<<byte, rest::binary>>, count, padding)
       when byte in [32, 9, 13, 10],
       do: scan_base64(rest, count, padding)

  defp scan_base64(<<"=", rest::binary>>, count, padding) when padding < 2,
    do: scan_base64(rest, count + 1, padding + 1)

  defp scan_base64(<<byte, rest::binary>>, count, 0)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"+/",
       do: scan_base64(rest, count + 1, 0)

  defp scan_base64(_encoded, _count, _padding), do: :error

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
