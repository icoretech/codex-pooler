defmodule CodexPooler.Gateway.Runtime.Streaming.NativeSSESocketCompletionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  test "real HTTP client closes after native completion while upstream EOF is held" do
    previous = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{sse_keepalive_interval_ms: 20}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    release_ref = make_ref()

    completed =
      "event: response.completed\ndata: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_socket_complete",
            "status" => "completed",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          }
        }) <> "\n\n"

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([completed],
          done: false,
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref
        )
      )

    fixture = gateway_setup(upstream)
    port = start_public_endpoint!()
    handler_id = "native-sse-socket-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:phoenix, :endpoint, :stop],
        &__MODULE__.endpoint_stopped/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)

    body =
      Jason.encode!(%{
        "model" => fixture.model.exposed_model_id,
        "input" => native_text_input("synthetic socket stream"),
        "stream" => true
      })

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        @endpoint_path,
        [{"authorization", fixture.authorization}, {"content-type", "application/json"}],
        body
      )

    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref},
                   @detection_timeout_ms

    try do
      {conn, received} = receive_completion(conn, ref, "", completed)
      assert String.replace(received, ": keepalive\n\n", "") == completed
      {:ok, _conn} = Mint.HTTP.close(conn)

      assert_receive {:native_endpoint_stopped, endpoint_pid}, @detection_timeout_ms
      monitor = Process.monitor(endpoint_pid)
      assert_receive {:DOWN, ^monitor, :process, ^endpoint_pid, _reason}, @detection_timeout_ms

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^fixture.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert request.status == "succeeded"
      assert attempt.status == "succeeded"
      assert request.usage_status == "usage_known"
      assert attempt.usage_status == "usage_known"
      assert is_nil(request.last_error_code)
      assert is_nil(attempt.network_error_code)
      assert FakeUpstream.count(upstream) == 1
    after
      Mint.HTTP.close(conn)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  def endpoint_stopped(_event, _measurements, %{conn: %{request_path: @endpoint_path}}, parent),
    do: send(parent, {:native_endpoint_stopped, self()})

  def endpoint_stopped(_event, _measurements, _metadata, _parent), do: :ok

  defp receive_completion(conn, ref, body, completed) do
    if String.contains?(body, completed) do
      {conn, body}
    else
      assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout_ms)

      body =
        Enum.reduce(responses, body, fn
          {:status, ^ref, status}, body ->
            assert status == 200
            body

          {:data, ^ref, data}, body ->
            body <> data

          {:done, ^ref}, _body ->
            flunk("upstream EOF must remain held until client closes")

          {:headers, ^ref, _headers}, body ->
            body
        end)

      receive_completion(conn, ref, body, completed)
    end
  end
end
