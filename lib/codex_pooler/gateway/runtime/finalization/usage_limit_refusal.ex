defmodule CodexPooler.Gateway.Runtime.Finalization.UsageLimitRefusal do
  @moduledoc """
  A provider usage-limit `429` as quota evidence and route health
  (findings#206 row 206-594).

  A usage limit refuses the account, not the route: it is recorded as the
  provider's denial on the windows its headers carry, and when those windows
  exclude the account (a window exhausted until a reset still ahead, or a
  `workspace_*` denial with a reset still ahead, which the account-denial
  routing filter reads) the refusal completes the route neutrally. It used to
  count as an upstream failure: a demotion and a circuit failure, so three
  refusals opened the account's circuit, an open circuit then withheld the
  Pool's terminal advice (rows 206-592, 206-593) and the account came back
  only after a circuit probe instead of with its window.

  A usage limit whose headers carry no window records nothing new: no window,
  duration or percentage is ever inferred from the body's reset. It keeps the
  circuit rule, which is then the only thing that stops the Pool from sending
  the account more requests. A plain throttle is not a usage limit and keeps
  the circuit rule too.

  A `429` is a usage limit when its drained body names `usage_limit_reached`
  or `usage_limit_exceeded` (as `type` or `code`), or it carries a
  `workspace_*` `x-codex-rate-limit-reached-type`; only those bounded tokens
  are read. A `rate_limit_reached` header on a body that names no usage limit
  is an ordinary per-window throttle (row 206-509), not a usage limit.
  """

  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType
  alias CodexPooler.Upstreams.Quota.Evidence, as: QuotaEvidence
  alias CodexPooler.Upstreams.Quota.Windows.AccountDenial

  @usage_limit_codes ["usage_limit_reached", "usage_limit_exceeded"]
  @body_max_bytes 65_536

  @doc """
  The refusal code the header parser records a usage limit's windows under,
  or `nil` when `response` is not a usage-limit `429`.
  """
  @spec denial_code(Req.Response.t()) :: String.t() | nil
  def denial_code(%Req.Response{status: 429} = response) do
    error = response |> Metadata.rejection_body() |> decode_error()

    cond do
      error["type"] in @usage_limit_codes -> error["type"]
      error["code"] in @usage_limit_codes -> error["code"]
      RateLimitReachedType.parse_header(response.headers) in AccountDenial.account_denial_types() -> "usage_limit_reached"
      true -> nil
    end
  end

  def denial_code(_response), do: nil

  @doc """
  Whether the usage-limit `429` in `response` is quota evidence that excludes
  the account, so the refusal says nothing against the route.
  """
  @spec route_neutral?(Req.Response.t(), String.t() | nil, DateTime.t()) :: boolean()
  def route_neutral?(%Req.Response{} = response, dispatched_model, %DateTime{} = now \\ DateTime.utc_now()) do
    case denial_code(response) do
      nil ->
        false

      code ->
        windows = QuotaEvidence.codex_header_windows(response.headers, now, dispatched_model, code)
        Enum.any?(windows, &exhausted_ahead?(&1, now)) or workspace_denial_ahead?(response.headers, windows, now)
    end
  end

  defp exhausted_ahead?(%{used_percent: %Decimal{} = used, reset_at: %DateTime{} = reset_at}, now),
    do: Decimal.compare(used, Decimal.new(100)) != :lt and DateTime.compare(reset_at, now) == :gt

  defp exhausted_ahead?(_window, _now), do: false

  defp workspace_denial_ahead?(headers, windows, now) do
    RateLimitReachedType.parse_header(headers) in AccountDenial.account_denial_types() and
      Enum.any?(windows, &reset_ahead?(&1, now))
  end

  defp reset_ahead?(%{reset_at: %DateTime{} = reset_at}, now), do: DateTime.compare(reset_at, now) == :gt
  defp reset_ahead?(_window, _now), do: false

  defp decode_error(body) when is_binary(body) and byte_size(body) <= @body_max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      _other -> %{}
    end
  end

  defp decode_error(_body), do: %{}
end
