defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.Audio do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @canonical_mimes %{
    "wav" => "audio/wav",
    "mp3" => "audio/mpeg",
    "m4a" => "audio/mp4",
    "webm" => "audio/webm",
    "ogg" => "audio/ogg"
  }

  @decoded_max_bytes 52_428_800
  @encoded_non_whitespace_max_bytes 69_905_068
  @encoded_count_chunk_bytes 65_536
  @ascii_whitespace [" ", "\t", "\r", "\n"]

  @type public_audio :: %{required(String.t()) => binary()}
  @type public_part :: %{required(String.t()) => binary() | public_audio()}
  @type canonical_part :: %{required(String.t()) => binary()}
  @type result :: {:ok, canonical_part()} | {:error, Error.reason()}
  @typep encoded_scan_result :: {boolean(), boolean()}

  @spec supported_format?(term()) :: boolean()
  def supported_format?(format) when is_binary(format), do: Map.has_key?(@canonical_mimes, format)
  def supported_format?(_format), do: false

  @spec normalize_part(public_part()) :: result()
  def normalize_part(%{
        "type" => "input_audio",
        "input_audio" => %{"data" => data, "format" => format}
      }) do
    with {:ok, whitespace?} <- precheck_encoded(data),
         {:ok, decoded} <- decode_audio(data, whitespace?) do
      mime = Map.fetch!(@canonical_mimes, format)

      {:ok,
       %{
         "type" => "input_audio",
         "audio_url" => "data:" <> mime <> ";base64," <> Base.encode64(decoded)
       }}
    end
  end

  @spec precheck_encoded(binary()) :: {:ok, boolean()} | {:error, Error.reason()}
  defp precheck_encoded(data) do
    case scan_encoded(data) do
      {true, _whitespace?} -> {:error, oversized_error()}
      {false, whitespace?} -> {:ok, whitespace?}
    end
  end

  @spec scan_encoded(binary()) :: encoded_scan_result()
  defp scan_encoded(data) do
    pattern = :binary.compile_pattern(@ascii_whitespace)

    if byte_size(data) <= @encoded_non_whitespace_max_bytes do
      {false, :binary.match(data, pattern) != :nomatch}
    else
      count_non_whitespace(data, pattern, 0, 0, false)
    end
  end

  @spec count_non_whitespace(
          binary(),
          :binary.cp(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) :: encoded_scan_result()
  defp count_non_whitespace(data, _pattern, offset, _count, whitespace?)
       when offset == byte_size(data),
       do: {false, whitespace?}

  defp count_non_whitespace(data, pattern, offset, count, whitespace?) do
    chunk_size = min(@encoded_count_chunk_bytes, byte_size(data) - offset)
    chunk = binary_part(data, offset, chunk_size)
    whitespace_count = length(:binary.matches(chunk, pattern))
    next_count = count + chunk_size - whitespace_count
    next_whitespace? = whitespace? or whitespace_count > 0

    if next_count > @encoded_non_whitespace_max_bytes do
      {true, next_whitespace?}
    else
      count_non_whitespace(
        data,
        pattern,
        offset + chunk_size,
        next_count,
        next_whitespace?
      )
    end
  end

  @spec decode_audio(binary(), boolean()) :: {:ok, binary()} | {:error, Error.reason()}
  defp decode_audio(data, whitespace?) do
    decoded =
      if whitespace?,
        do: Base.decode64(data, ignore: :whitespace),
        else: Base.decode64(data)

    case decoded do
      {:ok, <<>>} -> {:error, invalid_base64_error()}
      {:ok, decoded} when byte_size(decoded) > @decoded_max_bytes -> {:error, oversized_error()}
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, invalid_base64_error()}
    end
  end

  @spec invalid_base64_error() :: Error.reason()
  defp invalid_base64_error,
    do: Error.invalid_request("input_audio data must be base64", "input")

  @spec oversized_error() :: Error.reason()
  defp oversized_error,
    do: Error.invalid_request("input_audio data must be 50 MiB or smaller", "input")
end
