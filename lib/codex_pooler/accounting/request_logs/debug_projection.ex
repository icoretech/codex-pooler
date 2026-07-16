defmodule CodexPooler.Accounting.RequestLogs.DebugProjection do
  @moduledoc false

  alias CodexPooler.Accounting.{Attempt, Request}

  alias CodexPooler.Accounting.RequestLogs.DebugProjection.{
    TransportFailure,
    UpstreamWebsocketConnection
  }

  alias CodexPooler.Gateway.Persistence.SessionReadModel

  @bounded_detail_attempts 10
  @upstream_error_param_max_bytes 160
  @upstream_error_param_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]{0,3})\])*\z/

  @type surface :: :default | :admin

  @spec build(
          Request.t(),
          map(),
          SessionReadModel.request_turn_row() | nil,
          [Attempt.t()],
          surface()
        ) ::
          map()
  def build(%Request{} = request, metadata, turn, attempts, surface) do
    attempts = Enum.sort_by(attempts, & &1.attempt_number)
    latest_attempt = List.last(attempts)
    continuity = continuity_projection(request, metadata, turn)

    %{
      continuity: continuity,
      failure: failure_projection(request, turn, latest_attempt),
      attempt: attempt_projection(latest_attempt, attempts),
      terminal_state: terminal_state_projection(request, turn, latest_attempt, continuity),
      turn: turn_projection(request, turn, attempts),
      attempts: detail_attempts(request, turn, attempts, surface)
    }
  end

  defp continuity_projection(request, metadata, turn) do
    {metadata_session_id, session_shape} = metadata_session_id(metadata)
    session_id = metadata_session_id || maybe_field(turn, :codex_session_id)
    turn_status = maybe_field(turn, :status)
    terminal = terminal_state(request, turn, latest_attempt: nil, session_shape: session_shape)

    %{
      status: continuity_status(terminal.state, session_shape, session_id, turn),
      session_ref: ref(:session, session_id),
      session_source: if(present?(session_id), do: "continuity"),
      turn_ref: ref(:turn, maybe_field(turn, :id)),
      turn_status: turn_status,
      turn_status_source: if(present?(turn_status), do: "turn_state"),
      has_open_turn: open_turn_state(turn_status),
      terminal_state: terminal.state,
      terminal_state_source: terminal.source
    }
  end

  defp continuity_status("mismatch", _session_shape, _session_id, _turn), do: "mismatch"
  defp continuity_status(_state, :malformed, _session_id, nil), do: "unknown"

  defp continuity_status(_state, _session_shape, session_id, turn) do
    if present?(session_id) or present?(maybe_field(turn, :id)) do
      "available"
    else
      "not_applicable"
    end
  end

  defp terminal_state_projection(request, turn, latest_attempt, continuity) do
    terminal =
      terminal_state(request, turn,
        latest_attempt: latest_attempt,
        session_shape: continuity_status_to_session_shape(continuity.status)
      )

    %{
      state: terminal.state,
      mismatch: terminal.state == "mismatch",
      sources: state_sources(request, turn, latest_attempt)
    }
  end

  defp terminal_state(request, turn, opts) do
    latest_attempt = Keyword.get(opts, :latest_attempt)
    session_shape = Keyword.get(opts, :session_shape, :missing)
    turn_status = maybe_field(turn, :status)
    request_status = request.status

    turn_terminal_state(request_status, turn_status) ||
      session_terminal_state(session_shape) ||
      request_terminal_state(request_status) ||
      attempt_terminal_state(latest_attempt) ||
      %{state: "unknown", source: nil}
  end

  defp turn_terminal_state(request_status, "in_progress") do
    if terminal_request_status?(request_status) do
      %{state: "mismatch", source: "turn_state"}
    else
      %{state: "in_progress", source: "turn_state"}
    end
  end

  defp turn_terminal_state(_request_status, turn_status) do
    if terminal_status?(turn_status), do: %{state: "terminal", source: "turn_state"}
  end

  defp session_terminal_state(:malformed), do: %{state: "unknown", source: nil}
  defp session_terminal_state(_session_shape), do: nil

  defp request_terminal_state("in_progress"), do: %{state: "in_progress", source: "request_state"}
  defp request_terminal_state("rejected"), do: %{state: "not_applicable", source: nil}

  defp request_terminal_state(request_status) do
    if terminal_request_status?(request_status), do: %{state: "terminal", source: "request_state"}
  end

  defp attempt_terminal_state(latest_attempt) do
    if terminal_status?(maybe_field(latest_attempt, :status)),
      do: %{state: "terminal", source: "attempt_state"}
  end

  defp continuity_status_to_session_shape("unknown"), do: :malformed
  defp continuity_status_to_session_shape(_status), do: :missing

  defp state_sources(request, turn, latest_attempt) do
    [
      %{source: "request_state", status: request.status, error_code: request.last_error_code},
      source_for_turn(turn),
      source_for_attempt(latest_attempt)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp source_for_turn(nil), do: nil

  defp source_for_turn(turn) do
    %{
      source: "turn_state",
      status: maybe_field(turn, :status),
      error_code: maybe_field(turn, :error_code)
    }
  end

  defp source_for_attempt(nil), do: nil

  defp source_for_attempt(attempt) do
    %{source: "attempt_state", status: attempt.status, error_code: attempt.network_error_code}
  end

  defp failure_projection(request, turn, latest_attempt) do
    cond do
      terminal_status?(maybe_field(turn, :status)) and present?(maybe_field(turn, :error_code)) ->
        %{error_code: maybe_field(turn, :error_code), error_source: "turn_error"}

      present?(request.last_error_code) ->
        %{error_code: request.last_error_code, error_source: "request_error"}

      present?(maybe_field(latest_attempt, :network_error_code)) ->
        %{error_code: latest_attempt.network_error_code, error_source: "attempt_error"}

      present?(maybe_field(turn, :error_code)) ->
        %{error_code: maybe_field(turn, :error_code), error_source: "turn_error"}

      true ->
        %{error_code: nil, error_source: nil}
    end
  end

  defp attempt_projection(latest_attempt, attempts) do
    %{
      latest_attempt_number: maybe_field(latest_attempt, :attempt_number),
      latest_attempt_status: maybe_field(latest_attempt, :status),
      latest_attempt_retryable: maybe_field(latest_attempt, :retryable),
      latest_upstream_status_code: maybe_field(latest_attempt, :upstream_status_code),
      attempt_count: length(attempts)
    }
  end

  defp turn_projection(_request, nil, _attempts) do
    %{
      turn_ref: nil,
      status: nil,
      error_code: nil,
      final_attempt_ref: nil,
      inserted_at: nil,
      updated_at: nil,
      completed_at: nil
    }
  end

  defp turn_projection(request, turn, attempts) do
    %{
      turn_ref: ref(:turn, maybe_field(turn, :id)),
      status: maybe_field(turn, :status),
      error_code: maybe_field(turn, :error_code),
      final_attempt_ref: final_attempt_ref(request, turn, attempts),
      inserted_at: iso8601(maybe_field(turn, :created_at)),
      updated_at: iso8601(maybe_field(turn, :updated_at)),
      completed_at: iso8601(maybe_field(turn, :completed_at))
    }
  end

  defp final_attempt_ref(request, turn, attempts) do
    attempts
    |> Enum.find(&(&1.id == maybe_field(turn, :final_attempt_id)))
    |> case do
      nil -> nil
      attempt -> attempt_ref(request.id, attempt.attempt_number)
    end
  end

  defp detail_attempts(request, turn, attempts, surface) do
    attempts
    |> Enum.sort_by(& &1.attempt_number, :desc)
    |> Enum.take(@bounded_detail_attempts)
    |> Enum.sort_by(& &1.attempt_number)
    |> Enum.map(&detail_attempt(request.id, turn, &1, surface))
  end

  defp detail_attempt(request_id, turn, attempt, surface) do
    %{
      attempt_ref: attempt_ref(request_id, attempt.attempt_number),
      attempt_number: attempt.attempt_number,
      status: attempt.status,
      retryable: attempt.retryable,
      pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
      upstream_status_code: attempt.upstream_status_code,
      network_error_code: attempt.network_error_code,
      latency_ms: attempt.latency_ms,
      final: maybe_field(turn, :final_attempt_id) == attempt.id
    }
    |> maybe_put_transport_failure(attempt)
    |> maybe_put_upstream_error_param(attempt)
    |> maybe_put_upstream_websocket_connection(attempt, surface)
  end

  defp maybe_put_upstream_websocket_connection(projection, %Attempt{} = attempt, :admin) do
    case UpstreamWebsocketConnection.build(attempt.response_metadata) do
      nil -> projection
      connection -> Map.put(projection, :upstream_websocket_connection, connection)
    end
  end

  defp maybe_put_upstream_websocket_connection(projection, _attempt, :default), do: projection

  defp maybe_put_transport_failure(projection, %Attempt{} = attempt) do
    case TransportFailure.build(attempt) do
      transport_failure when map_size(transport_failure) > 0 ->
        Map.put(projection, :transport_failure, transport_failure)

      _transport_failure ->
        projection
    end
  end

  defp maybe_put_upstream_error_param(projection, %Attempt{status: status} = attempt)
       when status in ["failed", "retryable_failed"] do
    case valid_upstream_error_param(attempt.response_metadata) do
      nil -> projection
      value -> Map.put(projection, :upstream_error_param, value)
    end
  end

  defp maybe_put_upstream_error_param(projection, _attempt), do: projection

  defp valid_upstream_error_param(%{"upstream_error_param" => value}) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..@upstream_error_param_max_bytes and
         Regex.match?(@upstream_error_param_pattern, value) do
      value
    end
  end

  defp valid_upstream_error_param(_metadata), do: nil

  defp metadata_session_id(metadata) when is_map(metadata) do
    case Map.fetch(metadata, "codex_session_id") do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {nil, :malformed}, else: {value, :valid}

      {:ok, nil} ->
        {nil, :missing}

      {:ok, _value} ->
        {nil, :malformed}

      :error ->
        {nil, :missing}
    end
  end

  defp ref(_kind, value) when not is_binary(value), do: nil
  defp ref(_kind, ""), do: nil
  defp ref(:session, value), do: "session_" <> short_hash("codex_session:" <> value)
  defp ref(:turn, value), do: "turn_" <> short_hash("codex_turn:" <> value)

  defp attempt_ref(request_id, attempt_number) do
    "attempt_" <> short_hash("request_attempt:#{request_id}:#{attempt_number}")
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp terminal_status?(status)
       when status in ["succeeded", "failed", "interrupted", "cancelled"],
       do: true

  defp terminal_status?(_status), do: false

  defp terminal_request_status?(status) when status in ["succeeded", "failed"], do: true
  defp terminal_request_status?(_status), do: false

  defp open_turn_state("in_progress"), do: true
  defp open_turn_state(status) when is_binary(status), do: false
  defp open_turn_state(_status), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  defp maybe_field(nil, _field), do: nil
  defp maybe_field(struct, field), do: Map.get(struct, field)
end
