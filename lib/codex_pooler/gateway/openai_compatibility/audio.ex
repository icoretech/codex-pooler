defmodule CodexPooler.Gateway.OpenAICompatibility.Audio do
  @moduledoc false

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @backend_transcription_endpoint "/backend-api/transcribe"
  @supported_models ~w(gpt-4o-transcribe)

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

  defp prepare_transcription(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :audio),
         :ok <- validate_model(payload),
         {:ok, file} <- file_metadata(payload) do
      {:ok, %{payload: payload, validated_payload: Map.put(payload, "file", file)}}
    end
  end

  defp validate_model(%{"model" => model}) when model in @supported_models, do: :ok

  defp validate_model(%{"model" => _model}),
    do: {:error, Error.invalid_model("audio transcription model is not supported")}

  defp validate_model(_payload), do: {:error, Error.invalid_request("model is required", "model")}

  defp file_metadata(%{"file" => file}), do: Validation.upload_metadata(file)
  defp file_metadata(_payload), do: {:error, Error.invalid_request("file is required", "file")}
end
