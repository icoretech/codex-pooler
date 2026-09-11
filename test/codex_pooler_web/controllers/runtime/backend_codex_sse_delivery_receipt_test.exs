defmodule CodexPoolerWeb.Runtime.BackendCodexSseDeliveryReceiptTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"
  @prompt_sentinel "sse-receipt-prompt-sentinel"

  defmodule ClosedChunkAdapter do
    @moduledoc false
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  setup do
    # The receipt is an info line; the test logger level is :warning.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "completed native SSE turn records a delivered downstream receipt on the attempt", %{
    conn: conn
  } do
    response_id = "resp_sse_receipt_completed"

    upstream =
      start_upstream(
        # provenance: observed findings issue 122 (native Responses SSE created/delta/completed
        # shape; payload values invented)
        FakeUpstream.strict_sequence([
          expect_dispatch(
            FakeUpstream.sse_stream([
              created_event(response_id),
              delta_event(),
              completed_event(response_id)
            ])
          )
        ])
      )

    setup = gateway_setup(upstream)

    {conn, logs} =
      with_log([level: :info], fn ->
        conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup))
      end)

    assert conn.status == 200
    assert conn.resp_body =~ ~s("type":"response.completed")
    assert :ok = FakeUpstream.verify!(upstream)

    {request, attempt} = settled_rows(setup)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert attempt.status == "succeeded"

    assert %{
             "outcome" => "delivered",
             "terminal_class" => "response.completed",
             "pushed_at" => pushed_at,
             "frames_after_visible" => frames,
             "transport" => "http_sse"
           } = attempt.response_metadata["downstream_delivery"]

    assert frames >= 1
    assert {:ok, _pushed_at, 0} = DateTime.from_iso8601(pushed_at)

    assert logs =~
             "http_sse downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=#{session_correlator(request)} outcome=delivered " <>
               "terminal_class=response.completed frames_after_visible=#{frames}"

    assert_metadata_only!(request, attempt, logs, response_id)
  end

  test "client disconnect before the terminal records an aborted downstream receipt" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (client closes before any terminal reaches it)
        FakeUpstream.strict_sequence([
          expect_dispatch(
            FakeUpstream.sse_stream([created_event("resp_sse_receipt_abort"), delta_event()],
              done: false
            )
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = stream_payload(setup)

    {result, logs} =
      with_log([level: :info], fn ->
        assert {:ok, %{stream: stream}} =
                 Gateway.execute(
                   auth,
                   @endpoint_path,
                   payload,
                   RequestOptions.build(
                     %{upstream_endpoint: @endpoint_path},
                     @endpoint_path,
                     payload
                   )
                 )

        closed_conn = %{
          Phoenix.ConnTest.build_conn()
          | adapter: {ClosedChunkAdapter, nil},
            state: :chunked
        }

        stream.(closed_conn)
      end)

    assert {:ok, _conn} = result
    assert :ok = FakeUpstream.verify!(upstream)

    {request, attempt} = settled_rows(setup)
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert attempt.status == "failed"
    assert attempt.network_error_code == "client_disconnected"

    assert attempt.response_metadata["downstream_delivery"] == %{
             "outcome" => "aborted",
             "terminal_class" => "none",
             "pushed_at" => nil,
             "frames_after_visible" => 0,
             "transport" => "http_sse"
           }

    assert logs =~
             "http_sse downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=#{session_correlator(request)} outcome=aborted " <>
               "terminal_class=none frames_after_visible=0"

    assert_metadata_only!(request, attempt, logs, "resp_sse_receipt_abort")
  end

  test "provider response.failed after visible output records a response.failed terminal class",
       %{conn: conn} do
    response_id = "resp_sse_receipt_failed"

    upstream =
      start_upstream(
        # provenance: observed findings issue 122 (native Responses SSE failed after visible output;
        # payload values invented)
        FakeUpstream.strict_sequence([
          expect_dispatch(
            FakeUpstream.sse_stream(
              [created_event(response_id), delta_event(), failed_event(response_id)],
              done: false
            )
          )
        ])
      )

    setup = gateway_setup(upstream)

    {conn, logs} =
      with_log([level: :info], fn ->
        conn |> auth(setup) |> post(@endpoint_path, stream_payload(setup))
      end)

    assert conn.status == 200
    assert conn.resp_body =~ ~s("type":"response.failed")
    assert :ok = FakeUpstream.verify!(upstream)

    {request, attempt} = settled_rows(setup)
    assert request.status == "failed"
    assert attempt.status == "failed"

    assert %{
             "outcome" => "delivered",
             "terminal_class" => "response.failed",
             "pushed_at" => pushed_at,
             "frames_after_visible" => frames,
             "transport" => "http_sse"
           } = attempt.response_metadata["downstream_delivery"]

    assert frames >= 1
    assert {:ok, _pushed_at, 0} = DateTime.from_iso8601(pushed_at)

    assert logs =~
             "http_sse downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=#{session_correlator(request)} outcome=delivered " <>
               "terminal_class=response.failed frames_after_visible=#{frames}"

    assert_metadata_only!(request, attempt, logs, response_id)
  end

  defp expect_dispatch(respond) do
    FakeUpstream.expect_request(
      method: "POST",
      path: @endpoint_path,
      json: [valid: true, required: ["input"]],
      respond: respond
    )
  end

  defp stream_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(@prompt_sentinel),
      "stream" => true
    }
  end

  defp created_event(response_id) do
    {"response.created",
     %{
       "type" => "response.created",
       "response" => %{"id" => response_id, "status" => "in_progress"}
     }}
  end

  defp delta_event do
    {"response.output_text.delta",
     %{"type" => "response.output_text.delta", "delta" => "receipt-output-sentinel"}}
  end

  defp completed_event(response_id) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => response_id,
         "status" => "completed",
         "output" => [],
         "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
       }
     }}
  end

  defp failed_event(response_id) do
    {"response.failed",
     %{
       "type" => "response.failed",
       "response" => %{
         "id" => response_id,
         "status" => "failed",
         "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}
       }
     }}
  end

  defp settled_rows(setup) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    {request, attempt}
  end

  defp session_correlator(%Request{request_metadata: metadata}) do
    Map.get(metadata || %{}, "codex_session_id") || "none"
  end

  defp assert_metadata_only!(request, attempt, logs, response_id) do
    persisted = inspect({request.request_metadata, attempt.response_metadata})
    refute persisted =~ @prompt_sentinel
    refute persisted =~ "receipt-output-sentinel"
    refute persisted =~ response_id
    refute logs =~ @prompt_sentinel
    refute logs =~ "receipt-output-sentinel"
    refute logs =~ response_id
  end
end
