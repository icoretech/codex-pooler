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

  @doc "The progress digest recorded by the row holding `claim`, or `nil`."
  @spec recorded_for_claim(String.t()) :: String.t() | nil
  def recorded_for_claim(claim) when is_binary(claim) do
    Repo.one(
      from request in Request,
        where: request.correlation_id == ^claim,
        select: %Request{transport: request.transport, request_metadata: request.request_metadata}
    )
    |> recorded()
  end

  @doc """
  True when `progress` differs from the digest the holder of the turn's bare
  claim recorded: the request cannot be a retry of that holder, which only
  appends model output, so it is a later request of the turn. False when the
  holder recorded nothing.
  """
  @spec differs?(String.t() | nil, <<_::256>>) :: boolean()
  def differs?(recorded, <<_::256>> = progress) when is_binary(recorded),
    do: recorded != encode(progress)

  def differs?(nil, _progress), do: false

  @doc "The stored form of a progress digest."
  @spec encode(<<_::256>>) :: String.t()
  def encode(<<_::256>> = progress), do: Base.url_encode64(progress, padding: false)
end
