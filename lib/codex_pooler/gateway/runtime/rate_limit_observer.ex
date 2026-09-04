defmodule CodexPooler.Gateway.Runtime.RateLimitObserver do
  @moduledoc """
  Records upstream Codex rate-limit evidence observed while proxying requests.
  """

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @max_event_buffer_bytes 16_384
  @max_pending_events 32
  @quota_scope_fields ~w(metered_limit_name metered_feature limit_id limit_name model model_id model_identifier)
  @rate_limit_marker "codex.rate_limits"
  @event_supervisor CodexPooler.RateLimitEventSupervisor

  @type observer_result :: :ok
  @type observer_metadata :: keyword()
  @type event_state :: %{
          required(:buffer) => binary(),
          required(:skip_leading_lf?) => boolean(),
          optional(:pending_events) => [map()]
        }
  @type generation_authority :: %{
          required(:request_id) => Ecto.UUID.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:replay_generation) => non_neg_integer()
        }

  @spec record_headers(UpstreamIdentity.t(), Req.Response.t()) :: observer_result()
  def record_headers(%UpstreamIdentity{} = identity, response) do
    record_header_evidence(identity, response.headers, "rate_limit_headers", "runtime_headers")
  end

  @spec record_websocket_upgrade_headers(UpstreamIdentity.t() | term(), term()) ::
          observer_result()
  def record_websocket_upgrade_headers(%UpstreamIdentity{} = identity, headers) do
    record_header_evidence(
      identity,
      headers,
      "rate_limit_websocket_upgrade_headers",
      "runtime_websocket_upgrade_headers"
    )
  end

  def record_websocket_upgrade_headers(_identity, _headers), do: :ok

  defp record_header_evidence(%UpstreamIdentity{} = identity, headers, operation, source) do
    case QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers) do
      {:ok, windows} ->
        maybe_converge_saved_reset(identity, windows, source)

      {:error, reason} ->
        log_failure(operation, identity_metadata(identity), reason)
    end
  end

  @spec record_websocket_frame_headers(UpstreamIdentity.t() | term(), map() | term()) ::
          observer_result()
  def record_websocket_frame_headers(%UpstreamIdentity{} = identity, headers)
      when is_map(headers) and map_size(headers) > 0 do
    case QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers) do
      {:ok, windows} ->
        maybe_converge_saved_reset(identity, windows, "runtime_websocket_frame_headers")

      {:error, reason} ->
        log_failure("rate_limit_websocket_frame_headers", identity_metadata(identity), reason)
    end
  end

  def record_websocket_frame_headers(_identity, _headers), do: :ok

  @spec event_state() :: event_state()
  def event_state, do: StreamProtocol.new_sse_block_state()

  @spec record_complete_events(UpstreamIdentity.t() | term(), binary() | term()) ::
          observer_result()
  @spec record_complete_events(
          UpstreamIdentity.t() | term(),
          binary() | term(),
          generation_authority() | nil
        ) :: observer_result()
  def record_complete_events(identity, data, authority \\ nil) do
    with {:ok, state} <- collect_events(data, event_state()) do
      persist_events_async(identity, Map.get(state, :pending_events, []), authority)
    end

    :ok
  end

  @spec record_complete_event(
          UpstreamIdentity.t() | term(),
          map() | term(),
          generation_authority() | nil
        ) :: observer_result()
  def record_complete_event(identity, event, authority \\ nil)

  def record_complete_event(
        %UpstreamIdentity{} = identity,
        %{"type" => "codex.rate_limits"} = event,
        authority
      ) do
    persist_events_async(identity, [event], authority)
  end

  def record_complete_event(_identity, _event, _authority), do: :ok

  @spec record_events(UpstreamIdentity.t() | term(), binary() | term(), event_state()) ::
          {:ok, event_state()}
  def record_events(%UpstreamIdentity{} = identity, data, state) when is_binary(data) do
    with {:ok, state} <- collect_events(data, state) do
      persist_events_async(identity, Map.get(state, :pending_events, []), nil)
      {:ok, Map.delete(state, :pending_events)}
    end
  end

  def record_events(_identity, data, state), do: collect_events(data, state)

  @spec collect_events(binary() | term(), event_state()) :: {:ok, event_state()}
  def collect_events(data, state) when is_binary(data) do
    {events, state} = rate_limit_event_payloads(data, normalize_event_state(state))

    pending = Enum.reduce(events, Map.get(state, :pending_events, []), &retain_latest_event/2)
    {:ok, Map.put(state, :pending_events, pending)}
  end

  def collect_events(_data, state), do: {:ok, normalize_event_state(state)}

  @spec commit_events(UpstreamIdentity.t() | term(), event_state()) :: observer_result()
  @spec commit_events(
          UpstreamIdentity.t() | term(),
          event_state(),
          generation_authority() | nil
        ) :: observer_result()
  def commit_events(identity, state, authority \\ nil)

  def commit_events(%UpstreamIdentity{} = identity, state, authority) do
    persist_events(identity, Map.get(state, :pending_events, []), authority)
  end

  def commit_events(_identity, _state, _authority), do: :ok

  @spec clear_event_buffer(UpstreamIdentity.t()) :: observer_result()
  def clear_event_buffer(%UpstreamIdentity{}), do: :ok

  @spec record_error(UpstreamIdentity.t() | term(), binary() | term()) :: observer_result()
  def record_error(%UpstreamIdentity{} = identity, body) when is_binary(body) do
    persisted =
      body
      |> rate_limit_error_payloads()
      |> Enum.flat_map(fn payload ->
        case QuotaWindows.upsert_quota_windows_from_codex_rate_limit_error(
               identity,
               payload
             ) do
          {:ok, windows} ->
            windows

          {:error, reason} ->
            log_failure("rate_limit_error", identity_metadata(identity), reason)
            []
        end
      end)

    maybe_converge_saved_reset(identity, persisted, "runtime_error")
  end

  def record_error(_identity, _body), do: :ok

  @spec log_failure(String.t(), observer_metadata(), term()) :: observer_result()
  def log_failure(operation, metadata, reason) do
    Logger.warning(
      "gateway observer failure",
      [operation: operation, reason: observer_failure_code(reason)] ++ metadata
    )

    :ok
  end

  defp persist_events_async(_identity, [], _authority), do: :ok

  defp persist_events_async(%UpstreamIdentity{} = identity, events, authority)
       when not is_nil(authority) do
    maybe_wait_for_test_persistence_barrier()
    persist_events(identity, events, authority)
  end

  defp persist_events_async(%UpstreamIdentity{} = identity, events, authority) do
    # Keep the async task input bounded. Saved-reset convergence reloads the
    # authoritative lifecycle under its database lock after evidence commits.
    identity_snapshot = %UpstreamIdentity{
      id: identity.id,
      status: identity.status,
      metadata: identity.metadata
    }

    case Task.Supervisor.start_child(@event_supervisor, fn ->
           maybe_wait_for_test_persistence_barrier()
           persist_events(identity_snapshot, events, authority)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        log_failure("rate_limit_event_task", identity_metadata(identity), reason)
    end
  catch
    :exit, reason ->
      log_failure("rate_limit_event_task", identity_metadata(identity), reason)
  end

  defp persist_events(%UpstreamIdentity{} = identity, events, nil) do
    Enum.each(events, &persist_event(identity, &1))
    :ok
  end

  defp persist_events(%UpstreamIdentity{} = identity, events, authority) do
    with {:ok, request, attempt} <- load_generation_authority(authority),
         {:ok, :ok} <-
           Accounting.with_current_replay_generation(request, attempt, fn ->
             maybe_wait_for_test_authority_barrier()
             Enum.each(events, &persist_event(identity, &1))
             :ok
           end) do
      :ok
    else
      _stale_or_invalid -> :ok
    end
  end

  defp load_generation_authority(%{
         request_id: request_id,
         attempt_id: attempt_id,
         replay_generation: generation
       })
       when is_binary(request_id) and is_binary(attempt_id) and is_integer(generation) and
              generation >= 0 do
    case {CodexPooler.Repo.get(Request, request_id), CodexPooler.Repo.get(Attempt, attempt_id)} do
      {%Request{} = request,
       %Attempt{request_id: ^request_id, replay_generation: ^generation} = attempt} ->
        {:ok, request, attempt}

      _missing_or_mismatched ->
        {:error, :invalid_authority}
    end
  end

  defp load_generation_authority(_authority), do: {:error, :invalid_authority}

  if Mix.env() == :test do
    defp maybe_wait_for_test_persistence_barrier do
      case Application.get_env(:codex_pooler, :rate_limit_persistence_test_barrier) do
        {test_pid, barrier_ref} when is_pid(test_pid) and is_reference(barrier_ref) ->
          send(test_pid, {:rate_limit_persistence_ready, self(), barrier_ref})

          receive do
            {:release_rate_limit_persistence, ^barrier_ref} -> :ok
          end

        _no_barrier ->
          :ok
      end
    end

    defp maybe_wait_for_test_authority_barrier do
      case Application.get_env(:codex_pooler, :rate_limit_authority_test_barrier) do
        {test_pid, barrier_ref} when is_pid(test_pid) and is_reference(barrier_ref) ->
          send(test_pid, {:rate_limit_authority_ready, self(), barrier_ref})

          receive do
            {:release_rate_limit_authority, ^barrier_ref} -> :ok
          end

        _no_barrier ->
          :ok
      end
    end
  else
    defp maybe_wait_for_test_persistence_barrier, do: :ok
    defp maybe_wait_for_test_authority_barrier, do: :ok
  end

  defp persist_event(%UpstreamIdentity{} = identity, event) do
    case QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
           identity,
           event
         ) do
      {:ok, windows} ->
        maybe_converge_saved_reset(identity, windows, "runtime_event")

      {:error, reason} ->
        log_failure("rate_limit_event", identity_metadata(identity), reason)
    end
  end

  defp maybe_converge_saved_reset(%UpstreamIdentity{} = identity, persisted_windows, source) do
    if persisted_account_evidence?(persisted_windows) do
      case Convergence.converge(identity, DateTime.utc_now(), source) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          log_failure("saved_reset_convergence", identity_metadata(identity), reason)
      end
    else
      :ok
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      log_failure("saved_reset_convergence", identity_metadata(identity), exception)
  end

  # Upsert results are always lists of persisted windows.
  defp persisted_account_evidence?(windows),
    do: Enum.any?(windows, &(&1.quota_key == "account"))

  defp normalize_event_state(%{
         buffer: buffer,
         skip_leading_lf?: skip_leading_lf?,
         pending_events: pending_events
       })
       when is_binary(buffer) and is_boolean(skip_leading_lf?) and is_list(pending_events),
       do: %{
         buffer: buffer,
         skip_leading_lf?: skip_leading_lf?,
         pending_events: pending_events
       }

  defp normalize_event_state(%{buffer: buffer, skip_leading_lf?: skip_leading_lf?})
       when is_binary(buffer) and is_boolean(skip_leading_lf?),
       do: %{buffer: buffer, skip_leading_lf?: skip_leading_lf?, pending_events: []}

  defp normalize_event_state(%{buffer: buffer}) when is_binary(buffer),
    do: %{buffer: buffer, skip_leading_lf?: false, pending_events: []}

  defp normalize_event_state(_state), do: event_state()

  defp rate_limit_error_payloads(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        [decoded, Map.get(decoded, "error")]
        |> Enum.filter(&is_map/1)

      _not_json ->
        []
    end
  end

  defp rate_limit_event_payloads(data, state) do
    scan = state.buffer <> data
    pending_events = Map.get(state, :pending_events, [])

    {complete_blocks, state} =
      StreamProtocol.complete_sse_blocks(state, data, bounded?: false)

    state = state |> Map.put(:pending_events, pending_events) |> bounded_event_state()

    # Compatibility stance: the provider emits the event type as the literal
    # `codex.rate_limits`, not as a JSON unicode escape. Scan retained+current
    # bytes together so a transport split inside the literal cannot hide it.
    if :binary.match(scan, @rate_limit_marker) != :nomatch do
      direct_events = data |> String.trim() |> rate_limit_events_from_json()
      events = direct_events ++ rate_limit_events_from_sse_blocks(complete_blocks)
      {events, state}
    else
      {[], state}
    end
  end

  defp bounded_event_state(%{buffer: buffer} = state)
       when byte_size(buffer) > @max_event_buffer_bytes,
       do: Map.merge(state, event_state())

  defp bounded_event_state(state), do: state

  # Keep the latest snapshot per provider scope, merging partial window updates.
  # Both the count and each transient parsed event are bounded independently.
  defp retain_latest_event(%{"rate_limits" => %{} = limits} = event, pending) do
    if :erlang.external_size(event) <= @max_event_buffer_bytes do
      limits = valid_event_windows(event, limits)
      retain_valid_event(Map.put(event, "rate_limits", limits), pending)
    else
      pending
    end
  end

  defp retain_latest_event(_event, pending), do: pending

  defp valid_event_windows(event, limits) do
    limits
    |> Map.take(["primary", "secondary"])
    |> Enum.filter(fn {kind, window} ->
      Evidence.parse_codex_rate_limit_event(Map.put(event, "rate_limits", %{kind => window})) !=
        []
    end)
    |> Map.new()
  end

  defp retain_valid_event(%{"rate_limits" => limits}, pending) when map_size(limits) == 0,
    do: pending

  defp retain_valid_event(event, pending) do
    scope = Map.take(event, @quota_scope_fields)
    {same, rest} = Enum.split_with(pending, &(Map.take(&1, @quota_scope_fields) == scope))

    merged =
      case same do
        [previous | _] ->
          Map.update!(event, "rate_limits", &Map.merge(previous["rate_limits"], &1))

        [] ->
          event
      end

    event = if :erlang.external_size(merged) <= @max_event_buffer_bytes, do: merged, else: event
    Enum.take(rest ++ [event], @max_pending_events * -1)
  end

  defp rate_limit_events_from_sse_blocks(blocks) do
    Enum.flat_map(blocks, fn block ->
      event_name = sse_field(block, "event")
      payload = sse_field(block, "data")

      case {event_name, payload} do
        {"codex.rate_limits", payload} when is_binary(payload) ->
          payload
          |> rate_limit_events_from_json()
          |> Enum.map(&Map.put_new(&1, "type", "codex.rate_limits"))

        {_event_name, payload} when is_binary(payload) ->
          rate_limit_events_from_json(payload)

        _other ->
          []
      end
    end)
  end

  defp sse_field(block, name) do
    prefix = name <> ": "

    block
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  defp rate_limit_events_from_json(payload) do
    case Jason.decode(payload, strings: :copy) do
      {:ok, %{"type" => "codex.rate_limits"} = event} -> [event]
      {:ok, _decoded} -> []
      {:error, _reason} -> []
    end
  end

  defp identity_metadata(%UpstreamIdentity{} = identity), do: [upstream_identity_id: identity.id]

  defp observer_failure_code(%Ecto.Changeset{}), do: "changeset_invalid"
  defp observer_failure_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp observer_failure_code(%{code: code}) when is_binary(code), do: code
  defp observer_failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp observer_failure_code(reason) when is_binary(reason), do: reason

  defp observer_failure_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp observer_failure_code({_reason, _details}), do: "tuple_error"
  defp observer_failure_code(_reason), do: "unknown_error"
end
