defmodule CodexPoolerWeb.V1.AudioControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Repo

  @tag :transcription_success
  test "POST /v1/audio/transcriptions reuses transcription gateway and returns text", %{
    conn: conn
  } do
    transcript = "synthetic transcription"
    prompt = "synthetic glossary"
    audio_bytes = "synthetic audio bytes"
    upstream = start_upstream(FakeUpstream.json_response(%{"text" => transcript}))
    setup = upstream |> gateway_setup() |> use_transcription_model!()

    conn =
      conn
      |> auth(setup)
      |> post("/v1/audio/transcriptions", %{
        "model" => Gateway.backend_transcription_model(),
        "file" => upload_fixture("audio-secret.wav", "audio/wav", audio_bytes),
        "prompt" => prompt,
        "response_format" => "json"
      })

    assert %{"text" => ^transcript} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/transcribe"
    assert captured.body =~ prompt
    refute captured.body =~ setup.model.upstream_model_id
    refute captured.body =~ Gateway.backend_transcription_model()
    refute captured.body =~ "audio-secret.wav"
    assert captured.body =~ ~s(filename="audio.wav")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/transcribe"
    assert request.status == "succeeded"
    assert request.request_metadata["upload_bytes"] == byte_size(audio_bytes)

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/audio/transcriptions"

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/transcribe"

    refute inspect(request.request_metadata) =~ transcript
    refute inspect(request.request_metadata) =~ prompt
    refute inspect(request.request_metadata) =~ audio_bytes
  end

  test "POST /v1/audio/transcriptions routes when the public audio model is not listed", %{
    conn: conn
  } do
    transcript = "hidden transcription"
    audio_bytes = "hidden audio bytes"
    upstream = start_upstream(FakeUpstream.json_response(%{"text" => transcript}))

    setup =
      upstream
      |> gateway_setup()
      |> allow_models!([Gateway.backend_transcription_model()])

    conn =
      conn
      |> auth(setup)
      |> post("/v1/audio/transcriptions", %{
        "model" => Gateway.backend_transcription_model(),
        "file" => upload_fixture("hidden-audio.wav", "audio/wav", audio_bytes)
      })

    assert %{"text" => ^transcript} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/transcribe"
    refute captured.body =~ Gateway.backend_transcription_model()
    refute captured.body =~ setup.model.upstream_model_id
    refute captured.body =~ "language"
    refute captured.body =~ "response_format"
    refute captured.body =~ "temperature"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/transcribe"
    assert request.status == "succeeded"
    assert request.request_metadata["requested_model"] == Gateway.backend_transcription_model()
    assert request.request_metadata["effective_model"] == Gateway.backend_transcription_model()
    assert request.request_metadata["upload_bytes"] == byte_size(audio_bytes)
    refute inspect(request.request_metadata) =~ audio_bytes
  end

  test "POST /v1/audio/transcriptions rejects invalid model before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"text" => "should not dispatch"}))
    setup = upstream |> gateway_setup() |> use_transcription_model!()

    conn =
      conn
      |> auth(setup)
      |> post("/v1/audio/transcriptions", %{
        "model" => "whisper-1",
        "file" => upload_fixture("invalid.wav", "audio/wav", "invalid audio")
      })

    assert %{"error" => %{"code" => "invalid_model", "param" => "model"}} =
             json_response(conn, 400)

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
  end

  defp use_transcription_model!(setup) do
    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: Gateway.backend_transcription_model(),
        upstream_model_id: "provider-gpt-4o-transcribe",
        supports_responses: false,
        supports_streaming: false,
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "input_modalities" => ["audio"],
          "modes" => ["transcription"]
        }
      })
      |> Repo.update!()

    %{setup | model: model}
  end

  defp allow_models!(setup, allowed_model_identifiers) do
    api_key =
      setup.api_key
      |> Ecto.Changeset.change(%{allowed_model_identifiers: allowed_model_identifiers})
      |> Repo.update!()

    %{setup | api_key: api_key}
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-v1-audio-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
