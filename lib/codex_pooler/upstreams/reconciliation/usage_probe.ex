defmodule CodexPooler.Upstreams.Reconciliation.UsageProbe do
  @moduledoc false

  alias CodexPooler.Jobs
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Reconciliation.SavedResetUsageEnrichment
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @account_quota_key "account"
  @usage_auth_refresh_skew_seconds 5 * 60
  @chatgpt_usage_paths [
    "/backend-api/wham/usage",
    "/backend-api/codex/usage"
  ]
  @codex_api_usage_paths [
    "/api/codex/usage",
    "/backend-api/codex/usage",
    "/backend-api/wham/usage"
  ]

  @type usage_fetch_result :: {:ok, term(), String.t(), [map()]} | {:error, term()}
  @type usage_probe_result ::
          {:ok, term(), String.t(), [map()]}
          | :not_found
          | {:continue_error, term()}
          | {:halt_error, term()}

  @spec reconciliation_source(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), keyword()) ::
          {:usage, UpstreamIdentity.t(), term(), [map()], String.t()}
          | {:usage_unavailable, term()}
          | :auth_unavailable
  def reconciliation_source(%UpstreamIdentity{} = identity, assignment, opts) do
    with chatgpt_account_id when is_binary(chatgpt_account_id) and chatgpt_account_id != "" <-
           identity.chatgpt_account_id,
         {:ok, access_token} <- Secrets.decrypt_active_secret(identity, "access_token"),
         observed_at <- now() do
      case fetch(identity, assignment, access_token, observed_at, opts) do
        {:ok, payload, usage_url, windows} ->
          {:usage, identity, payload, windows, usage_url}

        {:error, {:upstream_status, status}} when status in [401, 403] ->
          maybe_retry_after_token_refresh(identity, assignment, observed_at, opts)

        {:error, reason} ->
          {:usage_unavailable, reason}
      end
    else
      _unavailable -> :auth_unavailable
    end
  end

  @spec fetch_from_identity(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          DateTime.t(),
          keyword()
        ) :: usage_fetch_result()
  def fetch_from_identity(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        %DateTime{} = observed_at,
        opts
      ) do
    with {:ok, access_token} <- Secrets.decrypt_active_secret(identity, "access_token") do
      fetch(identity, assignment, access_token, observed_at, opts)
    end
  end

  @spec fetch(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          String.t(),
          DateTime.t(),
          keyword()
        ) :: usage_fetch_result()
  def fetch(%UpstreamIdentity{} = identity, assignment, access_token, observed_at, opts) do
    base =
      identity
      |> EndpointMetadata.usage_base_url(assignment)
      |> EndpointMetadata.normalize_base_url()

    timeout = Keyword.get(opts, :receive_timeout, 30_000)
    headers = usage_headers(access_token, identity.chatgpt_account_id)

    identity
    |> usage_paths(assignment)
    |> Enum.reduce_while({:error, :not_found}, fn path, last_result ->
      base
      |> usage_url(path)
      |> probe_usage_url(identity, headers, observed_at, timeout)
      |> reduce_usage_probe_result(last_result)
    end)
  end

  defp usage_paths(%UpstreamIdentity{} = identity, %PoolUpstreamAssignment{} = assignment) do
    case configured_usage_path(identity, assignment) do
      path when path in ["/api/codex/usage", "/backend-api/codex/usage"] ->
        [path | @codex_api_usage_paths]
        |> Enum.uniq()

      _chatgpt_path ->
        @chatgpt_usage_paths
    end
  end

  defp configured_usage_path(
         %UpstreamIdentity{} = identity,
         %PoolUpstreamAssignment{} = assignment
       ) do
    metadata_usage_path(assignment.metadata) || metadata_usage_path(identity.metadata)
  end

  defp metadata_usage_path(%{} = metadata) do
    case Map.get(metadata, "saved_resets") do
      %{} = saved_resets -> Map.get(saved_resets, "usage_path") || Map.get(metadata, "usage_path")
      _other -> Map.get(metadata, "usage_path")
    end
  end

  defp metadata_usage_path(_metadata), do: nil

  defp maybe_retry_after_token_refresh(identity, assignment, observed_at, opts) do
    if access_token_refresh_due_after_usage_auth_failure?(identity, observed_at) do
      retry_after_token_refresh(identity, assignment, opts)
    else
      {:usage_unavailable, {:upstream_status, :auth_rejected}}
    end
  end

  defp retry_after_token_refresh(identity, assignment, opts) do
    case TokenRefresh.refresh_access_token(identity,
           trigger_kind: "account_reconciliation",
           receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
         ) do
      {:ok, %{status: :active, identity: refreshed_identity}} ->
        fetch_after_successful_token_refresh(refreshed_identity, assignment, opts)

      {:ok, %{status: :refresh_failed, retryable?: true, identity: failed_identity}} ->
        maybe_enqueue_account_reconciliation_token_refresh_recovery(failed_identity)
        :auth_unavailable

      _unavailable ->
        :auth_unavailable
    end
  end

  defp fetch_after_successful_token_refresh(refreshed_identity, assignment, opts) do
    with {:ok, access_token} <- Secrets.decrypt_active_secret(refreshed_identity, "access_token"),
         observed_at <- now(),
         {:ok, payload, usage_url, windows} <-
           fetch(
             refreshed_identity,
             assignment,
             access_token,
             observed_at,
             opts
           ) do
      {:usage, refreshed_identity, payload, windows, usage_url}
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp maybe_enqueue_account_reconciliation_token_refresh_recovery(
         %UpstreamIdentity{} = failed_identity
       ) do
    if account_reconciliation_refresh_failure?(failed_identity) do
      # Best-effort recovery nudge: the foreground reconciliation result stays
      # auth-unavailable whether the follow-up Oban enqueue wins a unique lock,
      # is already queued, or cannot be persisted.
      _ =
        Jobs.enqueue_token_refresh(failed_identity,
          trigger_kind: "account_reconciliation_recovery"
        )
    end

    :ok
  end

  defp account_reconciliation_refresh_failure?(%UpstreamIdentity{} = identity) do
    case identity.metadata["token_refresh"] do
      %{"status" => "failed", "trigger_kind" => "account_reconciliation"} -> true
      _metadata -> false
    end
  end

  defp usage_url(base, path), do: String.trim_trailing(base, "/") <> path

  @spec probe_usage_url(
          String.t(),
          UpstreamIdentity.t(),
          [{String.t(), String.t()}],
          DateTime.t(),
          timeout()
        ) :: usage_probe_result()
  defp probe_usage_url(url, identity, headers, observed_at, timeout) do
    probe_usage_url(url, identity, headers, observed_at, timeout, false)
  end

  defp probe_usage_url(url, identity, headers, observed_at, timeout, retried_after_cookie?) do
    url
    |> request_usage_url(headers, timeout)
    |> handle_usage_response(url, identity, headers, observed_at, timeout, retried_after_cookie?)
  end

  defp request_usage_url(url, headers, timeout) do
    Req.get(url,
      headers: CloudflareCookies.request_headers(url, headers),
      retry: false,
      receive_timeout: timeout
    )
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: status, body: body} = response},
         url,
         identity,
         headers,
         observed_at,
         timeout,
         _retried_after_cookie?
       )
       when status in 200..299 do
    CloudflareCookies.store_from_response(url, response)
    usage_probe_success(body, identity, url, observed_at, timeout, headers)
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: 404} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    :not_found
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: status} = response},
         url,
         identity,
         headers,
         observed_at,
         timeout,
         retried_after_cookie?
       )
       when status in [401, 403] do
    stored_cookie? = CloudflareCookies.store_from_response(url, response)

    if html_response?(response) and stored_cookie? and not retried_after_cookie? do
      probe_usage_url(url, identity, headers, observed_at, timeout, true)
    else
      auth_path_unavailable_response(status, response)
    end
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: 429} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    {:halt_error, {:upstream_status, 429}}
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: status} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    {:halt_error, {:upstream_status, status}}
  end

  defp handle_usage_response(
         {:error, reason},
         _url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _retried_after_cookie?
       ),
       do: {:halt_error, reason}

  @spec auth_path_unavailable_response(pos_integer(), Req.Response.t()) :: usage_probe_result()
  defp auth_path_unavailable_response(status, %Req.Response{} = response) do
    if html_response?(response) do
      :not_found
    else
      {:halt_error, {:upstream_status, status}}
    end
  end

  @spec html_response?(Req.Response.t()) :: boolean()
  defp html_response?(%Req.Response{body: body} = response) do
    html_body?(body) or
      response
      |> Req.Response.get_header("content-type")
      |> Enum.any?(&html_content_type?/1)
  end

  @spec html_body?(term()) :: boolean()
  defp html_body?(body) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?(["<!doctype html", "<html"])
  end

  defp html_body?(_body), do: false

  @spec html_content_type?(term()) :: boolean()
  defp html_content_type?(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.contains?("text/html")
  end

  defp html_content_type?(_content_type), do: false

  @spec usage_probe_success(
          term(),
          UpstreamIdentity.t(),
          String.t(),
          DateTime.t(),
          timeout(),
          [{String.t(), String.t()}]
        ) :: usage_probe_result()
  defp usage_probe_success(body, identity, url, observed_at, timeout, headers) do
    case Quota.Windows.codex_usage_quota_windows_from_payload(body, observed_at) do
      {:ok, windows} ->
        body =
          SavedResetUsageEnrichment.enrich(
            identity,
            body,
            url,
            observed_at,
            timeout,
            headers
          )

        {:ok, body, url, windows}

      {:error, reason} ->
        {:continue_error, reason}
    end
  end

  @spec reduce_usage_probe_result(usage_probe_result(), usage_fetch_result()) ::
          {:cont, usage_fetch_result()} | {:halt, usage_fetch_result()}
  defp reduce_usage_probe_result(:not_found, last_result), do: {:cont, last_result}

  defp reduce_usage_probe_result({:halt_error, reason}, _last_result),
    do: {:halt, {:error, reason}}

  defp reduce_usage_probe_result({:continue_error, reason}, last_result),
    do: {:cont, accumulate_successful_usage_result(last_result, {:error, reason})}

  defp reduce_usage_probe_result({:ok, _body, _url, windows} = result, last_result) do
    if account_primary_usage_window?(windows) do
      {:halt, prefer_current_usage_result(last_result, result)}
    else
      {:cont, accumulate_successful_usage_result(last_result, result)}
    end
  end

  defp prefer_current_usage_result(
         {:ok, _body, _url, previous_windows},
         {:ok, body, url, windows}
       ) do
    {:ok, body, url, merge_usage_windows(previous_windows, windows)}
  end

  defp prefer_current_usage_result(_last_result, result), do: result

  defp accumulate_successful_usage_result(
         {:ok, body, url, previous_windows},
         {:ok, _new_body, _new_url, windows}
       ) do
    {:ok, body, url, merge_usage_windows(previous_windows, windows)}
  end

  defp accumulate_successful_usage_result({:ok, _body, _url, _windows} = result, _new_result),
    do: result

  defp accumulate_successful_usage_result(_last_result, new_result), do: new_result

  defp merge_usage_windows(previous_windows, current_windows) do
    previous_windows
    |> Enum.concat(current_windows)
    |> Enum.reduce(%{}, fn window, acc ->
      Map.put(acc, usage_window_identity(window), window)
    end)
    |> Map.values()
    |> Enum.sort_by(&usage_window_identity/1)
  end

  defp usage_window_identity(window) do
    {Map.get(window, :quota_key), Map.get(window, :window_kind)}
  end

  defp account_primary_usage_window?(windows) when is_list(windows) do
    Enum.any?(windows, fn window ->
      Map.get(window, :quota_key) == @account_quota_key and
        Map.get(window, :window_kind) == "primary" and Map.get(window, :window_minutes) == 300 and
        match?(%DateTime{}, Map.get(window, :reset_at))
    end)
  end

  defp usage_headers(access_token, chatgpt_account_id) do
    headers = [
      {"authorization", "Bearer " <> String.trim(access_token)},
      {"accept", "application/json"}
    ]

    if send_chatgpt_account_header?(chatgpt_account_id) do
      headers ++
        [
          {"chatgpt-account-id", chatgpt_account_id}
        ]
    else
      headers
    end
  end

  defp send_chatgpt_account_header?(chatgpt_account_id) when is_binary(chatgpt_account_id) do
    chatgpt_account_id = String.trim(chatgpt_account_id)

    chatgpt_account_id != "" and not String.starts_with?(chatgpt_account_id, "email_") and
      not String.starts_with?(chatgpt_account_id, "local_")
  end

  defp send_chatgpt_account_header?(_chatgpt_account_id), do: false

  defp access_token_refresh_due_after_usage_auth_failure?(
         %UpstreamIdentity{} = identity,
         %DateTime{} = observed_at
       ) do
    case access_token_expires_at(identity.metadata) do
      {:ok, expires_at} ->
        refresh_at = DateTime.add(observed_at, @usage_auth_refresh_skew_seconds, :second)
        DateTime.compare(expires_at, refresh_at) in [:lt, :eq]

      :unknown ->
        true
    end
  end

  defp access_token_expires_at(%{} = metadata) do
    case metadata["access_token_expires_at"] do
      expires_at when is_binary(expires_at) ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, parsed, _offset} -> {:ok, DateTime.truncate(parsed, :microsecond)}
          _invalid -> :unknown
        end

      _value ->
        :unknown
    end
  end

  defp access_token_expires_at(_metadata), do: :unknown

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
