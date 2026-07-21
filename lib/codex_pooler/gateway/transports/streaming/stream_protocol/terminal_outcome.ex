defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.TerminalOutcome do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @terminal_event_types ["response.failed", "response.incomplete", "error"]
  @success_event_types ["response.completed", "response.done"]
  @downstream_visible_event_types @terminal_event_types ++
                                    ["response.created", "response.in_progress"]

  @type terminal_failure :: %{
          required(:code) => String.t(),
          required(:upstream_code) => String.t() | nil,
          required(:upstream_error_param) => String.t() | nil,
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil
        }
  @type terminal_outcome :: %{
          required(:kind) => atom(),
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil,
          optional(:failure) => terminal_failure(),
          optional(:incomplete_reason) => String.t() | nil
        }

  @spec first_complete_event(binary()) :: {:ok, map()} | :incomplete
  def first_complete_event(buffer) do
    case SSEParser.complete_sse_blocks(buffer, bounded?: false) do
      {[block | _rest], _remaining} ->
        {:ok, ErrorCanonicalization.event_summary_from_block(block)}

      {[], _remaining} ->
        ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(buffer)
    end
  end

  @spec terminal_outcome(binary()) :: {:ok, terminal_outcome()} | :error
  def terminal_outcome(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    blocks
    |> Enum.find_value(fn block ->
      {event_type, decoded} = SSEParser.stream_block_event(block)
      terminal_outcome(event_type, decoded)
    end)
    |> Kernel.||(direct_terminal_outcome(data))
  end

  @spec terminal_outcome_event(map()) :: {:ok, terminal_outcome()} | nil
  def terminal_outcome_event(%{event_type: "response.completed"} = event) do
    {:ok,
     %{
       kind: :completed,
       event_type: "response.completed",
       data_type: Map.get(event, :data_type)
     }}
  end

  def terminal_outcome_event(%{event_type: "response.incomplete"} = event) do
    if ErrorCanonicalization.incomplete_failure_event?(event) do
      failure = terminal_failure_from_event(event)

      {:ok,
       %{
         kind: :failed,
         event_type: "response.incomplete",
         data_type: Map.get(event, :data_type),
         incomplete_reason: Map.get(event, :incomplete_reason),
         failure: failure
       }}
    else
      {:ok,
       %{
         kind: :incomplete,
         event_type: "response.incomplete",
         data_type: Map.get(event, :data_type),
         incomplete_reason: Map.get(event, :incomplete_reason)
       }}
    end
  end

  def terminal_outcome_event(%{event_type: event_type} = event)
      when event_type in ["response.failed", "error"] do
    failure = terminal_failure_from_event(event)

    {:ok,
     %{
       kind: :failed,
       event_type: event_type,
       data_type: Map.get(event, :data_type),
       failure: failure
     }}
  end

  def terminal_outcome_event(_event), do: nil

  @spec terminal_failure(binary()) :: {:ok, terminal_failure()} | :error
  def terminal_failure(data) when is_binary(data) do
    case terminal_outcome(data) do
      {:ok, %{kind: :failed, failure: failure}} -> {:ok, failure}
      {:ok, _outcome} -> :error
      :error -> :error
    end
  end

  @spec terminal_outcome(String.t() | nil, map()) :: {:ok, terminal_outcome()} | nil
  def terminal_outcome(event_type, decoded) when is_map(decoded) do
    case structural_success_outcome(event_type, decoded) do
      {:ok, _outcome} = outcome ->
        outcome

      nil ->
        if not success_candidate?(event_type, decoded) and
             terminal_types_agree?(event_type, decoded) do
          (event_type || ErrorCanonicalization.decoded_string(decoded, "type"))
          |> ErrorCanonicalization.event_summary(decoded)
          |> terminal_outcome_event()
        end
    end
  end

  @spec terminal_failure_event(map()) :: {:ok, terminal_failure()} | nil
  def terminal_failure_event(event) do
    case terminal_outcome_event(event) do
      {:ok, %{kind: :failed, failure: failure}} -> {:ok, failure}
      _outcome -> nil
    end
  end

  @spec retryable_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def retryable_first_terminal_failure(event) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <- ErrorCanonicalization.retryable_first_event_code?(code),
         false <- ErrorCanonicalization.previous_response_miss_code?(failure.upstream_code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec retryable_first_terminal_failure(map(), boolean()) ::
          {:ok, terminal_failure()} | :error
  def retryable_first_terminal_failure(event, assignment_advertised?)
      when is_boolean(assignment_advertised?) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <-
           ErrorCanonicalization.retryable_first_event_code?(code) or
             ModelUnavailability.terminal_failure?(failure, assignment_advertised?),
         false <- ErrorCanonicalization.previous_response_miss_code?(failure.upstream_code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec auth_refresh_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def auth_refresh_first_terminal_failure(event) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <- ErrorCanonicalization.websocket_auth_refresh_event_code?(code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec internal_rate_limit_event?(term()) :: boolean()
  def internal_rate_limit_event?(%{} = event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    event_type == "codex.rate_limits" or data_type == "codex.rate_limits"
  end

  def internal_rate_limit_event?(data) when is_binary(data) do
    case ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> internal_rate_limit_event?(event)
      :incomplete -> false
    end
  end

  def internal_rate_limit_event?(_data), do: false

  @spec downstream_visible_event?(term()) :: boolean()
  def downstream_visible_event?(%{} = event) do
    not internal_rate_limit_event?(event) and visible_downstream_event?(event)
  end

  def downstream_visible_event?(data) when is_binary(data) do
    case ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> downstream_visible_event?(event)
      :incomplete -> false
    end
  end

  def downstream_visible_event?(_event), do: false

  @spec stream_data_visible?(term()) :: boolean()
  def stream_data_visible?(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    Enum.any?(blocks, fn block ->
      event_type = SSEParser.sse_field(block, "event")
      decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()
      data_type = ErrorCanonicalization.decoded_string(decoded, "type")
      downstream_visible_event?(%{event_type: event_type, data_type: data_type})
    end)
  end

  def stream_data_visible?(_data), do: false

  defp direct_terminal_outcome(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        terminal_outcome(nil, decoded) ||
          if(success_candidate?(nil, decoded),
            do: :error,
            else: direct_event_summary_outcome(data)
          )

      _other ->
        :error
    end
  end

  defp direct_event_summary_outcome(data) do
    case ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> terminal_outcome_event(event) || :error
      :incomplete -> :error
    end
  end

  defp structural_success_outcome(event_type, %{} = decoded) do
    data_type = Map.get(decoded, "type")

    cond do
      legacy_success?(event_type, decoded) ->
        {:ok, %{kind: :completed, event_type: nil, data_type: nil}}

      data_type in @success_event_types and success_types_agree?(event_type, data_type) and
          valid_success_response?(decoded) ->
        {:ok,
         %{
           kind: :completed,
           event_type: event_type || data_type,
           data_type: data_type
         }}

      true ->
        nil
    end
  end

  defp legacy_success?(nil, %{"id" => id} = decoded) when is_binary(id),
    do: not Map.has_key?(decoded, "type")

  defp legacy_success?(_event_type, _decoded), do: false

  defp success_types_agree?(nil, data_type), do: data_type in @success_event_types
  defp success_types_agree?(event_type, data_type), do: event_type == data_type

  defp success_candidate?(event_type, decoded) do
    event_type in @success_event_types or Map.get(decoded, "type") in @success_event_types
  end

  defp valid_success_response?(%{"response" => %{} = response}) do
    case Map.fetch(response, "status") do
      :error -> true
      {:ok, "completed"} -> true
      {:ok, _status} -> false
    end
  end

  defp valid_success_response?(_decoded), do: false

  defp terminal_types_agree?(event_type, decoded) do
    data_type = Map.get(decoded, "type")

    type_labels_agree?(event_type, data_type)
  end

  defp type_labels_agree?(event_type, data_type)
       when is_binary(event_type) and event_type != "" and is_binary(data_type) and
              data_type != "",
       do: event_type == data_type

  defp type_labels_agree?(_event_type, _data_type), do: true

  defp terminal_failure_from_event(event) do
    event_type = Map.get(event, :event_type)

    %{
      code: Map.get(event, :error_code) || event_type,
      upstream_code: Map.get(event, :upstream_error_code),
      upstream_error_param: Map.get(event, :upstream_error_param),
      event_type: event_type,
      data_type: Map.get(event, :data_type)
    }
  end

  defp visible_downstream_event?(event) do
    {event_type, data_type} = event_stream_types(event)

    visible_event_type?(event_type) or visible_event_type?(data_type)
  end

  defp event_stream_types(event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    {event_type, data_type}
  end

  defp visible_event_type?(type) when type in @downstream_visible_event_types, do: true

  defp visible_event_type?(type) when is_binary(type) do
    String.contains?(type, ".delta") or String.contains?(type, "output") or
      String.contains?(type, "message") or String.contains?(type, "tool")
  end

  defp visible_event_type?(_type), do: false
end
