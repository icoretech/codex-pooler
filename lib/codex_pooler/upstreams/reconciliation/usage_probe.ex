defmodule CodexPooler.Upstreams.Reconciliation.UsageProbe do
  @moduledoc false

  alias CodexPooler.Jobs
  alias CodexPooler.Quotas.{AccountAvailability, Evidence}
  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Quotas.Evidence.Descriptors
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
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
            opts,
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
      case fetch(fenced_identity, assignment, access_token, observed_at, opts) do
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

    with {:ok, result} <- do_fetch(identity, assignment, access_token, observed_at, opts) do
      {:ok, %{result | credential_fence: fence}}
    end
  end

  defp do_fetch(%UpstreamIdentity{} = identity, assignment, access_token, observed_at, opts) do
    base =
      identity
      |> EndpointMetadata.usage_base_url(assignment)
      |> EndpointMetadata.normalize_base_url()

    timeout = Keyword.get(opts, :receive_timeout, 30_000)
    headers = usage_headers(access_token, identity.chatgpt_account_id)

    paths = usage_paths(identity, assignment)

    paths
    |> Enum.reduce_while({:error, :not_found}, fn path, last_result ->
      base
      |> usage_url(path)
      |> probe_usage_url(identity, headers, observed_at, timeout)
      |> reduce_usage_probe_result(last_result)
    end)
    |> finalize_usage_probe_result(paths)
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
      receive_timeout: timeout,
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
    case Jason.decode(body) do
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
         _retried_after_cookie?
       )
       when status in 200..299 do
    CloudflareCookies.store_from_response(url, response)

    case decode_usage_body(body) do
      {:ok, payload} -> usage_probe_success(payload, identity, url, observed_at, timeout, headers)
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
         _retried_after_cookie?
       ) do
    CloudflareCookies.store_from_response(url, response)
    {:continue_error, {:upstream_status, 429}}
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

  @spec decode_usage_body(term()) :: {:ok, map()} | :error
  defp decode_usage_body(%{} = payload), do: {:ok, payload}

  defp decode_usage_body(payload) when is_binary(payload) do
    case Jason.decode(payload) do
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
          [{String.t(), String.t()}]
        ) :: usage_probe_result()
  defp usage_probe_success(body, identity, url, observed_at, timeout, headers) do
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
            headers
          )

        {:ok,
         %Result{
           payload: body,
           usage_url: url,
           usage_path: URI.parse(url).path,
           windows: windows,
           account_availability: account_availability,
           observed_at: observed_at,
           covered_descriptors:
             covered_descriptors(body, windows, account_availability, observed_at)
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
                headers
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
        covered_descriptors:
          merge_covered_descriptors(previous, current, windows, account_availability)
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

  defp account_descriptor?(
         {"account", "account", _model, _upstream_model, @account_quota_key, _source,
          _raw_limit_id, _raw_limit_name, _raw_metered_feature}
       ),
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

  defp retry_observed_at(opts) do
    case Keyword.get(opts, :retry_observed_at) do
      %DateTime{} = observed_at -> observed_at
      _missing -> now()
    end
  end
end
