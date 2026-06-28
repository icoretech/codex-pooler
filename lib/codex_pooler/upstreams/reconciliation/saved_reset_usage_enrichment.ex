defmodule CodexPooler.Upstreams.Reconciliation.SavedResetUsageEnrichment do
  @moduledoc false

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @spec enrich(
          UpstreamIdentity.t(),
          term(),
          String.t(),
          DateTime.t(),
          timeout(),
          [{String.t(), String.t()}]
        ) :: term()
  def enrich(%UpstreamIdentity{} = identity, payload, usage_url, observed_at, timeout, headers)
      when is_map(payload) do
    case SavedResets.count_from_usage_payload(payload) do
      {:reported, count} when count > 0 ->
        maybe_refresh_reset_credit_expirations(
          identity,
          payload,
          usage_url,
          observed_at,
          timeout,
          headers,
          count
        )

      _unreported_or_empty ->
        payload
    end
  end

  def enrich(_identity, payload, _usage_url, _observed_at, _timeout, _headers), do: payload

  defp maybe_refresh_reset_credit_expirations(
         identity,
         payload,
         usage_url,
         observed_at,
         timeout,
         headers,
         count
       ) do
    if SavedResets.reset_credit_list_refresh_due?(identity, count, observed_at) do
      refresh_reset_credit_expirations(
        identity,
        payload,
        usage_url,
        observed_at,
        timeout,
        headers
      )
    else
      SavedResets.reuse_expiration_metadata(payload, identity)
    end
  end

  defp refresh_reset_credit_expirations(
         identity,
         payload,
         usage_url,
         observed_at,
         timeout,
         headers
       ) do
    case fetch_reset_credits_payload(usage_url, observed_at, timeout, headers) do
      {:ok, reset_credits} -> merge_reset_credit_snapshot(payload, reset_credits)
      :error -> SavedResets.reuse_expiration_metadata(payload, identity, observed_at)
    end
  end

  defp fetch_reset_credits_payload(usage_url, observed_at, timeout, headers) do
    usage_url
    |> reset_credits_urls()
    |> Enum.reduce_while(:error, fn url, _last_result ->
      case Req.get(url,
             headers: headers,
             retry: false,
             receive_timeout: timeout
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:halt, {:ok, Map.put(body, "expires_observed_at", DateTime.to_iso8601(observed_at))}}

        _unavailable ->
          {:cont, :error}
      end
    end)
  end

  defp reset_credits_urls(usage_url) do
    parsed = URI.parse(usage_url)
    base = %{parsed | query: nil, fragment: nil}

    case parsed.path do
      "/backend-api/wham/usage" ->
        [uri_with_path(base, "/backend-api/wham/rate-limit-reset-credits")]

      "/wham/usage" ->
        [uri_with_path(base, "/wham/rate-limit-reset-credits")]

      path when path in ["/api/codex/usage", "/backend-api/codex/usage"] ->
        [
          uri_with_path(base, "/backend-api/wham/rate-limit-reset-credits"),
          uri_with_path(base, "/wham/rate-limit-reset-credits")
        ]

      _path ->
        []
    end
  end

  defp uri_with_path(%URI{} = uri, path), do: %{uri | path: path} |> URI.to_string()

  defp merge_reset_credit_snapshot(payload, reset_credits) do
    reset_credit_summary = Map.get(payload, "rate_limit_reset_credits") || %{}

    reset_credit_summary =
      reset_credit_summary
      |> put_if_present("available_count", Map.get(reset_credits, "available_count"))
      |> put_if_present("total_earned_count", Map.get(reset_credits, "total_earned_count"))
      |> put_reset_credit_list(reset_credits)

    Map.put(payload, "rate_limit_reset_credits", reset_credit_summary)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_reset_credit_list(map, %{"credits" => credits}) when is_list(credits),
    do: Map.put(map, "credits", credits)

  defp put_reset_credit_list(map, _reset_credits), do: map
end
