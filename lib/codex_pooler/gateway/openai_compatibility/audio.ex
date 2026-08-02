defmodule CodexPooler.Gateway.OpenAICompatibility.Audio do
  @moduledoc false

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @backend_transcription_endpoint "/backend-api/transcribe"
  @canonical_model "gpt-4o-transcribe"
  @supported_models [@canonical_model, "gpt-transcribe"]
  @decoded_list_fields ~w(keywords languages)

  @spec validate_transcription(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate_transcription(payload) do
    with {:ok, %{validated_payload: validated_payload}} <- prepare_transcription(payload) do
      {:ok, validated_payload}
    end
  end

  @spec coerce_transcription(term(), map() | keyword()) ::
          {:ok,
           %{
             endpoint: String.t(),
             payload: map(),
             request_options: RequestOptions.t(),
             audio_payload: map()
           }}
          | {:error, Error.reason()}
  def coerce_transcription(payload, opts \\ %{}) do
    with {:ok, %{payload: payload, validated_payload: validated_payload}} <-
           prepare_transcription(payload) do
      request_options =
        opts
        |> Map.new()
        |> Map.put(:upstream_endpoint, @backend_transcription_endpoint)
        |> Map.put(:forced_transcription_model, Gateway.backend_transcription_model())
        |> Map.put(:requested_model, @canonical_model)
        |> Map.put(:effective_model, @canonical_model)
        |> RequestOptions.from_conn_metadata(@backend_transcription_endpoint, payload)

      {:ok,
       %{
         endpoint: @backend_transcription_endpoint,
         payload: payload,
         request_options: request_options,
         audio_payload: validated_payload
       }}
    end
  end

  @spec normalize_response(map()) :: map()
  def normalize_response(response) when is_map(response), do: Map.delete(response, "languages")

  defp prepare_transcription(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- reject_unsupported_fields(payload),
         {:ok, payload} <- canonicalize_model(payload),
         {:ok, payload} <- normalize_decoded_lists(payload),
         {:ok, file} <- file_metadata(payload) do
      {:ok, %{payload: payload, validated_payload: Map.put(payload, "file", file)}}
    end
  end

  defp reject_unsupported_fields(payload) do
    Validation.reject_unsupported_fields(payload, :audio)
  end

  defp canonicalize_model(%{"model" => model} = payload) when model in @supported_models,
    do: {:ok, Map.put(payload, "model", @canonical_model)}

  defp canonicalize_model(%{"model" => _model}),
    do: {:error, Error.invalid_model("audio transcription model is not supported")}

  defp canonicalize_model(_payload),
    do: {:error, Error.invalid_request("model is required", "model")}

  defp normalize_decoded_lists(payload) do
    Enum.reduce_while(@decoded_list_fields, {:ok, payload}, fn field, {:ok, payload} ->
      case normalize_decoded_list(payload, field) do
        {:ok, payload} -> {:cont, {:ok, payload}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_decoded_list(payload, field) do
    case Map.fetch(payload, field) do
      :error ->
        {:ok, payload}

      {:ok, []} ->
        {:ok, Map.delete(payload, field)}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, payload},
          else: invalid_decoded_list(field)

      {:ok, _value} ->
        invalid_decoded_list(field)
    end
  end

  defp invalid_decoded_list(field) do
    {:error, Error.invalid_request("#{field} must be an array of non-empty strings", field)}
  end

  defp file_metadata(%{"file" => file}), do: Validation.upload_metadata(file)
  defp file_metadata(_payload), do: {:error, Error.invalid_request("file is required", "file")}
end
