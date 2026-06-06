defmodule CodexPooler.Gateway.Payloads.TranscriptionPayloadTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.TranscriptionPayload
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  @endpoint "/backend-api/transcribe"

  setup do
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  describe "normalize/2" do
    test "normalizes multipart uploads through typed request options" do
      upload = upload_fixture("synthetic audio")

      opts =
        %{}
        |> RequestOptions.build(@endpoint, %{})
        |> RequestOptions.put_payload_context(forced_transcription_model: "gpt-4o-transcribe")

      assert {:ok, safe_payload, media_opts} =
               TranscriptionPayload.normalize(
                 %{"file" => upload, "model" => "client-model", "language" => "en"},
                 opts
               )

      assert safe_payload == %{
               "file" => %{"kind" => "upload", "bytes" => 15},
               "language" => "en",
               "model" => "gpt-4o-transcribe"
             }

      assert %RequestOptions{} = media_opts
      assert media_opts.transport.transport == "http_multipart"
      assert media_opts.request_metadata.request_content_type == "multipart/form-data"
      assert media_opts.request_metadata.request_bytes == 15
      assert media_opts.request_metadata.upload_bytes == 15

      assert media_opts.payload_context.media_upload == %{
               path: upload.path,
               redacted_filename: "audio.wav",
               content_type: "audio/wav",
               size: 15
             }
    end

    test "rejects raw map options because Service owns legacy option conversion" do
      upload = upload_fixture("synthetic audio")

      assert {:error, %{code: "invalid_request", status: 400}} =
               TranscriptionPayload.normalize(%{"file" => upload}, %{})
    end
  end

  defp upload_fixture(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-transcription-#{System.unique_integer([:positive])}.wav"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: "sample.wav", content_type: "audio/wav"}
  end
end
