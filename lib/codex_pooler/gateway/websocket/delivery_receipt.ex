defmodule CodexPooler.Gateway.Websocket.DeliveryReceipt do
  @moduledoc false

  # Bounded, metadata-only evidence that the socket pushed (or decided not to
  # push) a turn's terminal frame to the downstream WebSock. The receipt is
  # merged into `attempts.response_metadata["downstream_delivery"]` after the
  # gateway finalized the attempt, so a completed request whose client never saw
  # `response.completed` can be told apart from a push that never happened.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Repo

  @metadata_key "downstream_delivery"
  @outcomes ~w(delivered completed aborted skipped)
  @terminal_classes ~w(response.completed response.failed response.incomplete error)
  @transports ~w(websocket http_sse)
  @default_transport "websocket"
  @unknown "unknown"
  @none "none"
  @persist_timeout_ms 5_000

  @type outcome :: String.t()
  @type terminal_class :: String.t() | nil
  @type receipt :: %{
          required(String.t()) => String.t() | non_neg_integer() | nil
        }
  @type context :: %{
          required(:request_id) => term(),
          optional(:attempt_id) => Ecto.UUID.t() | nil,
          optional(:codex_session_id) => term()
        }

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  Builds the persisted receipt from socket-side evidence.

  Every value is coerced onto a fixed vocabulary; nothing from the wire is
  copied through.
  """
  @spec build(map()) :: receipt()
  def build(fields) when is_map(fields) do
    %{
      "outcome" => vocabulary(Map.get(fields, :outcome), @outcomes, @unknown),
      "terminal_class" => terminal_class_value(Map.get(fields, :terminal_class)),
      "pushed_at" => iso8601(Map.get(fields, :pushed_at)),
      "frames_after_visible" => frame_count(Map.get(fields, :frames_after_visible)),
      "transport" => vocabulary(Map.get(fields, :transport), @transports, @default_transport)
    }
  end

  @doc """
  Classifies a downstream frame as a terminal of the fixed vocabulary, or `nil`
  when the frame is not a provider terminal.
  """
  @spec terminal_class(binary() | term()) :: terminal_class()
  def terminal_class(data) when is_binary(data) do
    case StreamProtocol.terminal_outcome(data) do
      {:ok, outcome} -> terminal_class_from_outcome(outcome)
      _other -> nil
    end
  end

  def terminal_class(_data), do: nil

  @spec terminal_class_from_outcome(map()) :: terminal_class()
  def terminal_class_from_outcome(%{kind: :completed}), do: "response.completed"
  def terminal_class_from_outcome(%{kind: :incomplete}), do: "response.incomplete"

  def terminal_class_from_outcome(%{kind: :failed} = outcome) do
    case Map.get(outcome, :event_type) do
      event_type when event_type in @terminal_classes -> event_type
      _other -> "response.failed"
    end
  end

  def terminal_class_from_outcome(_outcome), do: nil

  @doc """
  Logs the single info receipt line and merges the receipt into the attempt
  row when an attempt id is known. Never raises: a persistence failure is
  reported as one bounded warning so the socket lifecycle stays unaffected.
  """
  @spec record(context(), receipt()) :: :ok
  def record(context, receipt) when is_map(context) and is_map(receipt) do
    request_id = DiagnosticTaxonomy.safe_correlator(Map.get(context, :request_id))
    session_id = DiagnosticTaxonomy.safe_correlator(Map.get(context, :codex_session_id))

    Logger.info(
      "websocket downstream terminal pushed " <>
        "request_id=#{request_id} " <>
        "codex_session_id=#{session_id} " <>
        "outcome=#{receipt["outcome"]} " <>
        "terminal_class=#{receipt["terminal_class"]} " <>
        "frames_after_visible=#{receipt["frames_after_visible"]}"
    )

    case Map.get(context, :attempt_id) do
      attempt_id when is_binary(attempt_id) ->
        attempt_id
        |> persist(receipt)
        |> log_persist_failure(request_id, session_id)

      _missing ->
        :ok
    end
  end

  @doc """
  Merges the receipt under `#{@metadata_key}` with one bounded jsonb update,
  leaving every other attempt metadata key untouched.
  """
  @spec persist(Ecto.UUID.t(), receipt()) :: :ok | {:error, :attempt_not_found | term()}
  def persist(attempt_id, receipt) when is_binary(attempt_id) and is_map(receipt) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, _uuid} -> persist_receipt(attempt_id, receipt)
      :error -> {:error, :attempt_not_found}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp persist_receipt(attempt_id, receipt) do
    patch = %{@metadata_key => receipt}

    query =
      from a in Attempt,
        where: a.id == ^attempt_id,
        update: [
          set: [
            response_metadata:
              fragment("COALESCE(?, '{}'::jsonb) || ?", a.response_metadata, type(^patch, :map))
          ]
        ]

    case Repo.update_all(query, [], timeout: @persist_timeout_ms) do
      {1, _returned} -> :ok
      {0, _returned} -> {:error, :attempt_not_found}
    end
  end

  defp log_persist_failure(:ok, _request_id, _session_id), do: :ok

  defp log_persist_failure({:error, reason}, request_id, session_id) do
    Logger.warning(
      "websocket downstream delivery receipt not persisted " <>
        "request_id=#{request_id} " <>
        "codex_session_id=#{session_id} " <>
        "reason=#{failure_reason(reason)}"
    )

    :ok
  end

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason({:exit, _reason}), do: "exit"
  defp failure_reason(%module{}), do: inspect(module)
  defp failure_reason(_reason), do: "unknown"

  defp terminal_class_value(nil), do: @none
  defp terminal_class_value(value), do: vocabulary(value, @terminal_classes, @unknown)

  defp vocabulary(value, allowed, fallback) when is_atom(value) and not is_nil(value),
    do: vocabulary(Atom.to_string(value), allowed, fallback)

  defp vocabulary(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp vocabulary(_value, _allowed, fallback), do: fallback

  defp iso8601(%DateTime{} = pushed_at) do
    pushed_at
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_pushed_at), do: nil

  defp frame_count(count) when is_integer(count) and count >= 0, do: count
  defp frame_count(_count), do: 0
end
