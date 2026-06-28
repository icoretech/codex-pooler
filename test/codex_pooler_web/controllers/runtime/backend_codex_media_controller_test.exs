defmodule CodexPoolerWeb.Runtime.BackendCodexMediaControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle

  describe "Codex backend media endpoints" do
    setup do
      previous = Application.get_env(:codex_pooler, InstanceSettings, [])
      Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()

      on_exit(fn ->
        Application.put_env(:codex_pooler, InstanceSettings, previous)
        InstanceSettings.reset_cache_for_test()
      end)

      :ok
    end

    test "multipart parser ceiling does not cap configured transcription limits at the default" do
      configured_limit = 52_428_800
      update_transcription_limit!(configured_limit)

      assert CodexPoolerWeb.Endpoint.multipart_parser_length() >= configured_limit
    end

    test "POST /backend-api/transcribe requires auth before multipart parser side effects" do
      with_isolated_plug_tmpdir(fn tmp_root ->
        request_count_before = Repo.aggregate(Request, :count)

        conn =
          Plug.Test.conn(
            "POST",
            "/backend-api/transcribe",
            multipart_body("unauthenticated.wav", "unauthenticated audio bytes")
          )
          |> put_req_header(
            "content-type",
            "multipart/form-data; boundary=#{multipart_boundary()}"
          )
          |> @endpoint.call(@endpoint.init([]))

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
        assert Repo.aggregate(Request, :count) == request_count_before
        assert tmpdir_paths(tmp_root) == []
      end)
    end

    test "POST /backend-api/transcribe forces backend model and stores metadata only", %{
      conn: conn
    } do
      transcript = "backend " <> "transcript"
      requested_model = "client-selected-model"
      prompt = "backend " <> "glossary phrase"
      filename = "operator-secret.wav"
      upstream = start_upstream(FakeUpstream.json_response(%{"text" => transcript}))

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          upstream_model_id: "provider-backend-transcribe",
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      upload = upload_fixture(filename, "audio/wav", "fake backend audio")

      conn =
        conn
        |> auth(setup)
        |> post("/backend-api/transcribe", %{
          "model" => requested_model,
          "file" => upload,
          "prompt" => prompt,
          "response_format" => "json"
        })

      assert %{"text" => ^transcript} = json_response(conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/transcribe"
      refute captured.body =~ setup.model.upstream_model_id
      refute captured.body =~ Gateway.backend_transcription_model()
      refute captured.body =~ requested_model
      assert captured.body =~ prompt
      refute captured.body =~ filename
      assert captured.body =~ ~s(filename="audio.wav")
      refute captured.body =~ "language"
      refute captured.body =~ "response_format"
      refute captured.body =~ "temperature"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/transcribe"
      assert request.transport == "http_multipart"
      assert request.status == "succeeded"
      assert request.request_metadata["requested_model"] == Gateway.backend_transcription_model()
      assert request.request_metadata["effective_model"] == Gateway.backend_transcription_model()
      assert request.request_metadata["upload_bytes"] == byte_size("fake backend audio")
      refute inspect(request.request_metadata) =~ filename
      refute inspect(request.request_metadata) =~ prompt
      refute inspect(request.request_metadata) =~ transcript
    end

    test "POST /backend-api/transcribe accepts omitted model by using fixed backend semantics", %{
      conn: conn
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"text" => "backend ok"}))

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      upload = upload_fixture("fixture.wav", "audio/wav", "audio bytes")

      conn =
        conn
        |> auth(setup)
        |> post("/backend-api/transcribe", %{"file" => upload})

      assert %{"text" => "backend ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      refute captured.body =~ setup.model.upstream_model_id
      refute captured.body =~ Gateway.backend_transcription_model()
    end

    test "POST /backend-api/transcribe succeeds for transcription-only models", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"text" => "audio-only ok"}))

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          supports_responses: false,
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      upload = upload_fixture("audio-only.wav", "audio/wav", "audio only bytes")

      conn = conn |> auth(setup) |> post("/backend-api/transcribe", %{"file" => upload})

      assert %{"text" => "audio-only ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/transcribe"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/transcribe"
      assert request.status == "succeeded"
      assert request.request_metadata["upload_bytes"] == byte_size("audio only bytes")
      refute inspect(request.request_metadata) =~ "audio-only.wav"
      refute inspect(request.request_metadata) =~ "audio-only ok"
    end

    test "POST /backend-api/transcribe rejects missing file before upstream or accounting", %{
      conn: conn
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_happen"}))

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      conn = conn |> auth(setup) |> post("/backend-api/transcribe", %{"prompt" => "redacted"})

      assert json_response(conn, 400)["error"]["code"] == "invalid_request"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end

    test "POST /backend-api/transcribe rejects oversized upload before upstream or accounting", %{
      conn: conn
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_happen"}))

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      update_transcription_limit!(8)

      upload = upload_fixture("oversize.wav", "audio/wav", "ninebytes")

      conn = conn |> auth(setup) |> post("/backend-api/transcribe", %{"file" => upload})

      assert json_response(conn, 413)["error"]["code"] == "request_too_large"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end

    test "POST /backend-api/transcribe retries upstream 5xx before succeeding", %{conn: conn} do
      failing_upstream = start_upstream(FakeUpstream.http_500_json_error())
      healthy_upstream = start_upstream(FakeUpstream.json_response(%{"text" => "fallback ok"}))

      setup =
        gateway_setup(failing_upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      healthy = gateway_upstream(setup.pool, healthy_upstream, generated_secret("healthy"))
      prime_routing_quota!(healthy.identity)

      model =
        setup.model
        |> Ecto.Changeset.change(%{
          source_assignment_count: 2,
          metadata: %{"source_assignment_ids" => [setup.assignment.id, healthy.assignment.id]}
        })
        |> Repo.update!()

      setup = Map.put(setup, :model, model)

      request_id =
        seed_preferring_assignment(
          [setup.assignment.id, healthy.assignment.id],
          setup.assignment.id
        )

      upload = upload_fixture("retry.wav", "audio/wav", "retry audio")

      conn =
        conn
        |> put_req_header("x-request-id", request_id)
        |> auth(setup)
        |> post("/backend-api/transcribe", %{"file" => upload})

      assert %{"text" => "fallback ok"} = json_response(conn, 200)
      assert FakeUpstream.count(failing_upstream) == 1
      assert FakeUpstream.count(healthy_upstream) == 1

      assert [first_attempt, second_attempt] =
               Repo.all(from attempt in Attempt, order_by: [asc: attempt.attempt_number])

      assert first_attempt.status == "retryable_failed"
      assert second_attempt.status == "succeeded"
    end

    test "POST /backend-api/transcribe returns terminal upstream errors through accounting", %{
      conn: conn
    } do
      upstream = start_upstream({:json_error, 400, %{"error" => %{"code" => "bad_audio"}}})

      setup =
        gateway_setup(upstream,
          exposed_model_id: Gateway.backend_transcription_model(),
          model_metadata: %{"input_modalities" => ["audio"], "modes" => ["transcription"]}
        )

      upload = upload_fixture("terminal.wav", "audio/wav", "terminal audio")

      conn = conn |> auth(setup) |> post("/backend-api/transcribe", %{"file" => upload})

      assert json_response(conn, 400)["error"]["code"] == "bad_audio"
      assert FakeUpstream.count(upstream) == 1
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/transcribe"
      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400
    end
  end

  defp gateway_setup(upstream, opts) do
    key = active_api_key_fixture()
    pool = key.pool
    upstream_token = generated_secret("upstream")
    upstream = gateway_upstream(pool, upstream, upstream_token)
    prime_routing_quota!(upstream.identity)
    model_metadata = Keyword.get(opts, :model_metadata, %{})
    exposed_model_id = Keyword.get(opts, :exposed_model_id, "gpt-media-model")
    upstream_model_id = Keyword.get(opts, :upstream_model_id, "provider-gpt-media-model")
    supports_responses = Keyword.get(opts, :supports_responses, true)

    model =
      model_fixture(pool, %{
        exposed_model_id: exposed_model_id,
        upstream_model_id: upstream_model_id,
        pricing_ref: upstream_model_id,
        metadata:
          Map.merge(%{"source_assignment_ids" => [upstream.assignment.id]}, model_metadata),
        supports_responses: supports_responses,
        supports_streaming: false
      })

    pricing_snapshot!(model)

    Map.merge(key, %{
      identity: upstream.identity,
      assignment: upstream.assignment,
      model: model,
      upstream_token: upstream_token
    })
  end

  defp prime_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])
  end

  defp update_transcription_limit!(limit) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{
               "transcription" => %{"max_upload_bytes" => limit}
             })
  end

  defp gateway_upstream(pool, upstream, token) do
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Gateway upstream",
               onboarding_method: "import",
               metadata: metadata
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Gateway assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    %{identity: identity, assignment: assignment}
  end

  defp pricing_snapshot!(model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: model.upstream_model_id,
      price_version: "gateway-media-test-#{System.unique_integer([:positive])}",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: %{}
    }
    |> Repo.insert!()
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-upload-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp multipart_boundary, do: "codex-pooler-transcribe-boundary"

  defp multipart_body(filename, contents) do
    [
      "--#{multipart_boundary()}\r\n",
      "content-disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
      "content-type: audio/wav\r\n\r\n",
      contents,
      "\r\n--#{multipart_boundary()}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp with_isolated_plug_tmpdir(fun) do
    tmp_root =
      Path.join(System.tmp_dir!(), "codex-pooler-plug-tmp-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    previous_upload_term = :persistent_term.get(Plug.Upload)
    :persistent_term.put(Plug.Upload, {[tmp_root], "test-upload-suffix"})
    :ets.delete(Plug.Upload.Dir, self())
    :ets.delete(Plug.Upload.Path, self())

    try do
      fun.(tmp_root)
    after
      :ets.delete(Plug.Upload.Dir, self())
      :ets.delete(Plug.Upload.Path, self())
      :persistent_term.put(Plug.Upload, previous_upload_term)
      File.rm_rf!(tmp_root)
    end
  end

  defp tmpdir_paths(tmp_root) do
    case File.ls(tmp_root) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, :enoent} -> []
    end
  end

  defp generated_secret(label),
    do: "fixture-secret-#{label}-#{System.unique_integer([:positive])}"

  defp seed_preferring_assignment(assignment_ids, desired_assignment_id) do
    Enum.find(1..500, fn index ->
      seed = "bridge-ring-seed-#{index}"

      assignment_ids
      |> Enum.max_by(&rendezvous_score(seed, &1))
      |> Kernel.==(desired_assignment_id)
    end)
    |> then(&"bridge-ring-seed-#{&1}")
  end

  defp rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [seed, ?:, assignment_id])
    |> :binary.decode_unsigned()
  end
end
