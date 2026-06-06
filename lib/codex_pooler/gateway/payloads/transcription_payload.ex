defmodule CodexPooler.Gateway.Payloads.TranscriptionPayload do
  @moduledoc """
  Normalizes backend transcription multipart payloads for upstream dispatch.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.InstanceSettings

  @default_max_upload_bytes 26_214_400

  @type error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil
        }

  @spec normalize(map(), RequestOptions.t()) ::
          {:ok, map(), RequestOptions.t()} | {:error, error()}
  def normalize(payload, %RequestOptions{} = request_options) when is_map(payload) do
    with {:ok, upload, size} <- required_upload(payload),
         :ok <- enforce_max_upload_bytes(size) do
      model =
        request_options.payload_context.forced_transcription_model || Map.get(payload, "model")

      safe_payload = safe_payload(payload, model, size)
      media_opts = media_request_options(request_options, upload, size)

      {:ok, safe_payload, media_opts}
    end
  end

  def normalize(_payload, _opts),
    do: {:error, error(400, "invalid_request", "request body must be multipart/form-data")}

  defp required_upload(%{"file" => %Plug.Upload{} = upload}) do
    upload_size(upload)
  end

  defp required_upload(_payload),
    do: {:error, error(400, "invalid_request", "file is required", "file")}

  defp safe_payload(payload, model, size) do
    payload
    |> Map.take(["model", "language", "prompt", "response_format", "temperature"])
    |> Map.put("model", model)
    |> Map.put("file", %{"kind" => "upload", "bytes" => size})
  end

  defp media_request_options(%RequestOptions{} = request_options, upload, size) do
    request_options
    |> RequestOptions.put_transport(transport: "http_multipart")
    |> RequestOptions.put_request_metadata(
      request_content_type: "multipart/form-data",
      upload_bytes: size,
      request_bytes: size
    )
    |> RequestOptions.put_payload_context(media_upload: media_upload(upload, size))
  end

  defp media_upload(upload, size) do
    %{
      path: upload.path,
      redacted_filename: "audio.wav",
      content_type: upload.content_type || "application/octet-stream",
      size: size
    }
  end

  defp upload_size(%Plug.Upload{path: path} = upload) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, upload, size}

      {:error, _reason} ->
        {:error, error(400, "invalid_request", "file upload is not readable", "file")}
    end
  end

  defp enforce_max_upload_bytes(size) do
    if size <= max_upload_bytes() do
      :ok
    else
      {:error,
       error(
         413,
         "request_too_large",
         "transcription upload exceeds the maximum allowed size",
         "file"
       )}
    end
  end

  defp max_upload_bytes do
    InstanceSettings.current().transcription.max_upload_bytes || @default_max_upload_bytes
  end

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
