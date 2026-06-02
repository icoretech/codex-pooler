defmodule CodexPoolerWeb.Telemetry.MemorySamplerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPoolerWeb.Telemetry.MemorySampler

  test "logs a sanitized top-process snapshot when memory crosses the configured threshold" do
    name = :"memory-sampler-test-#{System.unique_integer([:positive])}"
    attach_id = {__MODULE__, name}
    ets_name = :"memory-sampler-secret-#{System.unique_integer([:positive])}"
    ets_table = :ets.new(ets_name, [:named_table, :public])

    :ets.insert(ets_table, {:token, "raw-secret-memory-sampler-value"})
    :ets.insert(ets_table, for(index <- 1..5_000, do: {index, index}))

    {:ok, pid} =
      start_supervised(
        {MemorySampler,
         enabled?: true,
         name: name,
         attach_id: attach_id,
         limit_bytes: 100,
         threshold_ratio: 0.5,
         min_interval_ms: 0,
         top_processes: 1,
         top_ets_tables: 1_000,
         cgroup_usage_reader: fn -> 80 end,
         cgroup_stat_reader: fn ->
           %{
             anon: 64,
             file: 16,
             kernel_stack: 8,
             slab: 4,
             inactive_file: 2,
             active_file: 1
           }
         end,
         env_reader: fn
           "OBAN_MODE" -> "scheduler"
           "HOSTNAME" -> "codex-pooler-oban-scheduler-example"
           "RELEASE_NODE" -> "codex_pooler@example"
           _name -> nil
         end}
      )

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:vm, :memory],
          %{
            total: 60,
            binary: 10,
            processes: 20,
            processes_used: 15,
            ets: 5,
            system: 25
          },
          %{}
        )

        :sys.get_state(pid)
      end)

    assert log =~ "memory sampler threshold exceeded"
    assert log =~ "beam_total_bytes=60"
    assert log =~ "cgroup_usage_bytes=80"
    assert log =~ "limit_bytes=100"
    assert log =~ "role="
    assert log =~ "scheduler"
    assert log =~ "codex-pooler-oban-scheduler-example"
    assert log =~ "cgroup_memory_stat="
    assert log =~ ~s("anon":64)
    assert log =~ ~s("system":25)
    assert log =~ "top_ets_tables="
    assert log =~ Atom.to_string(ets_name)
    refute log =~ "raw-secret-memory-sampler-value"
    assert log =~ "top_processes="
    assert log =~ "top_message_queues="
    assert log =~ "current_stacktrace"
  end

  test "logs an empty cgroup memory stat snapshot when stat data is unavailable" do
    name = :"memory-sampler-test-#{System.unique_integer([:positive])}"
    attach_id = {__MODULE__, name}

    {:ok, pid} =
      start_supervised(
        {MemorySampler,
         enabled?: true,
         name: name,
         attach_id: attach_id,
         limit_bytes: 100,
         threshold_ratio: 0.5,
         min_interval_ms: 0,
         top_processes: 1,
         top_ets_tables: 1,
         cgroup_usage_reader: fn -> nil end,
         cgroup_stat_reader: fn -> %{} end,
         env_reader: fn _name -> nil end}
      )

    log =
      capture_log(fn ->
        :telemetry.execute([:vm, :memory], %{total: 60}, %{})
        :sys.get_state(pid)
      end)

    assert log =~ "memory sampler threshold exceeded"
    assert log =~ "cgroup_usage_bytes=unknown"
    assert log =~ "cgroup_memory_stat={}"
    assert log =~ ~s("oban_mode":"unknown")
  end

  test "detaches the VM memory handler on supervised shutdown" do
    name = :"memory-sampler-test-#{System.unique_integer([:positive])}"
    attach_id = {__MODULE__, name}

    child_spec =
      Supervisor.child_spec(
        {MemorySampler,
         enabled?: true,
         name: name,
         attach_id: attach_id,
         limit_bytes: 100,
         cgroup_usage_reader: fn -> 0 end},
        id: name
      )

    start_supervised!(child_spec)

    assert memory_handler_attached?(attach_id)

    assert :ok = stop_supervised(name)

    refute memory_handler_attached?(attach_id)
  end

  defp memory_handler_attached?(attach_id) do
    [:vm, :memory]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == attach_id))
  end
end
