defmodule CodexPooler.Gateway.Runtime.RateLimitObserver do
  @moduledoc """
  Records upstream Codex rate-limit evidence observed while proxying requests.
  """

  require Logger

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @max_event_buffer_bytes 16_384
  @event_supervisor CodexPooler.RateLimitEventSupervisor

  @type observer_result :: :ok
  @type observer_metadata :: keyword()
  @type event_state :: %{required(:buffer) => binary()}

  @spec record_headers(UpstreamIdentity.t(), Req.Response.t()) :: observer_result()
  def record_headers(%UpstreamIdentity{} = identity, response) do
    record_header_evidence(identity, response.headers, "rate_limit_headers")
  end

  @spec record_websocket_upgrade_headers(UpstreamIdentity.t() | term(), term()) ::
          observer_result()
  def record_websocket_upgrade_headers(%UpstreamIdentity{} = identity, headers) do
    record_header_evidence(identity, headers, "rate_limit_websocket_upgrade_headers")
  end

  def record_websocket_upgrade_headers(_identity, _headers), do: :ok

  defp record_header_evidence(%UpstreamIdentity{} = identity, headers, operation) do
    case QuotaWindows.upsert_quota_windows_from_codex_headers(identity, headers) do
      {:ok, windows} ->
        maybe_converge_saved_reset(identity, windows)

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
        maybe_converge_saved_reset(identity, windows)

      {:error, reason} ->
        log_failure("rate_limit_websocket_frame_headers", identity_metadata(identity), reason)
    end
  end

  def record_websocket_frame_headers(_identity, _headers), do: :ok

  @spec event_state() :: event_state()
  def event_state, do: %{buffer: ""}

  @spec record_complete_events(UpstreamIdentity.t() | term(), binary() | term()) ::
          observer_result()
  def record_complete_events(identity, data) do
    _ignored = record_events(identity, data, event_state())
    :ok
  end

  @spec record_events(UpstreamIdentity.t() | term(), binary() | term(), event_state()) ::
          {:ok, event_state()}
  def record_events(%UpstreamIdentity{} = identity, data, %{buffer: previous_buffer})
      when is_binary(data) and is_binary(previous_buffer) do
    {events, buffer} = rate_limit_event_payloads(data, previous_buffer)

    persist_events_async(identity, events)
    {:ok, %{buffer: buffer}}
  end

  def record_events(_identity, _data, state), do: {:ok, normalize_event_state(state)}

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

    maybe_converge_saved_reset(identity, persisted)
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

  defp persist_events_async(_identity, []), do: :ok

  defp persist_events_async(%UpstreamIdentity{} = identity, events) do
    # Metadata rides along so the async task can run the cheap saved-reset
    # convergence pre-filter without a reload.
    identity_snapshot = %UpstreamIdentity{
      id: identity.id,
      status: identity.status,
      metadata: identity.metadata
    }

    case Task.Supervisor.start_child(@event_supervisor, fn ->
           Enum.each(events, &persist_event(identity_snapshot, &1))
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

  defp persist_event(%UpstreamIdentity{} = identity, event) do
    case QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
           identity,
           event
         ) do
      {:ok, windows} ->
        maybe_converge_saved_reset(identity, windows)

      {:error, reason} ->
        log_failure("rate_limit_event", identity_metadata(identity), reason)
    end
  end

  # Runtime evidence is the transport-agnostic seam for probe outcomes: a
  # confirmed quota-exhaustion error or exhausted headers reblock a pending
  # saved-reset lifecycle immediately, and usable evidence confirms it, without
  # waiting for the next reconciliation pass. Two cheap pre-filters keep the
  # per-request hot path free of extra locking transactions: convergence runs
  # only when this write actually persisted account evidence, and only for the
  # short pre-confirmation phase — a probe-confirmed lifecycle settles to
  # quota-confirmed on the reconciliation cadence instead of per response.
  defp maybe_converge_saved_reset(%UpstreamIdentity{} = identity, persisted_windows) do
    if persisted_account_evidence?(persisted_windows) and awaiting_probe?(identity) do
      case Convergence.converge(identity) do
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

  defp awaiting_probe?(%UpstreamIdentity{metadata: metadata}) do
    RedemptionLifecycle.phase((metadata || %{})["saved_reset_redemption"]) ==
      RedemptionLifecycle.consumed_pending_probe()
  end

  defp normalize_event_state(%{buffer: buffer}) when is_binary(buffer), do: %{buffer: buffer}
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

  defp rate_limit_event_payloads(data, previous_buffer) do
    direct_events =
      data
      |> String.trim()
      |> rate_limit_events_from_json()

    {complete_blocks, buffer} = complete_sse_blocks(previous_buffer <> data)
    events = direct_events ++ rate_limit_events_from_sse_blocks(complete_blocks)
    {events, buffer}
  end

  defp complete_sse_blocks(data) do
    data = String.replace(data, "\r\n", "\n")

    if String.contains?(data, "\n\n") do
      parts = String.split(data, "\n\n")
      ends_with_separator? = String.ends_with?(data, "\n\n")

      {complete, buffer} =
        if ends_with_separator? do
          {parts, ""}
        else
          {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      {Enum.reject(complete, &(&1 == "")), bounded_incomplete_sse_block(buffer)}
    else
      {[], bounded_incomplete_sse_block(data)}
    end
  end

  defp bounded_incomplete_sse_block(buffer) when byte_size(buffer) > @max_event_buffer_bytes,
    do: ""

  defp bounded_incomplete_sse_block(buffer), do: buffer

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
    case Jason.decode(payload) do
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
