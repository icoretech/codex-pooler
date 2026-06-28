defmodule CodexPooler.Gateway.Websocket do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.{ContinuityPayload, PayloadNormalizer, RequestOptions}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Admission

  alias CodexPooler.Gateway.Transports.Websocket.{
    RolloutDrain,
    UpstreamWebsocketSession,
    WebsocketOwnerContract,
    WebsocketOwnerForwarder,
    WebsocketOwnerSession
  }

  alias CodexPooler.RouteClass

  @type auth :: CodexPooler.Access.auth_context()
  @type opts :: map() | keyword() | RequestOptions.t()
  @type session_ref :: CodexSession.t() | Ecto.UUID.t()
  @type request_ref :: Request.t() | Ecto.UUID.t()
  @type payload :: map()
  @type session_result :: {:ok, CodexSession.t()} | {:error, term()}
  @type turn_result :: {:ok, CodexTurn.t()} | {:error, term()}
  @type owner_runtime_retarget_result ::
          {:ok, websocket_runtime()} | {:error, WebsocketOwnerContract.owner_error()}
  @type websocket_runtime :: %{
          required(:codex_session) => CodexSession.t(),
          optional(:upstream_websocket_session) => pid(),
          optional(:websocket_owner_lease_token) => String.t(),
          optional(:websocket_owner_downstream) => WebsocketOwnerSession.downstream(),
          optional(:websocket_owner_active_turn_reconnect?) => boolean()
        }

  @spec websocket_owner_forwarding_enabled?() :: boolean()
  defdelegate websocket_owner_forwarding_enabled?, to: OperationalSettings

  @spec require_websocket_owner_forwarding_enabled() ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def require_websocket_owner_forwarding_enabled do
    if websocket_owner_forwarding_enabled?(),
      do: :ok,
      else: {:error, :owner_forwarding_disabled}
  end

  @spec start_codex_session(auth(), opts()) :: session_result()
  def start_codex_session(auth, opts \\ %{}) do
    SessionContinuity.start_codex_session(auth, websocket_request_options(opts))
  end

  @spec prepare_websocket_session(auth(), opts()) :: {:ok, websocket_runtime()} | {:error, term()}
  def prepare_websocket_session(auth, opts \\ %{}) do
    opts = websocket_request_options(opts)

    with :ok <- reject_if_rollout_draining() do
      if websocket_owner_forwarding_enabled?(),
        do: prepare_owner_websocket_session(auth, opts),
        else: prepare_local_websocket_session(auth, opts)
    end
  end

  defp reject_if_rollout_draining do
    if RolloutDrain.draining?(),
      do: {:error, :owner_drained},
      else: :ok
  end

  defp prepare_local_websocket_session(auth, opts) do
    with {:ok, session} <- start_codex_session(auth, opts),
         {:ok, upstream_websocket_session} <- UpstreamWebsocketSession.start_link() do
      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}}
    end
  end

  defp prepare_owner_websocket_session(auth, opts) do
    opts = owner_websocket_opts(opts)

    with {:ok, session} <- start_codex_session(auth, opts) do
      prepare_owner_websocket_session_with_recovery(session, opts, true)
    end
  end

  defp prepare_owner_websocket_session_with_recovery(session, opts, allow_takeover?) do
    case attach_local_owner_websocket_session(session, opts) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, :owner_unavailable} when allow_takeover? ->
        log_owner_takeover_attempt(session, opts)
        replace_and_attach_unavailable_owner(session, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_and_attach_unavailable_owner(%CodexSession{} = session, %RequestOptions{} = opts) do
    case SessionContinuity.replace_unavailable_owner_lease(session, opts) do
      {:ok, replacement_session} ->
        attach_replacement_owner(session, replacement_session, opts)

      {:error, reason} = error ->
        log_owner_takeover_failure(session, opts, reason)
        error
    end
  end

  defp attach_replacement_owner(
         %CodexSession{} = previous_session,
         %CodexSession{} = replacement_session,
         %RequestOptions{} = opts
       ) do
    case prepare_owner_websocket_session_with_recovery(replacement_session, opts, false) do
      {:ok, _runtime} = result ->
        log_owner_takeover_success(previous_session, replacement_session, opts)
        result

      {:error, reason} = error ->
        log_owner_takeover_failure(replacement_session, opts, reason)
        error
    end
  end

  defp log_owner_takeover_attempt(%CodexSession{} = session, %RequestOptions{} = opts) do
    Logger.info(
      "websocket owner takeover attempted " <>
        owner_takeover_log_metadata(session, opts, "attempting", "none")
    )
  end

  defp log_owner_takeover_success(
         %CodexSession{} = previous_session,
         %CodexSession{} = replacement_session,
         %RequestOptions{} = opts
       ) do
    Logger.info(
      "websocket owner takeover succeeded " <>
        owner_takeover_log_metadata(replacement_session, opts, "succeeded", "none") <>
        " previous_owner_instance_id=#{safe_log_token(previous_session.owner_instance_id)}"
    )
  end

  defp log_owner_takeover_failure(%CodexSession{} = session, %RequestOptions{} = opts, reason) do
    Logger.warning(
      "websocket owner takeover failed " <>
        owner_takeover_log_metadata(session, opts, "failed", "investigate") <>
        " failure_reason=#{owner_takeover_reason(reason)}"
    )
  end

  defp owner_takeover_log_metadata(
         %CodexSession{} = session,
         %RequestOptions{} = opts,
         outcome,
         operator_action
       ) do
    [
      "recovery_class=owner_unavailable_takeover",
      "operator_action=#{safe_log_token(operator_action)}",
      "outcome=#{safe_log_token(outcome)}",
      "codex_session_id=#{safe_log_token(session.id)}",
      "request_id=#{safe_log_token(request_id(opts))}",
      "owner_instance_id=#{safe_log_token(session.owner_instance_id)}",
      "proxy_instance_id=#{safe_log_token(Atom.to_string(node()))}",
      "owner_lease_expires_at=#{safe_log_datetime(session.owner_lease_expires_at)}",
      "last_heartbeat_at=#{safe_log_datetime(session.last_heartbeat_at)}",
      "session_status=#{safe_log_token(session.status)}"
    ]
    |> Enum.join(" ")
  end

  defp owner_takeover_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp owner_takeover_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp owner_takeover_reason(_reason), do: "unavailable"

  defp safe_log_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe_log_datetime(_value), do: "none"

  defp safe_log_token(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:@-]+/, "_")
    |> String.slice(0, 160)
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp safe_log_token(_value), do: "none"

  defp attach_local_owner_websocket_session(session, opts) do
    with :ok <- ensure_local_owner_session(session, opts),
         {:ok, downstream} <- attach_owner_downstream(session, opts) do
      {:ok,
       %{
         codex_session: session,
         websocket_owner_lease_token: session.owner_lease_token,
         websocket_owner_downstream: downstream,
         websocket_owner_active_turn_reconnect?: active_turn_reconnect?(downstream)
       }}
    end
  end

  @spec websocket_response_options(opts(), CodexSession.t() | nil, pid() | nil, boolean()) ::
          RequestOptions.t()
  def websocket_response_options(
        opts,
        codex_session,
        upstream_websocket_session,
        reuse_upstream_session?
      ) do
    opts
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_continuity(codex_session: codex_session)
    |> maybe_put_upstream_websocket_session(upstream_websocket_session, reuse_upstream_session?)
  end

  @spec websocket_owner_response_options(
          opts(),
          CodexSession.t() | nil,
          String.t() | nil,
          WebsocketOwnerSession.downstream() | nil
        ) :: RequestOptions.t()
  def websocket_owner_response_options(opts, codex_session, owner_lease_token, downstream) do
    opts
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_continuity(codex_session: codex_session)
    |> RequestOptions.put_transport(
      websocket_owner_forwarding_enabled?: true,
      websocket_owner_session: codex_session,
      websocket_owner_lease_token: owner_lease_token,
      websocket_owner_downstream: downstream,
      websocket_owner_downstream_epoch: downstream_epoch(downstream),
      websocket_owner_proxy_instance_id: Atom.to_string(node()),
      websocket_owner_instance_id: owner_instance_id(codex_session),
      websocket_owner_forwarder_opts: owner_forwarder_opts(opts)
    )
  end

  @spec recover_websocket_owner_response_options(RequestOptions.t()) ::
          {:ok, RequestOptions.t()} | {:error, term()}
  def recover_websocket_owner_response_options(
        %RequestOptions{
          continuity: %{codex_session: %CodexSession{} = session}
        } = opts
      ) do
    if session.owner_instance_id == Atom.to_string(node()) do
      opts = owner_websocket_opts(opts)

      session
      |> prepare_owner_websocket_session_with_recovery(opts, true)
      |> recovered_websocket_owner_response_options(opts)
    else
      {:error, :owner_unavailable}
    end
  end

  def recover_websocket_owner_response_options(%RequestOptions{}),
    do: {:error, :owner_unavailable}

  @spec retarget_websocket_owner_runtime(auth(), websocket_runtime(), payload(), opts()) ::
          owner_runtime_retarget_result()
  def retarget_websocket_owner_runtime(auth, runtime, payload, opts \\ %{})

  def retarget_websocket_owner_runtime(auth, runtime, payload, opts)
      when is_map(runtime) and is_map(payload) do
    case ContinuityPayload.previous_response_id(payload) do
      nil ->
        retarget_websocket_owner_runtime_from_turn_state(auth, runtime, payload, opts)

      previous_response_id ->
        retarget_websocket_owner_runtime_from_previous_response_id(
          auth,
          runtime,
          previous_response_id,
          opts
        )
    end
  end

  def retarget_websocket_owner_runtime(_auth, runtime, _payload, _opts) when is_map(runtime),
    do: {:ok, runtime}

  @spec retarget_websocket_owner_runtime_from_previous_response_id(
          auth(),
          websocket_runtime(),
          String.t(),
          opts()
        ) :: owner_runtime_retarget_result()
  defp retarget_websocket_owner_runtime_from_previous_response_id(
         auth,
         %{codex_session: %CodexSession{} = current_session} = runtime,
         previous_response_id,
         opts
       )
       when is_binary(previous_response_id) do
    retarget_opts = owner_retarget_websocket_opts(opts, runtime, previous_response_id)

    with :ok <- require_websocket_owner_forwarding_enabled(),
         {:ok, %CodexSession{} = target_session} <-
           start_owner_session_from_previous_response_id(auth, retarget_opts) do
      retarget_owner_runtime_to_session(current_session, runtime, target_session, retarget_opts)
    end
  end

  defp retarget_websocket_owner_runtime_from_previous_response_id(
         _auth,
         _runtime,
         _previous_response_id,
         _opts
       ),
       do: {:error, :owner_unavailable}

  @spec retarget_websocket_owner_runtime_from_turn_state(
          auth(),
          websocket_runtime(),
          payload(),
          opts()
        ) ::
          owner_runtime_retarget_result()
  defp retarget_websocket_owner_runtime_from_turn_state(
         auth,
         %{codex_session: %CodexSession{} = current_session} = runtime,
         payload,
         opts
       )
       when is_map(payload) do
    with %RequestOptions{openai_compatibility: %{public_openai_responses_stream: false}} = opts <-
           owner_websocket_opts(opts),
         turn_state when is_binary(turn_state) <-
           PayloadNormalizer.backend_client_metadata_turn_state(payload) do
      retarget_opts = RequestOptions.put_continuity(opts, accepted_turn_state: turn_state)

      attach_websocket_owner_runtime_from_turn_state(
        auth,
        current_session,
        runtime,
        retarget_opts
      )
    else
      %RequestOptions{} -> {:ok, runtime}
      nil -> {:ok, runtime}
    end
  end

  defp retarget_websocket_owner_runtime_from_turn_state(_auth, runtime, _payload, _opts)
       when is_map(runtime),
       do: {:ok, runtime}

  @spec attach_websocket_owner_runtime_from_turn_state(
          auth(),
          CodexSession.t(),
          websocket_runtime(),
          RequestOptions.t()
        ) :: owner_runtime_retarget_result()
  defp attach_websocket_owner_runtime_from_turn_state(
         auth,
         %CodexSession{} = current_session,
         runtime,
         %RequestOptions{} = retarget_opts
       ) do
    with :ok <- require_websocket_owner_forwarding_enabled(),
         {:ok, %CodexSession{} = target_session} <-
           start_owner_session_from_turn_state(auth, retarget_opts) do
      retarget_owner_runtime_to_session(current_session, runtime, target_session, retarget_opts)
    else
      {:error, :session_not_found} -> {:ok, runtime}
      {:error, reason} -> owner_retarget_error(reason)
    end
  end

  @spec retarget_owner_runtime_to_session(
          CodexSession.t(),
          websocket_runtime(),
          CodexSession.t(),
          RequestOptions.t()
        ) :: owner_runtime_retarget_result()
  defp retarget_owner_runtime_to_session(
         %CodexSession{id: session_id},
         runtime,
         %CodexSession{id: session_id},
         %RequestOptions{}
       ) do
    {:ok, runtime}
  end

  defp retarget_owner_runtime_to_session(
         %CodexSession{},
         _runtime,
         %CodexSession{} = target_session,
         %RequestOptions{} = retarget_opts
       ) do
    target_session
    |> prepare_owner_websocket_session_with_recovery(retarget_opts, true)
    |> owner_runtime_retarget_result()
  end

  @spec owner_retarget_websocket_opts(opts(), websocket_runtime(), String.t()) ::
          RequestOptions.t()
  defp owner_retarget_websocket_opts(opts, _runtime, previous_response_id) do
    opts
    |> owner_websocket_opts()
    |> RequestOptions.put_continuity(previous_response_id: previous_response_id)
  end

  @spec start_owner_session_from_previous_response_id(auth(), RequestOptions.t()) ::
          {:ok, CodexSession.t()} | {:error, WebsocketOwnerContract.owner_error()}
  defp start_owner_session_from_previous_response_id(auth, %RequestOptions{} = opts) do
    case SessionContinuity.start_codex_session_from_previous_response_id(auth, opts) do
      {:ok, %CodexSession{} = session} -> {:ok, session}
      {:error, reason} -> owner_retarget_error(reason)
    end
  end

  @spec start_owner_session_from_turn_state(auth(), RequestOptions.t()) ::
          {:ok, CodexSession.t()}
          | {:error, :session_not_found | WebsocketOwnerContract.owner_error()}
  defp start_owner_session_from_turn_state(auth, %RequestOptions{} = opts) do
    case SessionContinuity.start_codex_session_from_turn_state(auth, opts) do
      {:ok, %CodexSession{} = session} -> {:ok, session}
      {:error, :session_not_found} -> {:error, :session_not_found}
      {:error, reason} -> owner_retarget_error(reason)
    end
  end

  @spec owner_runtime_retarget_result({:ok, websocket_runtime()} | {:error, term()}) ::
          owner_runtime_retarget_result()
  defp owner_runtime_retarget_result({:ok, runtime}), do: {:ok, runtime}
  defp owner_runtime_retarget_result({:error, reason}), do: owner_retarget_error(reason)

  @spec owner_retarget_error(term()) :: {:error, WebsocketOwnerContract.owner_error()}
  defp owner_retarget_error(reason) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_unavailable}
  end

  @spec monitor_websocket_owner(CodexSession.t() | nil) ::
          {:ok, pid(), reference()} | {:error, :owner_unavailable}
  def monitor_websocket_owner(%CodexSession{owner_instance_id: owner_instance_id, id: id})
      when is_binary(owner_instance_id) and is_binary(id) do
    if owner_instance_id == Atom.to_string(node()) do
      with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(id) do
        {:ok, owner_pid, Process.monitor(owner_pid)}
      end
    else
      {:error, :owner_unavailable}
    end
  end

  def monitor_websocket_owner(_session), do: {:error, :owner_unavailable}

  @spec release_websocket_owner_lease(
          CodexSession.t() | nil,
          Ecto.UUID.t() | String.t() | nil,
          String.t()
        ) :: :ok | {:error, :stale_owner | :owner_unavailable}
  def release_websocket_owner_lease(%CodexSession{} = session, owner_lease_token, reason)
      when is_binary(reason) do
    SessionContinuity.release_owner_lease(session, owner_lease_token, reason)
  end

  def release_websocket_owner_lease(_session, _owner_lease_token, _reason),
    do: {:error, :owner_unavailable}

  defp recovered_websocket_owner_response_options({:ok, runtime}, opts) do
    {:ok,
     websocket_owner_response_options(
       opts,
       runtime.codex_session,
       runtime.websocket_owner_lease_token,
       runtime.websocket_owner_downstream
     )}
  end

  defp recovered_websocket_owner_response_options({:error, reason}, _opts), do: {:error, reason}

  @spec run_websocket_response(auth(), binary(), opts(), (binary() -> any())) ::
          :ok | {:error, Contracts.gateway_error()}
  def run_websocket_response(auth, payload, opts, push_frame)
      when is_binary(payload) and is_function(push_frame, 1) do
    Admission.run(RouteClass.proxy_websocket(), websocket_metadata(opts), fn ->
      CodexPooler.Gateway.execute_websocket_response(auth, payload, opts, push_frame)
    end)
  end

  @spec detach_websocket_owner_downstream(
          CodexSession.t() | nil,
          String.t() | nil,
          WebsocketOwnerSession.downstream() | nil,
          opts()
        ) :: :ok | :detached_stale_downstream | {:error, WebsocketOwnerContract.owner_error()}
  def detach_websocket_owner_downstream(
        %CodexSession{} = session,
        owner_lease_token,
        downstream,
        opts
      )
      when is_binary(owner_lease_token) and is_map(downstream) do
    opts = websocket_request_options(opts)

    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <-
           WebsocketOwnerForwarder.resolve_owner(session, owner_forwarder_opts(opts)) do
      owner_detach_result(detach_owner(owner, session.id, downstream, opts))
    else
      {:error, :stale_owner} -> :ok
      {:error, reason} -> owner_detach_error(reason)
    end
  end

  def detach_websocket_owner_downstream(_session, _owner_lease_token, _downstream, _opts), do: :ok

  defp owner_detach_error(reason) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_unavailable}
  end

  defp owner_detach_result(:ok), do: :ok
  defp owner_detach_result({:error, :stale_owner}), do: :ok
  defp owner_detach_result({:error, :stale_downstream}), do: :detached_stale_downstream
  defp owner_detach_result({:error, :duplicate_downstream}), do: :detached_stale_downstream
  defp owner_detach_result({:error, reason}), do: owner_detach_error(reason)

  defp active_turn_reconnect?(%{active_turn_reconnect?: true}), do: true
  defp active_turn_reconnect?(_downstream), do: false

  defp owner_attach_error(reason) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_unavailable}
  end

  @spec close_websocket_session(pid() | term()) :: :ok
  def close_websocket_session(pid) when is_pid(pid), do: UpstreamWebsocketSession.close(pid)
  def close_websocket_session(_session), do: :ok

  @spec register_codex_session_continuity(
          CodexSession.t(),
          payload(),
          map() | binary(),
          opts()
        ) :: :ok | {:error, term()}
  def register_codex_session_continuity(session, payload, response_body, opts \\ %{}) do
    SessionContinuity.register_codex_session_continuity(
      session,
      payload,
      response_body,
      websocket_request_options(opts)
    )
  end

  @spec duplicate_codex_turn?(CodexSession.t(), Ecto.UUID.t() | String.t()) :: boolean()
  defdelegate duplicate_codex_turn?(session, request_id), to: SessionContinuity

  @spec start_codex_turn(CodexSession.t(), Request.t(), opts()) :: turn_result()
  def start_codex_turn(session, request, opts \\ %{}) do
    SessionContinuity.start_codex_turn(session, request, websocket_request_options(opts))
  end

  @spec mark_codex_turn_visible(request_ref()) :: :ok
  defdelegate mark_codex_turn_visible(request), to: SessionContinuity

  @spec interrupt_codex_session(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_session(session, opts \\ %{}) do
    Interruption.interrupt_codex_session(session, websocket_request_options(opts))
  end

  @spec interrupt_codex_turn(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_turn(session, opts \\ %{}) do
    Interruption.interrupt_codex_turn(session, websocket_request_options(opts))
  end

  @spec recover_owner_lifecycle_leftovers(session_ref(), atom() | String.t(), opts()) ::
          {:ok, term()} | {:error, term()}
  def recover_owner_lifecycle_leftovers(session, owner_reason, opts \\ %{}) do
    Interruption.recover_owner_lifecycle_leftovers(
      session,
      owner_reason,
      websocket_request_options(opts)
    )
  end

  defp maybe_put_upstream_websocket_session(opts, upstream_websocket_session, true) do
    RequestOptions.put_transport(opts, upstream_websocket_session: upstream_websocket_session)
  end

  defp maybe_put_upstream_websocket_session(opts, _upstream_websocket_session, false), do: opts

  defp downstream_epoch(%{epoch: epoch}) when is_integer(epoch) and epoch > 0, do: epoch
  defp downstream_epoch(_downstream), do: nil

  defp owner_instance_id(%CodexSession{owner_instance_id: owner_instance_id})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp owner_instance_id(_session), do: nil

  defp owner_websocket_opts(opts) do
    opts
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_continuity(authenticated_owner_attach: true)
  end

  defp ensure_local_owner_session(%CodexSession{} = session, opts) do
    owner_instance_id = Atom.to_string(node())

    if session.owner_instance_id == owner_instance_id do
      start_opts = [
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: owner_instance_id,
        request_id: request_id(opts)
      ]

      start_opts = maybe_put_owner_upstream(start_opts, opts)

      case WebsocketOwnerSession.start_owner(start_opts) do
        {:ok, _pid} -> :ok
        {:ok, _pid, :existing} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp attach_owner_downstream(%CodexSession{} = session, opts) do
    with :ok <- SessionContinuity.validate_owner_token(session, session.owner_lease_token),
         {:ok, owner} <-
           WebsocketOwnerForwarder.resolve_owner(session, owner_forwarder_opts(opts)) do
      attach_owner(owner, session.id, owner_downstream_target(opts), opts)
    else
      {:error, reason} -> owner_attach_error(reason)
    end
  end

  defp owner_downstream_target(%RequestOptions{
         transport: %{websocket_owner: %{downstream: %{pid: pid, correlation_id: correlation_id}}}
       })
       when is_pid(pid) and is_binary(correlation_id) do
    %{pid: pid, correlation_id: correlation_id}
  end

  defp owner_downstream_target(_opts), do: %{pid: self(), correlation_id: Ecto.UUID.generate()}

  defp attach_owner({:local, owner_instance_id}, codex_session_id, downstream, opts) do
    with {:ok, pid} <-
           WebsocketOwnerSession.lookup(
             codex_session_id,
             owner_lookup_metadata(owner_instance_id, opts)
           ) do
      WebsocketOwnerSession.attach_downstream(pid, downstream)
    end
  end

  defp attach_owner({:remote, node, _owner_instance_id}, codex_session_id, downstream, opts) do
    WebsocketOwnerForwarder.call_remote(
      node,
      :remote_attach_downstream,
      [codex_session_id, downstream],
      opts
      |> owner_forwarder_opts()
      |> Keyword.put_new(:timeout, WebsocketOwnerContract.default_owner_call_timeout_ms())
    )
  end

  defp detach_owner({:local, owner_instance_id}, codex_session_id, downstream, opts) do
    with {:ok, pid} <-
           WebsocketOwnerSession.lookup(
             codex_session_id,
             owner_lookup_metadata(owner_instance_id, opts)
           ) do
      WebsocketOwnerSession.detach_downstream(pid, downstream)
    end
  end

  defp detach_owner({:remote, node, _owner_instance_id}, codex_session_id, downstream, opts) do
    WebsocketOwnerForwarder.call_remote(
      node,
      :remote_cancel_downstream,
      [codex_session_id, downstream],
      opts
      |> owner_forwarder_opts()
      |> Keyword.put_new(:timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())
    )
  end

  defp owner_forwarder_opts(%RequestOptions{
         transport: %{websocket_owner: %{forwarder_opts: opts}}
       })
       when is_list(opts),
       do: opts

  defp owner_forwarder_opts(opts) do
    opts
    |> websocket_request_options()
    |> owner_forwarder_opts()
  end

  defp owner_lookup_metadata(owner_instance_id, opts) do
    [owner_instance_id: owner_instance_id, request_id: request_id(opts)]
  end

  defp maybe_put_owner_upstream(start_opts, %RequestOptions{
         transport: %{websocket_owner: %{forwarder_opts: opts}}
       }) do
    case Keyword.get(opts, :upstream) do
      nil -> start_opts
      upstream -> Keyword.put(start_opts, :upstream, upstream)
    end
  end

  defp websocket_metadata(opts) do
    opts = websocket_request_options(opts)

    %{
      request_id: request_id(opts),
      endpoint: "/backend-api/codex/responses",
      transport: "websocket"
    }
  end

  defp request_id(%RequestOptions{} = opts), do: opts.request_metadata.request_id
  defp websocket_request_options(%RequestOptions{} = opts), do: RequestOptions.for_websocket(opts)
  defp websocket_request_options(opts), do: RequestOptions.for_websocket(opts)
end
