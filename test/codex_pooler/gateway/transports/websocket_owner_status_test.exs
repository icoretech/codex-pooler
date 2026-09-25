defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerStatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  @timeout 15_000

  test "OTP status omits lease credentials, retained results and event history" do
    marker = "synthetic-owner-private-#{System.unique_integer([:positive])}"
    owner = start_owner(marker)

    :sys.replace_state(owner, fn state ->
      %{state | ordinary_success_result: %{body: marker}, first_compact_result: %{body: marker}}
    end)

    :sys.log(owner, true)
    send(owner, {:unknown_private_message, marker})
    _synced = :sys.get_state(owner)
    status = :sys.get_status(owner)

    # :sys.get_status also returns its privileged raw debug accumulator outside
    # the callback's formatted status; only the formatted data goes to Logger.
    disclosed? = String.contains?(inspect(formatted_status(status), limit: :infinity), marker)
    refute disclosed?
    assert status_state(status).active_turn? == false
    assert status_state(status).downstream_attached? == false
    assert status_state(status).upstream_alive? == true
  end

  test "real owner crash report omits last message, exception details and retained state" do
    marker = "synthetic-owner-private-#{System.unique_integer([:positive])}"
    parent = self()
    error = DBConnection.ConnectionError.exception(marker)

    # The real owner handles the frame and crashes inside its delivery callback.
    # The callback raises the observed exception class without needing a DB outage.
    owner = start_owner(marker, downstream_sender: fn _pid, _message -> raise error end)
    ref = make_ref()
    downstream = %{pid: parent, correlation_id: "synthetic-request", epoch: 1}

    :sys.replace_state(owner, fn state ->
      %{state | downstream: downstream, active_turn: %{ref: ref, collect?: false, terminal_forwarded?: false, visible_output?: true, downstream: downstream, task: nil, task_ref: nil}, first_compact_result: %{body: marker}}
    end)

    monitor = Process.monitor(owner)
    :sys.log(owner, true)

    log =
      capture_log(fn ->
        send(owner, {:websocket_owner_upstream_frame, ref, marker})
        assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, @timeout
        Elixir.Logger.flush()
      end)

    assert log =~ "terminating"
    assert log =~ "DBConnection.ConnectionError"
    disclosed? = String.contains?(log, marker)
    refute disclosed?
  end

  test "formatter scrubs every owner message carrier and nested exception without crashing" do
    marker = "synthetic-private-status"
    state = %WebsocketOwnerSession{owner_lease_token: marker}

    for {message, expected} <- [
          {{:websocket_owner_upstream_frame, make_ref(), marker}, :upstream_frame},
          {{:websocket_owner_upstream_frame, make_ref(), marker, %{terminal: marker}}, :upstream_frame},
          {{make_ref(), {:ok, %{body: marker}}}, :task_result},
          {{:"$gen_call", {self(), make_ref()}, {:submit_request, marker}}, :call},
          {{:"$gen_cast", {:send, marker}}, :cast},
          {{:DOWN, make_ref(), :process, self(), marker}, :process_down},
          {{:EXIT, self(), marker}, :process_exit},
          {:renew_owner_lease, :renew_owner_lease},
          {:idle_shutdown, :idle_shutdown},
          {{:unknown_message, marker}, :owner_message}
        ] do
      formatted =
        WebsocketOwnerSession.format_status(%{
          state: state,
          message: message,
          reason: {DBConnection.ConnectionError.exception(marker), [{__MODULE__, :probe, [marker], []}]},
          log: [{:in, message}],
          future_field: marker
        })

      assert formatted.message == expected
      assert formatted.reason == {:exception, DBConnection.ConnectionError}
      assert formatted.log == []
      assert formatted.future_field == :redacted
      assert formatted.state.admission_phase == :cleared
      disclosed? = String.contains?(inspect(formatted), marker)
      refute disclosed?
    end

    assert %{state: :unavailable, reason: :unknown} = WebsocketOwnerSession.format_status(%{state: marker, reason: marker})
    assert %{reason: :shutdown} = WebsocketOwnerSession.format_status(%{reason: {:shutdown, marker}})
    assert %{reason: :owner_crashed} = WebsocketOwnerSession.format_status(%{reason: :owner_crashed})
  end

  defp start_owner(marker, opts \\ []) do
    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    start_supervised!(%{
      id: {WebsocketOwnerSession, make_ref()},
      restart: :temporary,
      start:
        {WebsocketOwnerSession, :start_link,
         [
           [
             codex_session_id: "synthetic-session-#{System.unique_integer([:positive])}",
             owner_lease_token: marker,
             owner_instance_id: Atom.to_string(node()),
             owner_renewal_ms: 60_000,
             upstream: upstream
           ] ++ opts
         ]}
    })
  end

  defp status_state({:status, _pid, {:module, :gen_server}, [_dictionary, _running, _parent, _debug, status]}) do
    status
    |> Keyword.get_values(:data)
    |> Enum.flat_map(& &1)
    |> Enum.find_value(fn
      {~c"State", state} -> state
      _other -> nil
    end)
  end

  defp formatted_status({:status, _pid, {:module, :gen_server}, [_dictionary, _running, _parent, _debug, status]}), do: status
end
