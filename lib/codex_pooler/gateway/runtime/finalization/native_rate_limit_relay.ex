defmodule CodexPooler.Gateway.Runtime.Finalization.NativeRateLimitRelay do
  @moduledoc """
  The native answer to a provider `429` that the Pooler relays on the last
  eligible candidate without its own terminal usage limit (the reset or a
  sibling's return is not known, or the refusal is a plain throttle;
  findings#206 row 206-589).

  A streaming request used to get the `429` with an empty body, because the
  drain leaves no public body, and an explicit Full request a
  `server_error`/"upstream request failed" body. The released Codex client
  read both as `RetryLimit` ("exceeded retry limit, last status: 429"),
  whatever the provider said. This body keeps the tokens the client
  classifies a `429` by (`codex-api/src/api_bridge.rs`): `error.type`
  `usage_limit_reached` becomes `UsageLimitReached`, `usage_not_included` and
  `insufficient_quota` their own terminal errors, the quota codes
  `QuotaExceeded`, anything else `RetryLimit`, with `resets_at` naming the
  reset in the client's message. The same body goes out in Full and Lite,
  streaming or not.

  Only bounded tokens are read from the drained body: a classified type, a
  classified code and integer resets within a month. The provider's
  message, plan and any other field never reach the client, as in the
  Pooler's terminal usage-limit answer (row 206-531); the message is the
  Pooler's.
  """

  alias CodexPooler.Gateway.Runtime.Finalization.Metadata

  @usage_limit_types ["usage_limit_reached", "usage_not_included", "insufficient_quota"]
  @usage_limit_message "upstream usage limit reached"
  @throttle_message "upstream rate limited the request"
  @throttle_type "rate_limit_error"
  # The codes the released client classifies a `429` by, plus the provider's
  # own throttle and usage-limit codes; any other code is not relayed.
  @classified_codes ~w(insufficient_quota credit_balance_exhausted organization_spend_limit_exceeded project_spend_limit_exceeded organization_usage_limit_exceeded rate_limit_exceeded usage_limit_reached usage_limit_exceeded)
  @body_max_bytes 65_536
  @max_reset_seconds 32 * 24 * 3_600

  @doc "The error object for `response`'s relayed `429`."
  @spec error(Req.Response.t(), DateTime.t()) :: map()
  def error(%Req.Response{} = response, %DateTime{} = now \\ DateTime.utc_now()) do
    provider = response |> Metadata.rejection_body() |> decode_error()
    type = if provider["type"] in @usage_limit_types, do: provider["type"], else: @throttle_type

    %{
      "type" => type,
      "code" => code(provider["code"]),
      "message" => if(type == @throttle_type, do: @throttle_message, else: @usage_limit_message)
    }
    |> maybe_put("resets_at", resets_at(provider["resets_at"], now))
    |> maybe_put("resets_in_seconds", resets_in_seconds(provider["resets_in_seconds"]))
  end

  @doc """
  The retry advice of a relayed error that names a reset, in whole seconds
  (never zero), or `nil` (findings#206 row 206-597): the provider's
  `resets_in_seconds`, else the time left until its `resets_at`.
  """
  @spec retry_after_seconds(map(), DateTime.t()) :: pos_integer() | nil
  def retry_after_seconds(error, now \\ DateTime.utc_now())
  def retry_after_seconds(%{"resets_in_seconds" => seconds}, _now) when is_integer(seconds) and seconds > 0, do: seconds

  def retry_after_seconds(%{"resets_at" => resets_at}, now) when is_integer(resets_at),
    do: max(resets_at - DateTime.to_unix(now), 1)

  def retry_after_seconds(_error, _now), do: nil

  defp decode_error(body) when is_binary(body) and byte_size(body) <= @body_max_bytes do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      _other -> %{}
    end
  end

  defp decode_error(_body), do: %{}

  defp code(code) when code in @classified_codes, do: code
  defp code(_code), do: "upstream_rate_limited"

  defp resets_at(value, now) when is_integer(value) and value > 0 do
    seconds = value - DateTime.to_unix(now)
    if seconds > 0 and seconds <= @max_reset_seconds, do: value
  end

  defp resets_at(_value, _now), do: nil

  defp resets_in_seconds(value) when is_integer(value) and value > 0 and value <= @max_reset_seconds, do: value
  defp resets_in_seconds(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
