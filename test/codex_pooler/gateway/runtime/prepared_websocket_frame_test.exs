defmodule CodexPooler.Gateway.Runtime.PreparedWebsocketFrameTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Repo

  test "manually assembled prepared frames cannot enter prepared execution" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    request_options = RequestOptions.for_websocket(%{request_id: "manual-prepared"}, payload)

    manually_assembled = %PreparedWebsocketFrame{
      variant: :prewarm,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options
    }

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.execute_prepared_websocket_response(%{}, manually_assembled)
  end

  test "prepared prewarm execution reuses the built request options and stays row-free" do
    observer = fn -> send(self(), :request_options_built) end
    payload = %{"generate" => false, "model" => "gpt-example"}

    opts =
      %{request_id: "prepared-prewarm"}
      |> RequestOptions.for_websocket(payload)
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    assert {:ok, %PreparedWebsocketFrame{variant: :prewarm} = prepared} =
             Service.prepare_websocket_response(
               Jason.encode!(payload),
               opts,
               fn _frame -> :ok end
             )

    assert_receive :request_options_built
    refute_received :request_options_built
    row_count = Repo.aggregate(Request, :count)

    assert {:ok, prepared_result} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    assert prepared_result == WebsocketCodec.warmup_result()

    assert {:error, %{status: 409, code: "prepared_frame_consumed"}} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end

  test "concurrent prepared execution atomically admits exactly one consumer" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    opts = RequestOptions.for_websocket(%{request_id: "prepared-concurrent"}, payload)

    assert {:ok, %PreparedWebsocketFrame{variant: :prewarm} = prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    caller = self()
    start_ref = make_ref()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            {:start, ^start_ref} -> Service.execute_prepared_websocket_response(%{}, prepared)
          end
        end)
      end

    task_pids =
      for _index <- 1..2 do
        receive do
          {:ready, pid} -> pid
        end
      end

    Enum.each(task_pids, &send(&1, {:start, start_ref}))
    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{status: 409, code: "prepared_frame_consumed"}}, &1)
           ) == 1
  end

  test "prepared capability substitution invalidates the signed frame" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    opts = RequestOptions.for_websocket(%{request_id: "prepared-substitution"}, payload)

    assert {:ok, %PreparedWebsocketFrame{} = prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    substituted = %{
      prepared
      | provenance: %{prepared.provenance | capability: Capability.issue()}
    }

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.execute_prepared_websocket_response(%{}, substituted)
  end

  test "malformed input fails before preparation observation or accounting" do
    observer = fn -> send(self(), :request_options_built) end

    opts =
      RequestOptions.for_websocket(%{})
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    row_count = Repo.aggregate(Request, :count)

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.prepare_websocket_response("{invalid", opts, fn _frame -> :ok end)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end

  test "prepared response.processed keeps its control path without rebuilding options" do
    observer = fn -> send(self(), :request_options_built) end
    payload = %{"type" => "response.processed", "response_id" => "resp_prepared"}

    opts =
      %{request_id: "prepared-response-processed"}
      |> RequestOptions.for_websocket(payload)
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    assert {:ok, %PreparedWebsocketFrame{variant: :response_processed} = prepared} =
             Service.prepare_websocket_response(
               Jason.encode!(payload),
               opts,
               fn _frame -> :ok end
             )

    assert_receive :request_options_built
    refute_received :request_options_built
    row_count = Repo.aggregate(Request, :count)

    assert {:error, %{code: "upstream_websocket_forward_failed"}} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end
end
