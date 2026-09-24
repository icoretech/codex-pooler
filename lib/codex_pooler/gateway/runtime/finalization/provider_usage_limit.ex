defmodule CodexPooler.Gateway.Runtime.Finalization.ProviderUsageLimit do
  @moduledoc """
  A provider usage-limit `429` answered on the last eligible candidate, as the
  Pooler's terminal usage-limit refusal (findings#206 row 206-531).

  Nothing is left to fail over to, so the Pool is in the state routing answers
  with `429 usage_limit_reached` and the earliest reset once it has recorded
  it (row 206-508), one request earlier. When the provider named the refused
  account's reset, the request gets that answer now: `/v1` used to redact the
  refusal to a `rate_limit_error` without a reset or `Retry-After`, which the
  OpenAI SDKs resend twice, and a native streaming request received the `429`
  with an empty body, which the released Codex client cannot read as a usage
  limit.

  The refusal is a usage limit when its error `type` or `code` is the
  provider's `usage_limit_reached`/`usage_limit_exceeded`, or it carries a
  known `x-codex-rate-limit-reached-type`. The reset is the body's `resets_at`
  (epoch seconds), else its `resets_in_seconds`, and only one still ahead and
  within `@max_reset_seconds`; otherwise the relayed answer is unchanged. Only
  those tokens are read: the provider's message, plan and body never reach the
  client, and the persisted rejection metadata is untouched.

  The advice is the Pool's, as routing gives it one request later (row
  206-545): the soonest of the refused account's reset and the other
  candidates' returns (`CandidateEligibility.PoolReturn`). When another
  candidate has no known return, the Pool is not exhausted and the relayed
  answer is unchanged.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType

  # The code and message routing's own answer carries (`Quota`), so both
  # answers read the same to a client.
  # Written by `pool_frame/3` into a frame whose Pool advice is withheld, so the
  # socket relays it classified instead of as the terminal usage limit. A
  # provider frame that carried it would only lose the terminal wording; its
  # reset travels either way.
  @withheld_key "pooler_advice"
  @withheld "withheld"
  @retry_after_key "pooler_retry_after"
  @code "quota_exhausted"
  @message "upstream quota is exhausted until its reset time"
  @usage_limit_tokens ["usage_limit_reached", "usage_limit_exceeded"]
  @body_max_bytes 65_536
  # A monthly credit period with a margin; a later reset is not a reset.
  @max_reset_seconds 32 * 24 * 3_600

  @type others_return :: :none | {:ok, Contracts.usage_limit()} | :unknown

  @doc """
  The terminal refusal for `response`, or `:unknown`. `others` is called only
  for a usage limit with a known reset, and returns when the Pool's other
  candidates return.
  """
  @spec error(Req.Response.t(), (-> others_return()), DateTime.t()) :: {:ok, Contracts.gateway_error()} | :unknown
  def error(response, others \\ fn -> :none end, now \\ DateTime.utc_now())

  def error(%Req.Response{status: 429} = response, others, %DateTime{} = now) when is_function(others, 0),
    do: response |> Metadata.rejection_body() |> decode_error() |> refusal(response.headers, others, now)

  def error(_response, _others, _now), do: :unknown

  @doc """
  The same refusal for the upstream websocket's wrapped error frame
  (`{"type":"error","status":429,"error":{...},"headers":{...}}`), or its
  canonical `response.failed` that keeps the wrapped `status` and the
  provider's error object (findings#206 row 206-546). The advice is the
  refusing account's own reset: a socket frame carries no route context.
  """
  @spec frame_error(map() | term(), DateTime.t()) :: {:ok, Contracts.gateway_error()} | :unknown
  def frame_error(frame, now \\ DateTime.utc_now())

  def frame_error(%{"error" => %{@withheld_key => @withheld}}, _now), do: :unknown

  def frame_error(%{"error" => %{} = error} = frame, %DateTime{} = now) do
    if Map.get(frame, "status", Map.get(frame, "status_code")) == 429,
      do: refusal(error, Map.get(frame, "headers"), fn -> :none end, now),
      else: :unknown
  end

  def frame_error(_frame, _now), do: :unknown

  @doc "True for a provider `429` whose error or headers name a usage limit, whatever its reset."
  @spec usage_limit_refusal?(Req.Response.t()) :: boolean()
  def usage_limit_refusal?(%Req.Response{status: 429} = response),
    do: response |> Metadata.rejection_body() |> decode_error() |> usage_limit?(response.headers)

  def usage_limit_refusal?(_response), do: false

  @doc """
  A pre-output usage-limit frame of the last candidate, as the socket will
  project it, with the Pool's advice in place of the refusing account's own
  (findings#206 rows 206-545, 206-546): the soonest of its reset and
  `others`, or no reset at all when another candidate has no known return, so
  the socket keeps the retryable frame. Every other frame is returned as is.
  """
  @spec pool_frame(binary(), (-> others_return()), (-> pos_integer() | nil), DateTime.t()) :: binary()
  def pool_frame(frame, others, circuit_seconds \\ fn -> nil end, now \\ DateTime.utc_now())
      when is_binary(frame) and is_function(others, 0) and is_function(circuit_seconds, 0) do
    with {:ok, %{} = decoded} <- CodexPooler.JSON.decode(frame),
         {:ok, %{usage_limit: own}} <- frame_error(decoded, now) do
      case pool_return(own, others.()) do
        {:ok, ^own} -> frame
        {:ok, usage_limit} -> decoded |> put_frame_reset(%{"resets_at" => usage_limit.resets_at, "resets_in_seconds" => usage_limit.resets_in_seconds}) |> CodexPooler.JSON.encode!()
        :unknown -> decoded |> put_frame_reset(withheld_fields(circuit_seconds.())) |> CodexPooler.JSON.encode!()
      end
    else
      _other -> frame
    end
  end

  @doc """
  The frame's refusal as the socket relays it: `{:terminal, error}` for the
  Pooler's terminal usage limit, `{:relay, provider_error}` for a usage limit
  whose Pool advice was withheld or whose reset is not known (the socket then
  sends the classified wrapped `429` native HTTP sends, findings#206 row
  206-592), `:canonical` for any other frame (a plain throttle keeps the
  canonical frame the client classifies).
  """
  @spec frame_projection(map() | term(), DateTime.t()) :: {:terminal, Contracts.gateway_error()} | {:relay, map()} | :canonical
  def frame_projection(frame, now \\ DateTime.utc_now())

  def frame_projection(%{"error" => %{} = error} = frame, %DateTime{} = now) do
    with 429 <- Map.get(frame, "status", Map.get(frame, "status_code")),
         :unknown <- frame_error(frame, now) do
      if usage_limit?(error, Map.get(frame, "headers")), do: {:relay, Map.drop(error, [@withheld_key, @retry_after_key])}, else: :canonical
    else
      {:ok, terminal} -> {:terminal, terminal}
      _other_status -> :canonical
    end
  end

  def frame_projection(_frame, _now), do: :canonical

  defp withheld_fields(seconds) when is_integer(seconds) and seconds > 0, do: %{@withheld_key => @withheld, @retry_after_key => seconds}
  defp withheld_fields(_seconds), do: %{@withheld_key => @withheld}

  @doc """
  For a frame whose Pool advice was withheld: `{:withheld, retry_after}` with
  the seconds an open circuit of another candidate bounds the wait by, or
  `nil`; `:no` for every other frame (findings#206 row 206-593).
  """
  @spec withheld(map() | term()) :: {:withheld, pos_integer() | nil} | :no
  def withheld(%{"status" => 429, "error" => %{@withheld_key => @withheld} = error}) do
    case error[@retry_after_key] do
      seconds when is_integer(seconds) and seconds in 1..60 -> {:withheld, seconds}
      _none -> {:withheld, nil}
    end
  end

  def withheld(_frame), do: :no

  defp put_frame_reset(decoded, reset) do
    decoded
    |> update_error(["error"], reset)
    |> update_error(["response", "error"], reset)
  end

  defp update_error(decoded, path, fields) do
    case get_in(decoded, path) do
      %{} = error -> put_in(decoded, path, Map.merge(error, fields))
      _absent -> decoded
    end
  end

  defp refusal(error, headers, others, now) do
    with true <- usage_limit?(error, headers),
         {:ok, own} <- reset(error, now),
         {:ok, usage_limit} <- pool_return(own, others.()) do
      {:ok, %{status: 429, code: @code, message: @message, param: "model", usage_limit: usage_limit}}
    else
      _unknown -> :unknown
    end
  end

  defp pool_return(own, :none), do: {:ok, own}
  defp pool_return(own, {:ok, %{resets_at: resets_at} = other}), do: {:ok, if(resets_at < own.resets_at, do: other, else: own)}
  defp pool_return(_own, :unknown), do: :unknown

  defp decode_error(body) when is_binary(body) and byte_size(body) <= @body_max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      _other -> %{}
    end
  end

  defp decode_error(_body), do: %{}

  defp usage_limit?(error, headers) do
    error["type"] in @usage_limit_tokens or error["code"] in @usage_limit_tokens or
      is_binary(RateLimitReachedType.parse_header(headers))
  end

  defp reset(%{"resets_at" => resets_at}, now) when is_integer(resets_at) and resets_at > 0 do
    if resets_at - DateTime.to_unix(now) <= @max_reset_seconds,
      do: resets_at |> DateTime.from_unix!() |> usage_limit(now),
      else: :unknown
  end

  defp reset(%{"resets_in_seconds" => seconds}, now) when is_integer(seconds) and seconds > 0 and seconds <= @max_reset_seconds,
    do: now |> DateTime.add(seconds, :second) |> usage_limit(now)

  defp reset(_error, _now), do: :unknown

  # Rounded up like routing's answer (`UsageLimit`): whole seconds, never zero.
  defp usage_limit(reset_at, now) do
    case DateTime.diff(reset_at, now, :millisecond) do
      millis when millis > 0 -> {:ok, %{resets_at: ceil_unix(reset_at), resets_in_seconds: div(millis + 999, 1_000)}}
      _past -> :unknown
    end
  end

  defp ceil_unix(%DateTime{microsecond: {0, _precision}} = reset_at), do: DateTime.to_unix(reset_at)
  defp ceil_unix(reset_at), do: DateTime.to_unix(reset_at) + 1
end
