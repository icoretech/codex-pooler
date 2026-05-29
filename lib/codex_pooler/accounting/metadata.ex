defmodule CodexPooler.Accounting.Metadata do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.Request
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
  @safe_sensitive_exact_keys MapSet.new(["token_refresh_reason_code_preview"])
  @safe_control_plane_keys MapSet.new(["analytics_forwarding"])

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

  @spec merge_request_metadata(Request.t(), map()) :: {:ok, Request.t()} | {:error, term()}
  def merge_request_metadata(%Request{} = request, metadata) when is_map(metadata) do
    persisted = Repo.get(Request, request.id) || request
    merged = deep_merge(persisted.request_metadata || %{}, sanitize_metadata(metadata))

    persisted
    |> Ecto.Changeset.change(%{request_metadata: merged})
    |> Repo.update()
  end

  def merge_request_metadata(_request, _metadata), do: {:error, :invalid_request}

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

      %{request: request}
    end)
    |> unwrap_transaction()
    |> tap_request_log_event("request_log_created")
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
      String.match?(value, ~r/sk-cxp-[a-f0-9]{12}-[A-Za-z0-9_-]+/) -> @redacted
      String.match?(value, ~r/(?i)bearer\s+[A-Za-z0-9._~+\/-]+=*/) -> @redacted
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
