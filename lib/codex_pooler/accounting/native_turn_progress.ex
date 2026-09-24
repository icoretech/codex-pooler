defmodule CodexPooler.Accounting.NativeTurnProgress do
  @moduledoc false

  # The full-history progress digest a native Codex request recorded on its row
  # (`NativeTurnContinuation.turn_progress/1`): the latest compaction pivot and
  # the number of user messages after it, hashed. A native HTTP request records
  # it as `native_http_turn_progress` (findings#206 row 206-403); a websocket
  # request as `native_turn_progress` when its socket knew its history
  # (row 206-412). Both are the same digest, so a later request of a turn is
  # compared with the turn's opener whatever transport either used. Only the
  # digest is ever stored; a row without one (written before these releases, or
  # by a socket that could not know the history) answers `nil`, and its turn
  # keeps the bare claim.
  #
  # A different digest is not enough to call a request a later one (findings#206
  # row 206-423): a resend of the holder with trimmed history differs too. Rows
  # therefore also record the position (`NativeTurnContinuation.progress_position/1`:
  # the pivot's digest, absent when there is none, and the count of user
  # messages after it), and a request is re-keyed only when it is further along
  # than the holder (`advances?/2`). A holder recorded by the previous release
  # carries the digest alone and cannot be ordered, so it keeps the bare claim.

  import Ecto.Query

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Repo

  @native_http_transports ["http_json", "http_sse", "http_compact_json"]

  @doc "The progress digest a request row recorded, url-safe Base64 without padding, or `nil`."
  @spec recorded(Request.t() | nil) :: String.t() | nil
  def recorded(%Request{transport: transport, request_metadata: %{"native_http_turn_progress" => %{"version" => 1, "digest" => digest}}})
      when transport in @native_http_transports and is_binary(digest),
      do: digest

  def recorded(%Request{transport: "websocket", request_metadata: %{"native_turn_progress" => %{"version" => 1, "digest" => digest}}})
      when is_binary(digest),
      do: digest

  def recorded(_request), do: nil

  @typedoc "Where a request stands in its turn: the pivot's digest (or `nil`) and the user messages after it."
  @type position :: {<<_::256>> | nil, non_neg_integer()}

  @doc """
  The position a request row recorded beside its progress digest, or `nil` when
  it recorded none (no digest at all, or a row of the previous release that
  recorded the digest alone).
  """
  @spec recorded_position(Request.t() | nil) :: position() | nil
  def recorded_position(%Request{} = request) do
    with digest when is_binary(digest) <- recorded(request),
         %{"user_messages" => count} = recorded when is_integer(count) and count >= 0 <- recorded_map(request),
         {:ok, pivot} <- recorded_pivot(Map.get(recorded, "pivot")) do
      {pivot, count}
    else
      _unordered -> nil
    end
  end

  def recorded_position(nil), do: nil

  @doc "The position recorded by the row holding `claim`, or `nil`."
  @spec recorded_position_for_claim(String.t()) :: position() | nil
  def recorded_position_for_claim(claim) when is_binary(claim) do
    Repo.one(
      from request in Request,
        where: request.correlation_id == ^claim,
        select: %Request{transport: request.transport, request_metadata: request.request_metadata}
    )
    |> recorded_position()
  end

  @doc """
  True when a request at `position` is further along its turn than the holder
  of the turn's bare claim, which recorded `recorded`: the same compaction
  point (or none) and strictly more user messages after it (the user steered
  input in), or a compaction point the holder did not end on (a remote
  compaction replaced the history, keeping only messages and appending its
  item last). A retry of the holder only appends model output, so it stands
  where the holder stood; a resend with trimmed history stands behind it. Both
  answer false, and so does a holder that recorded no position.
  """
  @spec advances?(position() | nil, position() | nil) :: boolean()
  def advances?({pivot, held}, {pivot, count}) when is_integer(held) and is_integer(count), do: count > held
  def advances?({_held_pivot, held}, {<<_::256>>, count}) when is_integer(held) and is_integer(count), do: true
  def advances?(_recorded, _position), do: false

  defp recorded_map(%Request{transport: "websocket", request_metadata: %{"native_turn_progress" => recorded}}), do: recorded
  defp recorded_map(%Request{request_metadata: %{"native_http_turn_progress" => recorded}}), do: recorded

  defp recorded_pivot(nil), do: {:ok, nil}

  defp recorded_pivot(pivot) when is_binary(pivot) do
    case Base.url_decode64(pivot, padding: false) do
      {:ok, <<_::256>> = decoded} -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp recorded_pivot(_pivot), do: :error

  @doc "The stored form of a progress digest."
  @spec encode(<<_::256>>) :: String.t()
  def encode(<<_::256>> = progress), do: Base.url_encode64(progress, padding: false)
end
