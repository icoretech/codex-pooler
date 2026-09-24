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
  alias CodexPooler.Gateway.Transports.Websocket.AbandonedSubmissions
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
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
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV7
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

  @doc false
  @spec register_pre_attempt_admission(
          CodexSession.t(),
          CodexPooler.Gateway.Websocket.DirectCleanup.t(),
          submit_opts()
        ) :: :ok | {:error, term()}
  def register_pre_attempt_admission(session, context, opts) do
    with {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _} ->
          remote_register_pre_attempt_admission_v1(session.id, context)

        {:remote, node, _} ->
          call_remote(
            node,
            :remote_register_pre_attempt_admission_v1,
            [session.id, context],
            opts
          )
      end
    end
  end

  @doc false
  @spec remote_register_pre_attempt_admission_v1(
          Ecto.UUID.t(),
          CodexPooler.Gateway.Websocket.DirectCleanup.t()
        ) :: :ok | {:error, term()}
  def remote_register_pre_attempt_admission_v1(session_id, context) do
    with {:ok, owner} <- WebsocketOwnerSession.lookup(session_id) do
      WebsocketOwnerSession.register_pre_attempt_admission_v1(owner, context)
    end
  end

  @doc false
  @spec finish_pre_attempt_admission(
          CodexSession.t(),
          CodexPooler.Gateway.Websocket.DirectCleanup.t(),
          submit_opts()
        ) :: :ok | {:error, term()}
  def finish_pre_attempt_admission(session, context, opts) do
    with {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _} ->
          remote_finish_pre_attempt_admission_v1(session.id, context.task, context.ref)

        {:remote, node, _} ->
          call_remote(
            node,
            :remote_finish_pre_attempt_admission_v1,
            [session.id, context.task, context.ref],
            opts
          )
      end
    end
  end

  @doc false
  @spec remote_finish_pre_attempt_admission_v1(Ecto.UUID.t(), pid(), reference()) ::
          :ok | {:error, term()}
  def remote_finish_pre_attempt_admission_v1(session_id, task, ref) do
    with {:ok, owner} <- WebsocketOwnerSession.lookup(session_id) do
      GenServer.cast(owner, {:finish_pre_attempt_admission_v1, task, ref})
    end
  end

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
          | WebsocketOwnerRequestV7.t()
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
               WebsocketOwnerRequestV6,
               WebsocketOwnerRequestV7
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

  @doc false
  @spec reserve_compaction_retry_v7(
          CodexSession.t(),
          binary(),
          WebsocketOwnerSession.downstream(),
          submit_opts()
        ) :: {:ok, CompactionRetrySubmitHold.t()} | {:error, :owner_unavailable}
  def reserve_compaction_retry_v7(session, owner_lease_token, downstream, opts \\ []) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      args = [session.id, owner_lease_token, downstream, self()]

      result =
        case owner do
          {:local, _instance} ->
            remote_reserve_compaction_retry_v7(session.id, owner_lease_token, downstream, self())

          {:remote, node, _instance} ->
            call_remote(node, :remote_reserve_compaction_retry_v7, args, opts)
        end

      normalize_compaction_retry_hold(result)
    else
      _unavailable -> {:error, :owner_unavailable}
    end
  end

  defp normalize_compaction_retry_hold({:ok, %CompactionRetrySubmitHold{} = hold}) do
    if CompactionRetrySubmitHold.valid_shape?(hold),
      do: {:ok, hold},
      else: {:error, :owner_unavailable}
  end

  defp normalize_compaction_retry_hold(_unavailable), do: {:error, :owner_unavailable}

  @doc false
  @spec remote_reserve_compaction_retry_v7(
          binary(),
          binary(),
          WebsocketOwnerSession.downstream(),
          pid()
        ) :: {:ok, CompactionRetrySubmitHold.t()} | {:error, :owner_unavailable}
  def remote_reserve_compaction_retry_v7(session_id, owner_lease_token, downstream, requester) do
    with {:ok, owner} <- WebsocketOwnerSession.lookup(session_id) do
      WebsocketOwnerSession.reserve_compaction_retry_submit(
        owner,
        owner_lease_token,
        downstream,
        requester
      )
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @doc false
  @spec cancel_compaction_retry_v7(CompactionRetrySubmitHold.t()) :: :ok
  def cancel_compaction_retry_v7(%CompactionRetrySubmitHold{} = hold),
    do: WebsocketOwnerSession.cancel_compaction_retry_submit(hold)

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
  def remote_reconnect_control_v2(%RemoteReconnectControlV2{codex_session_id: session_id} = control) do
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
      owner_pid
      |> WebsocketOwnerSession.admission_control(control)
      |> owner_admission_answer(control)
    else
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  # Every admission control answer leaves the owner's node through this
  # function, whether the socket is on that node (`dispatch_admission_control/4`,
  # local) or on another one (`remote_admission_control_v1` over `call_remote`).
  # A refusal is passed on only when it is `NativeCompactionAdmission`'s or the
  # owner vocabulary's, which is exactly what `normalize_remote_call_result/2`
  # lets through on the calling node; anything else becomes the admission's own
  # `invalid_transition` here, identically for a local and a remote owner,
  # instead of reading `owner_crashed` only when the owner is remote
  # (findings#206 row 206-402).
  defp owner_admission_answer({:error, reason} = result, control) when is_atom(reason) do
    if admission_answer?(reason) do
      result
    else
      log_unlisted_admission_refusal(reason, control)
      {:error, :invalid_transition}
    end
  end

  defp owner_admission_answer(result, _control), do: result

  defp admission_answer?(reason),
    do: NativeCompactionAdmission.refusal_reason?(reason) or WebsocketOwnerContract.owner_error?(reason)

  defp log_unlisted_admission_refusal(reason, control) do
    require Logger

    reason_code = DiagnosticTaxonomy.identifier(Atom.to_string(reason))

    Logger.warning(
      "native compaction admission refusal outside vocabulary " <>
        "action=#{control.action} reason_code=#{reason_code} answered=invalid_transition"
    )
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
         opts = remote_submission_opts(owner_request, codex_session_id, downstream),
         {:ok, {owner_pid, downstream}} <- ensure_remote_owner(codex_session_id, downstream, owner_request, opts),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_remote_owner_request(
        owner_pid,
        codex_session_id,
        downstream,
        request,
        owner_request.submission_notification?,
        opts
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

  @spec remote_submit_request_v7(
          binary(),
          WebsocketOwnerSession.downstream(),
          WebsocketOwnerRequestV7.t()
        ) :: submitted_request_result()
  def remote_submit_request_v7(codex_session_id, downstream, owner_request)
      when is_binary(codex_session_id) and is_map(downstream) do
    with :ok <- validate_owner_request_v7(owner_request),
         {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id),
         %CompactionRetrySubmitHold{owner: ^owner_pid} = hold <-
           Map.get(owner_request, :compaction_retry_submit_hold),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      WebsocketOwnerSession.submit_compaction_retry(
        owner_pid,
        downstream,
        request,
        owner_request.submission_notification?,
        hold
      )
    else
      {:error, {:invalid_owner_request, _reason}} -> {:error, :owner_unavailable}
      {:error, :upstream_identity_not_found} -> {:error, :owner_unavailable}
      {:error, _reason} = error -> error
      _invalid_hold -> {:error, :owner_unavailable}
    end
  catch
    :exit, _reason -> {:error, :owner_crashed}
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
         opts = remote_submission_opts(owner_request, codex_session_id, downstream),
         {:ok, {owner_pid, downstream}} <- ensure_remote_owner(codex_session_id, downstream, owner_request, opts),
         {:ok, request} <- WebsocketRequestCallbacks.materialize(owner_request, nil) do
      submit_remote_owner_request(
        owner_pid,
        codex_session_id,
        downstream,
        request,
        owner_request.submission_notification?,
        opts
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

  @doc false
  @spec remote_abandon_turn_v1(binary(), WebsocketOwnerSession.per_call_downstream()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def remote_abandon_turn_v1(codex_session_id, %{owner_turn_id: owner_turn_id} = downstream)
      when is_binary(codex_session_id) and is_pid(owner_turn_id) do
    case abandon_on_registered_owner(codex_session_id, downstream) do
      # No owner took the abandon (none registered, or the one holding the
      # submission died under it), while the submission may still start or
      # recover one here (findings#206 row 206-316). The record comes first and
      # the owner is looked up again, so a submission that registered its owner
      # in between is abandoned there.
      {:error, reason} when reason in [:owner_unavailable, :owner_crashed] ->
        :ok = AbandonedSubmissions.record(AbandonedSubmissions.key(codex_session_id, downstream))
        abandon_on_registered_owner(codex_session_id, downstream)

      result ->
        result
    end
  end

  defp abandon_on_registered_owner(codex_session_id, downstream) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.abandon_turn(owner_pid, downstream)
    end
  catch
    :exit, _reason -> {:error, :owner_crashed}
  end

  @doc """
  Asks the session's owner to take over the running turn `downstream` inherited
  at its attach (`WebsocketOwnerSession.take_over_inherited_turn/2`), wherever
  the owner runs (findings#206 row 206-362).

  An owner node of an earlier release has no `remote_take_over_inherited_turn_v1`
  and answers `{:error, :remote_take_over_v1_unsupported}`; the caller then keeps
  the refusal that release gives, and the client's own close still cancels the
  turn. Every other failure changes nothing either.
  """
  @spec take_over_inherited_turn(CodexSession.t(), binary(), WebsocketOwnerSession.downstream(), submit_opts()) ::
          {:ok, %{semantic_turn_digest: <<_::256>>}}
          | {:error, WebsocketOwnerContract.owner_error() | :remote_take_over_v1_unsupported}
  def take_over_inherited_turn(%CodexSession{} = session, token, downstream, opts \\ [])
      when is_binary(token) and is_map(downstream) and is_list(opts) do
    downstream = Map.take(downstream, [:pid, :epoch, :correlation_id])

    with :ok <- SessionContinuity.validate_owner_token(session, token),
         {:ok, owner} <- resolve_owner(session, opts) do
      case owner do
        {:local, _instance} -> remote_take_over_inherited_turn_v1(session.id, downstream)
        {:remote, node, _instance} -> call_remote_take_over(node, [session.id, downstream], opts)
      end
    end
  end

  @doc false
  @spec remote_take_over_inherited_turn_v1(binary(), WebsocketOwnerSession.downstream()) ::
          {:ok, %{semantic_turn_digest: <<_::256>>}} | {:error, WebsocketOwnerContract.owner_error()}
  def remote_take_over_inherited_turn_v1(codex_session_id, downstream)
      when is_binary(codex_session_id) and is_map(downstream) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.take_over_inherited_turn(owner_pid, downstream)
    end
  catch
    :exit, _reason -> {:error, :owner_crashed}
  end

  defp call_remote_take_over(node, args, opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, :remote_take_over_inherited_turn_v1, args, timeout)
    |> case do
      {:ok, %{semantic_turn_digest: digest}} when is_binary(digest) and byte_size(digest) == 32 ->
        {:ok, %{semantic_turn_digest: digest}}

      {:error, :remote_take_over_v1_unsupported} = unsupported ->
        log_take_over_protocol_incompatibility()
        unsupported

      {:error, reason} when is_atom(reason) ->
        if WebsocketOwnerContract.owner_error?(reason), do: {:error, reason}, else: {:error, :owner_crashed}

      _unsafe_result ->
        {:error, :owner_crashed}
    end
  end

  @doc false
  @spec remote_detach_previsible_downstream_v1(binary(), WebsocketOwnerSession.downstream()) ::
          :suspended | :detached | :not_previsible | {:error, WebsocketOwnerContract.owner_error()}
  def remote_detach_previsible_downstream_v1(codex_session_id, downstream)
      when is_binary(codex_session_id) and is_map(downstream) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.detach_previsible_downstream(owner_pid, downstream)
    end
  end

  # Only `:suspended` means the remote owner armed the replay, and `:detached`
  # that it accepted nothing of the closing downstream and fenced it. Everything
  # else, including an owner node that predates this call (`undef`), leaves the
  # downstream attached for the socket's ordinary detach after its drain.
  #
  # The closing socket waits for this answer before its drain, so it keeps the
  # one-second budget (findings#206 row 206-245). An answer lost to it
  # converges: an erpc timeout abandons only the reply, the owner still suspends
  # or fences the downstream when it reaches the call, and the ordinary detach
  # the socket sends after its drain queues behind it and reads the stale
  # downstream (`:detached_stale_downstream`), with no owner-lost recovery and
  # no turn interrupt. The one step that path skips is the socket's turn
  # interrupt after a `:detached`, and the owner fences only a downstream it
  # holds no turn, suspended replay or handoff for.
  @spec detach_previsible_remote_downstream(
          node(),
          binary(),
          WebsocketOwnerSession.downstream(),
          submit_opts()
        ) :: :suspended | :detached | :not_previsible
  def detach_previsible_remote_downstream(node, codex_session_id, downstream, opts)
      when is_atom(node) and is_binary(codex_session_id) and is_map(downstream) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(
      node,
      __MODULE__,
      :remote_detach_previsible_downstream_v1,
      [codex_session_id, downstream],
      timeout
    )
    |> case do
      outcome when outcome in [:suspended, :detached] -> outcome
      _not_suspended -> :not_previsible
    end
  end

  @spec cancel_remote_downstream(
          node(),
          binary(),
          WebsocketOwnerSession.downstream() | WebsocketOwnerSession.per_call_downstream(),
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

  # Only the node named as the owner is asked for its role, so resolving an
  # owner costs one probe whatever else is connected.
  defp resolve_remote_owner(owner_instance_id, opts) do
    node_client = node_client(opts)

    node_client.connected_app_nodes()
    |> Enum.find_value(fn candidate_node ->
      candidate_node_string = safe_node_string(candidate_node)

      if candidate_node_string == owner_instance_id and
           remote_app_node?(candidate_node, candidate_node_string, opts) do
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

  # A timed-out frame forward sends no best-effort cancel (findings#206 row
  # 206-276). The frame is a single client control message (`response.processed`)
  # with no turn behind it to abandon, and an erpc timeout abandons only the
  # reply: the owner still takes the queued frame, whether it was stalled or
  # still recovering. The cancel is a detach, which the owner applied after
  # that frame, so the connected socket lost its downstream at the owner and
  # every later turn on it was refused `stale_owner` until it reconnected.
  defp dispatch_submit(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         frame,
         opts
       ) do
    call_remote(node, :remote_submit_frame, [codex_session_id, downstream, frame, opts], opts)
  end

  defp dispatch_reconnect_control({:local, _owner_instance_id}, control, _opts) do
    remote_reconnect_control_v1(control)
  end

  defp dispatch_reconnect_control({:remote, node, _owner_instance_id}, control, opts) do
    result = call_remote_control(node, control, opts)

    # The cancel keeps the one-second budget and its answer is ignored
    # (findings#206 row 206-245), as in `best_effort_cancel_downstream/5`: the
    # owner-node process still makes the call after an erpc timeout, and the
    # owner takes it after the timed-out preflight, which reached it first.
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
         %WebsocketOwnerRequestV7{} = owner_request,
         _opts
       ) do
    remote_submit_request_v7(codex_session_id, downstream, owner_request)
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

    # The owner still takes a client-retry turn after its budget expired, as
    # any turn (findings#206 rows 206-306, 206-315).
    if result == {:error, :owner_forward_timeout} do
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
    end

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
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
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
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
    end

    result
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         %WebsocketOwnerRequestV7{} = owner_request,
         opts
       ) do
    submitter = self()

    cancellation_watcher =
      start_remote_cancellation_watcher(submitter, node, codex_session_id, downstream, opts)

    result =
      call_remote_submission(
        node,
        :remote_submit_request_v7,
        [codex_session_id, downstream, owner_request],
        opts
      )

    stop_remote_cancellation_watcher(cancellation_watcher, submitter)

    if result == {:error, :owner_forward_timeout} do
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
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
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
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
      best_effort_abandon_turn(node, codex_session_id, downstream, opts)
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

  # Only a query answer of `:provisional` or `:consume_reserved` sends the
  # cancel, so an answer the caller stopped waiting for is a cancel never sent,
  # and the owner-node submission, which outlives its caller, can still commit
  # the replay. Once a reservation exists the owner answers both controls from
  # a database read of the replay binding, queued behind whatever the owner is
  # doing, so the caller waits the owner's own call budget for them: with the
  # one-second downstream send budget a slower answer was dropped and the dead
  # or timed-out submitter's unconsumed reservation was never cancelled
  # (findings#206 row 206-241). Both callers are the submitting response task
  # or a watcher nobody waits on, never the socket process.
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
    Keyword.put(opts, :timeout, WebsocketOwnerContract.default_owner_call_timeout_ms())
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
    with :ok <- refuse_abandoned_submission(opts) do
      WebsocketOwnerSession.submit_request(
        owner_pid,
        downstream,
        request,
        submission_notification?
      )
    end
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
             :ok <- notify_recovered_runtime(replacement_session, replacement_downstream),
             :ok <- refuse_abandoned_submission(opts) do
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

  defp validate_owner_request_v7(%WebsocketOwnerRequestV7{} = owner_request) do
    case WebsocketOwnerRequestV7.validate(owner_request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_owner_request, reason}}
    end
  end

  defp validate_owner_request_v7(_owner_request),
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

  # A remote turn submission carries the node-level key of its per-call
  # downstream, read after its owner is registered or recovered: a proxy that
  # abandoned it while no owner was registered here left that record
  # (findings#206 row 206-316).
  defp remote_submission_opts(owner_request, codex_session_id, downstream),
    do: Keyword.put(request_recovery_opts(owner_request), :abandoned_submission_key, AbandonedSubmissions.key(codex_session_id, downstream))

  defp refuse_abandoned_submission(opts) do
    if AbandonedSubmissions.consume(Keyword.get(opts, :abandoned_submission_key)),
      do: {:error, :stale_downstream},
      else: :ok
  end

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
      pool_id: session.pool_id,
      api_key_id: session.api_key_id,
      owner_lease_token: session.owner_lease_token,
      owner_instance_id: session.owner_instance_id,
      request_id: Keyword.get(opts, :request_id),
      idle_shutdown_ms: OperationalSettings.current().websocket_owner_idle_timeout_ms
    ]

    start_opts =
      start_opts
      |> maybe_put_recovery_upstream(opts)
      |> maybe_put_recovery_handoff_timeouts(opts)

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

  @recovery_handoff_timeout_keys [:handoff_soft_timeout_ms, :handoff_absolute_timeout_ms]

  # The caller options are the only request-scoped carrier for the handoff
  # timeouts `WebsocketOwnerSession.start_owner/1` accepts, so a recovered
  # owner copies positive integer values through beside the upstream boundary
  # exactly like the local gateway start path. Absent or malformed values keep
  # the owner defaults.
  defp maybe_put_recovery_handoff_timeouts(start_opts, opts) do
    Enum.reduce(@recovery_handoff_timeout_keys, start_opts, fn key, acc ->
      case Keyword.get(opts, key) do
        timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
          Keyword.put(acc, key, timeout_ms)

        _absent_or_invalid ->
          acc
      end
    end)
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

  # A turn submission whose forward budget expired (findings#206 row 206-299):
  # the client is told the turn failed, and an erpc timeout abandons only the
  # reply, so the owner may still take the queued turn. Its output must not
  # reach that client, but the socket is still connected: the owner stops only
  # the turn this per-call downstream submitted and keeps the downstream, where
  # the detach a closing socket sends also cleared it and every later turn on
  # the socket was refused `stale_owner`. Same one-second, ignored-answer
  # budget as the detach it replaces. A downstream that names no turn gets that
  # detach, as before.
  defp best_effort_abandon_turn(node, codex_session_id, %{owner_turn_id: owner_turn_id} = downstream, opts)
       when is_pid(owner_turn_id) do
    budget_opts = Keyword.put(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())

    case call_remote_abandon_turn(node, [codex_session_id, downstream], budget_opts) do
      {:error, :remote_abandon_v1_unsupported} -> stop_turn_without_abandon(node, codex_session_id, downstream, budget_opts)
      _result -> :ok
    end
  end

  defp best_effort_abandon_turn(node, codex_session_id, downstream, opts),
    do: best_effort_cancel_downstream(node, codex_session_id, downstream, opts)

  # An owner node that predates the abandon (findings#206 row 206-315). The
  # closing-socket detach is no way to stop the turn there: for a turn that
  # can be replayed (the released client's turns) and has shown nothing yet,
  # it arms a pre-visible replay, which makes the timed-out task's failure
  # settlement a stale generation, so the task ended as a success, no error
  # frame reached the still connected client and its delivery never completed
  # (every submission version alike; the client-retry one was only the first
  # seen). The per-call cancel of the rollout drain, which every release
  # without the abandon has, stops exactly that turn without a replay (the
  # owner records its cancel as `owner_drained` internally; the proxy's own
  # settlement keeps `owner_forward_timeout`). When it finds no turn of this
  # downstream, the submission has not reached the owner yet, and the detach
  # then clears the downstream so that late submission is refused, as before.
  # Both calls clear the owner's downstream, so later turns on the socket get
  # `stale_owner` until the client reconnects, as they did before the abandon.
  defp stop_turn_without_abandon(node, codex_session_id, downstream, budget_opts) do
    case cancel_remote_downstream(node, codex_session_id, downstream, :owner_drained, budget_opts) do
      :ok -> :ok
      _no_turn_of_this_downstream -> best_effort_cancel_downstream(node, codex_session_id, downstream, budget_opts)
    end
  end

  defp call_remote_abandon_turn(node, args, opts) do
    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, :remote_abandon_turn_v1, args, Keyword.fetch!(opts, :timeout))
    |> case do
      {:error, :remote_abandon_v1_unsupported} = unsupported -> unsupported
      result -> normalize_forward_result(result)
    end
  end

  # Fire and forget under the one-second budget on purpose (findings#206 row
  # 206-242): an erpc timeout abandons only the reply, the owner-node process
  # still runs the detach or cancel under the owner's own call budget, and no
  # caller acts on the answer. Contrast `reconcile_remote_v4_timeout/4`, whose
  # query answer decides whether a cancel is sent at all.
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

  # An owner's native compaction admission answer keeps its own vocabulary
  # across nodes, as it does from a local owner (`remote_admission_control_v1/2`
  # returns it unchanged there). Folded into `owner_crashed`, a remote owner's
  # refusal logged a crash that never happened and a compaction item mismatch
  # answered `503 owner_unavailable` instead of the local `409` (findings#206
  # row 206-334, two-node run). The vocabulary is `NativeCompactionAdmission`'s
  # own, read at run time: a copy kept here let a new refusal read
  # `owner_crashed` on a remote owner again (row 206-400).
  defp normalize_remote_call_result({:error, reason} = result, :remote_admission_control_v1)
       when is_atom(reason) do
    if NativeCompactionAdmission.refusal_reason?(reason),
      do: result,
      else: normalize_forward_result(result)
  end

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

  defp normalize_reconnect_control_result({:ok, :provisional, token, 1, generation, downstream} = result)
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

      version = missing_full_history_submit_version(reason, module, function, args) ->
        log_protocol_incompatibility(version)
        {:error, :owner_unavailable}

      missing_remote_submit_v2?(reason, module, function, args) ->
        log_protocol_incompatibility(:v2)
        {:error, :owner_unavailable}

      missing_remote_submit_v3?(reason, module, function, args) ->
        log_protocol_incompatibility(:v3)
        {:error, :owner_unavailable}

      unsupported = unsupported_remote_cancel(reason, module, function, args) ->
        {:error, unsupported}

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
          | :remote_abandon_v1_unsupported
          | :remote_take_over_v1_unsupported
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

      version = missing_full_history_submit_version(reason, module, function, args) ->
        log_protocol_incompatibility(version)
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

      unsupported = unsupported_remote_cancel(reason, module, function, args) ->
        unsupported

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
      version = missing_full_history_submit_version(reason, module, function, args) ->
        log_protocol_incompatibility(version)
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
         {:exception, :undef, [{module, :remote_submit_request_v1, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v1?(_reason, _module, _function, _args), do: false

  defp missing_full_history_submit_version(reason, module, function, args) do
    cond do
      missing_remote_submit_v7?(reason, module, function, args) -> :v7
      missing_remote_submit_v6?(reason, module, function, args) -> :v6
      true -> nil
    end
  end

  defp missing_remote_submit_v6?(
         {:exception, :undef, [{module, :remote_submit_request_v6, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v6,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v6?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v7?(
         {:exception, :undef, [{module, :remote_submit_request_v7, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v7,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v7?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v2?(
         {:exception, :undef, [{module, :remote_submit_request_v2, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v2,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v2?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v3?(
         {:exception, :undef, [{module, :remote_submit_request_v3, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v3,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v3?(_reason, _module, _function, _args), do: false

  defp missing_remote_submit_v5?(
         {:exception, :undef, [{module, :remote_submit_request_v5, remote_args, _location} | _stack]},
         module,
         :remote_submit_request_v5,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_submit_v5?(_reason, _module, _function, _args), do: false

  # An owner node that predates a versioned cancel entrypoint answers `undef`;
  # its caller then falls back to the legacy detach.
  defp unsupported_remote_cancel(reason, module, function, args) do
    cond do
      missing_remote_cancel_v1?(reason, module, function, args) -> :remote_cancel_v1_unsupported
      missing_remote_abandon_v1?(reason, module, function, args) -> :remote_abandon_v1_unsupported
      missing_remote_take_over_v1?(reason, module, function, args) -> :remote_take_over_v1_unsupported
      true -> nil
    end
  end

  defp missing_remote_cancel_v1?(
         {:exception, :undef, [{module, :remote_cancel_downstream_v1, remote_args, _location} | _stack]},
         module,
         :remote_cancel_downstream_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 3

  defp missing_remote_cancel_v1?(_reason, _module, _function, _args), do: false

  defp missing_remote_abandon_v1?(
         {:exception, :undef, [{module, :remote_abandon_turn_v1, remote_args, _location} | _stack]},
         module,
         :remote_abandon_turn_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 2

  defp missing_remote_abandon_v1?(_reason, _module, _function, _args), do: false

  defp missing_remote_take_over_v1?(
         {:exception, :undef, [{module, :remote_take_over_inherited_turn_v1, remote_args, _location} | _stack]},
         module,
         :remote_take_over_inherited_turn_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 2

  defp missing_remote_take_over_v1?(_reason, _module, _function, _args), do: false

  defp missing_remote_reconnect_control_v1?(
         {:exception, :undef, [{module, :remote_reconnect_control_v1, remote_args, _location} | _stack]},
         module,
         :remote_reconnect_control_v1,
         args
       ),
       do: remote_args == args and length(remote_args) == 1

  defp missing_remote_reconnect_control_v1?(_reason, _module, _function, _args), do: false

  defp log_take_over_protocol_incompatibility do
    require Logger

    Logger.warning(
      "websocket owner protocol incompatible event=owner_protocol_incompatible " <>
        "boundary=inherited_turn_take_over protocol=v1 canonical_error=owner_busy"
    )
  end

  defp log_control_protocol_incompatibility do
    require Logger

    Logger.warning(
      "websocket owner protocol incompatible event=owner_protocol_incompatible " <>
        "boundary=reconnect_control protocol=v1 canonical_error=owner_unavailable"
    )
  end

  defp log_protocol_incompatibility(version) when version in [:v1, :v2, :v3, :v5, :v6, :v7] do
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
    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

    @impl NodeClient
    def connected_app_nodes, do: Node.list()

    # The role probe waits as long as the owner call that follows it
    # (findings#206 row 206-245). Under a one-second budget an owner node that
    # stalled for longer resolved as unavailable, and a closing socket's detach
    # that reads `owner_unavailable` runs its owner-lost recovery against a turn
    # the owner is still serving: the outcome row 206-212 removed from the
    # detach call itself.
    @impl NodeClient
    def app_node?(node) when is_atom(node) do
      case :erpc.call(node, System, :get_env, ["OBAN_MODE"], WebsocketOwnerContract.default_owner_call_timeout_ms()) do
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
