defmodule CodexPooler.Upstreams.Reconciliation.SavedResetUsageEnrichment do
  @moduledoc false

  alias CodexPooler.Platform.OutboundHTTP
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @body_state_key :saved_reset_detail_body_state
  @body_limit_exceeded_key :saved_reset_detail_body_limit_exceeded

  @spec enrich(
          UpstreamIdentity.t(),
          term(),
          String.t(),
          DateTime.t(),
          timeout(),
          [{String.t(), String.t()}],
          map()
        ) :: term()
  def enrich(%UpstreamIdentity{} = identity, payload, usage_url, observed_at, timeout, headers, cooldown)
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
          cooldown,
          count
        )

      _unreported_or_empty ->
        payload
    end
  end

  def enrich(_identity, payload, _usage_url, _observed_at, _timeout, _headers, _cooldown), do: payload

  defp maybe_refresh_reset_credit_expirations(
         identity,
         payload,
         usage_url,
         observed_at,
         timeout,
         headers,
         cooldown,
         count
       ) do
    if SavedResets.reset_credit_list_refresh_due?(identity, count, observed_at) do
      refresh_reset_credit_expirations(
        identity,
        payload,
        usage_url,
        observed_at,
        timeout,
        headers,
        cooldown
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
         headers,
         cooldown
       ) do
    case fetch_reset_credits_payload(usage_url, observed_at, timeout, headers, cooldown) do
      {:ok, reset_credits} ->
        merge_reset_credit_snapshot(payload, reset_credits)

      # A read the provider told us not to make is not a read that failed:
      # nothing was attempted, so the cached expirations keep the time they
      # were actually observed rather than being restamped as fresh.
      :deferred ->
        SavedResets.reuse_expiration_metadata(payload, identity)

      :error ->
        SavedResets.reuse_expiration_metadata(payload, identity, observed_at)
    end
  end

  defp fetch_reset_credits_payload(usage_url, observed_at, timeout, headers, cooldown) do
    usage_url
    |> reset_credits_urls()
    |> Enum.reduce_while(:error, fn url, last_result ->
      case admit_detail_read(cooldown, observed_at) do
        :ok -> read_reset_credits_url(url, observed_at, timeout, headers, cooldown)
        {:deferred, _not_before} -> {:halt, deferred_detail_read(last_result)}
      end
    end)
  end

  defp read_reset_credits_url(url, observed_at, timeout, headers, cooldown) do
    case OutboundHTTP.get(url,
           headers: CloudflareCookies.request_headers(url, headers),
           decode_body: false,
           into: &collect_bounded_body/2,
           retry: false,
           receive_timeout: timeout,
           finch: OutboundHTTP.pool_options_for_url(url)
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        handle_successful_reset_credits_response(url, response, observed_at)

      {:ok, %Req.Response{status: status} = response} ->
        CloudflareCookies.store_from_response(url, response)
        maybe_record_detail_cooldown(response, status, cooldown)

      {:error, _reason} ->
        {:cont, :error}
    end
  end

  # The detail read shares the usage endpoints' origin, so a pause either of
  # them is told about applies to both. Recording it here is what stops the
  # next usage probe as well, not only the rest of this optional read.
  defp maybe_record_detail_cooldown(response, status, cooldown) do
    received_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with true <- is_binary(UsagePollCooldown.status_name(status)),
         {:retry_after, not_before} <- UsagePollCooldown.instruction(response, received_at),
         origin_key when is_binary(origin_key) <- Map.get(cooldown, :origin_key),
         {:ok, _deadline} <-
           UsagePollCooldown.record(
             cooldown.identity_id,
             cooldown.scope,
             origin_key,
             status,
             not_before,
             received_at
           ) do
      {:halt, :deferred}
    else
      _no_usable_instruction -> {:cont, :error}
    end
  end

  defp admit_detail_read(%{origin_key: nil}, _observed_at), do: :ok

  defp admit_detail_read(%{} = cooldown, observed_at) do
    UsagePollCooldown.admit_current(
      cooldown.identity_id,
      cooldown.scope,
      cooldown.origin_key,
      observed_at
    )
  end

  defp admit_detail_read(_cooldown, _observed_at), do: :ok

  defp deferred_detail_read({:ok, _reset_credits} = read), do: read
  defp deferred_detail_read(_last_result), do: :deferred

  defp handle_successful_reset_credits_response(url, response, observed_at) do
    CloudflareCookies.store_from_response(url, response)

    case decode_bounded_body(response) do
      {:ok, body} when is_map(body) ->
        {:halt, {:ok, Map.put(body, "expires_observed_at", DateTime.to_iso8601(observed_at))}}

      :error ->
        {:cont, :error}
    end
  end

  defp collect_bounded_body({:data, data}, {request, response}) do
    max_bytes = SavedResets.detail_payload_max_bytes()
    state = Req.Response.get_private(response, @body_state_key, %{chunks: [], seen_bytes: 0})

    if declared_over_limit?(response, max_bytes) or
         state.seen_bytes + byte_size(data) > max_bytes do
      response =
        response
        |> Req.Response.put_private(@body_limit_exceeded_key, true)
        |> Map.replace!(:body, "")

      {:halt, {request, response}}
    else
      state = %{chunks: [data | state.chunks], seen_bytes: state.seen_bytes + byte_size(data)}
      response = Req.Response.put_private(response, @body_state_key, state)
      {:cont, {request, response}}
    end
  end

  defp decode_bounded_body(response) do
    max_bytes = SavedResets.detail_payload_max_bytes()

    with false <- declared_over_limit?(response, max_bytes),
         false <- Req.Response.get_private(response, @body_limit_exceeded_key, false),
         %{chunks: chunks} <- Req.Response.get_private(response, @body_state_key),
         {:ok, %{} = body} <-
           chunks |> Enum.reverse() |> IO.iodata_to_binary() |> CodexPooler.JSON.decode() do
      {:ok, body}
    else
      _invalid_or_oversized -> :error
    end
  end

  defp declared_over_limit?(response, max_bytes) do
    response
    |> Req.Response.get_header("content-length")
    |> List.first()
    |> parse_content_length()
    |> case do
      content_length when is_integer(content_length) -> content_length > max_bytes
      _unknown -> false
    end
  end

  defp parse_content_length(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {content_length, ""} when content_length >= 0 -> content_length
      _invalid -> nil
    end
  end

  defp parse_content_length(_value), do: nil

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
    sanitized_detail = SavedResets.sanitize_reset_credit_detail(reset_credits)

    reset_credit_summary =
      reset_credit_summary
      |> put_if_present("available_count", Map.get(sanitized_detail, "available_count"))
      |> Map.put(
        :saved_reset_detail_status,
        Map.fetch!(sanitized_detail, "expires_detail_status")
      )
      |> put_reset_credit_list(sanitized_detail)

    Map.put(payload, "rate_limit_reset_credits", reset_credit_summary)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_reset_credit_list(map, %{"credits" => credits}) when is_list(credits),
    do: Map.put(map, "credits", credits)

  defp put_reset_credit_list(map, _reset_credits), do: map
end
