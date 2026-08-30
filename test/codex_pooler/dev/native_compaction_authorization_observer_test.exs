defmodule CodexPooler.Dev.NativeCompactionAuthorizationObserverTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_public_endpoint!: 0]

  alias CodexPooler.Dev.NativeCompactionAuthorizationObserver
  alias CodexPooler.Dev.NativeCompactionAuthorizationObserver.Plug, as: ObserverPlug
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation

  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]

  setup do
    on_exit(fn -> NativeCompactionAuthorizationObserver.disarm() end)
    :ok
  end

  test "serves only the fixed transition counts and clears them on disarm" do
    reset = conn(:post, "/reset") |> ObserverPlug.call([])
    assert reset.status == 200

    for transition <- NativeCompactionAuthorizationObservation.transitions() do
      :ok = NativeCompactionAuthorizationObservation.emit(transition, :direct)
    end

    served = conn(:get, "/") |> ObserverPlug.call([])
    assert served.status == 200

    assert Plug.Conn.get_resp_header(
             served,
             "x-native-compaction-authorization-observer"
           ) == ["pooler-native-compaction-v1"]

    assert %{"schemaVersion" => 1, "counts" => counts} = Jason.decode!(served.resp_body)

    assert Map.keys(counts) |> Enum.sort() ==
             NativeCompactionAuthorizationObservation.transitions()
             |> Enum.map(&Atom.to_string/1)
             |> Enum.sort()

    assert Enum.all?(counts, fn {_transition, count} -> count == 1 end)

    disarmed = conn(:post, "/disarm") |> ObserverPlug.call([])
    assert disarmed.status == 200
    refute NativeCompactionAuthorizationObserver.status()["storeRunning"]

    assert NativeCompactionAuthorizationObserver.captures()["counts"]
           |> Map.values()
           |> Enum.uniq() == [0]
  end

  test "rejects malformed telemetry and stays bounded to aggregate counts" do
    :ok = NativeCompactionAuthorizationObserver.arm()

    NativeCompactionAuthorizationObserver.handle_event(
      [:codex_pooler, :gateway, :native_compaction, :authorization_transition],
      %{count: 1},
      %{transition: :unknown, topology: :direct, token: "forbidden-token"},
      nil
    )

    assert NativeCompactionAuthorizationObserver.captures()["counts"]
           |> Map.values()
           |> Enum.uniq() == [0]

    body = conn(:get, "/") |> ObserverPlug.call([]) |> Map.fetch!(:resp_body)
    refute body =~ "forbidden-token"
    refute body =~ "topology"
  end

  test "projects only the closed break modes without changing collected events" do
    :ok = NativeCompactionAuthorizationObserver.arm()

    :ok = NativeCompactionAuthorizationObservation.emit(:compact_owner_issued, :direct)
    :ok = NativeCompactionAuthorizationObservation.emit(:final_owner_issued, :forwarded)
    :ok = NativeCompactionAuthorizationObservation.emit(:final_acknowledged, :forwarded)

    assert NativeCompactionAuthorizationObserver.captures()["counts"] ==
             expected_counts(%{
               "compact_owner_issued" => 1,
               "final_owner_issued" => 1,
               "final_acknowledged" => 1
             })

    assert :ok =
             NativeCompactionAuthorizationObserver.project("missing-compact-authorization")

    assert NativeCompactionAuthorizationObserver.captures()["counts"] ==
             expected_counts(%{"final_owner_issued" => 1, "final_acknowledged" => 1})

    assert :ok =
             NativeCompactionAuthorizationObserver.project("missing-final-authorization")

    assert NativeCompactionAuthorizationObserver.captures()["counts"] ==
             expected_counts(%{"compact_owner_issued" => 1, "final_acknowledged" => 1})

    assert :ok = NativeCompactionAuthorizationObserver.project("duplicate-final-replay")

    assert NativeCompactionAuthorizationObserver.captures()["counts"] ==
             expected_counts(%{
               "compact_owner_issued" => 1,
               "final_owner_issued" => 1,
               "final_acknowledged" => 2
             })

    assert :ok = NativeCompactionAuthorizationObserver.project("none")

    assert NativeCompactionAuthorizationObserver.captures()["counts"] ==
             expected_counts(%{
               "compact_owner_issued" => 1,
               "final_owner_issued" => 1,
               "final_acknowledged" => 1
             })

    assert {:error, :invalid_break_mode} = NativeCompactionAuthorizationObserver.project("other")
  end

  test "accepts strict projection JSON only while armed and reset clears projection" do
    assert conn(:post, "/project", Jason.encode!(%{"breakMode" => "none"}))
           |> ObserverPlug.call([])
           |> Map.fetch!(:status) == 400

    _reset = conn(:post, "/reset") |> ObserverPlug.call([])

    projected =
      conn(:post, "/project", Jason.encode!(%{"breakMode" => "duplicate-final-replay"}))
      |> ObserverPlug.call([])

    assert projected.status == 200

    malformed =
      conn(:post, "/project", Jason.encode!(%{"breakMode" => "none", "extra" => true}))
      |> ObserverPlug.call([])

    assert malformed.status == 400

    _reset = conn(:post, "/reset") |> ObserverPlug.call([])
    :ok = NativeCompactionAuthorizationObservation.emit(:final_acknowledged, :direct)
    assert NativeCompactionAuthorizationObserver.captures()["counts"]["final_acknowledged"] == 1
  end

  test "runs a real loopback reset project capture status and disarm lifecycle" do
    port = start_public_endpoint!()
    base = "http://127.0.0.1:#{port}/dev/native-compaction/authorization-capture"

    assert %{status: 200, headers: headers} = Req.post!(base <> "/reset")
    assert_header(headers)

    :ok = NativeCompactionAuthorizationObservation.emit(:compact_owner_issued, :direct)

    assert %{status: 200} =
             Req.post!(base <> "/project",
               json: %{"breakMode" => "missing-compact-authorization"}
             )

    assert %{status: 200, body: %{"schemaVersion" => 1, "counts" => counts}} = Req.get!(base)
    assert counts["compact_owner_issued"] == 0

    assert %{status: 200, body: %{"armed" => true, "storeRunning" => true}} =
             Req.get!(base <> "/status")

    assert %{status: 200, body: %{"armed" => false, "storeRunning" => false}} =
             Req.post!(base <> "/disarm")

    :ok = NativeCompactionAuthorizationObservation.emit(:compact_owner_issued, :direct)
    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})
  end

  test "concurrent arm calls are deterministic and leave one lifecycle" do
    results = concurrent_calls(24, &NativeCompactionAuthorizationObserver.arm/0)

    assert results == List.duplicate(:ok, 24)

    assert NativeCompactionAuthorizationObserver.status() == %{
             "armed" => true,
             "telemetryHandlers" => 1,
             "storeRunning" => true
           }
  end

  test "concurrent reset plugs all succeed and leave cleared counts" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    :ok = NativeCompactionAuthorizationObservation.emit(:compact_reserved, :direct)

    statuses = concurrent_calls(24, fn -> conn(:post, "/reset") |> ObserverPlug.call([]) end)

    assert Enum.map(statuses, & &1.status) == List.duplicate(200, 24)
    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})
    assert NativeCompactionAuthorizationObserver.status()["telemetryHandlers"] == 1
  end

  test "reset racing disarm has a deterministic terminal state without caller failure" do
    for final_operation <- [:arm, :disarm] do
      operations = Enum.map(1..24, fn index -> if rem(index, 2) == 0, do: :arm, else: :disarm end)

      results =
        concurrent_calls(operations, fn
          :arm -> NativeCompactionAuthorizationObserver.arm()
          :disarm -> NativeCompactionAuthorizationObserver.disarm()
        end)

      assert results == List.duplicate(:ok, 24)
      assert :ok = apply(NativeCompactionAuthorizationObserver, final_operation, [])

      expected = final_operation == :arm

      assert NativeCompactionAuthorizationObserver.status() == %{
               "armed" => expected,
               "telemetryHandlers" => if(expected, do: 1, else: 0),
               "storeRunning" => expected
             }
    end
  end

  test "events during reset or disarm never crash and cannot cross the reset boundary" do
    :ok = NativeCompactionAuthorizationObserver.arm()

    emitters =
      for _index <- 1..24 do
        Task.async(fn ->
          for _event <- 1..100 do
            :ok = NativeCompactionAuthorizationObservation.emit(:compact_consumed, :direct)
          end
        end)
      end

    assert :ok = NativeCompactionAuthorizationObserver.disarm()

    assert Enum.all?(emitters, fn task ->
             Task.await(task, 15_000) == List.duplicate(:ok, 100)
           end)

    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})

    assert :ok = NativeCompactionAuthorizationObserver.arm()
    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})
  end

  test "stale generation events and project calls cannot cross reset or disarm" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    owner = Process.whereis(NativeCompactionAuthorizationObserver)
    %{generation: old_generation} = :sys.get_state(owner)

    assert :ok = NativeCompactionAuthorizationObserver.project("duplicate-final-replay")
    assert :ok = NativeCompactionAuthorizationObserver.arm()

    GenServer.cast(owner, {:transition, old_generation, :compact_reserved})
    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})

    assert :ok = NativeCompactionAuthorizationObserver.disarm()
    assert {:error, :not_armed} = NativeCompactionAuthorizationObserver.project("none")
    GenServer.cast(owner, {:transition, old_generation, :compact_reserved})
    assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})
  end

  test "project racing reset or disarm returns only closed outcomes and preserves atomic status" do
    for lifecycle_operation <- [:arm, :disarm] do
      :ok = NativeCompactionAuthorizationObserver.arm()

      operations =
        Enum.map(1..24, fn index ->
          if rem(index, 2) == 0,
            do: {:project, "duplicate-final-replay"},
            else: lifecycle_operation
        end)

      results =
        concurrent_calls(operations, fn
          {:project, break_mode} -> NativeCompactionAuthorizationObserver.project(break_mode)
          :arm -> NativeCompactionAuthorizationObserver.arm()
          :disarm -> NativeCompactionAuthorizationObserver.disarm()
        end)

      assert Enum.all?(results, &(&1 in [:ok, {:error, :not_armed}]))

      status = NativeCompactionAuthorizationObserver.status()
      assert status["telemetryHandlers"] == if(status["armed"], do: 1, else: 0)
      assert status["storeRunning"] == status["armed"]
      assert map_size(NativeCompactionAuthorizationObserver.captures()["counts"]) == 12
    end
  end

  test "reads and controls after disarm stay truthful and never recreate the owner" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    :ok = NativeCompactionAuthorizationObserver.disarm()
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil

    for _read <- 1..3 do
      assert NativeCompactionAuthorizationObserver.captures()["counts"] == expected_counts(%{})

      assert NativeCompactionAuthorizationObserver.status() == %{
               "armed" => false,
               "telemetryHandlers" => 0,
               "storeRunning" => false
             }

      assert {:error, :not_armed} = NativeCompactionAuthorizationObserver.project("none")
      assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
      assert :telemetry.list_handlers(@event) == []
    end
  end

  test "concurrent post-disarm reads and controls cannot revive observer state" do
    :ok = NativeCompactionAuthorizationObserver.disarm()

    operations =
      Enum.map(1..30, fn index ->
        case rem(index, 3) do
          0 -> :captures
          1 -> :status
          2 -> :project
        end
      end)

    results =
      concurrent_calls(operations, fn
        :captures -> NativeCompactionAuthorizationObserver.captures()
        :status -> NativeCompactionAuthorizationObserver.status()
        :project -> NativeCompactionAuthorizationObserver.project("none")
      end)

    assert Enum.count(results, &match?(%{"schemaVersion" => 1}, &1)) == 10
    assert Enum.count(results, &match?(%{"armed" => false}, &1)) == 10
    assert Enum.count(results, &(&1 == {:error, :not_armed})) == 10
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert :telemetry.list_handlers(@event) == []
  end

  test "abnormal owner death is truthful and absent disarm removes its orphan handler" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    owner = Process.whereis(NativeCompactionAuthorizationObserver)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert length(:telemetry.list_handlers(@event)) == 1

    assert NativeCompactionAuthorizationObserver.status() == %{
             "armed" => false,
             "telemetryHandlers" => 1,
             "storeRunning" => false
           }

    assert :ok = NativeCompactionAuthorizationObservation.emit(:compact_consumed, :direct)
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil

    assert :ok = NativeCompactionAuthorizationObserver.disarm()
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert :telemetry.list_handlers(@event) == []
  end

  test "parallel absent disarms remove an orphan handler and new arm self-heals it" do
    for _round <- 1..3 do
      :ok = NativeCompactionAuthorizationObserver.arm()
      owner = Process.whereis(NativeCompactionAuthorizationObserver)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
      assert length(:telemetry.list_handlers(@event)) == 1

      assert concurrent_calls(24, &NativeCompactionAuthorizationObserver.disarm/0) ==
               List.duplicate(:ok, 24)

      assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
      assert :telemetry.list_handlers(@event) == []

      :ok = NativeCompactionAuthorizationObserver.arm()
      assert NativeCompactionAuthorizationObserver.status()["telemetryHandlers"] == 1
      assert :ok = NativeCompactionAuthorizationObserver.disarm()
    end
  end

  test "arm replaces a stale orphan handler with one live generation" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    owner = Process.whereis(NativeCompactionAuthorizationObserver)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert length(:telemetry.list_handlers(@event)) == 1

    assert :ok = NativeCompactionAuthorizationObserver.arm()
    assert length(:telemetry.list_handlers(@event)) == 1
    assert NativeCompactionAuthorizationObserver.status()["armed"]

    :ok = NativeCompactionAuthorizationObservation.emit(:compact_reserved, :direct)
    assert NativeCompactionAuthorizationObserver.captures()["counts"]["compact_reserved"] == 1
  end

  test "ordinary disarm tears down guardian store and handler before returning" do
    :ok = NativeCompactionAuthorizationObserver.arm()
    guardian = Process.whereis(NativeCompactionAuthorizationObserver.Guardian)
    store = Process.whereis(NativeCompactionAuthorizationObserver)
    assert is_pid(guardian)
    assert is_pid(store)

    assert :ok = NativeCompactionAuthorizationObserver.disarm()
    assert Process.whereis(NativeCompactionAuthorizationObserver.Guardian) == nil
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert :telemetry.list_handlers(@event) == []

    assert :ok = NativeCompactionAuthorizationObserver.disarm()
    assert Process.whereis(NativeCompactionAuthorizationObserver.Guardian) == nil
  end

  test "concurrent disarm callers all observe complete teardown" do
    :ok = NativeCompactionAuthorizationObserver.arm()

    assert concurrent_calls(24, &NativeCompactionAuthorizationObserver.disarm/0) ==
             List.duplicate(:ok, 24)

    assert Process.whereis(NativeCompactionAuthorizationObserver.Guardian) == nil
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert :telemetry.list_handlers(@event) == []
  end

  test "arm racing disarm finishes in one internally consistent state" do
    for final_operation <- [:arm, :disarm] do
      :ok = NativeCompactionAuthorizationObserver.arm()

      operations = Enum.map(1..24, fn index -> if rem(index, 2) == 0, do: :arm, else: :disarm end)

      assert concurrent_calls(operations, fn
               :arm -> NativeCompactionAuthorizationObserver.arm()
               :disarm -> NativeCompactionAuthorizationObserver.disarm()
             end) == List.duplicate(:ok, 24)

      assert :ok = apply(NativeCompactionAuthorizationObserver, final_operation, [])
      expected = final_operation == :arm
      status = NativeCompactionAuthorizationObserver.status()

      assert status == %{
               "armed" => expected,
               "telemetryHandlers" => if(expected, do: 1, else: 0),
               "storeRunning" => expected
             }

      assert is_pid(Process.whereis(NativeCompactionAuthorizationObserver.Guardian)) == expected
      assert is_pid(Process.whereis(NativeCompactionAuthorizationObserver)) == expected
    end
  end

  test "events during guardian termination are safe and leave no zombie state" do
    :ok = NativeCompactionAuthorizationObserver.arm()

    emitter =
      Task.async(fn ->
        for _event <- 1..1_000 do
          :ok = NativeCompactionAuthorizationObservation.emit(:final_consumed, :forwarded)
        end
      end)

    assert :ok = NativeCompactionAuthorizationObserver.disarm()
    assert Task.await(emitter, 15_000) == List.duplicate(:ok, 1_000)
    assert Process.whereis(NativeCompactionAuthorizationObserver.Guardian) == nil
    assert Process.whereis(NativeCompactionAuthorizationObserver) == nil
    assert :telemetry.list_handlers(@event) == []
  end

  defp concurrent_calls(count, callback) when is_integer(count) do
    concurrent_calls(Enum.to_list(1..count), fn _index -> callback.() end)
  end

  defp concurrent_calls(inputs, callback) when is_list(inputs) do
    gate = make_ref()
    parent = self()

    tasks =
      Enum.map(inputs, fn input ->
        Task.async(fn ->
          send(parent, {:ready, gate})

          receive do
            {:go, ^gate} -> callback.(input)
          end
        end)
      end)

    for _input <- inputs, do: assert_receive({:ready, ^gate})
    Enum.each(tasks, &send(&1.pid, {:go, gate}))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp assert_header(headers) do
    assert {_, ["pooler-native-compaction-v1"]} =
             Enum.find(headers, fn {name, _value} ->
               String.downcase(name) == "x-native-compaction-authorization-observer"
             end)
  end

  defp expected_counts(overrides) do
    NativeCompactionAuthorizationObservation.transitions()
    |> Map.new(&{Atom.to_string(&1), 0})
    |> Map.merge(overrides)
  end
end
