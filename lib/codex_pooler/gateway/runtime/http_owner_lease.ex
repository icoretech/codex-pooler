defmodule CodexPooler.Gateway.Runtime.HttpOwnerLease do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}

  # HTTP dispatch returns a deferred stream. Keep one heartbeat across both
  # phases, including time spent waiting for headers or for the first event.
  def run(%RequestOptions{transport: %{transport: "websocket"}}, callback), do: callback.()

  def run(
        %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} = opts,
        callback
      ) do
    case SessionContinuity.renew_owner_token(session, session.owner_lease_token, opts) do
      {:ok, _session} ->
        owner = self()
        interval = heartbeat_interval(opts)
        lease = {session.id, session.owner_lease_token}

        # The renewal process needs no request body, authorization or routing data.
        lease_opts =
          RequestOptions.build(
            %{bridge_owner_lease_ttl_seconds: opts.continuity.bridge_owner_lease_ttl_seconds},
            opts.transport.upstream_endpoint,
            %{}
          )

        {:ok, heartbeat} =
          Task.start_link(fn -> heartbeat(owner, lease, lease_opts, interval) end)

        try do
          case callback.() do
            {:ok, %{stream: stream} = result} when is_function(stream, 1) ->
              send(heartbeat, :await_stream)

              {:ok,
               Map.put(result, :stream, fn conn ->
                 # Preserve native delivery of an already-dispatched response even
                 # after owner loss. The original token still fences persistence;
                 # this message cannot restart an expired or stopped heartbeat.
                 send(heartbeat, :streaming)

                 try do
                   stream.(conn)
                 after
                   stop(heartbeat)
                 end
               end)}

            result ->
              stop(heartbeat)
              result
          end
        catch
          kind, reason ->
            stop(heartbeat)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        {:error,
         %{
           status: 409,
           code: Atom.to_string(reason),
           message: "HTTP session owner lease is unavailable",
           param: nil
         }}
    end
  end

  def run(%RequestOptions{}, callback), do: callback.()

  defp heartbeat(owner, session, opts, interval) do
    monitor = Process.monitor(owner)
    heartbeat_loop(owner, monitor, session, opts, interval, nil)
  end

  defp heartbeat_loop(owner, monitor, session, opts, interval, handoff_deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok

      :await_stream ->
        deadline = System.monotonic_time(:millisecond) + interval * 3
        heartbeat_loop(owner, monitor, session, opts, interval, deadline)

      :streaming ->
        heartbeat_loop(owner, monitor, session, opts, interval, nil)
    after
      interval ->
        handoff_expired? =
          is_integer(handoff_deadline) and
            System.monotonic_time(:millisecond) >= handoff_deadline

        if Process.alive?(owner) and not handoff_expired? do
          case renew(session, opts) do
            {:ok, _session} ->
              heartbeat_loop(owner, monitor, session, opts, interval, handoff_deadline)

            {:error, _reason} ->
              :ok
          end
        end
    end
  end

  # A database failure ends renewal. In particular, never reload a replacement
  # token or retry an expired lease. Completion still uses its admission fence.
  defp renew({session_id, owner_lease_token}, opts) do
    SessionContinuity.renew_owner_token(session_id, owner_lease_token, opts)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :owner_unavailable}
  end

  defp stop(heartbeat) do
    monitor = Process.monitor(heartbeat)
    Process.unlink(heartbeat)
    Process.exit(heartbeat, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^heartbeat, _reason} -> :ok
    end
  end

  defp heartbeat_interval(opts) do
    ttl =
      opts.continuity.bridge_owner_lease_ttl_seconds ||
        OperationalSettings.current().bridge_owner_lease_ttl_seconds

    max(div(ttl * 1_000, 3), 1)
  end
end
