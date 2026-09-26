defmodule CodexPooler.Gateway.Runtime.Streaming.ModelDeclarationObserver do
  @moduledoc false

  alias CodexPooler.Accounting.Metadata

  @lifecycle ~w(response.created response.queued response.in_progress response.completed response.failed response.incomplete response.cancelled)
  @terminal ~w(response.completed response.failed response.incomplete response.cancelled)

  defstruct first_model: nil,
            first_conflicting_model: nil,
            terminal_model: nil,
            terminal_status: nil,
            response_fingerprint: nil,
            conflict: nil,
            coverage: "full"

  @type t :: %__MODULE__{
          first_model: String.t() | nil,
          first_conflicting_model: String.t() | nil,
          terminal_model: String.t() | nil,
          terminal_status: String.t() | nil,
          response_fingerprint: binary() | nil,
          conflict: boolean() | nil,
          coverage: String.t()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec partial(t()) :: t()
  def partial(%{terminal_status: terminal} = state) when not is_nil(terminal), do: state
  def partial(state), do: %{state | coverage: "partial"}

  @spec observe(t(), term(), String.t() | nil) :: t()
  def observe(state, event, event_type \\ nil)
  def observe(%{terminal_status: terminal} = state, _event, _type) when not is_nil(terminal), do: state

  def observe(state, %{} = event, event_type) do
    type = if event_type == "chunk", do: event["type"], else: event_type || event["type"]

    if is_nil(type) or type in @lifecycle do
      response = response_envelope(event)
      fingerprint = response_fingerprint(response["id"])

      if state.response_fingerprint && fingerprint && state.response_fingerprint != fingerprint do
        partial(state)
      else
        state
        |> Map.put(:response_fingerprint, state.response_fingerprint || fingerprint)
        |> declare(Metadata.bounded_model_identifier(response["model"]))
        |> terminal(type, response)
      end
    else
      state
    end
  end

  def observe(state, _event, _type), do: partial(state)

  @spec json(term()) :: t()
  def json(%{} = decoded) do
    state = observe(new(), decoded)
    response = response_envelope(decoded)

    if is_nil(decoded["type"]) do
      %{state | terminal_model: state.first_model, terminal_status: json_status(response["status"])}
    else
      state
    end
  end

  def json(_decoded), do: partial(new())

  @spec put_usage(map(), t()) :: map()
  def put_usage(usage, %__MODULE__{} = state) do
    usage = Map.put(usage, :model_observation, evidence(state))

    case state.first_model do
      nil -> Map.delete(usage, :served_model)
      model -> Map.put(usage, :served_model, model)
    end
  end

  @spec evidence(t()) :: map()
  def evidence(state) do
    %{
      "version" => 1,
      "coverage" => state.coverage,
      "terminal_status" => state.terminal_status,
      "terminal_model" => state.terminal_model,
      "first_conflicting_model" => state.first_conflicting_model,
      "conflict" => state.conflict
    }
  end

  defp declare(state, nil), do: state
  defp declare(%{first_model: nil} = state, model), do: %{state | first_model: model, conflict: false}

  defp declare(state, model) do
    if String.downcase(state.first_model) == String.downcase(model) do
      state
    else
      %{state | conflict: true, first_conflicting_model: state.first_conflicting_model || model}
    end
  end

  defp terminal(state, type, response) when type in @terminal do
    %{state | terminal_status: String.replace_prefix(type, "response.", ""), terminal_model: Metadata.bounded_model_identifier(response["model"])}
  end

  defp terminal(state, _type, _response), do: state

  defp response_fingerprint(id) when is_binary(id) and byte_size(id) > 0,
    do: :crypto.hash(:sha256, Metadata.bounded_model_identifier(id) || "")

  defp response_fingerprint(_id), do: nil

  defp response_envelope(%{"response" => %{} = response} = event) do
    if is_nil(Metadata.bounded_model_identifier(response["model"])), do: Map.put(response, "model", event["model"]), else: response
  end

  defp response_envelope(event), do: event

  defp json_status(status) when status in ~w(completed failed incomplete cancelled), do: status
  defp json_status(_status), do: "json"
end
