defmodule CodexPooler.Gateway do
  @moduledoc """
  Gateway-owned runtime orchestration state for external protocol controllers.

  The gateway context owns Codex websocket session/turn lifecycle, idempotency,
  routing circuit state, and dispatch finalization. Pure request accounting
  lifecycle calls live in `CodexPooler.Accounting`.
  """

  require Logger

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Catalog.Model

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Service
  alias CodexPooler.Repo

  alias CodexPooler.Gateway.Transports.Admission

  alias CodexPooler.Gateway.Transports.Websocket.{
    UpstreamWebSocketSession,
    WebsocketOwnerContract,
    WebsocketOwnerForwarder,
    WebsocketOwnerSession
  }

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn,
    RoutingCircuitState,
    RuntimeCleanup,
    SessionContinuity,
    SessionReadModel
  }

  alias CodexPooler.Pools.Pool
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @type auth :: CodexPooler.Access.auth_context()
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type model_ref :: Model.t() | Ecto.UUID.t() | String.t()
  @type session_ref :: CodexSession.t() | Ecto.UUID.t()
  @type request_ref :: Request.t() | Ecto.UUID.t()
  @type payload :: map()
  @type opts :: map() | keyword() | RequestOptions.t()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  @type session_result :: {:ok, CodexSession.t()} | {:error, term()}
  @type turn_result :: {:ok, CodexTurn.t()} | {:error, term()}
  @type websocket_runtime :: %{
          required(:codex_session) => CodexSession.t(),
          optional(:upstream_websocket_session) => pid(),
          optional(:websocket_owner_lease_token) => String.t(),
          optional(:websocket_owner_downstream) => WebsocketOwnerSession.downstream()
        }
  @type admission_lease :: term()
  @type session_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          optional(atom()) => term()
        }
  @type turn_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          optional(atom()) => term()
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

  @spec routing_circuit_eligible?(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          boolean()
  def routing_circuit_eligible?(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      ) do
    CircuitState.eligible?(auth, model, assignment, route_class)
  end

  @spec begin_routing_circuit_attempt(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          {:ok, RoutingCircuitState.t() | nil} | {:error, term()}
  def begin_routing_circuit_attempt(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      ) do
    CircuitState.begin_attempt(auth, model, assignment, route_class)
  end

  @spec record_routing_circuit_success(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          {:ok, :ok | RoutingCircuitState.t()} | {:error, term()}
  def record_routing_circuit_success(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      ) do
    CircuitState.record_success(auth, model, assignment, route_class)
  end

  @spec record_routing_circuit_failure(
          auth(),
          Model.t(),
          PoolUpstreamAssignment.t(),
          String.t(),
          term()
        ) ::
          {:ok, RoutingCircuitState.t()} | {:error, term()}
  def record_routing_circuit_failure(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        model,
        %PoolUpstreamAssignment{} = assignment,
        route_class,
        reason_code
      ) do
    CircuitState.record_failure(auth, model, assignment, route_class, reason_code)
  end

  @spec start_codex_session(auth(), opts()) :: session_result()
  def start_codex_session(auth, opts \\ %{}) do
    SessionContinuity.start_codex_session(auth, websocket_request_options(opts))
  end

  @spec active_runtime_request?(request_ref(), DateTime.t()) :: boolean()
  def active_runtime_request?(%Request{id: request_id}, %DateTime{} = now) do
    active_runtime_request?(request_id, now)
  end

  def active_runtime_request?(request_id, %DateTime{} = now) when is_binary(request_id) do
    import Ecto.Query

    Repo.exists?(
      from turn in CodexTurn,
        join: session in CodexSession,
        on: session.id == turn.codex_session_id,
        where:
          turn.request_id == ^request_id and turn.status == "in_progress" and
            (is_nil(session.owner_lease_expires_at) or session.owner_lease_expires_at > ^now)
    )
  end

  @spec prepare_websocket_session(auth(), opts()) :: {:ok, websocket_runtime()} | {:error, term()}
  def prepare_websocket_session(auth, opts \\ %{}) do
    opts = websocket_request_options(opts)

    if websocket_owner_forwarding_enabled?(),
      do: prepare_owner_websocket_session(auth, opts),
      else: prepare_local_websocket_session(auth, opts)
  end

  defp prepare_local_websocket_session(auth, opts) do
    with {:ok, session} <- start_codex_session(auth, opts),
         {:ok, upstream_websocket_session} <- UpstreamWebSocketSession.start_link() do
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
    Logger.warning(
      "websocket owner takeover attempted " <>
        owner_takeover_log_metadata(session, opts)
    )
  end

  defp log_owner_takeover_success(
         %CodexSession{} = previous_session,
         %CodexSession{} = replacement_session,
         %RequestOptions{} = opts
       ) do
    Logger.warning(
      "websocket owner takeover succeeded " <>
        owner_takeover_log_metadata(replacement_session, opts) <>
        " previous_owner_instance_id=#{safe_log_token(previous_session.owner_instance_id)}"
    )
  end

  defp log_owner_takeover_failure(%CodexSession{} = session, %RequestOptions{} = opts, reason) do
    Logger.warning(
      "websocket owner takeover failed " <>
        owner_takeover_log_metadata(session, opts) <>
        " failure_reason=#{owner_takeover_reason(reason)}"
    )
  end

  defp owner_takeover_log_metadata(%CodexSession{} = session, %RequestOptions{} = opts) do
    [
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
         websocket_owner_downstream: downstream
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

  @spec run_websocket_response(auth(), binary(), opts(), (binary() -> any())) ::
          :ok | {:error, Service.gateway_error()}
  def run_websocket_response(auth, payload, opts, push_frame)
      when is_binary(payload) and is_function(push_frame, 1) do
    Admission.run(RouteClass.proxy_websocket(), websocket_metadata(opts), fn ->
      Service.execute_websocket_response(auth, payload, opts, push_frame)
    end)
  end

  @spec detach_websocket_owner_downstream(
          CodexSession.t() | nil,
          String.t() | nil,
          WebsocketOwnerSession.downstream() | nil,
          opts()
        ) :: :ok | {:error, WebsocketOwnerContract.owner_error()}
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
  defp owner_detach_result({:error, :stale_downstream}), do: :ok
  defp owner_detach_result({:error, :duplicate_downstream}), do: :ok
  defp owner_detach_result({:error, reason}), do: owner_detach_error(reason)

  defp owner_attach_error(reason) do
    if WebsocketOwnerContract.owner_error?(reason),
      do: {:error, reason},
      else: {:error, :owner_unavailable}
  end

  @spec run_admitted(String.t(), map(), (-> gateway_call_result())) :: gateway_call_result()
  def run_admitted(route_class, metadata, fun)
      when is_binary(route_class) and is_map(metadata) and is_function(fun, 0) do
    case Admission.acquire(route_class, metadata) do
      {:ok, lease} ->
        lease
        |> run_with_lease(fun)
        |> wrap_admitted_stream_result(lease)

      {:error, reason} ->
        {:error, Admission.overload_error(reason)}
    end
  end

  @spec close_websocket_session(pid() | term()) :: :ok
  def close_websocket_session(pid) when is_pid(pid), do: UpstreamWebSocketSession.close(pid)
  def close_websocket_session(_session), do: :ok

  @spec admit_browser(map()) :: {:ok, admission_lease()} | {:error, Contracts.gateway_error()}
  def admit_browser(metadata) when is_map(metadata) do
    case Admission.acquire(RouteClass.admin_browser(), metadata) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, Admission.overload_error(reason)}
    end
  end

  @spec admit_mcp(map()) :: {:ok, admission_lease()} | {:error, Contracts.gateway_error()}
  def admit_mcp(metadata) when is_map(metadata) do
    metadata = Map.put(metadata, :route_class, RouteClass.mcp())

    case Admission.acquire(RouteClass.mcp(), metadata) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, Admission.overload_error(reason)}
    end
  end

  @spec release_admission(admission_lease()) :: :ok
  def release_admission(lease), do: Admission.release(lease)

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

  @spec recover_owner_lifecycle_leftovers(session_ref(), atom() | String.t(), opts()) ::
          {:ok, term()} | {:error, term()}
  def recover_owner_lifecycle_leftovers(session, owner_reason, opts \\ %{}) do
    Interruption.recover_owner_lifecycle_leftovers(
      session,
      owner_reason,
      websocket_request_options(opts)
    )
  end

  @spec cleanup_expired_runtime_state(DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def cleanup_expired_runtime_state(now \\ now()) do
    with {:ok, recovered_summary} <- recover_expired_owner_runtime_state(now),
         {:ok, cleanup_summary} <- RuntimeCleanup.cleanup_expired(now) do
      {:ok, Map.merge(cleanup_summary, recovered_summary)}
    end
  end

  defp recover_expired_owner_runtime_state(%DateTime{} = now) do
    now = DateTime.truncate(now, :microsecond)

    sessions = expired_owner_sessions_with_active_turns(now)

    sessions
    |> Enum.reduce_while({:ok, 0}, &recover_expired_owner_session/2)
    |> case do
      {:ok, recovered_count} -> {:ok, %{expired_owner_sessions_recovered: recovered_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_expired_owner_session(session_id, {:ok, recovered_count}) do
    case Interruption.recover_owner_lifecycle_leftovers(
           session_id,
           :owner_unavailable,
           RequestOptions.for_websocket(%{})
         ) do
      {:ok, _result} -> {:cont, {:ok, recovered_count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp expired_owner_sessions_with_active_turns(%DateTime{} = now) do
    import Ecto.Query

    Repo.all(
      from session in CodexSession,
        join: lease in BridgeOwnerLease,
        on:
          lease.codex_session_id == session.id and
            lease.status == ^BridgeOwnerLease.active_status() and
            lease.expires_at <= ^now,
        join: turn in CodexTurn,
        on: turn.codex_session_id == session.id and turn.status == "in_progress",
        distinct: session.id,
        select: session.id
    )
  end

  @spec list_codex_sessions(pool_ref(), keyword()) :: %{
          required(:items) => [session_row()],
          required(:turns) => [turn_row()],
          required(:total) => non_neg_integer(),
          required(:limit) => pos_integer()
        }
  defdelegate list_codex_sessions(pool_or_id, opts \\ []), to: SessionReadModel

  @spec list_codex_turns_for_sessions([Ecto.UUID.t()]) :: [turn_row()]
  defdelegate list_codex_turns_for_sessions(session_ids), to: SessionReadModel

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
      attach_owner(owner, session.id, %{pid: self(), correlation_id: Ecto.UUID.generate()}, opts)
    else
      {:error, reason} -> owner_attach_error(reason)
    end
  end

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

  defp owner_forwarder_opts(%RequestOptions{transport: %{websocket_owner_forwarder_opts: opts}})
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
         transport: %{websocket_owner_forwarder_opts: opts}
       }) do
    case Keyword.get(opts, :upstream) do
      nil -> start_opts
      upstream -> Keyword.put(start_opts, :upstream, upstream)
    end
  end

  defp run_with_lease(lease, fun) do
    fun.()
  catch
    kind, reason ->
      Admission.release(lease)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp wrap_admitted_stream_result({:ok, %{stream: stream} = result}, lease) do
    wrapped = fn conn ->
      try do
        stream.(conn)
      after
        Admission.release(lease)
      end
    end

    {:ok, %{result | stream: wrapped}}
  end

  defp wrap_admitted_stream_result(result, lease) do
    Admission.release(lease)
    result
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
