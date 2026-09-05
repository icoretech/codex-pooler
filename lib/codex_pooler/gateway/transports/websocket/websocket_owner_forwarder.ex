defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder do
  @moduledoc """
  Websocket owner forwarding primitive for owner-mode websocket topology.

  When owner forwarding is enabled, websocket runtime calls this module to route
  upstream-touching websocket requests through the process that owns the
  persisted Codex session lease. When the topology flag is disabled, the default
  local upstream websocket behavior remains active.
  """

  alias CodexPooler.Gateway.{OperationalSettings, OperationalStatus}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV4
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.Repo

  @restore_downstream_keys [:correlation_id, :epoch, :pid]
  @stable_downstream_keys [:active_turn_reconnect? | @restore_downstream_keys]
  @public_per_call_downstream_keys [:owner_turn_id | @stable_downstream_keys]

  @type owner_node :: node()
  @type owner_resolution :: {:local, binary()} | {:remote, owner_node(), binary()}

  @type submit_opts :: [
          timeout: pos_integer(),
          node_client: module(),
          app_node_names: [binary()],
          local_node_string: binary(),
          upstream: map(),
          request_id: binary(),
          request_timeout: pos_integer()
        ]
  @type submit_error ::
          WebsocketOwnerContract.owner_error() | UpstreamWebsocketSession.request_failure()
  @type request_result :: :ok | {:ok, term()} | {:error, submit_error()}
  @type submitted_request_result ::
          request_result() | {:websocket_owner_submission_accepted, request_result()}
  @type reconnect_action :: :preflight | :cancel
  @type reconnect_control :: %{
          required(:version) => 1,
          required(:action) => reconnect_action(),
          required(:codex_session_id) => binary(),
          required(:downstream) => WebsocketOwnerSession.downstream(),
          required(:semantic_turn_key) => <<_::256>>,
          required(:control_ref) => reference()
        }

  @spec submit_frame(
          CodexSession.t(),
          binary(),
          WebsocketOwnerSession.downstream(),
          binary(),
          submit_opts()
        ) ::
          :ok | {:ok, term()} | {:error, WebsocketOwnerContract.owner_error()}
  def submit_frame(%CodexSession{} = session, owner_lease_token, downstream, frame, opts \\ [])
      when is_binary(owner_lease_token) and is_map(downstream) and is_binary(frame) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_submit(owner, session.id, downstream, frame, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec submit_request(
          CodexSession.t(),
          binary(),
          WebsocketOwnerSession.downstream(),
          UpstreamWebsocketSession.Request.t()
          | WebsocketOwnerRequest.t()
          | WebsocketOwnerRequestV2.t()
          | WebsocketOwnerRequestV3.t()
          | WebsocketOwnerRequestV4.t()
          | WebsocketOwnerRequestV6.t()
          | WebsocketOwnerRequestV5.t(),
          submit_opts()
        ) ::
          submitted_request_result()
  def submit_request(
        %CodexSession{} = session,
        owner_lease_token,
        downstream,
        request,
        opts \\ []
      )
      when is_binary(owner_lease_token) and is_map(downstream) and
             is_struct(request) and
             request.__struct__ in [
               UpstreamWebsocketSession.Request,
               WebsocketOwnerRequest,
               WebsocketOwnerRequestV2,
               WebsocketOwnerRequestV3,
               WebsocketOwnerRequestV4,
               WebsocketOwnerRequestV5,
               WebsocketOwnerRequestV6
             ] do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      opts =
        if is_struct(request, WebsocketOwnerRequestV4) do
          Keyword.put(opts, :replay_owner_lease_token, owner_lease_token)
        else
          opts
        end

      dispatch_submit_request(owner, session.id, downstream, request, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reconnect_control(
          reconnect_action(),
          binary(),
          WebsocketOwnerSession.downstream(),
          <<_::256>>,
          reference()
        ) :: reconnect_control()
  def reconnect_control(action, codex_session_id, downstream, semantic_turn_key, control_ref)
      when action in [:preflight, :cancel] and is_binary(codex_session_id) and
             is_map(downstream) and is_binary(semantic_turn_key) and
             byte_size(semantic_turn_key) == 32 and is_reference(control_ref) do
    %{
      version: 1,
      action: action,
      codex_session_id: codex_session_id,
      downstream: Map.take(downstream, @restore_downstream_keys),
      semantic_turn_key: semantic_turn_key,
      control_ref: control_ref
    }
  end

  @spec preflight_reconnect(
          CodexSession.t(),
          binary(),
          WebsocketOwnerSession.downstream(),
          <<_::256>>,
          reference(),
          submit_opts()
        ) :: WebsocketOwnerSession.reconnect_preflight_result()
  def preflight_reconnect(
        %CodexSession{} = session,
        owner_lease_token,
        downstream,
        semantic_turn_key,
        control_ref,
        opts \\ []
      )
      when is_binary(owner_lease_token) and is_map(downstream) and
             is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_reference(control_ref) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_reconnect_control(
        owner,
        reconnect_control(
          :preflight,
          session.id,
          downstream,
          semantic_turn_key,
          control_ref
        ),
        opts
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_reconnect(
          CodexSession.t(),
          binary(),
          WebsocketOwnerSession.downstream(),
          <<_::256>>,
          reference(),
          submit_opts()
        ) :: :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_reconnect(
        %CodexSession{} = session,
        owner_lease_token,
        downstream,
        semantic_turn_key,
        control_ref,
        opts \\ []
      )
      when is_binary(owner_lease_token) and is_map(downstream) and
             is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_reference(control_ref) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_reconnect_control(
        owner,
        reconnect_control(:cancel, session.id, downstream, semantic_turn_key, control_ref),
        opts
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec admission_control(
          CodexSession.t(),
          binary(),
          WebsocketOwnerAdmissionControlV1.t(),
          submit_opts()
        ) :: WebsocketOwnerSession.admission_result()
  def admission_control(
        %CodexSession{} = session,
        owner_lease_token,
        %WebsocketOwnerAdmissionControlV1{} = control,
        opts \\ []
      )
      when is_binary(owner_lease_token) and is_list(opts) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         :ok <- validate_admission_control(control),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_admission_control(owner, session.id, control, opts)
    else
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  @spec push_downstream(
          CodexSession.t(),
          binary(),
          WebsocketOwnerContract.downstream_payload(),
          submit_opts()
        ) ::
          request_result()
  def push_downstream(%CodexSession{} = session, owner_lease_token, payload, opts \\ [])
      when is_binary(owner_lease_token) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_push(owner, session.id, payload, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_owner(CodexSession.t(), submit_opts()) ::
          {:ok, owner_resolution()} | {:error, :owner_unavailable}
  def resolve_owner(session, opts \\ [])

  def resolve_owner(%CodexSession{owner_instance_id: owner_instance_id}, opts)
      when is_binary(owner_instance_id) do
    owner_instance_id = String.trim(owner_instance_id)

    cond do
      owner_instance_id == "" ->
        {:error, :owner_unavailable}

      owner_instance_id == local_node_string() ->
        {:ok, {:local, owner_instance_id}}

      true ->
        resolve_remote_owner(owner_instance_id, opts)
    end
  end

  def resolve_owner(%CodexSession{}, _opts), do: {:error, :owner_unavailable}

  @spec touch_replay_liveness(CodexSession.t(), map(), submit_opts()) ::
          :ok | {:error, :owner_unavailable}
  def touch_replay_liveness(%CodexSession{} = session, reference, opts \\ [])
      when is_map(reference) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    with {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} ->
          remote_touch_replay_liveness(session.id, reference, timeout)

        {:remote, node, _instance} ->
          call_remote(node, :remote_touch_replay_liveness, [session.id, reference, timeout], opts)
      end
    end
  end

  @doc false
  @spec remote_touch_replay_liveness(Ecto.UUID.t(), map()) ::
          :ok | {:error, :owner_unavailable}
  def remote_touch_replay_liveness(session_id, reference)
      when is_binary(session_id) and is_map(reference),
      do:
        remote_touch_replay_liveness(
          session_id,
          reference,
          WebsocketOwnerContract.default_forward_timeout_ms()
        )

  def remote_touch_replay_liveness(_session_id, _reference),
    do: {:error, :owner_unavailable}

  @doc false
  @spec remote_touch_replay_liveness(Ecto.UUID.t(), map(), pos_integer()) ::
          :ok | {:error, :owner_unavailable}
  def remote_touch_replay_liveness(session_id, reference, timeout)
      when is_binary(session_id) and is_map(reference) do
    with {:ok, owner} <- WebsocketOwnerSession.lookup(session_id) do
      WebsocketOwnerSession.touch_replay_liveness(owner, reference, timeout)
    end
  end

  @doc false
  @spec remote_attach_downstream(binary(), map(), keyword()) ::
          {:ok, WebsocketOwnerSession.downstream()}
          | {:error, WebsocketOwnerContract.owner_error()}
  def remote_attach_downstream(codex_session_id, downstream, opts \\ [])
      when is_binary(codex_session_id) and is_map(downstream) and is_list(opts) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.attach_downstream(owner_pid, downstream, opts)
    end
  end

  @doc """
  Builds the remote attach call arguments with rolling-deploy compatibility:
  an attach without options keeps the previous two-argument shape so a new
  proxy node can still attach through an owner node running the prior
  release, which only exports `remote_attach_downstream/2`. Only option-
  carrying attaches (the bridge's busy guard) use the new three-argument
  shape; against an old owner they fail closed and the bridge falls back.
  """
  @spec remote_attach_args(binary(), map(), keyword()) :: [term()]
  def remote_attach_args(codex_session_id, downstream, [] = _opts),
    do: [codex_session_id, downstream]

  def remote_attach_args(codex_session_id, downstream, opts) when is_list(opts),
    do: [codex_session_id, downstream, opts]

  @doc false
  @spec remote_reconnect_control_v1(reconnect_control()) ::
          WebsocketOwnerSession.reconnect_preflight_result() | :ok
  def remote_reconnect_control_v1(
        %{
          version: 1,
          action: action,
          codex_session_id: codex_session_id,
          downstream: downstream,
          semantic_turn_key: semantic_turn_key,
          control_ref: control_ref
        } = control
      )
      when action in [:preflight, :cancel] and is_binary(codex_session_id) and
             is_map(downstream) and is_binary(semantic_turn_key) and
             byte_size(semantic_turn_key) == 32 and is_reference(control_ref) and
             map_size(control) == 6 do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      case action do
        :preflight ->
          WebsocketOwnerSession.preflight_reconnect(
            owner_pid,
            downstream,
            semantic_turn_key,
            control_ref
          )

        :cancel ->
          WebsocketOwnerSession.cancel_reconnect(owner_pid, downstream, control_ref)
      end
    end
  end

  def remote_reconnect_control_v1(_control), do: {:error, :owner_unavailable}

  @doc false
  @spec remote_reconnect_control_v2(RemoteReconnectControlV2.t()) :: term()
  def remote_reconnect_control_v2(
        %RemoteReconnectControlV2{codex_session_id: session_id} = control
      ) do
    with :ok <- RemoteReconnectControlV2.validate(control),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
      case WebsocketOwnerSession.reconnect_control_v2(owner_pid, control) do
        {:error, :stale_owner} -> {:error, :owner_unavailable}
        result -> result
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  def remote_reconnect_control_v2(_control), do: {:error, :owner_unavailable}

  @spec consume_replay_reserve(CodexSession.t(), binary(), map(), submit_opts()) ::
          {:ok, reference()} | {:error, :invalid | :owner_unavailable}
  def consume_replay_reserve(session, token, proof, opts \\ [])

  def consume_replay_reserve(%CodexSession{} = session, token, proof, opts)
      when is_binary(token) and is_map(proof) and is_list(opts) do
    with :ok <- SessionContinuity.validate_owner_token(session, token),
         true <- proof.owner_lease_token == token,
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} -> remote_consume_replay_reserve(session.id, proof)
        {:remote, node, _instance} -> call_remote_replay_reserve(node, session.id, proof, opts)
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  def consume_replay_reserve(%CodexSession{}, _token, _proof, _opts),
    do: {:error, :owner_unavailable}

  @doc false
  @spec remote_consume_replay_reserve(binary(), map()) ::
          {:ok, reference()} | {:error, :invalid | :owner_unavailable}
  def remote_consume_replay_reserve(codex_session_id, proof)
      when is_binary(codex_session_id) and is_map(proof) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.consume_reserve_receipt(owner_pid, proof)
    end
  end

  def remote_consume_replay_reserve(_codex_session_id, _proof),
    do: {:error, :owner_unavailable}

  @spec validate_replay_reserve(
          CodexSession.t(),
          binary(),
          map(),
          reference(),
          submit_opts()
        ) :: :ok | {:error, :invalid | :owner_unavailable}
  def validate_replay_reserve(session, token, proof, consume_fence, opts \\ [])

  def validate_replay_reserve(%CodexSession{} = session, token, proof, consume_fence, opts)
      when is_binary(token) and is_map(proof) and is_reference(consume_fence) and is_list(opts) do
    with :ok <- SessionContinuity.validate_owner_token(session, token),
         true <- proof.owner_lease_token == token,
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} ->
          remote_validate_replay_reserve(session.id, proof, consume_fence)

        {:remote, node, _instance} ->
          call_remote_replay_reserve_action(
            node,
            :remote_validate_replay_reserve,
            session.id,
            proof,
            consume_fence,
            opts
          )
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  def validate_replay_reserve(%CodexSession{}, _token, _proof, _consume_fence, _opts),
    do: {:error, :owner_unavailable}

  @doc false
  @spec remote_validate_replay_reserve(binary(), map(), reference()) ::
          :ok | {:error, :invalid | :owner_unavailable}
  def remote_validate_replay_reserve(codex_session_id, proof, consume_fence)
      when is_binary(codex_session_id) and is_map(proof) and is_reference(consume_fence) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.validate_consumed_reserve_receipt(owner_pid, proof, consume_fence)
    end
  end

  def remote_validate_replay_reserve(_codex_session_id, _proof, _consume_fence),
    do: {:error, :owner_unavailable}

  @spec release_replay_reserve(
          CodexSession.t(),
          binary(),
          map(),
          reference(),
          submit_opts()
        ) :: :ok | {:error, :invalid | :owner_unavailable}
  def release_replay_reserve(session, token, proof, consume_fence, opts \\ [])

  def release_replay_reserve(%CodexSession{} = session, token, proof, consume_fence, opts)
      when is_binary(token) and is_map(proof) and is_reference(consume_fence) and is_list(opts) do
    with :ok <- SessionContinuity.validate_owner_token(session, token),
         true <- proof.owner_lease_token == token,
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} ->
          remote_release_replay_reserve(session.id, proof, consume_fence)

        {:remote, node, _instance} ->
          call_remote_replay_reserve_action(
            node,
            :remote_release_replay_reserve,
            session.id,
            proof,
            consume_fence,
            opts
          )
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  def release_replay_reserve(%CodexSession{}, _token, _proof, _consume_fence, _opts),
    do: {:error, :owner_unavailable}

  @doc false
  @spec remote_release_replay_reserve(binary(), map(), reference()) ::
          :ok | {:error, :invalid | :owner_unavailable}
  def remote_release_replay_reserve(codex_session_id, proof, consume_fence)
      when is_binary(codex_session_id) and is_map(proof) and is_reference(consume_fence) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.release_consumed_reserve_receipt(owner_pid, proof, consume_fence)
    end
  end

  def remote_release_replay_reserve(_codex_session_id, _proof, _consume_fence),
    do: {:error, :owner_unavailable}

  @spec reconnect_control_v2(
          CodexSession.t(),
          binary(),
          RemoteReconnectControlV2.t(),
          submit_opts()
        ) :: term()
  def reconnect_control_v2(
        %CodexSession{} = session,
        token,
        %RemoteReconnectControlV2{} = control,
        opts \\ []
      ) do
    with :ok <- SessionContinuity.validate_owner_token(session, token),
         :ok <- RemoteReconnectControlV2.validate(control),
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} ->
          remote_reconnect_control_v2(control)

        {:remote, node, _instance} ->
          call_remote_v2_control(node, control, opts)
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  @spec prepare_next_replay_descriptor(CodexSession.t(), binary(), map(), map(), submit_opts()) ::
          :ok | {:error, atom()}
  def prepare_next_replay_descriptor(session, token, downstream, descriptor, opts \\ [])

  def prepare_next_replay_descriptor(
        %CodexSession{} = session,
        token,
        downstream,
        descriptor,
        opts
      ) do
    with :ok <- SessionContinuity.validate_owner_token(session, token),
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} ->
          remote_prepare_next_replay_descriptor(session.id, downstream, descriptor)

        {:remote, node, _instance} ->
          call_remote(
            node,
            :remote_prepare_next_replay_descriptor,
            [session.id, downstream, descriptor],
            opts
          )
      end
    else
      _invalid -> {:error, :owner_unavailable}
    end
  end

  @doc false
  def remote_prepare_next_replay_descriptor(session_id, downstream, descriptor) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
      WebsocketOwnerSession.prepare_next_replay_descriptor(owner_pid, downstream, descriptor)
    end
  end

  @doc false
  @spec remote_admission_control_v1(binary(), WebsocketOwnerAdmissionControlV1.t()) ::
          WebsocketOwnerSession.admission_result()
  def remote_admission_control_v1(codex_session_id, control)
      when is_binary(codex_session_id) do
    with :ok <- validate_admission_control(control),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.admission_control(owner_pid, control)
    else
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  @doc false
  @spec remote_submit_frame(
          binary(),
          WebsocketOwnerSession.downstream(),
          binary(),
          submit_opts()
        ) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def remote_submit_frame(codex_session_id, downstream, frame, opts \\ [])
      when is_binary(codex_session_id) and is_map(downstream) and is_binary(frame) do
    with {:ok, {owner_pid, downstream}} <- ensure_remote_owner(codex_session_id, downstream, opts) do
      WebsocketOwnerSession.submit_frame(owner_pid, downstream, frame)
    end
  end

  @doc false
  @spec remote_submit_request(
          binary(),
          WebsocketOwnerSession.downstream(),
          UpstreamWebsocketSession.Request.t(),
          submit_opts()
        ) ::
          submitted_request_result()
  def remote_submit_request(_codex_session_id, _downstream, _request, _opts \\ []),
    do: {:error, :owner_unavailable}

  @doc false
  @spec remote_submit_request_v1(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequest.t()
        ) :: submitted_request_result()
  def remote_submit_request_v1(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with {:ok, owner_request} <- validate_owner_request(owner_request),
         {:ok, {owner_pid, downstream}} <-
           ensure_remote_owner(
             codex_session_id,
             downstream,
             owner_request,
             request_recovery_opts(owner_request)
           ),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_remote_owner_request(
        owner_pid,
        codex_session_id,
        downstream,
        request,
        owner_request.submission_notification?,
        request_recovery_opts(owner_request)
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_submit_request_v6(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV6.t()
        ) :: submitted_request_result()
  def remote_submit_request_v6(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v6(owner_request),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_collect_owner_request(
        owner_pid,
        downstream,
        request,
        owner_request.submission_notification?
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_submit_request_v2(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV2.t()
        ) :: submitted_request_result()
  def remote_submit_request_v2(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v2(owner_request),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_collect_owner_request(
        owner_pid,
        downstream,
        request,
        owner_request.submission_notification?
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_submit_request_v3(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV3.t()
        ) :: submitted_request_result()
  def remote_submit_request_v3(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v3(owner_request),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_collect_owner_request(
        owner_pid,
        downstream,
        request,
        owner_request.submission_notification?
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_submit_request_v4(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV4.t()
        ) :: submitted_request_result()
  def remote_submit_request_v4(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v4(owner_request),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_collect_owner_request(
        owner_pid,
        downstream,
        request,
        owner_request.submission_notification?
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_submit_request_v5(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV5.t()
        ) :: submitted_request_result()
  def remote_submit_request_v5(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v5(owner_request),
         {:ok, {owner_pid, downstream}} <-
           ensure_remote_owner(
             codex_session_id,
             downstream,
             owner_request,
             request_recovery_opts(owner_request)
           ),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_remote_owner_request(
        owner_pid,
        codex_session_id,
        downstream,
        request,
        owner_request.submission_notification?,
        request_recovery_opts(owner_request)
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :stale_owner}
      {:error, :upstream_identity_not_found} -> {:error, :stale_owner}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec remote_push_downstream(binary(), WebsocketOwnerContract.downstream_payload()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def remote_push_downstream(codex_session_id, payload) when is_binary(codex_session_id) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.push_downstream(owner_pid, payload)
    end
  end

  @doc false
  @spec remote_cancel_downstream(binary(), WebsocketOwnerSession.downstream()) ::
          WebsocketOwnerContract.detach_result()
  def remote_cancel_downstream(codex_session_id, downstream)
      when is_binary(codex_session_id) and is_map(downstream) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.detach_downstream(owner_pid, downstream)
    end
  end

  @doc false
  @spec remote_cancel_downstream_v1(
          binary(),
          WebsocketOwnerSession.downstream(),
          :client_disconnected | :owner_drained
        ) :: WebsocketOwnerContract.detach_result()
  def remote_cancel_downstream_v1(codex_session_id, downstream, reason)
      when is_binary(codex_session_id) and is_map(downstream) and
             reason in [:client_disconnected, :owner_drained] do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      case reason do
        :owner_drained -> WebsocketOwnerSession.cancel_downstream(owner_pid, downstream, reason)
        :client_disconnected -> WebsocketOwnerSession.detach_downstream(owner_pid, downstream)
      end
    end
  end

  @spec cancel_remote_downstream(
          node(),
          binary(),
          WebsocketOwnerSession.downstream(),
          :client_disconnected | :owner_drained,
          submit_opts()
        ) :: WebsocketOwnerContract.detach_result()
  def cancel_remote_downstream(node, codex_session_id, downstream, reason, opts)
      when is_atom(node) and is_binary(codex_session_id) and is_map(downstream) and
             reason in [:client_disconnected, :owner_drained] and is_list(opts) do
    args = [codex_session_id, downstream, reason]

    case call_remote_versioned_cancel(node, args, opts) do
      {:error, :remote_cancel_v1_unsupported} ->
        call_remote(node, :remote_cancel_downstream, [codex_session_id, downstream], opts)

      result ->
        result
    end
  end

  defp resolve_remote_owner(owner_instance_id, opts) do
    node_client = node_client(opts)

    node_client.connected_app_nodes()
    |> Enum.find_value(fn candidate_node ->
      candidate_node_string = safe_node_string(candidate_node)

      if remote_app_node?(candidate_node, candidate_node_string, opts) and
           candidate_node_string == owner_instance_id do
        {:ok, {:remote, candidate_node, candidate_node_string}}
      end
    end)
    |> case do
      nil -> {:error, :owner_unavailable}
      result -> result
    end
  end

  defp dispatch_submit({:local, _owner_instance_id}, codex_session_id, downstream, frame, _opts) do
    remote_submit_frame(codex_session_id, downstream, frame)
  end

  defp dispatch_submit(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         frame,
         opts
       ) do
    result =
      call_remote(node, :remote_submit_frame, [codex_session_id, downstream, frame, opts], opts)

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_reconnect_control({:local, _owner_instance_id}, control, _opts) do
    remote_reconnect_control_v1(control)
  end

  defp dispatch_reconnect_control({:remote, node, _owner_instance_id}, control, opts) do
    result = call_remote_control(node, control, opts)

    if control.action == :preflight and result == {:error, :owner_forward_timeout} do
      cancel_control = %{control | action: :cancel}

      _cancel_result =
        call_remote_control(
          node,
          cancel_control,
          Keyword.put(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())
        )
    end

    result
  end

  defp dispatch_admission_control(
         {:local, _owner_instance_id},
         codex_session_id,
         control,
         _opts
       ) do
    remote_admission_control_v1(codex_session_id, control)
  end

  defp dispatch_admission_control(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         control,
         opts
       ) do
    call_remote(node, :remote_admission_control_v1, [codex_session_id, control], opts)
  end

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV5{} = owner_request,
         _opts
       ),
       do: remote_submit_request_v5(codex_session_id, downstream, owner_request)

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV4{} = owner_request,
         _opts
       ),
       do: remote_submit_request_v4(codex_session_id, downstream, owner_request)

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV3{} = owner_request,
         _opts
       ) do
    remote_submit_request_v3(codex_session_id, downstream, owner_request)
  end

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV6{} = owner_request,
         _opts
       ) do
    remote_submit_request_v6(codex_session_id, downstream, owner_request)
  end

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV2{} = owner_request,
         _opts
       ) do
    remote_submit_request_v2(codex_session_id, downstream, owner_request)
  end

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequest{} = owner_request,
         _opts
       ) do
    remote_submit_request_v1(codex_session_id, downstream, owner_request)
  end

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         %UpstreamWebsocketSession.Request{} = request,
         opts
       ) do
    with {:ok, {owner_pid, downstream}} <-
           ensure_remote_owner(codex_session_id, downstream, request, opts) do
      submit_remote_owner_request(
        owner_pid,
        codex_session_id,
        downstream,
        request,
        submission_notification?(request),
        opts
      )
    end
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV5{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts)

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v5,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)
    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV4{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_replay_cancellation_watcher(
        submitter,
        node,
        codex_session_id,
        owner_request,
        opts
      )

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v4,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      reconcile_remote_v4_timeout(node, codex_session_id, owner_request, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV3{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts)

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v3,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV6{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts)

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v6,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV2{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts)

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v2,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequest{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(
        submitter,
        node,
        codex_session_id,
        downstream,
        opts
      )

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v1,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, _node, _owner_instance_id},
         _codex_session_id,
         _downstream,
         %UpstreamWebsocketSession.Request{},
         _opts
       ),
       do: {:error, :owner_unavailable}

  defp reconcile_remote_v4_timeout(node, codex_session_id, owner_request, opts) do
    with owner_lease_token when is_binary(owner_lease_token) <-
           Keyword.get(opts, :replay_owner_lease_token),
         {:ok, query} <-
           replay_timeout_control(codex_session_id, owner_request, owner_lease_token),
         {:ok, status} <- call_remote_v2_control(node, query, replay_reconcile_opts(opts)),
         true <- status in [:provisional, :consume_reserved],
         {:ok, cancel} <-
           replay_timeout_control(
             codex_session_id,
             owner_request,
             owner_lease_token,
             :provisional_cancel
           ) do
      _result = call_remote_v2_control(node, cancel, replay_reconcile_opts(opts))
      :ok
    else
      _committed_started_terminal_or_uncertain -> :ok
    end
  end

  defp replay_timeout_control(
         codex_session_id,
         %WebsocketOwnerRequestV4{} = owner_request,
         owner_lease_token,
         action \\ :provisional_query
       ) do
    RemoteReconnectControlV2.new(%{
      version: 2,
      action: action,
      intent: :suspended_replay,
      codex_session_id: codex_session_id,
      downstream: nil,
      semantic_turn_digest: owner_request.native_replay_binding.semantic_turn_digest,
      replay_claim_digest: owner_request.native_replay_binding.replay_claim_digest,
      provisional_token: owner_request.provisional_token,
      replay_generation: 1,
      owner_lease_token: owner_lease_token,
      control_ref: make_ref(),
      authorization_binding: nil,
      consume_binding: nil
    })
  end

  defp replay_reconcile_opts(opts) do
    Keyword.put(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())
  end

  defp start_remote_replay_cancellation_watcher(
         submitter,
         node,
         codex_session_id,
         owner_request,
         opts
       ) do
    spawn(fn ->
      submitter_monitor = Process.monitor(submitter)

      receive do
        {:remote_submit_complete, ^submitter} ->
          Process.demonitor(submitter_monitor, [:flush])

        {:DOWN, ^submitter_monitor, :process, ^submitter, _reason} ->
          reconcile_remote_v4_timeout(node, codex_session_id, owner_request, opts)
      end
    end)
  end

  defp start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts) do
    spawn(fn ->
      submitter_monitor = Process.monitor(submitter)

      receive do
        {:remote_submit_complete, ^submitter} ->
          Process.demonitor(submitter_monitor, [:flush])

        {:DOWN, ^submitter_monitor, :process, ^submitter, reason} ->
          best_effort_cancel_downstream(
            node,
            codex_session_id,
            downstream,
            remote_cancel_reason(reason),
            opts
          )
      end
    end)
  end

  defp stop_remote_cancellation_watcher(watcher, submitter) do
    send(watcher, {:remote_submit_complete, submitter})
    :ok
  end

  defp dispatch_push({:local, _owner_instance_id}, codex_session_id, payload, _opts) do
    remote_push_downstream(codex_session_id, payload)
  end

  defp dispatch_push({:remote, node, _owner_instance_id}, codex_session_id, payload, opts) do
    call_remote(node, :remote_push_downstream, [codex_session_id, payload], opts)
  end

  defp ensure_remote_owner(codex_session_id, downstream, opts) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        {:ok, {owner_pid, downstream}}

      {:error, :owner_unavailable} ->
        with {:ok, {owner_pid, recovered_downstream, _recovery_session}} <-
               recover_remote_owner(codex_session_id, downstream, opts) do
          {:ok, {owner_pid, recovered_downstream}}
        end
    end
  end

  defp ensure_remote_owner(codex_session_id, downstream, request, opts) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        {:ok, {owner_pid, downstream}}

      {:error, :owner_unavailable} ->
        recover_remote_owner_for_request(codex_session_id, downstream, request, opts)
    end
  end

  defp recover_remote_owner_for_request(codex_session_id, downstream, request, opts) do
    if bound_reset_probe?(request) do
      {:error, :owner_unavailable}
    else
      with {:ok, {owner_pid, recovered_downstream, _recovery_session}} <-
             recover_remote_owner(codex_session_id, downstream, opts) do
        {:ok, {owner_pid, recovered_downstream}}
      end
    end
  end

  defp recover_remote_owner(codex_session_id, downstream, opts),
    do: recover_remote_owner(codex_session_id, downstream, opts, :reuse_lease)

  defp recover_remote_owner(codex_session_id, downstream, opts, lease_recovery) do
    with :ok <- reject_if_rollout_draining(),
         %CodexSession{} = session <- Repo.get(CodexSession, codex_session_id),
         :ok <- require_local_owner_session(session, opts),
         {:ok, recovery_session} <- recover_remote_owner_lease(session, opts, lease_recovery),
         {:ok, owner_pid} <- start_recovered_remote_owner(recovery_session, opts),
         {:ok, downstream} <- attach_recovered_downstream(owner_pid, downstream) do
      {:ok, {owner_pid, downstream, recovery_session}}
    else
      nil -> {:error, :owner_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_if_rollout_draining do
    if OperationalStatus.draining?(), do: {:error, :owner_drained}, else: :ok
  end

  defp submit_remote_owner_request(
         owner_pid,
         codex_session_id,
         downstream,
         request,
         submission_notification?,
         opts
       ) do
    {request, visibility} = track_request_visibility(request)

    do_submit_remote_owner_request(
      owner_pid,
      codex_session_id,
      downstream,
      request,
      submission_notification?,
      visibility,
      opts
    )
  end

  defp do_submit_remote_owner_request(
         owner_pid,
         codex_session_id,
         downstream,
         request,
         submission_notification?,
         visibility,
         opts
       ) do
    WebsocketOwnerSession.submit_request(
      owner_pid,
      downstream,
      request,
      submission_notification?
    )
  catch
    :exit, reason ->
      if bound_reset_probe?(request) or Process.alive?(owner_pid) or
           :atomics.get(visibility, 1) == 1 or
           not recoverable_owner_exit?(reason) do
        {:error, :owner_crashed}
      else
        with {:ok, {replacement_pid, replacement_downstream, replacement_session}} <-
               recover_remote_owner(
                 codex_session_id,
                 downstream,
                 opts,
                 :replace_unavailable_lease
               ),
             :ok <- notify_recovered_runtime(replacement_session, replacement_downstream) do
          WebsocketOwnerSession.submit_request(
            replacement_pid,
            replacement_downstream,
            request,
            submission_notification?
          )
        end
      end
  end

  defp submit_collect_owner_request(owner_pid, downstream, request, submission_notification?) do
    WebsocketOwnerSession.submit_request(
      owner_pid,
      downstream,
      request,
      submission_notification?
    )
  catch
    :exit, _reason -> {:error, :owner_crashed}
  end

  defp recoverable_owner_exit?({reason, {GenServer, :call, _details}}),
    do: recoverable_owner_exit?(reason)

  defp recoverable_owner_exit?(reason) when reason in [:normal, :shutdown], do: false
  defp recoverable_owner_exit?({:shutdown, _details}), do: false
  defp recoverable_owner_exit?(_reason), do: true

  defp track_request_visibility(%UpstreamWebsocketSession.Request{} = request) do
    visibility = :atomics.new(1, [])
    observer = request.frame_observer

    tracked_observer = fn frame, decoded ->
      unless StreamProtocol.internal_control_event?(decoded),
        do: :atomics.put(visibility, 1, 1)

      cond do
        is_function(observer, 2) -> observer.(frame, decoded)
        is_function(observer, 1) -> observer.(frame)
        true -> :ok
      end
    end

    {%{request | frame_observer: tracked_observer}, visibility}
  end

  defp bound_reset_probe?(%UpstreamWebsocketSession.Request{
         reset_probe: %ResetProbe{} = probe
       }),
       do: ResetProbe.bound?(probe)

  defp bound_reset_probe?(%UpstreamWebsocketSession.Request{}), do: false

  defp bound_reset_probe?(%WebsocketOwnerRequest{reset_probe: %ResetProbe{} = probe}),
    do: ResetProbe.bound?(probe)

  defp bound_reset_probe?(%WebsocketOwnerRequest{}), do: false

  defp submission_notification?(%UpstreamWebsocketSession.Request{submission_observer: observer}),
    do: is_function(observer, 0)

  defp validate_owner_request(%WebsocketOwnerRequest{} = owner_request) do
    case WebsocketOwnerRequest.validate(owner_request) do
      :ok -> {:ok, owner_request}
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request(owner_request) do
    case WebsocketOwnerRequest.new(owner_request) do
      {:ok, owner_request} -> {:ok, owner_request}
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v6(%WebsocketOwnerRequestV6{} = owner_request) do
    case WebsocketOwnerRequestV6.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v6(_owner_request),
    do: {:error, {:invalid_owner_request, {:invalid_field, :envelope}}}

  defp validate_owner_request_v2(%WebsocketOwnerRequestV2{} = owner_request) do
    case WebsocketOwnerRequestV2.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v2(_owner_request),
    do: {:error, {:invalid_owner_request, {:invalid_field, :envelope}}}

  defp validate_owner_request_v3(%WebsocketOwnerRequestV3{} = owner_request) do
    case WebsocketOwnerRequestV3.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v3(_owner_request),
    do: {:error, {:invalid_owner_request, {:invalid_field, :envelope}}}

  defp validate_owner_request_v4(%WebsocketOwnerRequestV4{} = owner_request) do
    case WebsocketOwnerRequestV4.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v4(_owner_request),
    do: {:error, {:invalid_owner_request, {:invalid_field, :envelope}}}

  defp validate_owner_request_v5(%WebsocketOwnerRequestV5{} = owner_request) do
    case WebsocketOwnerRequestV5.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v5(_owner_request),
    do: {:error, {:invalid_owner_request, {:invalid_field, :envelope}}}

  defp validate_admission_control(%WebsocketOwnerAdmissionControlV1{} = control) do
    case WebsocketOwnerAdmissionControlV1.validate(control) do
      :ok -> :ok
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  defp validate_admission_control(_control), do: {:error, :owner_unavailable}

  defp request_recovery_opts(%WebsocketOwnerRequest{observation: observation}) do
    case Map.get(observation, :request_id) do
      request_id when is_binary(request_id) -> [request_id: request_id]
      nil -> []
    end
  end

  defp request_recovery_opts(%WebsocketOwnerRequestV5{observation: observation}) do
    case Map.get(observation, :request_id) do
      request_id when is_binary(request_id) -> [request_id: request_id]
      nil -> []
    end
  end

  defp recover_remote_owner_lease(session, _opts, :reuse_lease), do: {:ok, session}

  defp recover_remote_owner_lease(session, opts, :replace_unavailable_lease) do
    takeover_opts =
      RequestOptions.for_websocket(
        owner_instance_id: local_node_string(opts),
        request_id: Keyword.get(opts, :request_id)
      )

    SessionContinuity.replace_unavailable_owner_lease(session, takeover_opts)
  end

  defp require_local_owner_session(
         %CodexSession{
           owner_instance_id: owner_instance_id,
           owner_lease_token: token
         },
         opts
       )
       when is_binary(owner_instance_id) and is_binary(token) do
    if owner_instance_id == local_node_string(opts), do: :ok, else: {:error, :owner_unavailable}
  end

  defp require_local_owner_session(%CodexSession{}, _opts), do: {:error, :owner_unavailable}

  defp start_recovered_remote_owner(%CodexSession{} = session, opts) do
    start_opts = [
      codex_session_id: session.id,
      owner_lease_token: session.owner_lease_token,
      owner_instance_id: session.owner_instance_id,
      request_id: Keyword.get(opts, :request_id),
      idle_shutdown_ms: OperationalSettings.current().websocket_owner_idle_timeout_ms
    ]

    start_opts = maybe_put_recovery_upstream(start_opts, opts)

    case WebsocketOwnerSession.start_owner(start_opts) do
      {:ok, owner_pid} -> {:ok, owner_pid}
      {:ok, owner_pid, :existing} -> {:ok, owner_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_recovery_upstream(start_opts, opts) do
    case Keyword.fetch(opts, :upstream) do
      {:ok, upstream} -> Keyword.put(start_opts, :upstream, upstream)
      :error -> start_opts
    end
  end

  defp attach_recovered_downstream(
         owner_pid,
         downstream
       )
       when is_map(downstream) do
    with {:ok, restore_input} <- restore_input(downstream),
         {:ok, stable_downstream} <-
           WebsocketOwnerSession.restore_downstream(owner_pid, restore_input),
         :ok <- require_exact_keys(stable_downstream, @stable_downstream_keys) do
      recovered_per_call_downstream(stable_downstream, downstream)
    end
  end

  defp restore_input(downstream) do
    cond do
      exact_keys?(downstream, @restore_downstream_keys) ->
        {:ok, downstream}

      exact_keys?(downstream, @stable_downstream_keys) ->
        {:ok, Map.take(downstream, @restore_downstream_keys)}

      exact_keys?(downstream, @public_per_call_downstream_keys) and
          is_pid(Map.get(downstream, :owner_turn_id)) ->
        {:ok, Map.take(downstream, @restore_downstream_keys)}

      true ->
        {:error, :stale_downstream}
    end
  end

  defp recovered_per_call_downstream(stable_downstream, original_downstream) do
    if Map.has_key?(original_downstream, :owner_turn_id) do
      owner_turn_id = Map.get(original_downstream, :owner_turn_id)

      if exact_keys?(original_downstream, @public_per_call_downstream_keys) and
           is_pid(owner_turn_id) do
        {:ok, Map.put(stable_downstream, :owner_turn_id, owner_turn_id)}
      else
        {:error, :stale_downstream}
      end
    else
      {:ok, stable_downstream}
    end
  end

  defp require_exact_keys(map, keys) do
    if exact_keys?(map, keys), do: :ok, else: {:error, :stale_downstream}
  end

  defp exact_keys?(map, keys) when is_map(map) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp notify_recovered_runtime(%CodexSession{} = session, downstream)
       when is_map(downstream) do
    stable_downstream = Map.drop(downstream, [:owner_turn_id])

    with :ok <- require_exact_keys(stable_downstream, @stable_downstream_keys),
         %{pid: pid, correlation_id: correlation_id, epoch: epoch} <- stable_downstream,
         true <- is_pid(pid) and is_binary(correlation_id) and is_integer(epoch) and epoch > 0 do
      send(
        pid,
        {:websocket_owner_runtime_recovered, correlation_id, epoch,
         %{
           codex_session: session,
           websocket_owner_lease_token: session.owner_lease_token,
           websocket_owner_downstream: stable_downstream
         }}
      )

      :ok
    else
      _other -> {:error, :stale_downstream}
    end
  end

  defp notify_recovered_runtime(_session, _downstream), do: {:error, :stale_downstream}

  defp best_effort_cancel_downstream(node, codex_session_id, downstream, opts) do
    best_effort_cancel_downstream(
      node,
      codex_session_id,
      downstream,
      :client_disconnected,
      opts
    )
  end

  defp best_effort_cancel_downstream(
         node,
         codex_session_id,
         downstream,
         reason,
         opts
       ) do
    _result =
      cancel_remote_downstream(
        node,
        codex_session_id,
        downstream,
        reason,
        Keyword.put(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())
      )

    :ok
  end

  defp remote_cancel_reason({:shutdown, :owner_drained}), do: :owner_drained
  defp remote_cancel_reason(_reason), do: :client_disconnected

  defp call_remote_versioned_cancel(node, args, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(
      node,
      __MODULE__,
      :remote_cancel_downstream_v1,
      args,
      timeout
    )
    |> case do
      {:error, :remote_cancel_v1_unsupported} = unsupported -> unsupported
      result -> normalize_forward_result(result)
    end
  end

  @doc false
  @spec call_remote(node(), atom(), [term()], submit_opts()) ::
          request_result() | WebsocketOwnerContract.detach_result()
  def call_remote(node, function, args, opts)
      when is_atom(node) and is_atom(function) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, function, args, timeout)
    |> normalize_remote_call_result(function)
  end

  defp normalize_remote_call_result(result, :remote_cancel_downstream)
       when result in [:reattachable, :suspended],
       do: result

  defp normalize_remote_call_result({:error, result}, :remote_cancel_downstream)
       when result in [:reattachable, :suspended],
       do: result

  defp normalize_remote_call_result(result, _function), do: normalize_forward_result(result)

  defp call_remote_submission(node, function, args, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, function, args, timeout)
    |> normalize_submitted_request_result()
  end

  defp call_remote_control(node, control, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, :remote_reconnect_control_v1, [control], timeout)
    |> normalize_reconnect_control_result()
  end

  defp call_remote_v2_control(node, control, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, :remote_reconnect_control_v2, [control], timeout)
    |> normalize_v2_control_result()
  end

  defp call_remote_replay_reserve(node, codex_session_id, proof, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(
      node,
      __MODULE__,
      :remote_consume_replay_reserve,
      [codex_session_id, proof],
      timeout
    )
    |> case do
      {:ok, consume_fence} when is_reference(consume_fence) -> {:ok, consume_fence}
      {:error, :invalid} = error -> error
      {:error, _reason} -> {:error, :owner_unavailable}
      _invalid -> {:error, :owner_unavailable}
    end
  end

  defp call_remote_replay_reserve_action(
         node,
         function,
         codex_session_id,
         proof,
         consume_fence,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(
      node,
      __MODULE__,
      function,
      [codex_session_id, proof, consume_fence],
      timeout
    )
    |> case do
      :ok -> :ok
      {:error, :invalid} = error -> error
      {:error, _reason} -> {:error, :owner_unavailable}
      _invalid -> {:error, :owner_unavailable}
    end
  end

  defp normalize_v2_control_result({:ok, :fresh_dispatch, downstream} = result)
       when is_map(downstream), do: result

  defp normalize_v2_control_result({:ok, :same_turn_reattach, downstream} = result)
       when is_map(downstream), do: result

  defp normalize_v2_control_result({:ok, :provisional, token, 1, generation, downstream} = result)
       when is_binary(token) and byte_size(token) == 32 and is_integer(generation) and
              generation > 0 and is_map(downstream),
       do: result

  defp normalize_v2_control_result({:ok, :consume_reserved, timeout, receipt, digest} = result)
       when is_integer(timeout) and timeout in 1..60_000 and is_binary(receipt) and
              byte_size(receipt) == 32 and is_binary(digest) and byte_size(digest) == 32,
       do: result

  defp normalize_v2_control_result({:ok, phase, binding} = result)
       when phase in [:committed_not_started, :started] and is_map(binding), do: result

  defp normalize_v2_control_result({:ok, status} = result)
       when status in [
              :provisional,
              :consume_reserved,
              :committed_not_started,
              :started,
              :cancelled,
              :expired
            ],
       do: result

  defp normalize_v2_control_result({:error, reason}) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_crashed}
  end

  defp normalize_v2_control_result(_result), do: {:error, :owner_crashed}

  defp normalize_reconnect_control_result(result)
       when result in [{:ok, :dispatch}, {:ok, :same_turn_replay}, :ok],
       do: result

  defp normalize_reconnect_control_result({:ok, disposition, control_ref} = result)
       when disposition in [:replacement_handoff, :duplicate_replacement] and
              is_reference(control_ref),
       do: result

  defp normalize_reconnect_control_result({:ok, :fresh_dispatch, downstream} = result)
       when is_map(downstream), do: result

  defp normalize_reconnect_control_result({:ok, :same_turn_reattach, downstream} = result)
       when is_map(downstream), do: result

  defp normalize_reconnect_control_result(
         {:ok, :provisional, token, 1, generation, downstream} = result
       )
       when is_binary(token) and byte_size(token) == 32 and is_integer(generation) and
              generation > 0 and is_map(downstream),
       do: result

  defp normalize_reconnect_control_result({:ok, status} = result)
       when status in [
              :provisional,
              :consume_reserved,
              :committed_not_started,
              :started,
              :cancelled,
              :expired
            ],
       do: result

  defp normalize_reconnect_control_result({:error, reason}) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_crashed}
  end

  defp normalize_reconnect_control_result(_unsafe_result), do: {:error, :owner_crashed}

  defp safe_remote_call(node_client, node, module, function, args, timeout) do
    node_client.call_owner(node, module, function, args, timeout)
    |> normalize_returned_remote_failure(module, function, args)
  catch
    :exit, reason ->
      {:error, normalize_remote_failure(:exit, reason, module, function, args)}

    kind, reason when kind in [:error, :throw] ->
      {:error, normalize_remote_failure(kind, reason, module, function, args)}
  end

  defp normalize_returned_remote_failure({:error, reason}, module, function, args) do
    cond do
      missing_remote_submit_v1?(reason, module, function, args) ->
        log_protocol_incompatibility(:v1)
        {:error, :owner_unavailable}

      missing_remote_submit_v6?(reason, module, function, args) ->
        log_protocol_incompatibility(:v6)
        {:error, :owner_unavailable}

      missing_remote_submit_v2?(reason, module, function, args) ->
        log_protocol_incompatibility(:v2)
        {:error, :owner_unavailable}

      missing_remote_submit_v3?(reason, module, function, args) ->
        log_protocol_incompatibility(:v3)
        {:error, :owner_unavailable}

      missing_remote_cancel_v1?(reason, module, function, args) ->
        {:error, :remote_cancel_v1_unsupported}

      missing_remote_reconnect_control_v1?(reason, module, function, args) ->
        log_control_protocol_incompatibility()
        {:error, :owner_unavailable}

      remote_transport_failure?(reason) ->
        {:error, normalize_remote_transport_failure(reason)}

      true ->
        {:error, reason}
    end
  end

  defp normalize_returned_remote_failure(result, _module, _function, _args), do: result

  defp normalize_forward_result(:ok), do: :ok
  defp normalize_forward_result({:ok, _value} = result), do: result

  defp normalize_forward_result({:error, %{body: _body, reason: _reason} = response}),
    do: {:error, response}

  defp normalize_forward_result({:error, reason}) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_crashed}
  end

  defp normalize_forward_result(_unsafe_result), do: {:error, :owner_crashed}

  defp normalize_submitted_request_result({:websocket_owner_submission_accepted, result}) do
    {:websocket_owner_submission_accepted, normalize_accepted_request_result(result)}
  end

  defp normalize_submitted_request_result(:ok),
    do: {:websocket_owner_submission_accepted, :ok}

  defp normalize_submitted_request_result({:ok, _value} = result),
    do: {:websocket_owner_submission_accepted, result}

  defp normalize_submitted_request_result(result), do: normalize_forward_result(result)

  defp normalize_accepted_request_result(:ok), do: :ok
  defp normalize_accepted_request_result({:ok, _value} = result), do: result

  defp normalize_accepted_request_result({:error, %{body: _body, reason: _reason}} = result),
    do: result

  defp normalize_accepted_request_result({:error, reason}) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_crashed}
  end

  defp normalize_accepted_request_result(_unsafe_result), do: {:error, :owner_crashed}

  @doc false
  @spec normalize_remote_failure(atom(), term(), module(), atom(), [term()]) ::
          :owner_forward_timeout
          | :owner_unavailable
          | :owner_crashed
          | :remote_cancel_v1_unsupported
  def normalize_remote_failure(kind, reason, module, function, args) do
    case normalize_protocol_failure(kind, reason, module, function, args) do
      nil -> normalize_remote_transport_failure(reason)
      failure -> failure
    end
  end

  defp normalize_protocol_failure(:error, reason, module, function, args) do
    cond do
      missing_remote_submit_v1?(reason, module, function, args) ->
        log_protocol_incompatibility(:v1)
        :owner_unavailable

      missing_remote_submit_v6?(reason, module, function, args) ->
        log_protocol_incompatibility(:v6)
        :owner_unavailable

      missing_remote_submit_v2?(reason, module, function, args) ->
        log_protocol_incompatibility(:v2)
        :owner_unavailable

      missing_remote_submit_v3?(reason, module, function, args) ->
        log_protocol_incompatibility(:v3)
        :owner_unavailable

      missing_remote_submit_v5?(reason, module, function, args) ->
        log_protocol_incompatibility(:v5)
        :owner_unavailable

      missing_remote_cancel_v1?(reason, module, function, args) ->
        :remote_cancel_v1_unsupported

      missing_remote_reconnect_control_v1?(reason, module, function, args) ->
        log_control_protocol_incompatibility()
        :owner_unavailable

      true ->
        nil
    end
  end

  defp normalize_protocol_failure(kind, reason, module, function, args)
       when kind in [:exit, :throw] do
    cond do
      missing_remote_submit_v6?(reason, module, function, args) ->
        log_protocol_incompatibility(:v6)
        :owner_unavailable

      missing_remote_submit_v2?(reason, module, function, args) ->
        log_protocol_incompatibility(:v2)
        :owner_unavailable

      missing_remote_submit_v3?(reason, module, function, args) ->
        log_protocol_incompatibility(:v3)
        :owner_unavailable

      missing_remote_submit_v5?(reason, module, function, args) ->
        log_protocol_incompatibility(:v5)
        :owner_unavailable

      missing_remote_reconnect_control_v1?(reason, module, function, args) ->
        log_control_protocol_incompatibility()
        :owner_unavailable

      true ->
        nil
    end
  end

  defp normalize_protocol_failure(_kind, _reason, _module, _function, _args), do: nil

  defp normalize_remote_transport_failure(reason) do
    cond do
      reason in [:timeout, {:erpc, :timeout}, :owner_forward_timeout] ->
        :owner_forward_timeout

      reason in [:noconnection, {:erpc, :noconnection}, :noproc, :owner_unavailable] ->
        :owner_unavailable

      match?({:nodedown, _node}, reason) or match?({:noproc, _details}, reason) ->
        :owner_unavailable

      true ->
        :owner_crashed
    end
  end

  defp remote_transport_failure?(reason) do
    reason in [
      :timeout,
      {:erpc, :timeout},
      :owner_forward_timeout,
      :noconnection,
      {:erpc, :noconnection},
      :noproc,
      :owner_unavailable
    ] or match?({:nodedown, _node}, reason) or match?({:noproc, _details}, reason)
  end

  defp missing_remote_submit_v1?(
         {:exception, :undef,
          [{module, :remote_submit_request_v1, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v1?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v6?(
         {:exception, :undef,
          [{module, :remote_submit_request_v6, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v6,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v6?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v2?(
         {:exception, :undef,
          [{module, :remote_submit_request_v2, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v2,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v2?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v3?(
         {:exception, :undef,
          [{module, :remote_submit_request_v3, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v3,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v3?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v5?(
         {:exception, :undef,
          [{module, :remote_submit_request_v5, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v5,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v5?(_reason, _module, _function, _args), do: false

  defp missing_remote_cancel_v1?(
         {:exception, :undef,
          [{module, :remote_cancel_downstream_v1, remote_args, _location} | _stack]},
         module,
         :remote_cancel_downstream_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_cancel_v1?(_reason, _module, _function, _args), do: false

  defp missing_remote_reconnect_control_v1?(
         {:exception, :undef,
          [{module, :remote_reconnect_control_v1, remote_args, _location} | _stack]},
         module,
         :remote_reconnect_control_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 1

  defp missing_remote_reconnect_control_v1?(_reason, _module, _function, _args), do: false

  defp log_control_protocol_incompatibility do
    require Logger

    Logger.warning(
      "websocket owner protocol incompatible event=owner_protocol_incompatible " <>
        "boundary=reconnect_control protocol=v1 canonical_error=owner_unavailable"
    )
  end

  defp log_protocol_incompatibility(version) when version in [:v1, :v2, :v3, :v5, :v6] do
    require Logger

    Logger.warning(
      "websocket owner protocol incompatible event=owner_protocol_incompatible " <>
        "boundary=submit protocol=#{version} " <>
        "canonical_error=owner_unavailable"
    )
  end

  defp remote_app_node?(node, node_string, opts) when is_atom(node) and is_binary(node_string) do
    not role_node_string?(node_string) and
      (explicit_app_node?(node_string, opts) or node_client(opts).app_node?(node))
  end

  defp remote_app_node?(_node, _node_string, _opts), do: false

  defp explicit_app_node?(node_string, opts) do
    node_string in explicit_app_node_names(opts)
  end

  defp explicit_app_node_names(opts) do
    opts
    |> Keyword.get(:app_node_names, configured_app_node_names())
    |> Enum.filter(&is_binary/1)
  end

  defp configured_app_node_names do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:app_node_names, [])
  end

  defp role_node_string?(node_string) do
    node_string
    |> String.downcase()
    |> then(fn lowered ->
      String.contains?(lowered, ["worker", "scheduler", "migration", "migrations"])
    end)
  end

  defp safe_node_string(node) when is_atom(node), do: Atom.to_string(node)
  defp safe_node_string(node) when is_binary(node), do: node
  defp safe_node_string(_node), do: nil

  defp local_node_string, do: Atom.to_string(node())

  defp local_node_string(opts), do: Keyword.get(opts, :local_node_string, local_node_string())

  defp node_client(opts), do: Keyword.get(opts, :node_client, __MODULE__.ERPCNodeClient)

  defmodule NodeClient do
    @moduledoc false

    @callback connected_app_nodes() :: [node()]
    @callback app_node?(node()) :: boolean()
    @callback call_owner(node(), module(), atom(), [term()], pos_integer()) :: term()
  end

  defmodule ERPCNodeClient do
    @moduledoc false

    @behaviour NodeClient
    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

    @impl NodeClient
    def connected_app_nodes, do: Node.list()

    @impl NodeClient
    def app_node?(node) when is_atom(node) do
      case :erpc.call(node, System, :get_env, ["OBAN_MODE"], 1_000) do
        role when role in [nil, "", "web", "all"] -> true
        _role -> false
      end
    catch
      :exit, _reason -> false
      _kind, _reason -> false
    end

    @impl NodeClient
    def call_owner(node, module, function, args, timeout)
        when is_atom(node) and is_atom(module) and is_atom(function) and is_list(args) and
               is_integer(timeout) and timeout > 0 do
      :erpc.call(node, module, function, args, timeout)
    catch
      :exit, reason ->
        {:error, normalize_erpc_failure(:exit, reason, module, function, args)}

      kind, reason when kind in [:error, :throw] ->
        {:error, normalize_erpc_failure(kind, reason, module, function, args)}
    end

    defp normalize_erpc_failure(kind, reason, module, function, args),
      do:
        WebsocketOwnerForwarder.normalize_remote_failure(
          kind,
          reason,
          module,
          function,
          args
        )
  end
end
