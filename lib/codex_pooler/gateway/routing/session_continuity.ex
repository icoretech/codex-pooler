defmodule CodexPooler.Gateway.Routing.SessionContinuity do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Transport
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: ContinuityStore
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type auth :: CodexPooler.Access.auth_context()
  @type payload :: map()
  @type reserved_request :: %{required(:request) => Request.t(), optional(atom()) => term()}
  @type metadata :: %{optional(String.t()) => term()}
  @type gateway_error :: Contracts.gateway_error()

  @spec attach_codex_session(auth(), payload(), RequestOptions.t()) ::
          {:ok, RequestOptions.t()} | {:error, gateway_error()}
  def attach_codex_session(
        auth,
        payload,
        %RequestOptions{continuity: %{codex_session: %CodexSession{id: session_id}}} =
          request_options
      ) do
    request_options = ContinuityPayload.put_previous_response_id(request_options, payload)

    case start_previous_response_codex_session(auth, request_options) do
      {:ok, %CodexSession{} = session} ->
        {:ok, RequestOptions.put_continuity(request_options, codex_session: session)}

      {:error, :session_not_found} ->
        attach_existing_codex_session(session_id, request_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def attach_codex_session(auth, payload, %RequestOptions{} = request_options) do
    request_options = ContinuityPayload.put_previous_response_id(request_options, payload)

    if continuity_session_requested?(request_options) do
      with {:ok, session} <- ContinuityStore.start_codex_session(auth, request_options) do
        {:ok, RequestOptions.put_continuity(request_options, codex_session: session)}
      end
    else
      {:ok, request_options}
    end
  end

  defp start_previous_response_codex_session(auth, %RequestOptions{} = request_options) do
    if previous_response_id?(request_options) do
      ContinuityStore.start_codex_session_from_previous_response_id(auth, request_options)
    else
      {:error, :session_not_found}
    end
  end

  defp attach_existing_codex_session(session_id, request_options) do
    case Repo.get(CodexSession, session_id) do
      %CodexSession{} = session ->
        {:ok, RequestOptions.put_continuity(request_options, codex_session: session)}

      nil ->
        {:ok, request_options}
    end
  end

  @spec attach_file_affinity(auth(), String.t(), payload(), RequestOptions.t()) ::
          {:ok, RequestOptions.t()} | {:error, gateway_error()}
  def attach_file_affinity(auth, "/backend-api/codex/responses", payload, request_options) do
    case response_file_ids(payload) do
      [] ->
        {:ok, request_options}

      file_ids ->
        request_options = ContinuityPayload.put_previous_response_id(request_options, payload)

        with {:ok, affinities} <- Files.response_assignment_affinities(auth, file_ids),
             {:ok, assignment_id} <- single_file_assignment_id(affinities),
             :ok <- ensure_file_affinity_matches_session(auth, request_options, assignment_id) do
          {:ok,
           RequestOptions.put_routing(request_options, file_affinity_assignment_id: assignment_id)}
        end
    end
  end

  def attach_file_affinity(_auth, _endpoint, _payload, %RequestOptions{} = request_options),
    do: {:ok, request_options}

  @spec ensure_unique_turn(RequestOptions.t()) :: :ok | {:error, gateway_error()}
  def ensure_unique_turn(%RequestOptions{
        continuity: %{codex_session: %CodexSession{} = session, codex_turn_id: turn_id}
      })
      when is_binary(turn_id) do
    if ContinuityStore.duplicate_codex_turn?(session, turn_id) do
      {:error,
       error(
         409,
         "duplicate_turn",
         "duplicate Codex turn was already recorded for this session",
         "request_id"
       )}
    else
      :ok
    end
  end

  def ensure_unique_turn(%RequestOptions{}), do: :ok

  @spec start_turn(reserved_request(), RequestOptions.t()) ::
          {:ok, reserved_request()} | {:error, term()}
  def start_turn(
        reserved,
        %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} = request_options
      ) do
    with {:ok, turn} <-
           ContinuityStore.start_codex_turn(session, reserved.request, request_options) do
      {:ok, Map.put(reserved, :codex_turn, turn)}
    end
  end

  def start_turn(reserved, %RequestOptions{}), do: {:ok, reserved}

  @spec put_session_metadata(metadata(), RequestOptions.t()) :: metadata()
  def put_session_metadata(
        metadata,
        %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}}
      ) do
    metadata
    |> Map.put("codex_session_id", session.id)
    |> Map.put("codex_session_key", session.session_key)
  end

  def put_session_metadata(metadata, %RequestOptions{}), do: metadata

  @spec websocket_turn_id(payload()) :: String.t() | nil
  def websocket_turn_id(payload) when is_map(payload) do
    payload
    |> Map.get("turn_id")
    |> Kernel.||(Map.get(payload, :turn_id))
    |> Kernel.||(Map.get(payload, "request_id"))
    |> Kernel.||(Map.get(payload, :request_id))
    |> clean_string()
  end

  def websocket_turn_id(_payload), do: nil

  @spec filter_file_affinity([BridgeRing.candidate()], RequestOptions.t()) ::
          {:ok, [BridgeRing.candidate()]} | {:error, gateway_error()}
  def filter_file_affinity(
        candidates,
        %RequestOptions{routing: %{file_affinity_assignment_id: assignment_id}}
      )
      when is_binary(assignment_id) do
    candidates =
      Enum.filter(candidates, fn {assignment, _identity} -> assignment.id == assignment_id end)

    if candidates == [] do
      {:error,
       error(
         409,
         "file_assignment_conflict",
         "referenced file cannot be used with this model routing assignment",
         "file_id"
       )}
    else
      {:ok, candidates}
    end
  end

  def filter_file_affinity(candidates, %RequestOptions{}), do: {:ok, candidates}

  @spec apply_codex_session_assignment([BridgeRing.candidate()], RequestOptions.t(), Model.t()) ::
          {:ok, [BridgeRing.candidate()]} | {:error, gateway_error()}
  def apply_codex_session_assignment(
        candidates,
        %RequestOptions{
          continuity: %{codex_session: %CodexSession{pool_upstream_assignment_id: assignment_id}}
        } = request_options,
        %Model{} = model
      )
      when is_binary(assignment_id) do
    if hard_pin_codex_session_assignment?(request_options, model) do
      filter_codex_session_assignment(candidates, request_options)
    else
      {:ok, prefer_codex_session_assignment(candidates, assignment_id)}
    end
  end

  def apply_codex_session_assignment(candidates, %RequestOptions{} = request_options, %Model{}),
    do: filter_codex_session_assignment(candidates, request_options)

  @spec filter_codex_session_assignment([BridgeRing.candidate()], RequestOptions.t(), Model.t()) ::
          {:ok, [BridgeRing.candidate()]} | {:error, gateway_error()}
  def filter_codex_session_assignment(
        candidates,
        %RequestOptions{} = request_options,
        %Model{} = model
      ),
      do: apply_codex_session_assignment(candidates, request_options, model)

  @spec filter_codex_session_assignment([BridgeRing.candidate()], RequestOptions.t()) ::
          {:ok, [BridgeRing.candidate()]} | {:error, gateway_error()}
  def filter_codex_session_assignment(
        candidates,
        %RequestOptions{
          continuity: %{codex_session: %CodexSession{pool_upstream_assignment_id: assignment_id}}
        }
      )
      when is_binary(assignment_id) do
    candidates =
      Enum.filter(candidates, fn {assignment, _identity} -> assignment.id == assignment_id end)

    if candidates == [] do
      {:error, pinned_session_assignment_unavailable_error(assignment_id)}
    else
      {:ok, candidates}
    end
  end

  def filter_codex_session_assignment(candidates, %RequestOptions{}), do: {:ok, candidates}

  @type pin_mode :: :hard | :soft
  @type pin_reason ::
          :previous_response_id
          | :file_affinity
          | :live_upstream_websocket
          | :local_session_header
          | :accepted_turn_state
          | :same_model_successful_turn
          | :codex_session_assignment

  @spec hard_pin_codex_session_assignment?(RequestOptions.t(), Model.t()) :: boolean()
  defp hard_pin_codex_session_assignment?(%RequestOptions{} = request_options, %Model{} = model) do
    match?({:hard, _reason}, classify_codex_session_pin(request_options, model))
  end

  @spec classify_codex_session_pin(RequestOptions.t(), Model.t()) :: {pin_mode(), pin_reason()}
  defp classify_codex_session_pin(%RequestOptions{} = request_options, %Model{} = model) do
    cond do
      previous_response_id?(request_options) ->
        {:hard, :previous_response_id}

      file_affinity?(request_options) ->
        {:hard, :file_affinity}

      live_upstream_websocket_continuity?(request_options) ->
        {:hard, :live_upstream_websocket}

      local_session_header?(request_options) ->
        {:soft, :local_session_header}

      accepted_turn_state?(request_options) ->
        {:soft, :accepted_turn_state}

      same_model_successful_turn?(request_options, model) ->
        {:soft, :same_model_successful_turn}

      true ->
        {:soft, :codex_session_assignment}
    end
  end

  @spec previous_response_id?(RequestOptions.t()) :: boolean()
  defp previous_response_id?(%RequestOptions{
         continuity: %{previous_response_id: previous_response_id}
       }),
       do: is_binary(clean_string(previous_response_id))

  @spec accepted_turn_state?(RequestOptions.t()) :: boolean()
  defp accepted_turn_state?(%RequestOptions{
         continuity: %{accepted_turn_state: accepted_turn_state}
       }),
       do: is_binary(clean_string(accepted_turn_state))

  @spec local_session_header?(RequestOptions.t()) :: boolean()
  defp local_session_header?(%RequestOptions{continuity: continuity}) do
    is_binary(clean_string(continuity.session_header)) and
      is_binary(clean_string(continuity.session_header_source))
  end

  @spec file_affinity?(RequestOptions.t()) :: boolean()
  defp file_affinity?(%RequestOptions{routing: %{file_affinity_assignment_id: assignment_id}}),
    do: is_binary(clean_string(assignment_id))

  @spec live_upstream_websocket_continuity?(RequestOptions.t()) :: boolean()
  defp live_upstream_websocket_continuity?(%RequestOptions{transport: transport}) do
    live_direct_upstream_websocket?(transport.upstream_websocket_session) or
      live_owner_forwarded_websocket?(transport)
  end

  @spec live_direct_upstream_websocket?(term()) :: boolean()
  defp live_direct_upstream_websocket?(pid), do: is_pid(pid)

  @spec live_owner_forwarded_websocket?(Transport.t()) :: boolean()
  defp live_owner_forwarded_websocket?(transport) do
    transport.websocket_owner_forwarding_enabled? == true and
      match?(%CodexSession{}, transport.websocket_owner_session) and
      is_binary(clean_string(transport.websocket_owner_lease_token)) and
      websocket_owner_downstream?(transport.websocket_owner_downstream)
  end

  @spec websocket_owner_downstream?(term()) :: boolean()
  defp websocket_owner_downstream?(%{pid: pid, correlation_id: correlation_id}),
    do: is_pid(pid) and is_binary(clean_string(correlation_id))

  defp websocket_owner_downstream?(_downstream), do: false

  @spec same_model_successful_turn?(RequestOptions.t(), Model.t()) :: boolean()
  defp same_model_successful_turn?(
         %RequestOptions{continuity: %{codex_session: %CodexSession{id: session_id}}} =
           request_options,
         %Model{} = model
       )
       when is_binary(session_id) do
    case requested_model_identifier(request_options, model) do
      requested_model when is_binary(requested_model) ->
        Repo.exists?(
          from turn in CodexTurn,
            join: request in Request,
            on: request.id == turn.request_id,
            where:
              turn.codex_session_id == ^session_id and
                turn.status == ^CodexTurn.succeeded_status() and
                request.status == "succeeded" and
                request.requested_model == ^requested_model
        )

      nil ->
        false
    end
  end

  defp same_model_successful_turn?(%RequestOptions{}, %Model{}), do: false

  @spec requested_model_identifier(RequestOptions.t(), Model.t()) :: String.t() | nil
  defp requested_model_identifier(
         %RequestOptions{routing: %{requested_model: requested_model}},
         %Model{exposed_model_id: exposed_model_id}
       ) do
    clean_string(requested_model) || clean_string(exposed_model_id)
  end

  @spec prefer_codex_session_assignment([BridgeRing.candidate()], Ecto.UUID.t() | String.t()) ::
          [BridgeRing.candidate()]
  defp prefer_codex_session_assignment(candidates, assignment_id) do
    {pinned, fallback} =
      Enum.split_with(candidates, fn {assignment, _identity} -> assignment.id == assignment_id end)

    pinned ++ fallback
  end

  @spec pinned_session_assignment_unavailable_error(Ecto.UUID.t() | String.t()) :: gateway_error()
  defp pinned_session_assignment_unavailable_error(assignment_id) do
    case persisted_pinned_reauth_assignment(assignment_id) do
      {:ok, %PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity, reason_code} ->
        Contracts.pinned_continuation_reauth_required_error()
        |> Map.put(:param, "model")
        |> Map.put(
          :continuity_denial,
          pinned_reauth_continuity_metadata(assignment, identity, reason_code)
        )

      :error ->
        session_assignment_unavailable_error()
    end
  end

  @spec persisted_pinned_reauth_assignment(Ecto.UUID.t() | String.t()) ::
          {:ok, PoolUpstreamAssignment.t(), UpstreamIdentity.t(), String.t()} | :error
  defp persisted_pinned_reauth_assignment(assignment_id) when is_binary(assignment_id) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             join: identity in UpstreamIdentity,
             on: identity.id == assignment.upstream_identity_id,
             where: assignment.id == ^assignment_id,
             select: {assignment, identity}
         ) do
      {%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity} ->
        if revoked_refresh_token_pinned_reauth?(assignment, identity) do
          {:ok, assignment, identity, "refresh_token_revoked"}
        else
          :error
        end

      nil ->
        :error
    end
  end

  @spec revoked_refresh_token_pinned_reauth?(PoolUpstreamAssignment.t(), UpstreamIdentity.t()) ::
          boolean()
  defp revoked_refresh_token_pinned_reauth?(assignment, identity) do
    assignment.status == PoolUpstreamAssignment.active_status() and
      assignment.health_status == PoolUpstreamAssignment.disabled_health_status() and
      assignment.eligibility_status == PoolUpstreamAssignment.ineligible_status() and
      identity.status == UpstreamIdentity.reauth_required_status() and
      token_refresh_reason_code(identity.metadata) == "refresh_token_revoked"
  end

  @spec token_refresh_reason_code(term()) :: String.t() | nil
  defp token_refresh_reason_code(%{
         "token_refresh" => %{
           "status" => "reauth_required",
           "reason" => %{"code" => reason_code}
         }
       })
       when is_binary(reason_code),
       do: reason_code

  defp token_refresh_reason_code(_metadata), do: nil

  @spec pinned_reauth_continuity_metadata(
          PoolUpstreamAssignment.t(),
          UpstreamIdentity.t(),
          String.t()
        ) :: map()
  defp pinned_reauth_continuity_metadata(assignment, identity, reason_code) do
    %{
      "denial_family" => "pinned_continuation_reauth",
      "continuity_family" => "pinned_codex_session",
      "upstream_lifecycle_family" => "reauth_required",
      "token_refresh_reason_code_preview" => reason_code,
      "pool_upstream_assignment_id" => assignment.id,
      "upstream_identity_id" => identity.id
    }
  end

  @spec session_assignment_unavailable_error() :: gateway_error()
  defp session_assignment_unavailable_error do
    error(
      503,
      "session_assignment_unavailable",
      "the upstream assignment for this Codex session is not currently available",
      "model"
    )
  end

  defp continuity_session_requested?(%RequestOptions{continuity: continuity}) do
    [
      continuity.accepted_turn_state,
      continuity.previous_response_id,
      continuity.session_header
    ]
    |> Enum.any?(&clean_string/1)
  end

  defp response_file_ids(payload) do
    payload
    |> Map.get("input")
    |> collect_input_file_ids()
    |> Enum.uniq()
  end

  defp collect_input_file_ids(%{} = value) do
    value = Map.new(value, fn {key, item_value} -> {to_string(key), item_value} end)

    file_ids =
      case value do
        %{"type" => "input_file", "file_id" => file_id} when is_binary(file_id) ->
          [String.trim(file_id)]

        _value ->
          []
      end

    nested_ids = value |> Map.values() |> Enum.flat_map(&collect_input_file_ids/1)
    Enum.reject(file_ids ++ nested_ids, &(&1 == ""))
  end

  defp collect_input_file_ids(values) when is_list(values) do
    Enum.flat_map(values, &collect_input_file_ids/1)
  end

  defp collect_input_file_ids(_value), do: []

  defp ensure_file_affinity_matches_session(auth, opts, file_assignment_id)
       when is_binary(file_assignment_id) do
    case existing_codex_session_assignment_id(auth, opts) do
      assignment_id when assignment_id in [nil, file_assignment_id] ->
        :ok

      _other_assignment_id ->
        {:error,
         error(
           409,
           "file_assignment_conflict",
           "referenced file conflicts with existing session routing assignment",
           "file_id"
         )}
    end
  end

  defp existing_codex_session_assignment_id(
         _auth,
         %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}}
       ) do
    clean_string(session.pool_upstream_assignment_id)
  end

  defp existing_codex_session_assignment_id(
         %{pool: pool, api_key: api_key},
         %RequestOptions{} = request_options
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    request_options
    |> codex_session_affinity_aliases()
    |> Enum.find_value(fn {kind, value} ->
      alias_hash = :crypto.hash(:sha256, value)

      Repo.one(
        from session in CodexSession,
          join: alias_record in BridgeSessionAlias,
          on: alias_record.codex_session_id == session.id,
          where:
            alias_record.pool_id == ^pool.id and alias_record.api_key_id == ^api_key.id and
              alias_record.alias_kind == ^kind and alias_record.alias_hash == ^alias_hash and
              alias_record.status == "active" and alias_record.expires_at > ^now and
              session.status in ^["active", "interrupted"] and
              session.owner_lease_expires_at > ^now,
          order_by: [desc: alias_record.last_seen_at, desc: alias_record.updated_at],
          limit: 1,
          select: session.pool_upstream_assignment_id
      )
      |> clean_string()
    end)
  end

  defp codex_session_affinity_aliases(%RequestOptions{continuity: continuity}) do
    opts = %{
      accepted_turn_state: continuity.accepted_turn_state,
      previous_response_id: continuity.previous_response_id,
      session_header: continuity.session_header
    }

    [
      {"turn_state", Map.get(opts, :accepted_turn_state)},
      {"previous_response_id", Map.get(opts, :previous_response_id)},
      {"session_header", Map.get(opts, :session_header)}
    ]
    |> Enum.map(fn {kind, value} -> {kind, clean_string(value)} end)
    |> Enum.reject(fn {_kind, value} -> is_nil(value) end)
    |> Enum.uniq()
  end

  defp single_file_assignment_id(affinities) do
    assignment_ids = affinities |> Map.values() |> Enum.uniq()

    case assignment_ids do
      [assignment_id] when is_binary(assignment_id) ->
        {:ok, assignment_id}

      _conflicting ->
        {:error,
         error(
           409,
           "file_assignment_conflict",
           "referenced files belong to different upstream assignments",
           "file_id"
         )}
    end
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp error(status, code, message, param) do
    %{status: status, code: code, message: message, param: param}
  end
end
