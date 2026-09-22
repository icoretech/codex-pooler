defmodule CodexPooler.Upstreams.Reconciliation.UsageProbe do
  @moduledoc false

  alias CodexPooler.Jobs
  alias CodexPooler.Platform.OutboundHTTP
  alias CodexPooler.Quotas.{AccountAvailability, Evidence}
  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Quotas.Evidence.Descriptors
  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefresh, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Reconciliation.SavedResetUsageEnrichment
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
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

  defmodule Result do
    @moduledoc false

    alias CodexPooler.Quotas.{AccountAvailability, Evidence}

    @enforce_keys [
      :payload,
      :usage_url,
      :usage_path,
      :windows,
      :covered_descriptors,
      :account_availability,
      :observed_at
    ]
    defstruct [
      :payload,
      :usage_url,
      :usage_path,
      :credential_fence,
      :account_availability,
      :observed_at,
      windows: [],
      covered_descriptors: MapSet.new()
    ]

    @type t :: %__MODULE__{
            payload: term(),
            usage_url: String.t(),
            usage_path: String.t(),
            credential_fence: CredentialFencing.fence() | nil,
            account_availability: AccountAvailability.t() | nil,
            observed_at: DateTime.t(),
            windows: [map()],
            covered_descriptors: MapSet.t(Evidence.descriptor_key())
          }
  end

  @typep usage_poll_cooldown :: %{
           identity_id: Ecto.UUID.t(),
           scope: UsagePollCooldown.scope(),
           origin_key: String.t() | nil
         }

  @type usage_fetch_result :: {:ok, Result.t()} | {:error, term()}
  @type usage_probe_result ::
          {:ok, Result.t()}
          | :not_found
          | {:auth_rejected, String.t()}
          | {:continue_error, term()}
          | {:halt_error, term()}
  @type usage_probe_accumulator ::
          usage_fetch_result()
          | {:probe_failures, MapSet.t(String.t()), term() | nil}

  @spec reconciliation_source(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), keyword()) ::
          {:usage, UpstreamIdentity.t(), Result.t()}
          | {:usage_rejected, UpstreamIdentity.t(), CredentialFencing.fence()}
          | {:usage_unavailable, term(), CredentialFencing.fence()}
          | {:auth_unavailable, CredentialFencing.fence()}
          | :auth_unavailable
  def reconciliation_source(%UpstreamIdentity{} = identity, assignment, opts) do
    with chatgpt_account_id when is_binary(chatgpt_account_id) and chatgpt_account_id != "" <-
           identity.chatgpt_account_id,
         {:ok, fenced_identity, fence} <- CredentialFencing.allocate_usage_probe(identity) do
      case Secrets.decrypt_active_secret(fenced_identity, "access_token") do
        {:ok, access_token} ->
          probe_reconciliation_source(
            fenced_identity,
            assignment,
            access_token,
            now(),
            Keyword.put(opts, :credential_fence, fence),
            fence
          )

        _unavailable ->
          {:auth_unavailable, fence}
      end
    else
      _unavailable -> :auth_unavailable
    end
  end

  defp probe_reconciliation_source(identity, assignment, access_token, observed_at, opts, fence) do
    case fetch(identity, assignment, access_token, observed_at, opts) do
      {:ok, %Result{} = result} ->
        {:usage, identity, %{result | credential_fence: fence}}

      {:error, :definitive_provider_auth_rejected} ->
        {:usage_rejected, identity, fence}

      {:error, {:upstream_status, status}} when status in [401, 403] ->
        maybe_retry_after_token_refresh(identity, assignment, observed_at, opts, fence)

      {:error, reason} ->
        {:usage_unavailable, reason, fence}
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
    with {:ok, fenced_identity, fence} <- CredentialFencing.allocate_usage_probe(identity),
         {:ok, access_token} <- Secrets.decrypt_active_secret(fenced_identity, "access_token") do
      case fetch(
             fenced_identity,
             assignment,
             access_token,
             observed_at,
             Keyword.put(opts, :credential_fence, fence)
           ) do
        {:ok, %Result{} = result} ->
          {:ok, %{result | credential_fence: fence}}

        {:error, :definitive_provider_auth_rejected} ->
          {:error, {:definitive_provider_auth_rejected, fence}}

        {:error, reason} ->
          {:error, reason}
      end
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
    fence = Keyword.get(opts, :credential_fence)

    with {:ok, credential_epoch} <- probe_credential_epoch(identity, fence),
         {:ok, result} <-
           do_fetch(identity, assignment, access_token, observed_at, opts, credential_epoch) do
      {:ok, %{result | credential_fence: fence}}
    end
  end

  # A fenced caller read its epoch under the allocation lock, so it is already
  # the credential this probe holds. A direct caller may be carrying an identity
  # snapshot from before a credential replacement, and an epoch that is no
  # longer current would look past a pause recorded against the credential we
  # actually have. Reject it instead of dispatching on the strength of a stale
  # witness.
  @spec probe_credential_epoch(UpstreamIdentity.t(), CredentialFencing.fence() | term()) ::
          {:ok, pos_integer()} | {:error, :stale_credential_epoch}
  defp probe_credential_epoch(_identity, %{credential_epoch: epoch})
       when is_integer(epoch) and epoch > 0,
       do: {:ok, epoch}

  defp probe_credential_epoch(%UpstreamIdentity{} = identity, _fence) do
    epoch = CredentialFencing.credential_epoch(identity)

    if is_integer(epoch) and epoch > 0 and
         CredentialFencing.current_credential_epoch?(identity.id, epoch) do
      {:ok, epoch}
    else
      {:error, :stale_credential_epoch}
    end
  end

  defp do_fetch(
         %UpstreamIdentity{} = identity,
         assignment,
         access_token,
         observed_at,
         opts,
         credential_epoch
       ) do
    base =
      identity
      |> EndpointMetadata.usage_base_url(assignment)
      |> EndpointMetadata.normalize_base_url()

    timeout = Keyword.get(opts, :receive_timeout, 30_000)
    headers = usage_headers(access_token, identity.chatgpt_account_id)

    cooldown = %{
      identity_id: identity.id,
      scope: UsagePollCooldown.scope(identity, credential_epoch),
      origin_key: UsagePollCooldown.origin_key(base)
    }

    paths = usage_paths(identity, assignment)

    paths
    |> Enum.reduce_while({:error, :not_found}, fn path, last_result ->
      probe_admitted_usage_url(usage_url(base, path), identity, headers, observed_at, timeout, cooldown, last_result)
    end)
    |> finalize_usage_probe_result(paths)
  end

  # Every outbound read asks again, because the pause that matters may have
  # been committed by a sibling replica between this chain's own requests.
  defp probe_admitted_usage_url(url, identity, headers, observed_at, timeout, cooldown, last_result) do
    case admit_usage_read(cooldown, observed_at) do
      :ok ->
        url
        |> probe_usage_url(identity, headers, observed_at, timeout, cooldown)
        |> reduce_usage_probe_result(last_result)

      {:deferred, not_before} ->
        {:halt, deferred_usage_read(last_result, not_before)}
    end
  end

  defp admit_usage_read(%{origin_key: nil}, _observed_at), do: :ok

  defp admit_usage_read(cooldown, observed_at) do
    UsagePollCooldown.admit_current(
      cooldown.identity_id,
      cooldown.scope,
      cooldown.origin_key,
      observed_at
    )
  end

  # An auth rejection already observed on an earlier path is the stronger fact
  # about this credential, so the chain finishes with the result it would have
  # produced anyway rather than reporting only that it stopped early.
  defp deferred_usage_read({:probe_failures, _paths, _reason} = accumulated, _not_before),
    do: accumulated

  defp deferred_usage_read(_last_result, not_before),
    do: {:error, {:usage_poll_deferred, not_before}}

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

  defp maybe_retry_after_token_refresh(identity, assignment, observed_at, opts, fence) do
    if access_token_refresh_due_after_usage_auth_failure?(identity, observed_at) do
      retry_after_token_refresh(identity, assignment, opts, fence)
    else
      {:usage_unavailable, {:upstream_status, :auth_rejected}, fence}
    end
  end

  # The expected epoch is the one the failed probe ran under: if credentials
  # rotated meanwhile, the refresh skips the provider call and hands back the
  # current active identity, and the usage fetch retries with its token.
  defp retry_after_token_refresh(identity, assignment, opts, fence) do
    case TokenRefresh.refresh_access_token(identity,
           trigger_kind: "account_reconciliation",
           receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
           expected_credential_epoch: fence.credential_epoch
         ) do
      {:ok, %{status: :active, identity: refreshed_identity}} ->
        fetch_after_successful_token_refresh(refreshed_identity, assignment, opts)

      {:ok, %{status: :refresh_failed, retryable?: true, identity: failed_identity}} ->
        maybe_enqueue_account_reconciliation_token_refresh_recovery(failed_identity)
        {:auth_unavailable, fence}

      _unavailable ->
        {:auth_unavailable, fence}
    end
  end

  defp fetch_after_successful_token_refresh(refreshed_identity, assignment, opts) do
    case CredentialFencing.allocate_usage_probe(refreshed_identity) do
      {:ok, fenced_identity, fence} ->
        fetch_refreshed_probe(fenced_identity, assignment, fence, opts)

      _unavailable ->
        :auth_unavailable
    end
  end

  defp fetch_refreshed_probe(fenced_identity, assignment, fence, opts) do
    case Secrets.decrypt_active_secret(fenced_identity, "access_token") do
      {:ok, access_token} ->
        case fetch(fenced_identity, assignment, access_token, retry_observed_at(opts), opts) do
          {:ok, %Result{} = result} ->
            {:usage, fenced_identity, %{result | credential_fence: fence}}

          {:error, :definitive_provider_auth_rejected} ->
            {:usage_rejected, fenced_identity, fence}

          {:error, reason} ->
            {:usage_unavailable, reason, fence}
        end

      _unavailable ->
        {:auth_unavailable, fence}
    end
  end

  defp maybe_enqueue_account_reconciliation_token_refresh_recovery(%UpstreamIdentity{} = failed_identity) do
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
          timeout(),
          usage_poll_cooldown()
        ) :: usage_probe_result()
  defp probe_usage_url(url, identity, headers, observed_at, timeout, cooldown) do
    probe_usage_url(url, identity, headers, observed_at, timeout, cooldown, false)
  end

  defp probe_usage_url(url, identity, headers, observed_at, timeout, cooldown, retried_after_cookie?) do
    url
    |> request_usage_url(headers, timeout)
    |> handle_usage_response(url, identity, headers, observed_at, timeout, cooldown, retried_after_cookie?)
  end

  defp request_usage_url(url, headers, timeout) do
    OutboundHTTP.get(url,
      headers: CloudflareCookies.request_headers(url, headers),
      retry: false,
      receive_timeout: timeout,
      finch: OutboundHTTP.pool_options_for_url(url),
      decode_body: false
    )
    |> decode_usage_response()
  end

  @spec decode_usage_response({:ok, Req.Response.t()} | {:error, term()}) ::
          {:ok, Req.Response.t()} | {:error, term()}
  defp decode_usage_response({:ok, %Req.Response{body: body} = response}) do
    {:ok, %{response | body: decode_response_body(body)}}
  end

  defp decode_usage_response(result), do: result

  @spec decode_response_body(term()) :: term()
  defp decode_response_body(body) when is_binary(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, decoded} -> decoded
      _invalid -> body
    end
  end

  defp decode_response_body(body), do: body

  defp handle_usage_response(
         {:ok, %Req.Response{status: status, body: body} = response},
         url,
         identity,
         headers,
         observed_at,
         timeout,
         cooldown,
         _retried_after_cookie?
       )
       when status in 200..299 do
    CloudflareCookies.store_from_response(url, response)

    case decode_usage_body(body) do
      {:ok, payload} -> usage_probe_success(payload, identity, url, observed_at, timeout, headers, cooldown)
      :error -> {:continue_error, :invalid_usage_payload}
    end
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: 404} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _cooldown,
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
         cooldown,
         retried_after_cookie?
       )
       when status in [401, 403] do
    stored_cookie? = CloudflareCookies.store_from_response(url, response)

    if html_response?(response) and stored_cookie? and not retried_after_cookie? do
      probe_usage_url(url, identity, headers, observed_at, timeout, cooldown, true)
    else
      auth_path_unavailable_response(
        status,
        response,
        URI.parse(url).path,
        access_token_refresh_due_after_usage_auth_failure?(identity, observed_at)
      )
    end
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: 429} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         cooldown,
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    throttled_usage_response(response, 429, cooldown, {:continue_error, {:upstream_status, 429}})
  end

  defp handle_usage_response(
         {:ok, %Req.Response{status: status} = response},
         url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         cooldown,
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    throttled_usage_response(response, status, cooldown, {:halt_error, {:upstream_status, status}})
  end

  defp handle_usage_response(
         {:error, reason},
         _url,
         _identity,
         _headers,
         _observed_at,
         _timeout,
         _cooldown,
         _retried_after_cookie?
       ),
       do: {:halt_error, reason}

  # A provider that says when it will answer again has told us the one thing we
  # can act on. A deadline we can read stops this chain and is committed, so the
  # alternative endpoint, the next scheduled probe and every other replica see
  # it too. An instruction we cannot read changes nothing: the status keeps
  # behaving exactly as it did before this existed.
  @spec throttled_usage_response(
          Req.Response.t(),
          pos_integer(),
          usage_poll_cooldown(),
          usage_probe_result()
        ) :: usage_probe_result()
  defp throttled_usage_response(response, status, cooldown, without_instruction) do
    received_at = now()

    if UsagePollCooldown.status_name(status) do
      case UsagePollCooldown.instruction(response, received_at) do
        {:retry_after, not_before} ->
          record_usage_poll_cooldown(cooldown, status, not_before, received_at)

        :retry_now ->
          {:halt_error, {:upstream_status, status}}

        :absent ->
          without_instruction
      end
    else
      without_instruction
    end
  end

  # Without committed state there is nothing to suppress the next read, so a
  # write that does not land stops this chain and says only that the provider
  # throttled it. It never sleeps or retries inline.
  defp record_usage_poll_cooldown(%{origin_key: nil}, status, _not_before, _received_at),
    do: {:halt_error, {:upstream_status, status}}

  defp record_usage_poll_cooldown(cooldown, status, not_before, received_at) do
    case UsagePollCooldown.record(
           cooldown.identity_id,
           cooldown.scope,
           cooldown.origin_key,
           status,
           not_before,
           received_at
         ) do
      {:ok, deadline} -> {:halt_error, {:usage_poll_deferred, deadline}}
      {:error, _unwritten} -> {:halt_error, {:upstream_status, status}}
    end
  end

  @spec decode_usage_body(term()) :: {:ok, map()} | :error
  defp decode_usage_body(%{} = payload), do: {:ok, payload}

  defp decode_usage_body(payload) when is_binary(payload) do
    case CodexPooler.JSON.decode(payload) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp decode_usage_body(_payload), do: :error

  @spec auth_path_unavailable_response(pos_integer(), Req.Response.t(), String.t(), boolean()) ::
          usage_probe_result()
  defp auth_path_unavailable_response(status, %Req.Response{} = response, path, refresh_due?) do
    if decoded_json_object?(response.body) do
      auth_rejected_response(status, path, refresh_due?)
    else
      :not_found
    end
  end

  defp auth_rejected_response(401, _path, true),
    do: {:halt_error, {:upstream_status, 401}}

  defp auth_rejected_response(401, path, false), do: {:auth_rejected, path}

  defp auth_rejected_response(403, path, _refresh_due?), do: {:auth_rejected, path}

  defp auth_rejected_response(status, _path, _refresh_due?) do
    {:halt_error, {:upstream_status, status}}
  end

  @spec finalize_usage_probe_result(usage_probe_accumulator(), [String.t()]) ::
          usage_fetch_result()
  defp finalize_usage_probe_result({:probe_failures, rejected_paths, reason}, paths) do
    expected_paths = MapSet.new(paths)

    cond do
      MapSet.equal?(rejected_paths, expected_paths) and is_nil(reason) ->
        {:error, :definitive_provider_auth_rejected}

      MapSet.size(rejected_paths) > 0 and not is_nil(reason) ->
        {:error, {:mixed_auth_rejection, reason}}

      MapSet.size(rejected_paths) > 0 ->
        {:error, {:upstream_status, 401}}

      true ->
        {:error, reason}
    end
  end

  defp finalize_usage_probe_result(result, _paths), do: result

  defp decoded_json_object?(%{}), do: true
  defp decoded_json_object?(_body), do: false

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
          [{String.t(), String.t()}],
          usage_poll_cooldown()
        ) :: usage_probe_result()
  defp usage_probe_success(body, identity, url, observed_at, timeout, headers, cooldown) do
    case CodexParsers.parse_codex_usage_result(body, observed_at) do
      {:ok, %{windows: windows, account_availability: account_availability}}
      when windows != [] or not is_nil(account_availability) ->
        windows = suppress_conflicted_account_windows(windows, account_availability)

        body =
          SavedResetUsageEnrichment.enrich(
            identity,
            body,
            url,
            observed_at,
            timeout,
            headers,
            cooldown
          )

        {:ok,
         %Result{
           payload: body,
           usage_url: url,
           usage_path: URI.parse(url).path,
           windows: windows,
           account_availability: account_availability,
           observed_at: observed_at,
           covered_descriptors: covered_descriptors(body, windows, account_availability, observed_at)
         }}

      {:ok, %{windows: [], account_availability: nil}} ->
        case CodexParsers.legacy_usage_windows_for_strict_result(body, observed_at) do
          [] ->
            {:continue_error,
             %{
               code: :upstream_quota_unusable,
               message: "upstream quota payload had no usable windows"
             }}

          windows ->
            body =
              SavedResetUsageEnrichment.enrich(
                identity,
                body,
                url,
                observed_at,
                timeout,
                headers,
                cooldown
              )

            {:ok,
             %Result{
               payload: body,
               usage_url: url,
               usage_path: URI.parse(url).path,
               windows: windows,
               account_availability: nil,
               observed_at: observed_at,
               covered_descriptors: covered_descriptors(body, windows, nil, observed_at)
             }}
        end

      {:error, reason} ->
        {:continue_error, reason}
    end
  end

  defp suppress_conflicted_account_windows(
         windows,
         %AccountAvailability{basis: :conflict, account_windows: :unknown}
       ) do
    Enum.reject(windows, &account_window?/1)
  end

  defp suppress_conflicted_account_windows(windows, _account_availability), do: windows

  @spec reduce_usage_probe_result(usage_probe_result(), usage_probe_accumulator()) ::
          {:cont, usage_probe_accumulator()} | {:halt, usage_probe_accumulator()}
  defp reduce_usage_probe_result(:not_found, last_result), do: {:cont, last_result}

  defp reduce_usage_probe_result({:auth_rejected, _path}, {:ok, %Result{}}),
    do: {:halt, {:error, :definitive_provider_auth_rejected}}

  defp reduce_usage_probe_result(
         {:auth_rejected, path},
         {:probe_failures, paths, reason}
       ),
       do: {:cont, {:probe_failures, MapSet.put(paths, path), reason}}

  defp reduce_usage_probe_result({:auth_rejected, path}, _last_result),
    do: {:cont, {:probe_failures, MapSet.new([path]), nil}}

  defp reduce_usage_probe_result(
         {:halt_error, {:upstream_status, status} = reason},
         {:ok, %Result{}}
       )
       when status in [401, 403],
       do: {:halt, {:error, reason}}

  defp reduce_usage_probe_result({:halt_error, _reason}, {:ok, %Result{}} = last_result),
    do: {:halt, last_result}

  defp reduce_usage_probe_result(
         {:halt_error, reason},
         {:probe_failures, paths, _previous_reason}
       ) do
    if MapSet.size(paths) > 0,
      do: {:halt, {:error, {:mixed_auth_rejection, reason}}},
      else: {:halt, {:error, reason}}
  end

  defp reduce_usage_probe_result({:halt_error, reason}, _last_result),
    do: {:halt, {:error, reason}}

  defp reduce_usage_probe_result(
         {:continue_error, reason},
         {:probe_failures, paths, _previous_reason}
       ),
       do: {:cont, {:probe_failures, paths, reason}}

  defp reduce_usage_probe_result({:continue_error, _reason}, {:ok, %Result{}} = last_result),
    do: {:cont, last_result}

  defp reduce_usage_probe_result({:continue_error, reason}, _last_result),
    do: {:cont, {:probe_failures, MapSet.new(), reason}}

  defp reduce_usage_probe_result(
         {:ok, %Result{}} = result,
         {:probe_failures, rejected_paths, _reason} = last_result
       ) do
    if MapSet.size(rejected_paths) > 0 do
      {:halt, {:error, :definitive_provider_auth_rejected}}
    else
      reduce_successful_usage_result(result, last_result)
    end
  end

  defp reduce_usage_probe_result({:ok, %Result{}} = result, last_result),
    do: reduce_successful_usage_result(result, last_result)

  defp reduce_successful_usage_result(
         {:ok, %Result{windows: windows}} = result,
         last_result
       ) do
    if account_primary_usage_window?(windows) do
      {:halt, prefer_current_usage_result(last_result, result)}
    else
      {:cont, accumulate_successful_usage_result(last_result, result)}
    end
  end

  defp prefer_current_usage_result(
         {:ok, %Result{} = previous},
         {:ok, %Result{} = current}
       ) do
    {:ok, merge_results(previous, current, :current)}
  end

  defp prefer_current_usage_result(_last_result, result), do: result

  defp accumulate_successful_usage_result(
         {:ok, %Result{} = previous},
         {:ok, %Result{} = current}
       ) do
    {:ok, merge_results(previous, current, :previous)}
  end

  defp accumulate_successful_usage_result(_last_result, new_result), do: new_result

  defp merge_usage_windows(previous_windows, current_windows, preferred) do
    windows =
      if preferred == :current,
        do: previous_windows ++ current_windows,
        else: current_windows ++ previous_windows

    windows
    |> Enum.reduce(%{}, fn window, acc ->
      Map.put(acc, Evidence.identity_key(window), window)
    end)
    |> Map.values()
    |> Enum.sort_by(&Evidence.identity_key/1)
  end

  defp merge_results(previous, current, preferred) do
    %Result{} = selected = if preferred == :current, do: current, else: previous
    windows = merge_usage_windows(previous.windows, current.windows, preferred)
    account_availability = reduce_account_availability(previous, current)

    %Result{
      selected
      | windows: windows,
        account_availability: account_availability,
        covered_descriptors: merge_covered_descriptors(previous, current, windows, account_availability)
    }
  end

  defp covered_descriptors(payload, windows, account_availability, observed_at) do
    windows_by_descriptor = Enum.group_by(windows, &Evidence.descriptor_key/1)

    covered =
      payload
      |> raw_descriptors()
      |> Enum.reduce(MapSet.new(), fn {kind, descriptor}, covered ->
        descriptor_windows = parsed_descriptor_windows(kind, descriptor, observed_at)

        if safely_parsed_descriptor?(descriptor, descriptor_windows) do
          descriptor_windows
          |> Enum.map(&Evidence.descriptor_key/1)
          |> Enum.filter(&Map.has_key?(windows_by_descriptor, &1))
          |> Enum.reduce(covered, &MapSet.put(&2, &1))
        else
          covered
        end
      end)

    if account_absence_covered?(account_availability) do
      MapSet.put(covered, account_descriptor_key())
    else
      covered
    end
  end

  defp reduce_account_availability(previous, current) do
    [{previous, semantic_strength(previous)}, {current, semantic_strength(current)}]
    |> Enum.max_by(fn {_result, strength} -> strength end, fn -> {previous, 0} end)
    |> elem(0)
    |> Map.get(:account_availability)
  end

  defp semantic_strength(%Result{} = result) do
    observation = result.account_availability

    cond do
      match?(%AccountAvailability{state: :blocked}, observation) -> 5
      Enum.any?(result.windows, &account_window?/1) -> 4
      match?(%AccountAvailability{basis: :conflict}, observation) -> 3
      match?(%AccountAvailability{state: :available}, observation) -> 2
      match?(%AccountAvailability{basis: :no_proof}, observation) -> 1
      true -> 0
    end
  end

  defp merge_covered_descriptors(previous, current, windows, account_availability) do
    non_account =
      MapSet.union(previous.covered_descriptors, current.covered_descriptors)
      |> MapSet.reject(&account_descriptor?/1)

    cond do
      account_absence_covered?(account_availability) ->
        MapSet.put(non_account, account_descriptor_key())

      Enum.any?(windows, &account_window?/1) ->
        MapSet.union(non_account, account_coverage(previous, current))

      account_availability && account_availability.basis in [:conflict, :no_proof] ->
        non_account

      true ->
        non_account
    end
  end

  defp account_coverage(previous, current) do
    MapSet.union(previous.covered_descriptors, current.covered_descriptors)
    |> MapSet.filter(&account_descriptor?/1)
  end

  defp account_absence_covered?(%AccountAvailability{state: state, account_windows: :absent})
       when state in [:available, :blocked],
       do: true

  defp account_absence_covered?(_observation), do: false

  defp account_descriptor?({"account", "account", _model, _upstream_model, @account_quota_key, _source, _raw_limit_id, _raw_limit_name, _raw_metered_feature}),
    do: true

  defp account_descriptor?(_descriptor), do: false

  defp account_descriptor_key do
    Descriptors.account_descriptor()
    |> Map.put(:source, "codex_usage_api")
    |> Evidence.descriptor_key()
  end

  defp raw_descriptors(%{} = payload) do
    account_descriptors =
      case payload["rate_limit"] do
        %{} = rate_limit -> [{:account, rate_limit}]
        _unsupported -> []
      end

    account_descriptors ++ additional_descriptors(payload["additional_rate_limits"])
  end

  defp raw_descriptors(_payload), do: []

  defp additional_descriptors(limits) when is_list(limits) do
    Enum.flat_map(limits, fn
      %{"rate_limit" => %{} = additional_rate_limit} = limit ->
        [{:additional, {limit, additional_rate_limit}}]

      _unsupported ->
        []
    end)
  end

  defp additional_descriptors(_limits), do: []

  defp parsed_descriptor_windows(:account, rate_limit, observed_at) do
    parse_isolated_descriptor(%{"rate_limit" => rate_limit}, observed_at, fn window ->
      account_window?(window)
    end)
  end

  defp parsed_descriptor_windows(:additional, {limit, _rate_limit}, observed_at) do
    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 60
        }
      },
      "additional_rate_limits" => [limit]
    }

    parse_isolated_descriptor(payload, observed_at, fn window ->
      not account_window?(window)
    end)
  end

  defp parse_isolated_descriptor(payload, observed_at, filter) do
    case Quota.Windows.codex_usage_quota_windows_from_payload(payload, observed_at) do
      {:ok, windows} -> Enum.filter(windows, filter)
      {:error, _reason} -> []
    end
  end

  defp safely_parsed_descriptor?(descriptor, parsed_windows) do
    supported = present_supported_windows(descriptor)

    supported != [] and parsed_windows != [] and
      Enum.all?(supported, fn {_field, window} -> valid_supported_window?(window) end)
  end

  defp present_supported_windows({limit, rate_limit}) when is_map(limit),
    do: present_supported_windows(rate_limit)

  # While the provider's anchored 5h windows are suspended (announced as
  # temporary on 2026-07-13), the usage payload declares the missing window as
  # an explicit `"secondary_window" => null` alongside the weekly
  # `primary_window`. A declared-null window is an explicit absence — there is
  # nothing to parse and nothing that can be mis-parsed — so it must not veto
  # coverage of the sibling windows that did parse. Malformed non-null windows
  # still fail validation and cover nothing, and if the 5h windows return both
  # windows are non-null maps and validate exactly as before.
  defp present_supported_windows(rate_limit) when is_map(rate_limit) do
    for field <- ~w(primary_window primary secondary_window secondary),
        not is_nil(Map.get(rate_limit, field)),
        do: {field, Map.get(rate_limit, field)}
  end

  defp valid_supported_window?(%{} = window) do
    isolated_rate_limit = %{"primary_window" => window}
    parsed_descriptor_windows(:account, isolated_rate_limit, now()) != []
  end

  defp valid_supported_window?(_window), do: false

  # Only a reset-bearing 5h account primary window halts multi-path probing.
  # A weekly-primary result must NOT halt: paths can diverge, and a later path
  # may still report the 5h window when an earlier one has gone weekly-only,
  # so the probe keeps walking every path and merges the results.
  defp account_primary_usage_window?(windows) when is_list(windows) do
    Enum.any?(windows, fn window ->
      account_window?(window) and
        Map.get(window, :window_kind) == "primary" and Map.get(window, :window_minutes) == 300 and
        match?(%DateTime{}, Map.get(window, :reset_at))
    end)
  end

  defp account_window?(window) when is_map(window) do
    Map.get(window, :quota_scope) == "account" and
      Map.get(window, :quota_family) == "account" and
      Map.get(window, :quota_key) == @account_quota_key
  end

  defp account_window?(_window), do: false

  defp usage_headers(access_token, chatgpt_account_id) do
    headers = [{"authorization", "Bearer " <> String.trim(access_token)}]

    if account_scope = UpstreamIdentity.account_scope(chatgpt_account_id) do
      headers ++
        [
          {"chatgpt-account-id", account_scope}
        ]
    else
      headers
    end
  end

  defp access_token_refresh_due_after_usage_auth_failure?(
         %UpstreamIdentity{} = identity,
         %DateTime{} = observed_at
       ) do
    refresh_at = DateTime.add(observed_at, @usage_auth_refresh_skew_seconds, :second)

    identity.metadata
    |> TokenRefreshMetadata.project_access_token_expiry()
    |> AccessTokenExpiry.evaluate(refresh_at)
    |> Map.fetch!(:state)
    |> then(&(&1 in [:expired, :unknown]))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp retry_observed_at(opts) do
    case Keyword.get(opts, :retry_observed_at) do
      %DateTime{} = observed_at -> observed_at
      _missing -> now()
    end
  end
end
