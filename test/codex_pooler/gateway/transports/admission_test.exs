defmodule CodexPooler.Gateway.Transports.AdmissionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.RouteClass

  defmodule BlockingSaturationServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
    def init(:ok), do: {:ok, :ok}
    def handle_call(:saturation, _from, state), do: {:noreply, state}
  end

  setup do
    old_config = Application.get_env(:codex_pooler, OperationalSettings, [])
    Admission.reset_for_test()

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      old_config
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()
    setup_settings(settings())

    on_exit(fn ->
      Admission.reset_for_test()
      Application.put_env(:codex_pooler, OperationalSettings, old_config)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)
  end

  test "each route class has independent concurrency and queue limits" do
    for route_class <- Admission.route_classes() do
      Admission.reset_for_test()
      assert {:ok, held} = Admission.acquire(route_class, %{request_id: "held-#{route_class}"})

      assert {:error, %{code: "bulkhead_rejected", route_class: ^route_class}} =
               Admission.acquire(route_class, %{request_id: "rejected-#{route_class}"})

      other_classes = Admission.route_classes() -- [route_class]

      leases =
        Enum.map(other_classes, fn other_class ->
          assert {:ok, lease} =
                   Admission.acquire(other_class, %{request_id: "accepted-#{other_class}"})

          lease
        end)

      Enum.each([held | leases], &Admission.release/1)
    end
  end

  test "unknown route classes fail without acquiring another class lease" do
    assert {:error, %{code: "unknown_route_class", route_class: "proxy_magic"}} =
             Admission.acquire("proxy_magic", %{request_id: "unknown-route"})

    assert {:ok, lease} = Admission.acquire("proxy_http", %{request_id: "first-http"})

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_http"}} =
             Admission.acquire("proxy_http", %{request_id: "second-http"})

    Admission.release(lease)
  end

  test "unknown route class errors are returned as sanitized overload responses" do
    assert {:error,
            %{
              status: 503,
              code: "unknown_route_class",
              message: "gateway route class is unknown",
              route_class: "proxy_magic"
            }} =
             Admission.run("proxy_magic", %{request_id: "unknown-route"}, fn -> :ok end)
  end

  test "overload responses keep each bounded internal reason while using the common client code" do
    for internal_reason <- ["bulkhead_rejected", "bulkhead_queue_timeout"] do
      assert %{
               status: 503,
               code: "server_is_overloaded",
               message: "gateway route class is temporarily overloaded",
               param: nil,
               route_class: "proxy_http",
               internal_reason: ^internal_reason,
               accounting_disposition: :zero_work
             } =
               Admission.overload_error(%{code: internal_reason, route_class: "proxy_http"})
    end
  end

  test "route class catalog exposes a dedicated MCP lane with defaults" do
    assert RouteClass.mcp() in Admission.route_classes()
    assert Map.has_key?(OperationalSettings.current().bulkheads, RouteClass.mcp())

    assert RouteClass.default_bulkheads()[RouteClass.mcp()] == %{
             max_concurrency: 4,
             queue_limit: 8,
             queue_timeout_ms: 5_000
           }
  end

  test "saturation returns every route class with safe zero values before admission" do
    assert {:ok, snapshot} = Admission.saturation()

    assert Map.keys(snapshot) |> Enum.sort() == Enum.sort(RouteClass.all())

    for route_class <- RouteClass.all() do
      assert %{running: 0, queued: 0} == snapshot[route_class]
    end

    refute inspect(snapshot) =~ "lease"
    refute inspect(snapshot) =~ "monitor"
    refute inspect(snapshot) =~ "request_id"
    refute inspect(snapshot) =~ "pid"
  end

  test "saturation tracks running and queued leases without exposing private state" do
    setup_settings(settings_with_queues())
    Admission.reset_for_test()
    attach_telemetry()

    assert {:ok, held} = Admission.acquire("proxy_stream", %{request_id: "held-stream"})

    queued =
      Task.async(fn ->
        Admission.acquire("proxy_stream", %{request_id: "queued-stream"})
      end)

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :enqueued],
                    _measurements, %{route_class: "proxy_stream"}}

    assert {:ok, snapshot} = Admission.saturation()
    assert %{running: 1, queued: 1} = snapshot["proxy_stream"]

    refute inspect(snapshot) =~ "held-stream"
    refute inspect(snapshot) =~ "queued-stream"
    refute inspect(snapshot) =~ "leases"
    refute inspect(snapshot) =~ "monitors"

    Admission.release(held)
    assert {:ok, lease} = Task.await(queued, 1_000)
    Admission.release(lease)
  end

  test "saturation distinguishes timeout from an unavailable server" do
    name = {:global, {:blocking_saturation, System.unique_integer([:positive])}}
    {:ok, _pid} = start_supervised({BlockingSaturationServer, name: name})

    assert {:error, :timeout} = Admission.saturation(name, 1)
    assert {:error, :unavailable} = Admission.saturation(:missing_admission_server, 10)
  end

  test "operational settings backfill the MCP bulkhead for existing settings rows" do
    instance_settings = InstanceSettings.ensure_singleton!()
    bulkheads_without_mcp = Map.delete(instance_settings.gateway.bulkheads, RouteClass.mcp())

    settings =
      OperationalSettings.from_instance_settings(%{
        instance_settings
        | gateway: %{instance_settings.gateway | bulkheads: bulkheads_without_mcp}
      })

    assert settings.bulkheads[RouteClass.mcp()] ==
             RouteClass.default_bulkheads()[RouteClass.mcp()]
  end

  test "queued requests dequeue when capacity is released" do
    setup_settings(settings_with_queues())
    Admission.reset_for_test()
    attach_telemetry()
    assert {:ok, held} = Admission.acquire("proxy_stream", %{request_id: "held-stream"})

    task =
      Task.async(fn ->
        Admission.acquire("proxy_stream", %{
          request_id: "queued-stream",
          endpoint: "/backend-api/codex/responses"
        })
      end)

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :enqueued],
                    _measurements, %{route_class: "proxy_stream", request_id: "queued-stream"}}

    Admission.release(held)
    assert {:ok, queued_lease} = Task.await(task, 1_000)

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :dequeued],
                    measurements, %{route_class: "proxy_stream", request_id: "queued-stream"}}

    assert is_integer(measurements.queued_ms)
    Admission.release(queued_lease)
  end

  test "active leases are released when the owning process exits" do
    parent = self()

    pid =
      spawn(fn ->
        assert {:ok, lease} =
                 Admission.acquire("proxy_websocket", %{request_id: "held-websocket"})

        send(parent, {:held, self(), lease})

        receive do
          :release -> Admission.release(lease)
        end
      end)

    assert_receive {:held, ^pid, _lease}

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_websocket"}} =
             Admission.acquire("proxy_websocket", %{request_id: "rejected-websocket"})

    monitor = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}
    _state = :sys.get_state(Admission)

    assert {:ok, recovered_lease} =
             Admission.acquire("proxy_websocket", %{request_id: "recovered-websocket"})

    Admission.release(recovered_lease)
  end

  test "queue timeouts emit sanitized telemetry" do
    setup_settings(settings_with_queues())
    Admission.reset_for_test()
    attach_telemetry()
    assert {:ok, held} = Admission.acquire("audio_transcription", %{request_id: "held-media"})

    task =
      Task.async(fn ->
        Admission.acquire("audio_transcription", %{
          request_id: "queued-media",
          endpoint: "/backend-api/transcribe",
          body: "private prompt",
          authorization: "Bearer secret-token"
        })
      end)

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :enqueued],
                    _measurements, metadata}

    assert metadata.route_class == "audio_transcription"
    refute inspect(metadata) =~ "private prompt"
    refute inspect(metadata) =~ "secret-token"

    assert {:error, %{code: "bulkhead_queue_timeout", route_class: "audio_transcription"}} =
             Task.await(task, 1_000)

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :timeout],
                    measurements, timeout_metadata}

    assert timeout_metadata.route_class == "audio_transcription"
    assert timeout_metadata.request_id == "queued-media"
    assert timeout_metadata.internal_reason == "bulkhead_queue_timeout"
    assert is_integer(measurements.queued_ms)
    refute inspect(timeout_metadata) =~ "private prompt"
    refute inspect(timeout_metadata) =~ "secret-token"

    Admission.release(held)
  end

  test "rejections emit their bounded internal reason without retaining request contents" do
    attach_telemetry()
    assert {:ok, held} = Admission.acquire("proxy_http", %{request_id: "held-http"})

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_http"}} =
             Admission.acquire("proxy_http", %{
               request_id: "rejected-http",
               body: "private prompt",
               authorization: "Bearer secret-token"
             })

    assert_receive {:admission_event, [:codex_pooler, :gateway, :admission, :rejected],
                    _measurements, metadata}

    assert metadata.route_class == "proxy_http"
    assert metadata.internal_reason == "bulkhead_rejected"
    refute inspect(metadata) =~ "private prompt"
    refute inspect(metadata) =~ "secret-token"

    Admission.release(held)
  end

  test "bulkhead updates affect new admission decisions without dropping in-flight leases" do
    assert {:ok, held} = Admission.acquire("proxy_stream", %{request_id: "held-stream"})

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_stream"}} =
             Admission.acquire("proxy_stream", %{request_id: "rejected-before-update"})

    setup_settings(
      put_in(settings().bulkheads["proxy_stream"], %{
        max_concurrency: 2,
        queue_limit: 0,
        queue_timeout_ms: 25
      })
    )

    assert {:ok, expanded} =
             Admission.acquire("proxy_stream", %{request_id: "accepted-after-expand"})

    setup_settings(
      put_in(settings().bulkheads["proxy_stream"], %{
        max_concurrency: 1,
        queue_limit: 0,
        queue_timeout_ms: 25
      })
    )

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_stream"}} =
             Admission.acquire("proxy_stream", %{request_id: "rejected-after-shrink"})

    Admission.release(expanded)

    assert {:error, %{code: "bulkhead_rejected", route_class: "proxy_stream"}} =
             Admission.acquire("proxy_stream", %{request_id: "held-still-counts"})

    Admission.release(held)

    assert {:ok, recovered} =
             Admission.acquire("proxy_stream", %{request_id: "accepted-after-release"})

    Admission.release(recovered)
  end

  defp settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 25}}
        end)
    }
  end

  defp settings_with_queues do
    %OperationalSettings{
      bulkheads:
        settings().bulkheads
        |> Map.put("proxy_stream", %{max_concurrency: 1, queue_limit: 1, queue_timeout_ms: 1_000})
        |> Map.put("audio_transcription", %{
          max_concurrency: 1,
          queue_limit: 1,
          queue_timeout_ms: 25
        })
    }
  end

  defp attach_telemetry do
    test_pid = self()
    handler_id = "admission-test-#{System.unique_integer([:positive])}"

    events =
      Enum.map([:accepted, :rejected, :enqueued, :dequeued, :timeout], fn event ->
        [:codex_pooler, :gateway, :admission, event]
      end)

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:admission_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp setup_settings(%OperationalSettings{} = settings) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(instance_settings, %{
               "gateway" => %{
                 "bulkheads" => string_keyed_map(settings.bulkheads)
               }
             })
  end

  defp string_keyed_map(map), do: map |> Jason.encode!() |> Jason.decode!()
end
