defmodule CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseFixture do
  @moduledoc false

  @source_commit "a589116bb733fb53c58520637ea70382c68e6bd3"
  @legacy_protocol %{function: :remote_submit_request, arity: 4}
  @forwarder CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  @external_network_calls [
    {Req, :request, 1},
    {Req, :request, 2},
    {Mint.HTTP, :connect, 4},
    {Mint.HTTP, :connect, 5},
    {:httpc, :request, 1},
    {:httpc, :request, 2},
    {:httpc, :request, 4},
    {:httpc, :request, 5}
  ]

  @spec provenance() :: %{source_commit: binary(), legacy_protocol: map()}
  def provenance do
    %{source_commit: @source_commit, legacy_protocol: @legacy_protocol}
  end

  @spec load_forwarder(node()) :: {:module, module()}
  def load_forwarder(node) when is_atom(node) do
    {:ok, module, beam} = compile_forwarder()

    :erpc.call(node, :code, :purge, [module])
    :erpc.call(node, :code, :delete, [module])
    :erpc.call(node, :code, :load_binary, [module, ~c"previous_release_fixture", beam])
  end

  @spec load_current_dispatch_identity(node(), binary()) :: binary()
  def load_current_dispatch_identity(node, identity)
      when is_atom(node) and is_binary(identity) do
    module = CodexPooler.Gateway.Transports.UpstreamDispatch
    {:module, ^module} = Code.ensure_loaded(module)
    {^module, beam, _filename} = :code.get_object_code(module)
    {:ok, ^module, chunks} = :beam_lib.all_chunks(beam)

    identified_chunks =
      Enum.map(chunks, fn
        {~c"CInf", content} -> {~c"CInf", content <> identity}
        chunk -> chunk
      end)

    {:ok, identified_beam} = :beam_lib.build_module(identified_chunks)

    :erpc.call(node, :code, :purge, [module])
    :erpc.call(node, :code, :delete, [module])

    {:module, ^module} =
      :erpc.call(node, :code, :load_binary, [
        module,
        ~c"current_dispatch_fixture",
        identified_beam
      ])

    :crypto.hash(:sha256, identified_beam)
  end

  @spec load_synthetic_identity_lookup(node(), binary()) :: {:module, module()}
  def load_synthetic_identity_lookup(node, identity_id)
      when is_atom(node) and is_binary(identity_id) do
    module = CodexPooler.Upstreams
    fixture = __MODULE__

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [get_upstream_identity: 1]},
      {:function, 1, :get_upstream_identity, 1,
       [
         {:clause, 1, [{:var, 1, :IdentityId}], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, fixture}, {:atom, 1, :synthetic_identity}},
             [{:var, 1, :IdentityId}]}
          ]}
       ]}
    ]

    {:ok, ^module, beam} = compile_forms(forms)
    :erpc.call(node, :persistent_term, :put, [{__MODULE__, :identity_id}, identity_id])
    :erpc.call(node, :code, :purge, [module])
    :erpc.call(node, :code, :delete, [module])
    :erpc.call(node, :code, :load_binary, [module, ~c"synthetic_identity_fixture", beam])
  end

  @spec call_current_v1(node(), binary(), map(), term(), pos_integer()) :: term()
  def call_current_v1(owner_node, session_id, downstream, request, timeout)
      when is_atom(owner_node) and is_binary(session_id) and is_map(downstream) and
             is_integer(timeout) and timeout > 0 do
    @forwarder.ERPCNodeClient.call_owner(
      owner_node,
      @forwarder,
      :remote_submit_request_v1,
      [session_id, downstream, request],
      timeout
    )
  end

  @spec call_current_owner(node(), binary(), map(), term(), keyword()) :: term()
  def call_current_owner(owner_node, session_id, downstream, request, opts)
      when is_atom(owner_node) and is_binary(session_id) and is_map(downstream) and
             is_list(opts) do
    :erpc.call(owner_node, @forwarder, :remote_submit_request, [
      session_id,
      downstream,
      request,
      opts
    ])
  catch
    kind, reason when kind in [:error, :exit, :throw] ->
      @forwarder.normalize_remote_failure(
        kind,
        reason,
        @forwarder,
        :remote_submit_request,
        [session_id, downstream, request, opts]
      )
      |> then(&{:error, &1})
  end

  @spec legacy_request(pid()) :: struct()
  def legacy_request(notify) when is_pid(notify) do
    marker = fn label -> send(notify, {:previous_release_callback_invoked, label}) end

    %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{
      url: "https://upstream.example.test/backend-api/codex/responses",
      headers: [],
      payload: "fixture-payload",
      timeouts: %{},
      writer: fn _output -> marker.(:writer) end,
      message_mapper: fn output ->
        marker.(:message_mapper)
        output
      end,
      frame_observer: fn _frame, _decoded -> marker.(:frame_observer) end,
      submission_observer: fn -> marker.(:submission_observer) end,
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: false,
      connection_bound_continuation?: false,
      forward_error_body?: true
    }
  end

  @spec legacy_opts(pid()) :: keyword()
  def legacy_opts(notify) when is_pid(notify) do
    marker = fn label -> send(notify, {:previous_release_callback_invoked, label}) end

    [
      upstream: %{
        start: fn ->
          marker.(:upstream_start)
          {:error, :must_not_start}
        end,
        send: fn _pid, _request, _writer -> marker.(:upstream_send) end,
        close: fn _pid -> marker.(:upstream_close) end
      },
      submission_observer: fn -> marker.(:option_submission_observer) end
    ]
  end

  @spec start_runtime() :: {:ok, pid()}
  def start_runtime do
    caller = self()
    ready_ref = make_ref()

    runtime =
      spawn(fn ->
        {:ok, _registry} =
          Registry.start_link(
            keys: :unique,
            name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry
          )

        {:ok, _task_supervisor} =
          Task.Supervisor.start_link(
            name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor
          )

        send(caller, {ready_ref, :ready})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {^ready_ref, :ready} -> {:ok, runtime}
    after
      10_000 -> {:error, :runtime_start_timeout}
    end
  end

  @spec synthetic_identity(binary()) :: struct() | nil
  def synthetic_identity(identity_id) when is_binary(identity_id) do
    if :persistent_term.get({__MODULE__, :identity_id}) == identity_id do
      %CodexPooler.Upstreams.Schemas.UpstreamIdentity{
        id: identity_id,
        account_label: "mixed-release-fixture",
        onboarding_method: "import",
        status: "active",
        headers_profile_version: 1,
        metadata: %{}
      }
    end
  end

  @spec start_owner(map(), pid(), [binary()]) :: {:ok, pid()} | {:error, term()}
  def start_owner(session, notify, terminal_messages)
      when is_map(session) and is_pid(notify) and is_list(terminal_messages) do
    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, request, writer ->
        send(notify, {:mixed_release_upstream_send, node()})

        Enum.each(terminal_messages, fn terminal ->
          discriminator =
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator.classify(
              terminal
            )

          writer.(terminal, discriminator)
        end)

        send(notify, {:mixed_release_request_materialized, request.url})

        {:ok,
         %{
           body: Enum.join(terminal_messages, "\n"),
           terminal: "response.completed",
           status: 200,
           headers: [],
           websocket_frame_headers: %{}
         }}
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end,
      invalidate: fn _upstream_pid -> :ok end
    }

    persistence = %{
      renew_owner_token: fn _session_id, _token, _opts -> {:error, :stale_owner} end,
      release_owner_lease: fn _session_id, _token, _reason -> :ok end,
      interrupt_codex_session: fn _session_id, _opts -> :ok end
    }

    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.start_owner(
      codex_session_id: session.id,
      owner_lease_token: session.owner_lease_token,
      owner_instance_id: session.owner_instance_id,
      owner_renewal_ms: 60_000,
      upstream: upstream,
      persistence: persistence
    )
  end

  @spec start_external_network_guard(pid()) :: pid()
  def start_external_network_guard(notify) when is_pid(notify) do
    tracer = spawn(fn -> network_trace_loop(notify) end)
    Enum.each(@external_network_calls, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])
    tracer
  end

  @spec stop_external_network_guard(pid()) :: :ok
  def stop_external_network_guard(tracer) when is_pid(tracer) do
    :erlang.trace(:all, false, [:call])
    :erlang.trace(:new, false, [:call])
    Enum.each(@external_network_calls, &:erlang.trace_pattern(&1, false, [:local]))
    send(tracer, :stop)
    :ok
  end

  defp compile_forwarder do
    session = CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

    # Derived from the recorded source commit's legacy remote_submit_request/4
    # protocol shape. The fixture intentionally carries no deployment data.
    forms = [
      {:attribute, 1, :module, @forwarder},
      {:attribute, 1, :export, [remote_attach_downstream: 2, remote_submit_request: 4]},
      {:function, 1, :remote_attach_downstream, 2,
       [
         {:clause, 1, [{:var, 1, :SessionId}, {:var, 1, :Downstream}], [],
          [
            {:case, 1,
             {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :lookup}},
              [{:var, 1, :SessionId}]},
             [
               {:clause, 1, [{:tuple, 1, [{:atom, 1, :ok}, {:var, 1, :OwnerPid}]}], [],
                [
                  {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :attach_downstream}},
                   [{:var, 1, :OwnerPid}, {:var, 1, :Downstream}]}
                ]},
               {:clause, 1, [{:var, 1, :Error}], [], [{:var, 1, :Error}]}
             ]}
          ]}
       ]},
      {:function, 1, :remote_submit_request, 4,
       [
         {:clause, 1,
          [
            {:var, 1, :SessionId},
            {:var, 1, :Downstream},
            {:var, 1, :Request},
            {:var, 1, :Opts}
          ], [],
          [
            {:case, 1,
             {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :lookup}},
              [{:var, 1, :SessionId}]},
             [
               {:clause, 1, [{:tuple, 1, [{:atom, 1, :ok}, {:var, 1, :OwnerPid}]}], [],
                [
                  {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :submit_request}},
                   [
                     {:var, 1, :OwnerPid},
                     {:var, 1, :Downstream},
                     {:var, 1, :Request}
                   ]}
                ]},
               {:clause, 1, [{:var, 1, :Error}], [], [{:var, 1, :Error}]}
             ]}
          ]}
       ]}
    ]

    compile_forms(forms)
  end

  defp compile_forms(forms) do
    case :compile.forms(forms, [:binary]) do
      {:ok, module, beam} -> {:ok, module, beam}
      {:ok, module, beam, _warnings} -> {:ok, module, beam}
    end
  end

  defp network_trace_loop(notify) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        send(notify, {:external_network_call, node(), module, function, length(args)})
        network_trace_loop(notify)

      :stop ->
        :ok

      _other ->
        network_trace_loop(notify)
    end
  end
end
