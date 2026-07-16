defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder do
  @moduledoc """
  Websocket owner forwarding primitive for owner-mode websocket topology.

  When owner forwarding is enabled, websocket runtime calls this module to route
  upstream-touching websocket requests through the process that owns the
  persisted Codex session lease. When the topology flag is disabled, the default
  local upstream websocket behavior remains active.
  """

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @type owner_node :: node()
  @type owner_resolution :: {:local, binary()} | {:remote, owner_node(), binary()}

  @type submit_opts :: [
          timeout: pos_integer(),
          node_client: module(),
          app_node_names: [binary()],
          local_node_string: binary(),
          upstream: map(),
          request_id: binary()
        ]
  @type submit_error ::
          WebsocketOwnerContract.owner_error() | UpstreamWebsocketSession.request_failure()

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
          UpstreamWebsocketSession.Request.t(),
          submit_opts()
        ) ::
          :ok | {:ok, term()} | {:error, submit_error()}
  def submit_request(
        %CodexSession{} = session,
        owner_lease_token,
        downstream,
        request,
        opts \\ []
      )
      when is_binary(owner_lease_token) and is_map(downstream) and
             is_struct(request, UpstreamWebsocketSession.Request) do
    with :ok <- SessionContinuity.validate_owner_token(session, owner_lease_token),
         {:ok, owner} <- resolve_owner(session, opts) do
      dispatch_submit_request(owner, session.id, downstream, request, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec push_downstream(
          CodexSession.t(),
          binary(),
          WebsocketOwnerContract.downstream_payload(),
          submit_opts()
        ) ::
          :ok | {:ok, term()} | {:error, WebsocketOwnerContract.owner_error()}
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
          :ok | {:ok, term()} | {:error, WebsocketOwnerContract.owner_error()}
  def remote_submit_request(codex_session_id, downstream, request, opts \\ [])
      when is_binary(codex_session_id) and is_map(downstream) and
             is_struct(request, UpstreamWebsocketSession.Request) do
    with {:ok, {owner_pid, downstream}} <- ensure_remote_owner(codex_session_id, downstream, opts) do
      WebsocketOwnerSession.submit_request(owner_pid, downstream, request)
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
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def remote_cancel_downstream(codex_session_id, downstream)
      when is_binary(codex_session_id) and is_map(downstream) do
    with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.detach_downstream(owner_pid, downstream)
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

  defp dispatch_submit_request(
         {:local, _owner_instance_id},
         codex_session_id,
         downstream,
         request,
         _opts
       ) do
    remote_submit_request(codex_session_id, downstream, request)
  end

  defp dispatch_submit_request(
         {:remote, node, _owner_instance_id},
         codex_session_id,
         downstream,
         request,
         opts
       ) do
    result =
      call_remote(
        node,
        :remote_submit_request,
        [codex_session_id, downstream, request, opts],
        opts
      )

    if result == {:error, :owner_forward_timeout} do
      best_effort_cancel_downstream(node, codex_session_id, downstream, opts)
    end

    result
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
        recover_remote_owner(codex_session_id, downstream, opts)
    end
  end

  defp recover_remote_owner(codex_session_id, downstream, opts) do
    with %CodexSession{} = session <- Repo.get(CodexSession, codex_session_id),
         :ok <- require_local_owner_session(session, opts),
         {:ok, owner_pid} <- start_recovered_remote_owner(session, opts),
         {:ok, downstream} <- attach_recovered_downstream(owner_pid, downstream) do
      {:ok, {owner_pid, downstream}}
    else
      nil -> {:error, :owner_unavailable}
      {:error, reason} -> {:error, reason}
    end
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

  defp attach_recovered_downstream(owner_pid, %{pid: pid, correlation_id: correlation_id})
       when is_pid(pid) and is_binary(correlation_id) do
    WebsocketOwnerSession.attach_downstream(owner_pid, %{pid: pid, correlation_id: correlation_id})
  end

  defp attach_recovered_downstream(_owner_pid, _downstream), do: {:error, :stale_downstream}

  defp best_effort_cancel_downstream(node, codex_session_id, downstream, opts) do
    _result =
      call_remote(
        node,
        :remote_cancel_downstream,
        [codex_session_id, downstream],
        Keyword.put(opts, :timeout, WebsocketOwnerContract.default_downstream_send_timeout_ms())
      )

    :ok
  end

  @doc false
  @spec call_remote(node(), atom(), [term()], submit_opts()) ::
          :ok | {:ok, term()} | {:error, submit_error()}
  def call_remote(node, function, args, opts)
      when is_atom(node) and is_atom(function) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, WebsocketOwnerContract.default_forward_timeout_ms())

    opts
    |> node_client()
    |> safe_remote_call(node, __MODULE__, function, args, timeout)
    |> normalize_forward_result()
  end

  defp safe_remote_call(node_client, node, module, function, args, timeout) do
    node_client.call_owner(node, module, function, args, timeout)
  catch
    :exit, reason -> {:error, map_remote_failure(reason)}
    kind, reason when kind in [:error, :throw] -> {:error, map_remote_failure(reason)}
  end

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

  defp map_remote_failure(:timeout), do: :owner_forward_timeout
  defp map_remote_failure({:erpc, :timeout}), do: :owner_forward_timeout
  defp map_remote_failure(:noconnection), do: :owner_unavailable
  defp map_remote_failure({:erpc, :noconnection}), do: :owner_unavailable
  defp map_remote_failure({:nodedown, _node}), do: :owner_unavailable
  defp map_remote_failure(:noproc), do: :owner_unavailable
  defp map_remote_failure({:noproc, _details}), do: :owner_unavailable
  defp map_remote_failure(:owner_forward_timeout), do: :owner_forward_timeout
  defp map_remote_failure(:owner_unavailable), do: :owner_unavailable
  defp map_remote_failure(_reason), do: :owner_crashed

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
      :exit, reason -> {:error, map_erpc_failure(reason)}
      kind, reason when kind in [:error, :throw] -> {:error, map_erpc_failure(reason)}
    end

    defp map_erpc_failure(:timeout), do: :owner_forward_timeout
    defp map_erpc_failure({:erpc, :timeout}), do: :owner_forward_timeout
    defp map_erpc_failure(:noconnection), do: :owner_unavailable
    defp map_erpc_failure({:erpc, :noconnection}), do: :owner_unavailable
    defp map_erpc_failure({:nodedown, _node}), do: :owner_unavailable
    defp map_erpc_failure(:noproc), do: :owner_unavailable
    defp map_erpc_failure({:noproc, _details}), do: :owner_unavailable
    defp map_erpc_failure(_reason), do: :owner_crashed
  end
end
