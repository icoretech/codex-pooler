defmodule CodexPooler.Gateway.OpenAICompatibility.NativeImageResult do
  @moduledoc false

  @spec valid?(binary()) :: boolean()
  def valid?(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"created" => created, "data" => [_ | _] = data} = response}
      when is_integer(created) and created >= 0 ->
        is_nil(response["error"]) and Enum.all?(data, &valid_image?/1)

      _invalid ->
        false
    end
  end

  defp valid_image?(%{"b64_json" => encoded}) when is_binary(encoded) and encoded != "" do
    case Base.decode64(encoded) do
      {:ok, bytes} -> plausible_image?(bytes)
      :error -> false
    end
  end

  defp valid_image?(_image), do: false

  defp plausible_image?(
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32,
           header::binary-size(5), crc::32, chunks::binary>>
       )
       when width > 0 and height > 0,
       do:
         :erlang.crc32(<<"IHDR", width::32, height::32, header::binary>>) == crc and
           png_chunks?(chunks, false)

  defp plausible_image?(<<255, 216, 255, rest::binary>>) when byte_size(rest) > 8,
    do: binary_part(rest, byte_size(rest) - 2, 2) == <<255, 217>>

  defp plausible_image?(
         <<"RIFF", size::32-little, "WEBP", kind::binary-size(4), chunk_size::32-little,
           rest::binary>>
       )
       when kind in ["VP8 ", "VP8L", "VP8X"] and chunk_size > 0,
       do: size == byte_size(rest) + 12 and byte_size(rest) >= chunk_size

  defp plausible_image?(_bytes), do: false

  defp png_chunks?(<<0::32, "IEND", crc::32>>, true), do: crc == :erlang.crc32("IEND")

  defp png_chunks?(<<size::32, type::binary-size(4), rest::binary>>, data?)
       when byte_size(rest) >= size + 4 do
    <<data::binary-size(^size), crc::32, tail::binary>> = rest

    :erlang.crc32(type <> data) == crc and
      png_chunks?(tail, data? or (type == "IDAT" and size > 0))
  end

  defp png_chunks?(_invalid, _data?), do: false
end
