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

  def error(%Req.Response{status: 429} = response, others, %DateTime{} = now) when is_function(others, 0) do
    error = response |> Metadata.rejection_body() |> decode_error()

    with true <- usage_limit?(error, response.headers),
         {:ok, own} <- reset(error, now),
         {:ok, usage_limit} <- pool_return(own, others.()) do
      {:ok, %{status: 429, code: @code, message: @message, param: "model", usage_limit: usage_limit}}
    else
      _unknown -> :unknown
    end
  end

  def error(_response, _others, _now), do: :unknown

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
