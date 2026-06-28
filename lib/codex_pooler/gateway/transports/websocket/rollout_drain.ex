defmodule CodexPooler.Gateway.Transports.Websocket.RolloutDrain do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @registry WebsocketOwnerSession.Registry
  @default_timeout_ms 50_000

  @type summary :: %{
          required(:result) => :ok | :error,
          required(:owners_seen) => non_neg_integer(),
          required(:owners_drained) => non_neg_integer(),
          required(:owners_failed) => non_neg_integer(),
          required(:timeout_ms) => pos_integer(),
          required(:elapsed_ms) => non_neg_integer(),
          required(:already_draining?) => boolean()
        }

  @type option :: {:name, GenServer.server()} | {:timeout_ms, pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec draining?([option()]) :: boolean()
  def draining?(opts \\ []) do
    opts
    |> configured_server_name()
    |> call_if_started(:draining?, false)
  end

  @spec start_drain([option()]) :: summary()
  def start_drain(opts \\ []) do
    timeout_ms = timeout_ms(opts)
    call_drain(opts, {:start_drain, timeout_ms}, timeout_ms)
  end

  @spec drain_for_shutdown() :: summary()
  def drain_for_shutdown do
    timeout_ms = configured_timeout_ms()
    call_drain([], {:drain_for_shutdown, timeout_ms}, timeout_ms)
  end

  @spec configured_timeout_ms() :: pos_integer()
  def configured_timeout_ms do
    "CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS"
    |> System.get_env()
    |> parse_timeout_ms()
  end

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       draining?: false,
       active_drain: nil,
       shutdown_started_at_ms: nil,
       shutdown_timeout_ms: nil
     }}
  end

  @impl GenServer
  def handle_call(:draining?, _from, state) do
    {:reply, state.draining?, state}
  end

  def handle_call({:start_drain, _timeout_ms}, from, %{active_drain: active_drain} = state)
      when is_map(active_drain) do
    active_drain = %{active_drain | waiters: [from | active_drain.waiters]}
    {:noreply, %{state | active_drain: active_drain}}
  end

  def handle_call({:start_drain, timeout_ms}, from, state) do
    start_owner_drain(timeout_ms, from, state, false)
  end

  def handle_call(
        {:drain_for_shutdown, timeout_ms},
        from,
        %{active_drain: active_drain} = state
      )
      when is_map(active_drain) do
    active_drain = %{active_drain | waiters: [from | active_drain.waiters]}

    {:noreply,
     state
     |> ensure_shutdown_budget_started(timeout_ms)
     |> Map.put(:active_drain, active_drain)}
  end

  def handle_call({:drain_for_shutdown, timeout_ms}, from, state) do
    case shutdown_timeout_budget(state) do
      :not_started ->
        start_owner_drain(timeout_ms, from, state, true)

      {:remaining, remaining_timeout_ms} ->
        start_owner_drain(remaining_timeout_ms, from, state, true)

      :exhausted ->
        summary = empty_summary(:ok, state.shutdown_timeout_ms, true)
        log_drain_finished(summary)
        {:reply, summary, state}
    end
  end

  @impl GenServer
  def handle_info({:rollout_drain_finished, ref, summary}, %{active_drain: %{ref: ref}} = state) do
    Enum.each(state.active_drain.waiters, &GenServer.reply(&1, summary))
    {:noreply, %{state | active_drain: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec drain_local_owners(pos_integer(), boolean()) :: summary()
  defp drain_local_owners(timeout_ms, already_draining?) do
    started_at = System.monotonic_time(:millisecond)
    owners = local_owner_sessions()

    {owners_drained, owners_failed} =
      owners
      |> Task.async_stream(
        fn {_key, owner} -> drain_owner(owner) end,
        max_concurrency: max(1, length(owners)),
        on_timeout: :kill_task,
        ordered: false,
        timeout: timeout_ms
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, :ok}, {drained, failed} -> {drained + 1, failed}
        _result, {drained, failed} -> {drained, failed + 1}
      end)

    elapsed_ms = max(0, System.monotonic_time(:millisecond) - started_at)
    owners_seen = length(owners)

    %{
      result: drain_result(owners_failed),
      owners_seen: owners_seen,
      owners_drained: owners_drained,
      owners_failed: owners_failed,
      timeout_ms: timeout_ms,
      elapsed_ms: elapsed_ms,
      already_draining?: already_draining?
    }
  end

  defp local_owner_sessions do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_key, owner} -> is_pid(owner) and Process.alive?(owner) end)
  end

  defp drain_owner(owner) do
    WebsocketOwnerSession.drain_owner(owner)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp drain_result(0), do: :ok
  defp drain_result(_owners_failed), do: :error

  defp call_drain(opts, request, timeout_ms) do
    call_timeout = timeout_ms + 1_000

    case GenServer.whereis(configured_server_name(opts)) do
      nil ->
        summary = empty_summary(:error, timeout_ms, false)
        log_drain_finished(summary)
        summary

      server ->
        GenServer.call(server, request, call_timeout)
    end
  end

  defp start_owner_drain(timeout_ms, from, state, shutdown?) do
    already_draining? = state.draining?
    ref = make_ref()
    caller = self()

    log_drain_started(timeout_ms, already_draining?)

    {:ok, _pid} =
      Task.start(fn ->
        summary = drain_local_owners(timeout_ms, already_draining?)
        log_drain_finished(summary)
        send(caller, {:rollout_drain_finished, ref, summary})
      end)

    active_drain = %{ref: ref, waiters: [from]}

    state =
      state
      |> ensure_shutdown_budget_started(timeout_ms, shutdown?)
      |> Map.merge(%{draining?: true, active_drain: active_drain})

    {:noreply, state}
  end

  defp ensure_shutdown_budget_started(state, timeout_ms, true) do
    ensure_shutdown_budget_started(state, timeout_ms)
  end

  defp ensure_shutdown_budget_started(state, _timeout_ms, false), do: state

  defp ensure_shutdown_budget_started(%{shutdown_started_at_ms: nil} = state, timeout_ms) do
    %{
      state
      | shutdown_started_at_ms: System.monotonic_time(:millisecond),
        shutdown_timeout_ms: timeout_ms
    }
  end

  defp ensure_shutdown_budget_started(state, _timeout_ms), do: state

  defp shutdown_timeout_budget(%{shutdown_started_at_ms: nil}), do: :not_started

  defp shutdown_timeout_budget(state) do
    elapsed_ms = max(0, System.monotonic_time(:millisecond) - state.shutdown_started_at_ms)
    remaining_timeout_ms = max(0, state.shutdown_timeout_ms - elapsed_ms)

    if remaining_timeout_ms > 0 do
      {:remaining, remaining_timeout_ms}
    else
      :exhausted
    end
  end

  defp call_if_started(server_name, request, fallback) do
    case GenServer.whereis(server_name) do
      nil -> fallback
      server -> GenServer.call(server, request)
    end
  end

  defp configured_server_name(opts) do
    Keyword.get(opts, :name) ||
      :codex_pooler
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:server_name, __MODULE__)
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, configured_timeout_ms()) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _invalid -> @default_timeout_ms
    end
  end

  defp parse_timeout_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {timeout_ms, ""} when timeout_ms > 0 -> timeout_ms
      _invalid -> @default_timeout_ms
    end
  end

  defp parse_timeout_ms(_value), do: @default_timeout_ms

  defp log_drain_started(timeout_ms, already_draining?) do
    Logger.info(
      "websocket rollout drain started " <>
        "timeout_ms=#{timeout_ms} already_draining=#{already_draining?}"
    )
  end

  defp log_drain_finished(summary) do
    Logger.info(
      "websocket rollout drain finished " <>
        "owners_seen=#{summary.owners_seen} " <>
        "owners_drained=#{summary.owners_drained} " <>
        "owners_failed=#{summary.owners_failed} " <>
        "timeout_ms=#{summary.timeout_ms} " <>
        "elapsed_ms=#{summary.elapsed_ms} " <>
        "result=#{summary.result}"
    )
  end

  defp empty_summary(result, timeout_ms, already_draining?) do
    %{
      result: result,
      owners_seen: 0,
      owners_drained: 0,
      owners_failed: 0,
      timeout_ms: timeout_ms,
      elapsed_ms: 0,
      already_draining?: already_draining?
    }
  end
end
