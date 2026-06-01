defmodule CodexPooler.Gateway.Transports.Streaming.StreamRelayTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay

  test "leaves unrelated mailbox messages observable while waiting for async response events" do
    parent = self()
    ref = make_ref()
    unrelated = {:unrelated_stream_message, make_ref()}
    response = async_response(ref)

    pid =
      spawn(fn ->
        send(self(), unrelated)
        send(self(), {ref, {:data, "hello"}})
        send(self(), {ref, :done})

        result = StreamRelay.run(:stream_state, response, handlers())

        preserved =
          receive do
            ^unrelated -> unrelated
          after
            0 -> :missing
          end

        send(parent, {:stream_relay_result, result, preserved})
      end)

    monitor = Process.monitor(pid)

    assert_receive {:stream_relay_result, {:ok, :stream_state}, ^unrelated}, 1_000
    assert_process_down(monitor, pid)
  end

  test "upstream timeout before any stream event finalizes without first-event retry" do
    parent = self()
    ref = make_ref()
    response = async_response(ref)
    timeout = %Req.TransportError{reason: :timeout}

    pid =
      spawn(fn ->
        send(self(), {ref, {:error, timeout}})

        result =
          StreamRelay.run(:stream_state, response, %{
            handlers()
            | first_event_retry: fn _state, _body, _failure ->
                send(parent, :unexpected_first_event_retry)
                {:error, :unexpected_first_event_retry}
              end
          })

        send(parent, {:stream_relay_result, result})
      end)

    monitor = Process.monitor(pid)

    assert_receive {:stream_relay_result, {:error, {:upstream_idle_timeout, ^timeout}}}, 1_000
    refute_received :unexpected_first_event_retry
    assert_process_down(monitor, pid)
  end

  test "success finalization keeps only a bounded retained body while writing all chunks" do
    parent = self()
    ref = make_ref()
    response = async_response(ref)
    chunk = String.duplicate("stream-relay-retained-body-sentinel", 2_048)
    chunks = List.duplicate(chunk, 4)
    full_body = Enum.join(chunks)

    pid =
      spawn(fn ->
        Enum.each(chunks, &send(self(), {ref, {:data, &1}}))
        send(self(), {ref, :done})

        result =
          StreamRelay.run(:stream_state, response, %{
            handlers()
            | write_chunk: fn state, data ->
                send(parent, {:stream_relay_chunk, data})
                {:ok, state}
              end,
              finalize_success: fn body ->
                send(parent, {:stream_relay_retained_body, body})
                {:ok, :finalized}
              end
          })

        send(parent, {:stream_relay_result, result})
      end)

    monitor = Process.monitor(pid)

    assert_receive {:stream_relay_result, {:ok, :stream_state}}, 1_000
    assert_receive {:stream_relay_retained_body, retained_body}, 1_000

    written_body =
      1..length(chunks)
      |> Enum.map_join(fn _index ->
        assert_receive {:stream_relay_chunk, data}, 1_000
        data
      end)

    assert written_body == full_body
    assert byte_size(retained_body) <= 65_536
    assert byte_size(retained_body) < byte_size(full_body)
    assert String.ends_with?(full_body, retained_body)
    assert_process_down(monitor, pid)
  end

  defp assert_process_down(monitor, pid) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  defp async_response(ref) do
    %Req.Response{
      body: %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &parse_async_message/2,
        cancel_fun: fn _ref -> :ok end
      }
    }
  end

  defp parse_async_message(ref, {ref, {:data, data}}), do: {:ok, data: data}
  defp parse_async_message(ref, {ref, :done}), do: {:ok, [:done]}
  defp parse_async_message(ref, {ref, {:error, reason}}), do: {:error, reason}
  defp parse_async_message(_ref, _message), do: :unknown

  defp handlers do
    %{
      write_chunk: fn state, _data -> {:ok, state} end,
      write_keepalive: fn state -> {:ok, state} end,
      finalize_success: fn _body -> {:ok, :finalized} end,
      finalize_failure: fn _body, reason -> {:error, reason} end,
      first_event_retry: fn state, _body, _failure -> {:retry, state} end
    }
  end
end
