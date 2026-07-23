defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @terminal_success_event_types ["response.completed", "response.done"]
  @terminal_failure_event_types ["response.failed", "response.incomplete", "error"]
  @terminal_event_types @terminal_success_event_types ++ @terminal_failure_event_types

  defstruct terminal: nil,
            last_upstream_event_type: "none",
            last_upstream_event_class: "none",
            terminal_candidate?: false,
            terminal_candidate_type: nil,
            terminal_candidate_class: nil,
            terminal_candidate_rejection: nil

  @type t :: %__MODULE__{
          terminal: String.t() | nil,
          last_upstream_event_type: String.t(),
          last_upstream_event_class: String.t(),
          terminal_candidate?: boolean(),
          terminal_candidate_type: String.t() | nil,
          terminal_candidate_class: String.t() | nil,
          terminal_candidate_rejection: String.t() | nil
        }

  @spec classify(binary()) :: t()
  def classify(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        classify_decoded(decoded)

      {:ok, _decoded} ->
        %__MODULE__{
          last_upstream_event_type: "non_object_json",
          last_upstream_event_class: "invalid_frame"
        }

      {:error, _reason} ->
        %__MODULE__{
          last_upstream_event_type: "invalid_json",
          last_upstream_event_class: "invalid_frame"
        }
    end
  end

  defp classify_decoded(decoded) do
    outcome = StreamProtocol.terminal_outcome(nil, decoded)

    {terminal_candidate?, terminal_candidate_type, terminal_candidate_class,
     terminal_candidate_rejection} = terminal_candidate(decoded, outcome)

    %__MODULE__{
      terminal: terminal_type(outcome),
      last_upstream_event_type: last_upstream_event_type(decoded),
      last_upstream_event_class: last_upstream_event_class(decoded),
      terminal_candidate?: terminal_candidate?,
      terminal_candidate_type: terminal_candidate_type,
      terminal_candidate_class: terminal_candidate_class,
      terminal_candidate_rejection: terminal_candidate_rejection
    }
  end

  defp terminal_candidate(decoded, outcome) do
    type = Map.get(decoded, "type")

    cond do
      type in @terminal_success_event_types ->
        {true, type, "success", success_rejection(decoded, outcome)}

      type in @terminal_failure_event_types ->
        {true, type, "failure", parser_rejection(outcome)}

      not Map.has_key?(decoded, "type") and Map.has_key?(decoded, "id") ->
        {true, "legacy_response", "legacy_success", legacy_rejection(decoded, outcome)}

      true ->
        {false, nil, nil, nil}
    end
  end

  defp success_rejection(_decoded, {:ok, _outcome}), do: nil

  defp success_rejection(decoded, _outcome) do
    case Map.get(decoded, "response") do
      %{} = response ->
        if Map.has_key?(response, "status") and Map.get(response, "status") != "completed" do
          "invalid_response_status"
        else
          "parser_rejected"
        end

      _response ->
        "missing_response_object"
    end
  end

  defp legacy_rejection(_decoded, {:ok, _outcome}), do: nil

  defp legacy_rejection(decoded, _outcome) do
    if is_binary(Map.get(decoded, "id")), do: "parser_rejected", else: "invalid_legacy_id"
  end

  defp parser_rejection({:ok, _outcome}), do: nil
  defp parser_rejection(_outcome), do: "parser_rejected"

  defp terminal_type({:ok, %{kind: :completed}}), do: "response.completed"

  defp terminal_type({:ok, %{event_type: type}}) when type in @terminal_failure_event_types,
    do: type

  defp terminal_type(_outcome), do: nil

  defp last_upstream_event_type(decoded) do
    case Map.fetch(decoded, "type") do
      {:ok, type} -> bounded_event_type(type)
      :error -> "missing_type"
    end
  end

  defp bounded_event_type(type) when type in @terminal_event_types, do: type

  defp bounded_event_type(type) when type in ["response.created", "response.in_progress"],
    do: type

  defp bounded_event_type("codex.rate_limits"), do: "codex.rate_limits"

  defp bounded_event_type(type) when is_binary(type) do
    cond do
      String.starts_with?(type, "response.") -> "response.other"
      String.starts_with?(type, "codex.") -> "codex.other"
      true -> "other"
    end
  end

  defp bounded_event_type(_type), do: "invalid_type"

  defp last_upstream_event_class(decoded) do
    case Map.fetch(decoded, "type") do
      {:ok, type} when type in @terminal_success_event_types ->
        "terminal_success_candidate"

      {:ok, type} when type in @terminal_failure_event_types ->
        "terminal_failure_candidate"

      {:ok, type} when type in ["response.created", "response.in_progress"] ->
        "response_lifecycle"

      {:ok, "codex.rate_limits"} ->
        "rate_limit_event"

      {:ok, type} when is_binary(type) ->
        bounded_event_class(type)

      {:ok, _type} ->
        "invalid_frame"

      :error ->
        if Map.has_key?(decoded, "id"), do: "legacy_success_candidate", else: "untyped_event"
    end
  end

  defp bounded_event_class(type) do
    cond do
      String.starts_with?(type, "response.") -> "response_event"
      String.starts_with?(type, "codex.") -> "codex_event"
      true -> "other_event"
    end
  end
end
