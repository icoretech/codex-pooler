defmodule CodexPooler.Accounting.Metadata do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Request, RequestLogFacts}
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_eligible PoolUpstreamAssignment.eligible_status()
  @usage_not_applicable "not_applicable"
  @redacted "[REDACTED]"
  @sensitive_key_fragments ~w(api_key apikey authorization bearer token access_token refresh_token upstream_token upstream_secret cookie set-cookie secret password prompt messages input output completion content raw_request raw_response body payload file filename audio image transcript transcription upload_url download_url sas_url signed_url auth_json chatgpt_account_id)
  @sensitive_exact_keys MapSet.new([
                          "analytics",
                          "arc",
                          "idempotency_key",
                          "previous_response_id",
                          "sdp",
                          "trace",
                          "websocket_frame"
                        ])
  @safe_sensitive_exact_keys MapSet.new([
                               "api_key_id",
                               "payload_compression",
                               "reservation_snapshot_inputs",
                               "token_refresh_reason_code_preview"
                             ])
  @safe_control_plane_keys MapSet.new(["analytics_forwarding"])
  @payload_compression_statuses ~w(disabled ineligible compressed no_change skipped error_passthrough)
  @payload_compression_reasons ~w(
                                  pool_disabled
                                  route_ineligible
                                  transport_ineligible
                                  payload_kind_ineligible
                                  invalid_json
                                  no_candidates
                                  no_rewrites
                                  below_min_bytes
                                  scanner_error
                                  strategy_unavailable
                                  tokenizer_unavailable
                                  token_count_failed
                                  tokenizer_input_limit
                                  no_token_shrink
                                  over_body_limit
                                  over_candidate_limit
                                  compression_error
                                  native_load_failed
                                  rewritten
                                )
  @payload_compression_strategy_names ~w(
                                         diff
                                         json_array_lossless
                                         log_output
                                         search_results
                                       )
  @payload_compression_bool_keys MapSet.new(~w(attempted enabled))
  @payload_compression_integer_keys MapSet.new(~w(
                                      candidate_count
                                      compressed_bytes
                                      compressed_count
                                      compressed_tokens
                                      elapsed_ms
                                      original_bytes
                                      original_tokens
                                      saved_bytes
                                      saved_tokens
                                      skipped_count
                                      tokenizer_input_skipped_count
                                    ))
  @payload_compression_number_keys MapSet.new(~w(
                                     byte_savings_percent
                                     byte_savings_ratio
                                     compression_ratio
                                     token_savings_percent
                                     token_savings_ratio
                                   ))
  @payload_compression_identifier_keys MapSet.new(~w(route_class tokenizer transport))
  @safe_payload_compression_value ~r/\A[a-zA-Z0-9_.:-]+\z/
  @safe_payload_compression_keys MapSet.new(~w(
                                    attempted
                                    byte_savings_percent
                                    byte_savings_ratio
                                    candidate_count
                                    compressed_bytes
                                    compressed_count
                                    compressed_tokens
                                    compression_ratio
                                    elapsed_ms
                                    enabled
                                    original_bytes
                                    original_tokens
                                    reason
                                    route_class
                                    saved_bytes
                                    saved_tokens
                                    skipped_count
                                    status
                                    strategies
                                    token_savings_percent
                                    token_savings_ratio
                                    tokenizer_input_skipped_count
                                    tokenizer
                                    transport
                                  ))

  @type accounting_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type request_result_row :: %{required(:request) => Request.t(), optional(atom()) => term()}
  @type request_result :: {:ok, request_result_row()} | {:error, accounting_error()}

  @spec record_metadata_request(term(), map()) :: request_result()
  def record_metadata_request(auth, attrs \\ %{})

  def record_metadata_request(%{pool: pool, api_key: api_key} = auth, attrs) when is_map(attrs) do
    timestamp = now(attrs)
    endpoint = attr(attrs, :endpoint)
    transport = attr(attrs, :transport) || "http_json"
    status = attr(attrs, :status) || "succeeded"

    Repo.transaction(fn ->
      request =
        %Request{
          pool_id: pool.id,
          api_key_id: api_key.id,
          requested_model: blank_to_nil(attr(attrs, :requested_model)) || endpoint,
          endpoint: endpoint,
          transport: transport,
          status: status,
          usage_status: @usage_not_applicable,
          correlation_id: attr(attrs, :correlation_id) || Ecto.UUID.generate(),
          idempotency_key: nil,
          client_ip: blank_to_nil(attr(attrs, :client_ip)),
          user_agent: blank_to_nil(attr(attrs, :user_agent)),
          request_metadata:
            metadata_request_metadata(auth, attr(attrs, :request_metadata) || %{}),
          admitted_at: timestamp,
          completed_at: timestamp,
          response_status_code: attr(attrs, :response_status_code),
          retry_count: attr(attrs, :retry_count) || 0,
          last_error_code: attr(attrs, :last_error_code),
          upstream_account_label: metadata_identity_label(attrs),
          upstream_account_email: metadata_identity_email(attrs),
          upstream_account_plan_label: metadata_identity_plan_label(attrs),
          upstream_account_plan_family: metadata_identity_plan_family(attrs)
        }
        |> Repo.insert!()

      RequestLogFacts.record_request_created!(request)

      %{request: request}
    end)
    |> unwrap_transaction()
    |> tap_request_log_event("request_log_created")
  end

  def record_metadata_request(_auth, _attrs),
    do:
      {:error, accounting_error(:invalid_request, "authenticated pool and api key are required")}

  @spec record_upstream_identity_metadata_request(UpstreamIdentity.t(), map()) :: request_result()
  def record_upstream_identity_metadata_request(identity, attrs \\ %{})

  def record_upstream_identity_metadata_request(%UpstreamIdentity{} = identity, attrs)
      when is_map(attrs) do
    case metadata_assignment_for_identity(identity) do
      %PoolUpstreamAssignment{} = assignment ->
        do_record_upstream_identity_metadata_request(identity, assignment, attrs)

      nil ->
        {:error, accounting_error(:pool_assignment_not_found, "pool assignment was not found")}
    end
  end

  def record_upstream_identity_metadata_request(_identity, _attrs),
    do: {:error, accounting_error(:invalid_request, "upstream identity is required")}

  @spec accumulate_request_metadata(Request.t(), map()) :: {:ok, Request.t()} | {:error, term()}
  def accumulate_request_metadata(%Request{} = request, metadata) when is_map(metadata) do
    {:ok, put_sanitized_request_metadata(request, metadata)}
  end

  def accumulate_request_metadata(_request, _metadata), do: {:error, :invalid_request}

  @spec persist_request_metadata(Request.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def persist_request_metadata(request, opts \\ [])

  def persist_request_metadata(%Request{} = request, opts) when is_list(opts) do
    persisted = persisted_request(request, opts)

    merged =
      deep_merge(
        persisted.request_metadata || %{},
        sanitize_metadata(request.request_metadata || %{})
      )

    persisted
    |> Ecto.Changeset.change(%{request_metadata: merged})
    |> Repo.update()
  end

  def persist_request_metadata(_request, _opts), do: {:error, :invalid_request}

  @spec merge_request_metadata(Request.t(), map(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def merge_request_metadata(request, metadata, opts \\ [])

  def merge_request_metadata(%Request{} = request, metadata, opts)
      when is_map(metadata) and is_list(opts) do
    request
    |> put_sanitized_request_metadata(metadata)
    |> persist_request_metadata(opts)
  end

  def merge_request_metadata(_request, _metadata, _opts), do: {:error, :invalid_request}

  @spec sanitize_metadata(term()) :: term()
  def sanitize_metadata(value), do: sanitize_value(value, nil)

  @spec accounting_error(atom(), String.t()) :: accounting_error()
  def accounting_error(code, message), do: %{code: code, message: message}

  defp do_record_upstream_identity_metadata_request(identity, assignment, attrs) do
    timestamp = now(attrs)
    endpoint = attr(attrs, :endpoint)
    transport = attr(attrs, :transport) || "http_json"
    status = attr(attrs, :status) || "succeeded"

    Repo.transaction(fn ->
      request =
        %Request{
          pool_id: assignment.pool_id,
          api_key_id: nil,
          requested_model: blank_to_nil(attr(attrs, :requested_model)) || endpoint,
          endpoint: endpoint,
          transport: transport,
          status: status,
          usage_status: @usage_not_applicable,
          correlation_id: attr(attrs, :correlation_id) || Ecto.UUID.generate(),
          idempotency_key: nil,
          client_ip: blank_to_nil(attr(attrs, :client_ip)),
          user_agent: blank_to_nil(attr(attrs, :user_agent)),
          request_metadata:
            identity_metadata_request_metadata(identity, attr(attrs, :request_metadata) || %{}),
          admitted_at: timestamp,
          completed_at: timestamp,
          response_status_code: attr(attrs, :response_status_code),
          retry_count: attr(attrs, :retry_count) || 0,
          last_error_code: attr(attrs, :last_error_code),
          upstream_account_label: identity.account_label,
          upstream_account_email: identity_account_email(identity),
          upstream_account_plan_label: identity.plan_label,
          upstream_account_plan_family: identity.plan_family
        }
        |> Repo.insert!()

      RequestLogFacts.record_request_created!(request)

      %{request: request}
    end)
    |> unwrap_transaction()
    |> tap_request_log_event("request_log_created")
  end

  defp put_sanitized_request_metadata(%Request{} = request, metadata) do
    %{
      request
      | request_metadata: deep_merge(request.request_metadata || %{}, sanitize_metadata(metadata))
    }
  end

  defp persisted_request(%Request{} = request, opts) do
    if Keyword.get(opts, :reload?, true) do
      Repo.get(Request, request.id) || request
    else
      request
    end
  end

  defp metadata_request_metadata(auth, metadata) do
    metadata
    |> sanitize_metadata()
    |> Map.merge(%{"api_key" => %{"id" => auth.api_key.id, "prefix" => auth.api_key.key_prefix}})
  end

  defp metadata_identity_label(attrs) do
    case attr(attrs, :upstream_identity) do
      %UpstreamIdentity{} = identity ->
        identity.account_label

      _value ->
        blank_to_nil(attr(attrs, :upstream_account_label)) || metadata_identity_email(attrs)
    end
  end

  defp metadata_identity_email(attrs) do
    case attr(attrs, :upstream_identity) do
      %UpstreamIdentity{} = identity -> identity_account_email(identity)
      _value -> attr(attrs, :upstream_account_email) |> blank_to_nil() |> email_label_or_nil()
    end
  end

  defp metadata_identity_plan_label(attrs) do
    case attr(attrs, :upstream_identity) do
      %UpstreamIdentity{} = identity -> identity.plan_label
      _value -> blank_to_nil(attr(attrs, :upstream_account_plan_label))
    end
  end

  defp identity_account_email(%UpstreamIdentity{} = identity) do
    identity.account_email
    |> blank_to_nil()
    |> email_label_or_nil()
  end

  defp metadata_identity_plan_family(attrs) do
    case attr(attrs, :upstream_identity) do
      %UpstreamIdentity{} = identity -> identity.plan_family
      _value -> blank_to_nil(attr(attrs, :upstream_account_plan_family))
    end
  end

  defp identity_metadata_request_metadata(%UpstreamIdentity{} = identity, metadata) do
    metadata
    |> sanitize_metadata()
    |> Map.merge(%{
      "auth_mode" => "chatgpt_account_token",
      "upstream_identity" => %{
        "id" => identity.id,
        "label" => identity.account_label,
        "plan_family" => identity.plan_family,
        "plan_label" => identity.plan_label
      }
    })
  end

  defp metadata_assignment_for_identity(%UpstreamIdentity{id: identity_id}) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status == ^@assignment_active and
            assignment.eligibility_status == ^@assignment_eligible,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        limit: 1
    )
  end

  defp tap_request_log_event({:ok, %{request: request}} = result, reason) do
    Events.broadcast_request_logs(request.pool_id, reason, %{
      request_id: request.id,
      status: request.status
    })

    result
  end

  defp tap_request_log_event(result, _reason), do: result

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp sanitize_value(value, key) when is_map(value) do
    normalized = normalize_key(key)

    cond do
      normalized == "payload_compression" ->
        sanitize_payload_compression_map(value)

      sensitive_key?(normalized) ->
        @redacted

      normalized == "control_plane" ->
        sanitize_control_plane_map(value)

      true ->
        Map.new(value, fn {child_key, child_value} ->
          {child_key, sanitize_value(child_value, child_key)}
        end)
    end
  end

  defp sanitize_value(value, key) when is_list(value) do
    if sensitive_key?(key) do
      @redacted
    else
      Enum.map(value, &sanitize_value(&1, key))
    end
  end

  defp sanitize_value(value, key) when is_binary(value) do
    cond do
      sensitive_key?(key) -> @redacted
      sensitive_binary?(value) -> @redacted
      true -> value
    end
  end

  defp sanitize_value(value, _key), do: value

  defp sanitize_control_plane_map(value) when is_map(value) do
    Map.new(value, fn {child_key, child_value} ->
      normalized = normalize_key(child_key)

      sanitized_value =
        if MapSet.member?(@safe_control_plane_keys, normalized) do
          sanitize_value(child_value, child_key)
        else
          @redacted
        end

      {child_key, sanitized_value}
    end)
  end

  defp sanitize_payload_compression_map(value) when is_map(value) do
    Map.new(value, fn {child_key, child_value} ->
      normalized = normalize_key(child_key)

      sanitized_value =
        if MapSet.member?(@safe_payload_compression_keys, normalized) do
          sanitize_payload_compression_value(normalized, child_value)
        else
          @redacted
        end

      {child_key, sanitized_value}
    end)
  end

  defp sanitize_payload_compression_value("status", value),
    do: allowed_payload_compression_value(value, @payload_compression_statuses)

  defp sanitize_payload_compression_value("reason", value),
    do: allowed_payload_compression_value(value, @payload_compression_reasons)

  defp sanitize_payload_compression_value("strategies", value)
       when is_list(value) do
    value
    |> Enum.map(&allowed_payload_compression_value(&1, @payload_compression_strategy_names))
    |> Enum.reject(&(is_nil(&1) or &1 == @redacted))
    |> Enum.take(12)
  end

  defp sanitize_payload_compression_value("strategies", nil), do: nil
  defp sanitize_payload_compression_value("strategies", _value), do: @redacted

  defp sanitize_payload_compression_value(key, value) do
    cond do
      MapSet.member?(@payload_compression_bool_keys, key) ->
        payload_compression_bool(value)

      MapSet.member?(@payload_compression_integer_keys, key) ->
        payload_compression_integer(value)

      MapSet.member?(@payload_compression_number_keys, key) ->
        payload_compression_number(value)

      MapSet.member?(@payload_compression_identifier_keys, key) ->
        safe_payload_compression_value(value)

      true ->
        @redacted
    end
  end

  defp payload_compression_bool(value) when is_boolean(value), do: value
  defp payload_compression_bool(nil), do: nil
  defp payload_compression_bool(_value), do: @redacted

  defp payload_compression_integer(value) when is_integer(value) and value >= 0, do: value
  defp payload_compression_integer(nil), do: nil
  defp payload_compression_integer(_value), do: @redacted

  defp payload_compression_number(value) when is_integer(value) and value >= 0, do: value
  defp payload_compression_number(value) when is_float(value) and value >= 0, do: value
  defp payload_compression_number(nil), do: nil
  defp payload_compression_number(_value), do: @redacted

  defp allowed_payload_compression_value(value, allowed_values) do
    case safe_payload_compression_value(value) do
      nil ->
        nil

      value when is_binary(value) ->
        if value in allowed_values, do: value, else: @redacted
    end
  end

  defp safe_payload_compression_value(nil), do: nil

  defp safe_payload_compression_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_payload_compression_value()

  defp safe_payload_compression_value(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 120)

    cond do
      value == "" -> nil
      sensitive_binary?(value) -> @redacted
      String.match?(value, @safe_payload_compression_value) -> value
      true -> @redacted
    end
  end

  defp safe_payload_compression_value(_value), do: @redacted

  defp sensitive_binary?(value) do
    String.match?(value, ~r/sk-cxp-[a-f0-9]{12}-[A-Za-z0-9_-]+/) or
      String.match?(value, ~r/(?i)bearer\s+[A-Za-z0-9._~+\/-]+=*/) or
      String.match?(value, ~r/\Ask-(?!cxp-[a-f0-9]{12}\z)[A-Za-z0-9_-]{24,}\z/)
  end

  defp sensitive_key?(nil), do: false

  defp sensitive_key?(key) do
    normalized = normalize_key(key)

    normalized not in ["content_type", "request_content_type", "response_content_type"] and
      not MapSet.member?(@safe_sensitive_exact_keys, normalized) and
      (MapSet.member?(@sensitive_exact_keys, normalized) or
         Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1)))
  end

  defp normalize_key(nil), do: nil

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp email_label_or_nil(label) when is_binary(label) do
    label = String.trim(label)
    if String.contains?(label, "@"), do: label, else: nil
  end

  defp email_label_or_nil(_label), do: nil

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp now(opts),
    do:
      Map.get(opts, :now) || Map.get(opts, "now") ||
        DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
end
