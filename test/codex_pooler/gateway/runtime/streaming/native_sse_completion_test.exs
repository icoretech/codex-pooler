defmodule CodexPooler.Gateway.Runtime.Streaming.NativeSSECompletionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  defmodule ClosingAdapter do
    @moduledoc false

    def chunk(%{closed?: true}, _data), do: {:error, :closed}

    def chunk(%{adapter: adapter, payload: payload} = state, data) do
      {:ok, body, payload} = adapter.chunk(payload, data)
      closed? = body == state.close_after
      {:ok, body, %{state | payload: payload, closed?: closed?}}
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 20}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)
  end

  test "native completion remains successful when the client closes before upstream EOF" do
    completed = completed_event()
    {request, attempt, body} = close_after_delivery([completed])

    assert body == completed
    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert attempt.usage_status == "usage_known"
    assert is_nil(request.last_error_code)
    assert is_nil(attempt.network_error_code)

    refute inspect({request.request_metadata, attempt.response_metadata}) =~
             "resp_native_complete"
  end

  test "native completion split across chunks keeps its original bytes and successful settlement" do
    completed = completed_event()
    split = div(byte_size(completed), 2)
    <<prefix::binary-size(^split), suffix::binary>> = completed
    {request, attempt, body} = close_after_delivery([prefix, suffix])

    assert body == completed
    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
  end

  test "client close after a tool item without response completion remains health neutral failure" do
    item =
      event("response.output_item.done", %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "name" => "sample_tool",
          "call_id" => "sample_call"
        }
      })

    {request, attempt, body} = close_after_delivery([item])

    assert body == item
    assert request.status == "failed"
    assert attempt.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert attempt.network_error_code == "client_disconnected"
    assert Repo.all(BridgeDemotion) == []
    assert Repo.all(RoutingCircuitState) == []
  end

  test "a completion label with failed response status cannot turn a client close into success" do
    malformed =
      event("response.completed", %{
        "type" => "response.completed",
        "response" => %{"status" => "failed"}
      })

    {request, attempt, body} = close_after_delivery([malformed])

    assert body == malformed
    assert request.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
  end

  test "client close while writing completion is not treated as a delivered completion" do
    {request, attempt, body} = close_after_delivery([completed_event()], closed?: true)

    assert body == ""
    assert request.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
    assert Repo.all(BridgeDemotion) == []
    assert Repo.all(RoutingCircuitState) == []
  end

  defp close_after_delivery(chunks, opts \\ []) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(chunks,
          done: false,
          barrier_after: length(chunks),
          notify: self(),
          release_ref: release_ref
        )
      )

    fixture = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payload = %{
      "model" => fixture.model.exposed_model_id,
      "input" => native_text_input("synthetic native stream"),
      "stream" => true
    }

    task =
      Task.async(fn ->
        request_options = RequestOptions.build(%{}, @endpoint_path, payload)

        {:ok, %{stream: stream}} =
          Gateway.execute(auth, @endpoint_path, payload, request_options)

        conn = build_conn() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {adapter, adapter_payload} = conn.adapter

        adapter_state = %{
          adapter: adapter,
          payload: adapter_payload,
          close_after: IO.iodata_to_binary(chunks),
          closed?: Keyword.get(opts, :closed?, false)
        }

        stream.(%{conn | adapter: {ClosingAdapter, adapter_state}})
      end)

    assert_receive {:fake_upstream_chunk_barrier, _index, upstream_pid, ^release_ref},
                   @detection_timeout_ms

    try do
      assert {:ok, conn} = Task.await(task, @detection_timeout_ms)
      assert FakeUpstream.count(upstream) == 1
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^fixture.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      {request, attempt, conn.resp_body}
    after
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  defp completed_event do
    event("response.completed", %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_native_complete",
        "status" => "completed",
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
      }
    })
  end

  defp event(type, payload), do: "event: #{type}\ndata: #{Jason.encode!(payload)}\n\n"
end
