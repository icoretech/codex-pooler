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
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
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
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
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
