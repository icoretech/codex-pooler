defmodule CodexPooler.Accounting.NativeWebsocketSizeRecovery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Request, RequestLifecycle}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @limit 16_777_216
  @reason "native_websocket_message_too_large"
  @endpoint "/backend-api/codex/responses"
  @type marker :: %{
          String.t() => String.t() | pos_integer()
        }
  @type result :: {:ok, :native_websocket_size_recovery} | {:error, :storage_unavailable}
  @type lookup_result :: {:ok, boolean()} | {:error, :storage_unavailable}

  @spec marker(String.t(), pos_integer()) :: marker() | nil
  def marker(digest, bytes), do: sanitize(%{"version" => 1, "window_digest" => digest, "limit_bytes" => @limit, "message_bytes" => bytes, "serving_mode" => "full", "decision" => "preclaim"})

  @spec sanitize(term()) :: marker() | nil
  def sanitize(%{"version" => 1, "window_digest" => digest, "limit_bytes" => @limit, "message_bytes" => bytes, "serving_mode" => "full", "decision" => "preclaim"} = marker)
      when map_size(marker) == 6 and is_binary(digest) and is_integer(bytes) and bytes > @limit and bytes <= 9_223_372_036_854_775_807 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest), do: marker
  end

  def sanitize(_marker), do: nil

  @spec record(Access.auth_context(), CodexPooler.Accounting.model_ref(), map()) :: result()
  def record(auth, model, attrs) do
    # An inner transaction cannot acknowledge a commit controlled by its caller.
    if Repo.in_transaction?() do
      {:error, :storage_unavailable}
    else
      commit(auth, model, attrs)
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError, Ecto.InvalidChangesetError] -> {:error, :storage_unavailable}
  end

  defp commit(auth, model, attrs) do
    case Repo.transaction(fn -> record_locked(auth, model, attrs) end) do
      {:ok, :native_websocket_size_recovery} = confirmed -> confirmed
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  defp record_locked(auth, model, attrs) do
    with {:ok, authorization} <- Access.authorize_api_key_runtime_turn_for_read(auth.api_key, auth.api_key.runtime_revocation_epoch),
         true <- authorization.api_key.pool_id == auth.pool.id,
         marker when not is_nil(marker) <- sanitize(attrs.request_metadata["native_websocket_size_recovery"]),
         true <- attrs.endpoint == @endpoint and attrs.transport == "websocket" and not Map.has_key?(attrs, :turn_claim),
         {:ok, %{request: request}} <- RequestLifecycle.record_denied_request(auth, model, Map.put(attrs, :now, database_now())),
         %Request{} = persisted <- Repo.get(Request, request.id),
         true <- confirmed?(persisted, auth, marker, attrs) do
      :native_websocket_size_recovery
    else
      _unconfirmed -> Repo.rollback(:storage_unavailable)
    end
  end

  defp confirmed?(request, auth, marker, attrs) do
    expected = %{pool_id: auth.pool.id, api_key_id: auth.api_key.id, status: "rejected", usage_status: "not_applicable", last_error_code: @reason, transport: "websocket", endpoint: attrs.endpoint, correlation_id: attrs.correlation_id, response_status_code: 413}
    Map.take(request, Map.keys(expected)) == expected and request.request_metadata["native_websocket_size_recovery"] == marker
  end

  defp database_now, do: Repo.one!(from r in fragment("SELECT now() AT TIME ZONE 'UTC' AS value"), select: type(field(r, :value), :utc_datetime_usec))

  @spec recent(Access.auth_context(), String.t()) :: lookup_result()
  def recent(auth, digest) do
    if valid_digest?(digest) do
      {:ok, Repo.one(query(auth, digest)) == true}
    else
      {:ok, false}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :storage_unavailable}
  end

  @doc false
  @spec query(Access.auth_context(), String.t()) :: Ecto.Query.t()
  def query(%{pool: pool, api_key: key}, digest) do
    query =
      from r in Request,
        join: k in APIKey,
        on: k.id == r.api_key_id and k.pool_id == r.pool_id,
        join: p in Pool,
        on: p.id == k.pool_id,
        where: r.api_key_id == ^key.id and r.pool_id == ^pool.id,
        where: k.status == "active" and p.status == "active" and k.runtime_revocation_epoch == ^key.runtime_revocation_epoch,
        where: is_nil(k.expires_at) or k.expires_at > fragment("now()"),
        where: r.admitted_at > fragment("now() - interval '60 seconds'") and r.admitted_at <= fragment("now()")

    matching_marker(query, digest)
  end

  defp matching_marker(query, digest) do
    from r in query,
      where: r.endpoint == @endpoint and r.transport == "websocket" and r.status == "rejected" and r.usage_status == "not_applicable" and r.last_error_code == ^@reason,
      where: fragment("?->'native_websocket_size_recovery' = jsonb_build_object('version', 1, 'window_digest', ?::text, 'limit_bytes', 16777216, 'message_bytes', ?->'native_websocket_size_recovery'->'message_bytes', 'serving_mode', 'full', 'decision', 'preclaim')", r.request_metadata, ^digest, r.request_metadata),
      where: fragment("?->'native_websocket_size_recovery'->>'version' = '1' AND ?->'native_websocket_size_recovery'->>'limit_bytes' = '16777216'", r.request_metadata, r.request_metadata),
      where: fragment("jsonb_typeof(?->'native_websocket_size_recovery'->'message_bytes') = 'number'", r.request_metadata),
      where: fragment("CASE WHEN (?->'native_websocket_size_recovery'->>'message_bytes') ~ '^[0-9]{1,19}$' THEN (?->'native_websocket_size_recovery'->>'message_bytes')::numeric BETWEEN 16777217 AND 9223372036854775807 ELSE false END", r.request_metadata, r.request_metadata),
      limit: 1,
      select: true
  end

  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
end
