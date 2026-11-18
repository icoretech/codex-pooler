defmodule CodexPoolerWeb.V1.ResponsesRefusedRequestFieldsTest do
  # The Codex backend now refuses three request fields `/v1` used to forward
  # (direct probe 2026-10-06, findings#333, `gpt-6-luna`, Full and Lite request
  # shapes, HTTP and websocket; `FakeUpstream` answers them the same way):
  #
  #   * `metadata`: `Unsupported parameter: metadata`, an empty object included,
  #     in both serving modes. It is client bookkeeping, so it is accepted with
  #     the public API's shape and stripped before dispatch on every surface,
  #     with the other upstream-unsupported controls.
  #   * `web_search_preview`: `Unsupported tool type` on Full, refused on some
  #     Lite requests and not others while the refusal rolls out. Refused before
  #     dispatch in both modes, never rewritten to `web_search`.
  #   * `programmatic_tool_calling`: `Unsupported tool type` on Full, accepted in
  #     a Lite manifest. A `/v1` declaration is refused before dispatch on Full
  #     and forwarded in the manifest on Lite; its type-only `tool_choice` and
  #     `allowed_tools` member, which the backend refuses on Full and Lite
  #     refuses as an object choice, are refused in both modes.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      await_public_websocket_upgrade: 2,
      decode_public_websocket_data!: 2,
      gateway_setup: 1,
      mint_websocket_new!: 4,
      native_text_input: 1,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1,
      stream_success_sse: 0
    ]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [assert_single_native_turn_terminal!: 2, collect_native_turn_frames!: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @frame_timeout_ms 15_000
  @metadata %{"smoke_request_label" => "synthetic-label"}
  @lookup %{"type" => "function", "name" => "lookup_fixture", "parameters" => %{"type" => "object", "properties" => %{}}}

  describe "metadata" do
    for mode <- ["full", "lite"], stream? <- [true, false] do
      @tag mode: mode, stream: stream?
      test "POST /v1/responses accepts metadata and never forwards it (#{mode}, stream #{stream?})", %{conn: conn, mode: mode, stream: stream?} do
        upstream = start_upstream(stream_success_sse())
        setup = serve!(gateway_setup(upstream), mode)

        response = conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic metadata request", "metadata" => @metadata, "stream" => stream?})

        assert response.status == 200
        assert [captured] = FakeUpstream.requests(upstream)
        refute Map.has_key?(captured.json, "metadata")
      end
    end

    # The smoke lane's shape: three creates carrying `metadata`, sent without
    # waiting, two sharing a stream id.
    for topology <- [:direct, :local_owner], mode <- ["full", "lite"] do
      @tag topology: topology, mode: mode
      test "pipelined #{mode} websocket creates carrying metadata all complete in order, #{topology}", %{topology: topology, mode: mode} do
        if topology == :local_owner, do: enable_owner_forwarding!()
        upstream = start_upstream(FakeUpstream.repeat_last([FakeUpstream.websocket_text_frames([completed_frame("resp_metadata_create")])]))
        setup = serve!(gateway_setup(upstream), mode)
        client = connect!(setup)

        try do
          client = Enum.reduce([{"first", "shared"}, {"second", "shared"}, {"third", "other"}], client, fn {label, stream_id}, client -> send_create!(client, setup, stream_id, %{"metadata" => %{"smoke_request_label" => label}}) end)
          {_client, texts} = receive_terminals!(client, 3)

          assert Enum.map(texts, &(CodexPooler.JSON.decode!(&1) |> then(fn event -> {event["type"], event["stream_id"]} end))) == [
                   {"response.completed", "shared"},
                   {"response.completed", "shared"},
                   {"response.completed", "other"}
                 ]

          assert [_first, _second, _third] = captured = FakeUpstream.requests(upstream)
          refute Enum.any?(captured, &Map.has_key?(&1.json, "metadata"))
        after
          Mint.HTTP.close(client.conn)
        end
      end
    end

    test "POST /v1/chat/completions accepts metadata and never forwards it", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic chat"}], "metadata" => @metadata})

      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      refute Map.has_key?(captured.json, "metadata")
    end

    test "the native HTTP route strips metadata like the other upstream-unsupported controls", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_native_metadata", "object" => "response", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}))
      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic native"), "metadata" => @metadata})

      assert %{"id" => "resp_native_metadata"} = json_response(response, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      refute Map.has_key?(captured.json, "metadata")
    end

    for topology <- [:direct, :local_owner] do
      @tag topology: topology
      test "the native #{topology} websocket strips metadata", %{topology: topology} do
        if topology == :local_owner, do: enable_owner_forwarding!()
        upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_native_ws_metadata")]))
        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
        {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: "native-metadata-#{topology}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})

        try do
          payload =
            CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic native"), "metadata" => @metadata, "stream" => true, "generate" => true})

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          {state, frames} = collect_native_turn_frames!(state)
          assert %{"response" => %{"id" => "resp_native_ws_metadata"}} = assert_single_native_turn_terminal!(frames, "response.completed")
          assert [captured] = FakeUpstream.requests(upstream)
          refute Map.has_key?(captured.json, "metadata")
          assert :ok = CodexResponsesSocket.terminate(:closed, state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end
    end

    # The public API's own refusals (raw probe 2026-10-06), on `metadata`
    # without echoing a client key or value.
    test "POST /v1/responses refuses a malformed metadata before dispatch with the public API's codes", %{conn: conn} do
      cases = [
        {"x", "invalid_type"},
        {Map.new(1..17, &{"k#{&1}", "v"}), "object_above_max_properties"},
        {%{String.duplicate("k", 65) => "v"}, "property_name_above_max_length"},
        {%{"k" => 1}, "invalid_type"},
        {%{"k" => String.duplicate("v", 513)}, "string_above_max_length"}
      ]

      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream)

      for {metadata, code} <- cases do
        response = conn |> recycle() |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "metadata" => metadata})
        assert %{"error" => %{"code" => ^code, "param" => "metadata", "type" => "invalid_request_error"}} = json_response(response, 400)
        refute response.resp_body =~ String.duplicate("k", 65)
      end

      # The limits themselves are accepted, and so is null.
      for metadata <- [nil, Map.put(Map.new(1..15, &{"k#{&1}", "v"}), String.duplicate("k", 64), String.duplicate("v", 512))] do
        response = conn |> recycle() |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "metadata" => metadata, "stream" => true})
        assert response.status == 200
      end

      assert FakeUpstream.count(upstream) == 2
    end

    test "a websocket create with a malformed metadata is refused before dispatch" do
      upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_never")]))
      setup = gateway_setup(upstream)
      client = connect!(setup)

      try do
        client = send_create!(client, setup, "malformed", %{"metadata" => %{"k" => 1}})
        {_client, [text]} = receive_terminals!(client, 1)
        assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_type", "param" => "metadata"}} = CodexPooler.JSON.decode!(text)
        assert FakeUpstream.count(upstream) == 0
        assert no_requests?(setup)
      after
        Mint.HTTP.close(client.conn)
      end
    end
  end

  # openai-python 3.53.0 added two top-level Responses request fields with no Codex backend support evidence:
  # `background_options` (`completion_window` `soonest`/`2h`/`8h` and `continuation_id`, which the public API ties to
  # `background: true`, itself refused here) and `image` (`context_compression`). `/v1` refuses both explicitly with
  # `unsupported_parameter` on the field, before any upstream work, instead of implying discounted windows,
  # continuation priority or image compression on Codex-backed traffic (findings#597).
  describe "background_options and image" do
    @sdk_fields %{
      "background_options" => %{"completion_window" => "2h", "continuation_id" => "cont_synthetic_0001"},
      "image" => %{"context_compression" => "enabled"}
    }

    for {field, value} <- @sdk_fields, stream? <- [true, false] do
      test "POST /v1/responses refuses #{field} before dispatch (stream #{stream?})", %{conn: conn} do
        upstream = start_upstream(stream_success_sse())
        setup = gateway_setup(upstream)
        payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "stream" => unquote(stream?), unquote(field) => unquote(Macro.escape(value))}

        response = conn |> auth(setup) |> post("/v1/responses", payload)

        assert %{"error" => %{"type" => "invalid_request_error", "code" => "unsupported_parameter", "param" => unquote(field), "message" => "Unsupported parameter: " <> unquote(field)}} = json_response(response, 400)
        assert FakeUpstream.count(upstream) == 0
        assert no_requests?(setup)
      end
    end

    test "POST /v1/responses refuses background_options beside background: true, flex service tier and non-streaming", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream)
      payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "stream" => false, "service_tier" => "flex", "background" => true, "background_options" => %{"completion_window" => "8h"}}

      response = conn |> auth(setup) |> post("/v1/responses", payload)

      assert %{"error" => %{"code" => "unsupported_parameter", "param" => param}} = json_response(response, 400)
      assert param in ["background", "background_options"]
      assert FakeUpstream.count(upstream) == 0
      assert no_requests?(setup)
    end

    for {field, value} <- @sdk_fields do
      test "a websocket create carrying #{field} is refused before dispatch" do
        upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_never")]))
        setup = gateway_setup(upstream)
        client = connect!(setup)

        try do
          client = send_create!(client, setup, unquote(field), %{unquote(field) => unquote(Macro.escape(value))})
          {_client, [text]} = receive_terminals!(client, 1)
          assert %{"type" => "error", "status" => 400, "error" => %{"code" => "unsupported_parameter", "param" => unquote(field)}} = CodexPooler.JSON.decode!(text)
          assert FakeUpstream.count(upstream) == 0
          assert no_requests?(setup)
        after
          Mint.HTTP.close(client.conn)
        end
      end
    end
  end

  describe "web_search_preview" do
    for mode <- ["full", "lite"] do
      @tag mode: mode
      test "POST /v1/responses refuses a web_search_preview tool before dispatch (#{mode})", %{conn: conn, mode: mode} do
        upstream = start_upstream(stream_success_sse())
        setup = serve!(gateway_setup(upstream), mode)

        response = conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "tools" => [%{"type" => "web_search_preview"}]})

        assert json_response(response, 400) == %{
                 "error" => %{"code" => "invalid_request", "param" => "tools", "type" => "invalid_request_error", "message" => "web_search_preview tools are not supported; declare web_search"}
               }

        assert FakeUpstream.count(upstream) == 0
        assert no_requests?(setup)
      end

      @tag mode: mode
      test "a #{mode} websocket create declaring web_search_preview is refused before dispatch", %{mode: mode} do
        upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_never")]))
        setup = serve!(gateway_setup(upstream), mode)
        client = connect!(setup)

        try do
          client = send_create!(client, setup, "wsp", %{"tools" => [%{"type" => "web_search_preview"}]})
          {_client, [text]} = receive_terminals!(client, 1)
          assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_request", "param" => "tools"}} = CodexPooler.JSON.decode!(text)
          assert FakeUpstream.count(upstream) == 0
          assert no_requests?(setup)
        after
          Mint.HTTP.close(client.conn)
        end
      end
    end

    test "an allowed_tools choice naming web_search_preview is refused before dispatch", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic",
          "tools" => [%{"type" => "web_search"}],
          "tool_choice" => %{"type" => "allowed_tools", "mode" => "auto", "tools" => [%{"type" => "web_search_preview"}]}
        })

      assert %{"error" => %{"param" => "tool_choice"}} = json_response(response, 400)
      assert FakeUpstream.count(upstream) == 0
    end

    test "POST /v1/chat/completions refuses a web_search_preview tool before dispatch", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "tools" => [%{"type" => "web_search_preview"}]})

      assert %{"error" => %{"code" => "invalid_request", "param" => "tools"}} = json_response(response, 400)
      assert FakeUpstream.count(upstream) == 0
    end
  end

  describe "programmatic_tool_calling" do
    test "POST /v1/responses refuses the declaration before dispatch on Full", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = serve!(gateway_setup(upstream), "full")

      response = conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "tools" => [%{"type" => "programmatic_tool_calling"}, @lookup]})

      assert json_response(response, 400) == %{
               "error" => %{"code" => "invalid_request", "param" => "tools", "type" => "invalid_request_error", "message" => "programmatic_tool_calling is not supported on a Full Responses backend"}
             }

      assert FakeUpstream.count(upstream) == 0
      # Refused once the serving mode is resolved: a rejected row, never an attempt.
      assert [%Request{status: "rejected", last_error_code: "invalid_request", response_status_code: 400} = request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
      assert Repo.aggregate(from(attempt in Attempt, where: attempt.request_id == ^request.id), :count) == 0
    end

    for topology <- [:direct, :local_owner] do
      @tag topology: topology
      test "a Full websocket create declaring it is refused before dispatch, #{topology}", %{topology: topology} do
        if topology == :local_owner, do: enable_owner_forwarding!()
        upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_never")]))
        setup = serve!(gateway_setup(upstream), "full")
        client = connect!(setup)

        try do
          client = send_create!(client, setup, "ptc", %{"tools" => [%{"type" => "programmatic_tool_calling"}]})
          {_client, [text]} = receive_terminals!(client, 1)
          assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_request", "param" => "tools"}} = CodexPooler.JSON.decode!(text)
          assert FakeUpstream.count(upstream) == 0
        after
          Mint.HTTP.close(client.conn)
        end
      end
    end

    test "POST /v1/responses forwards the declaration in the Lite manifest", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = serve!(gateway_setup(upstream), "lite")

      response = conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "tools" => [%{"type" => "programmatic_tool_calling"}, @lookup], "stream" => true})

      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      refute Map.has_key?(captured.json, "tools")
      assert [%{"type" => "additional_tools", "tools" => [%{"type" => "programmatic_tool_calling"}, %{"name" => "lookup_fixture"}]} | _rest] = captured.json["input"]
    end

    test "a Lite websocket create forwards the declaration in the manifest" do
      upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_lite_ptc")]))
      setup = serve!(gateway_setup(upstream), "lite")
      client = connect!(setup)

      try do
        client = send_create!(client, setup, "ptc", %{"tools" => [%{"type" => "programmatic_tool_calling"}]})
        {_client, [text]} = receive_terminals!(client, 1)
        assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(text)
        assert [captured] = FakeUpstream.requests(upstream)
        assert [%{"type" => "additional_tools", "tools" => [%{"type" => "programmatic_tool_calling"}]} | _rest] = captured.json["input"]
      after
        Mint.HTTP.close(client.conn)
      end
    end

    for mode <- ["full", "lite"] do
      @tag mode: mode
      test "a type-only tool_choice and an allowed_tools member naming it are refused before dispatch (#{mode})", %{conn: conn, mode: mode} do
        upstream = start_upstream(stream_success_sse())
        setup = serve!(gateway_setup(upstream), mode)

        for choice <- [%{"type" => "programmatic_tool_calling"}, %{"type" => "allowed_tools", "mode" => "auto", "tools" => [%{"type" => "programmatic_tool_calling"}]}] do
          response =
            conn
            |> recycle()
            |> auth(setup)
            |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "tools" => [%{"type" => "programmatic_tool_calling"}], "tool_choice" => choice})

          assert %{"error" => %{"param" => "tool_choice", "type" => "invalid_request_error"}} = json_response(response, 400)
        end

        assert FakeUpstream.count(upstream) == 0
      end
    end
  end

  defp no_requests?(setup), do: Repo.aggregate(from(request in Request, where: request.pool_id == ^setup.pool.id), :count) == 0

  defp serve!(setup, mode) do
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode})
    setup
  end

  defp completed_frame(response_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "object" => "response", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}
    })
  end

  defp connect!(setup) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", setup.authorization}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp send_create!(client, setup, stream_id, fields) do
    frame =
      %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic create #{stream_id}", "stream_id" => stream_id}
      |> Map.merge(fields)
      |> CodexPooler.JSON.encode!()

    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_terminals!(client, count), do: receive_terminals!(client, count, [])

  defp receive_terminals!(client, 0, terminals), do: {client, Enum.reverse(terminals)}

  defp receive_terminals!(client, count, terminals) do
    receive do
      message ->
        case Mint.WebSocket.stream(client.conn, message) do
          {:ok, conn, responses} ->
            {websocket, texts} =
              Enum.reduce(responses, {client.websocket, []}, fn
                {:data, ref, data}, {websocket, acc} when ref == client.ref ->
                  case decode_public_websocket_data!(websocket, data) do
                    {:ok, websocket, decoded} -> {websocket, acc ++ decoded}
                    {:cont, websocket} -> {websocket, acc}
                  end

                _part, acc ->
                  acc
              end)

            new_terminals = Enum.filter(texts, &terminal?/1)
            receive_terminals!(%{client | conn: conn, websocket: websocket}, max(count - length(new_terminals), 0), Enum.reverse(new_terminals) ++ terminals)

          {:error, _conn, reason, _responses} ->
            flunk("public websocket receive failed: #{inspect(reason)}")

          :unknown ->
            receive_terminals!(client, count, terminals)
        end
    after
      @frame_timeout_ms -> flunk("timed out waiting for #{count} more terminal events; received #{length(terminals)}")
    end
  end

  defp terminal?(text),
    do: match?({:ok, %{"type" => type}} when type in ["response.completed", "response.failed", "response.incomplete", "error"], CodexPooler.JSON.decode(text))

  defp enable_owner_forwarding! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
  end
end
