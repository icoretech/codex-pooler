defmodule CodexPoolerWeb.V1.ResponsesWebsocketProviderRejectionTest do
  # A provider validation refusal reaches the public `GET /v1/responses`
  # websocket the way the OpenAI websocket mode sends it: one
  # `{"type": "error", "status": 4xx, "error": {...}}` event carrying the same
  # sanitized error object the HTTP path answers (`upstream rejected parameter
  # ... (code)`, provider type, code and param, never the provider message),
  # and the attempt records the same rejection fields. It used to be masked
  # into a `response.failed` `server_error`, which an SDK reads as a retryable
  # server failure (findings#254 row 254-15; the SSE bridge since
  # findings#225 row 225-98). A 429 and a 5xx keep the masked failure.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      await_public_websocket_upgrade: 2,
      decode_public_websocket_data!: 2,
      gateway_setup: 1,
      mint_websocket_new!: 4,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @frame_timeout_ms 15_000
  @provider_sentinel "private-public-ws-rejection-sentinel"
  @prompt_sentinel "private-public-ws-rejection-prompt-sentinel"
  @param "input[1].id"

  for topology <- [:direct, :local_owner] do
    @tag :v1_websocket
    @tag topology: topology
    test "a provider 400 frame reaches the #{topology} public websocket as the HTTP path's error, with its rejection fields", %{conn: conn, topology: topology} do
      http_error = http_answer!(conn, provider_error())
      if topology == :local_owner, do: enable_owner_forwarding!()

      {texts, request, attempt} = public_websocket_turn!(topology, provider_frame(400, provider_error()))

      assert [text] = texts
      event = CodexPooler.JSON.decode!(text)

      assert %{"type" => "error", "status" => 400, "error" => error} = event

      # The HTTP answer maps the param to the client's input position through
      # the turn's index map; the socket holds none, so the event keeps the
      # path without its index rather than risk naming a position a Lite
      # rewrite moved (findings#254 row 254-61).
      assert http_error.body["error"]["param"] == @param
      assert error == %{http_error.body["error"] | "param" => "input[].id", "message" => "upstream rejected parameter input[].id (invalid_value)"}

      assert error == %{
               "message" => "upstream rejected parameter input[].id (invalid_value)",
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => "input[].id"
             }

      # The websocket turn keeps settling under the provider's terminal code
      # (the HTTP path settles `upstream_status`); only the wire and the
      # rejection fields are aligned.
      assert request.status == "failed"
      assert request.last_error_code == "invalid_value"
      assert attempt.status == "failed"
      assert rejection_fields(attempt) == rejection_fields(http_error.attempt)
      assert attempt.response_metadata["rejection_error_param"] == @param
      assert settlement_count(request.id) == 1

      for row <- [request, attempt] do
        refute inspect(row) =~ @provider_sentinel
        refute inspect(row) =~ @prompt_sentinel
      end

      refute text =~ @provider_sentinel
    end

    for {shape, provider_error} <- [
          codeless: %{"type" => "invalid_request_error", "message" => "Model '#{@provider_sentinel}' does not support image inputs."},
          unrelayable_code: %{"type" => "invalid_request_error", "code" => "synthetic_refusal", "message" => "Refused '#{@provider_sentinel}'.", "param" => "input"}
        ] do
      @tag :v1_websocket
      @tag topology: topology, provider_error: provider_error
      test "a provider 400 frame (#{shape}) reaches the #{topology} public websocket as the HTTP path's error", %{conn: conn, topology: topology, provider_error: provider_error} do
        http_error = http_answer!(conn, provider_error)
        if topology == :local_owner, do: enable_owner_forwarding!()

        {[text], _request, attempt} = public_websocket_turn!(topology, provider_frame(400, provider_error))

        assert %{"type" => "error", "status" => 400, "error" => error} = CodexPooler.JSON.decode!(text)
        assert error == http_error.body["error"]
        # Redacted on both surfaces, and typed from the 400 it rides on rather
        # than as the retryable `server_error` class (findings#254 row 254-51).
        assert error == %{"message" => "upstream request failed", "type" => "invalid_request_error", "code" => "upstream_status"}
        assert rejection_fields(attempt) == rejection_fields(http_error.attempt)
        assert rejection_fields(attempt)["rejection_error_type"] == "invalid_request_error"
        refute text =~ @provider_sentinel
      end
    end

    # A provider error frame that spans several lines (a pretty-printed error
    # object, the shape the production rows of 254-60 fit) must still record
    # its rejection fields: the finalizer reads the terminal back out of the
    # retained SSE body, where every line after the first used to fall outside
    # the event (findings#254 row 254-60).
    @tag :v1_websocket
    @tag topology: topology
    test "a provider 400 frame spanning several lines records its rejection fields on the #{topology} public websocket", %{conn: conn, topology: topology} do
      provider_error = %{"type" => "invalid_request_error", "code" => nil, "message" => "Invalid '#{@param}': '#{@provider_sentinel}'.", "param" => nil}
      http_error = http_answer!(conn, provider_error)
      if topology == :local_owner, do: enable_owner_forwarding!()

      frame = Jason.encode!(%{"type" => "error", "status" => 400, "error" => provider_error}, pretty: true)
      assert frame =~ "\n"

      {[text], request, attempt} = public_websocket_turn!(topology, frame)

      assert %{"type" => "error", "status" => 400, "error" => error} = CodexPooler.JSON.decode!(text)
      assert error == http_error.body["error"]
      assert request.status == "failed"
      assert rejection_fields(attempt) == rejection_fields(http_error.attempt)
      assert rejection_fields(attempt)["rejection_error_type"] == "invalid_request_error"
      assert rejection_fields(attempt)["rejection_message_present"] == true
      refute inspect(attempt) =~ @provider_sentinel
    end

    for status <- [429, 500] do
      @tag :v1_websocket
      @tag topology: topology, provider_status: status
      test "a provider #{status} frame keeps the masked failure on the #{topology} public websocket", %{topology: topology, provider_status: status} do
        if topology == :local_owner, do: enable_owner_forwarding!()

        provider_error = %{"type" => "server_error", "code" => "synthetic_#{status}", "message" => "synthetic #{@provider_sentinel}"}
        {[text], request, attempt} = public_websocket_turn!(topology, provider_frame(status, provider_error))

        event = CodexPooler.JSON.decode!(text)
        assert %{"type" => "response.failed", "response" => %{"status" => "failed"}} = event
        refute text =~ @provider_sentinel
        assert request.status == "failed"
        refute Map.has_key?(attempt.response_metadata, "rejection_error_code")

        # The masked error is typed from the status like the `/v1` HTTP answer
        # of the same failure: a throttle is `rate_limit_error` (findings#254
        # row 254-82), a 5xx stays `server_error`.
        expected_error = %{"code" => "synthetic_#{status}", "message" => "upstream request failed", "type" => masked_error_type(status)}
        assert event["response"]["error"] == expected_error
        assert Map.get(event, "error", expected_error) == expected_error
      end
    end
  end

  defp http_answer!(conn, provider_error) do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error}})
        ])
      )

    setup = gateway_setup(upstream)
    response = conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => @prompt_sentinel, "stream" => true})
    assert response.status == 400
    {request, attempt} = sole_rows!(setup)
    %{body: json_response(response, 400), request: request, attempt: attempt}
  end

  defp public_websocket_turn!(topology, frame) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_v1_websocket_connect!(port, setup, topology)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => @prompt_sentinel, "stream" => true})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, texts} = receive_until_terminal!(conn, websocket, ref, [])
      assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @frame_timeout_ms
      assert FakeUpstream.http_request_count(upstream) == 0
      {request, attempt} = sole_rows!(setup)
      assert attempt.transport == "websocket"
      {texts, request, attempt}
    after
      Mint.HTTP.close(conn)
    end
  end

  defp masked_error_type(429), do: "rate_limit_error"
  defp masked_error_type(_status), do: "server_error"

  defp provider_frame(status, error), do: CodexPooler.JSON.encode!(%{"type" => "error", "status" => status, "error" => error})

  defp provider_error do
    %{"type" => "invalid_request_error", "code" => "invalid_value", "message" => "Invalid 'input[1].id': '#{@provider_sentinel}'.", "param" => @param}
  end

  defp rejection_fields(attempt), do: Map.filter(attempt.response_metadata, fn {key, _value} -> String.starts_with?(key, "rejection_") end)

  defp sole_rows!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    {request, attempt}
  end

  defp settlement_count(request_id) do
    Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement"), :count)
  end

  defp receive_until_terminal!(conn, websocket, ref, texts) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, new_texts} = decode_texts(websocket, ref, responses)
            texts = texts ++ new_texts

            if Enum.any?(new_texts, &terminal_text?/1),
              do: {conn, texts},
              else: receive_until_terminal!(conn, websocket, ref, texts)

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            receive_until_terminal!(conn, websocket, ref, texts)
        end
    after
      @frame_timeout_ms -> flunk("timed out waiting for the public terminal; received #{length(texts)} frames")
    end
  end

  defp decode_texts(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, acc} ->
        case decode_public_websocket_data!(websocket, data) do
          {:ok, websocket, texts} -> {websocket, acc ++ texts}
          {:cont, {:cont, websocket}} -> {websocket, acc}
        end

      _part, acc ->
        acc
    end)
  end

  defp terminal_text?(text) do
    match?({:ok, %{"type" => type}} when type in ["response.completed", "response.failed", "response.incomplete", "error"], CodexPooler.JSON.decode(text))
  end

  defp public_v1_websocket_connect!(port, setup, topology) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    turn_state = "public-ws-rejection-#{topology}-#{System.unique_integer([:positive])}"

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", turn_state},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp enable_owner_forwarding! do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_owner_sessions()

      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)
  end

  defp stop_registered_owner_sessions do
    _logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
              _result = GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    :ok
  end
end
