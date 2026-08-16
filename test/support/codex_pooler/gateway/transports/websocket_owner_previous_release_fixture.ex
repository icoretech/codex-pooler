defmodule CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseFixture do
  @moduledoc false

  @source_commit "a589116bb733fb53c58520637ea70382c68e6bd3"
  @source_path "lib/codex_pooler/gateway/transports/websocket/websocket_owner_forwarder.ex"
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

  @spec provenance() :: map()
  def provenance do
    %{
      source_commit: @source_commit,
      source_path: @source_path,
      public_entrypoint: {:remote_submit_request, 4},
      owner_resolution: {:ensure_remote_owner, 4},
      submission: {:submit_remote_owner_request, 5},
      visibility: {:track_request_visibility, 1}
    }
  end

  @spec load_forwarder(node(), pid()) :: {:module, module()}
  def load_forwarder(node, notify) when is_atom(node) and is_pid(notify) do
    {:ok, module, beam} = compile_forwarder()

    :erpc.call(node, :persistent_term, :put, [{__MODULE__, :protocol_notify}, notify])
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

  @spec load_lookup_sentinels(node()) :: :ok
  def load_lookup_sentinels(node) when is_atom(node) do
    :ok = :erpc.call(node, __MODULE__, :initialize_lookup_sentinels, [])
    load_owner_lookup_sentinel(node)
    load_identity_lookup_sentinel(node)
    :ok
  end

  @doc false
  @spec initialize_lookup_sentinels() :: :ok
  def initialize_lookup_sentinels do
    :persistent_term.put({__MODULE__, :lookup_counts}, :atomics.new(2, []))
  end

  @spec lookup_sentinel_counts(node()) :: %{identity: non_neg_integer(), owner: non_neg_integer()}
  def lookup_sentinel_counts(node) when is_atom(node) do
    :erpc.call(node, __MODULE__, :local_lookup_sentinel_counts, [])
  end

  @doc false
  @spec local_lookup_sentinel_counts() :: %{identity: non_neg_integer(), owner: non_neg_integer()}
  def local_lookup_sentinel_counts do
    counters = :persistent_term.get({__MODULE__, :lookup_counts})
    %{owner: :atomics.get(counters, 1), identity: :atomics.get(counters, 2)}
  end

  @doc false
  @spec record_lookup_sentinel(:identity | :owner) :: {:error, :owner_unavailable} | nil
  def record_lookup_sentinel(kind) when kind in [:identity, :owner] do
    counters = :persistent_term.get({__MODULE__, :lookup_counts})
    index = if kind == :owner, do: 1, else: 2
    :atomics.add(counters, index, 1)
    if kind == :owner, do: {:error, :owner_unavailable}
  end

  @spec call_current_v1(node(), binary(), map(), term(), pos_integer()) ::
          {:rpc_receipt, [term()], term()}
  def call_current_v1(owner_node, session_id, downstream, request, timeout)
      when is_atom(owner_node) and is_binary(session_id) and is_map(downstream) and
             is_integer(timeout) and timeout > 0 do
    rpc_arguments = [session_id, downstream, request]

    result =
      @forwarder.ERPCNodeClient.call_owner(
        owner_node,
        @forwarder,
        :remote_submit_request_v1,
        rpc_arguments,
        timeout
      )

    {:rpc_receipt, rpc_arguments, result}
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

  @spec historical_request(pid()) :: struct()
  def historical_request(notify) when is_pid(notify) do
    %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{
      url: "https://upstream.example.test/backend-api/codex/responses",
      headers: [],
      payload: "fixture-payload",
      timeouts: %{},
      writer: fn _output -> send(notify, {:previous_release_callback_invoked, :writer}) end,
      message_mapper: &Function.identity/1,
      frame_observer: fn _frame, _decoded ->
        send(notify, {:previous_release_callback_invoked, :frame_observer})
      end,
      submission_observer: nil,
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: false,
      connection_bound_continuation?: false,
      forward_error_body?: true
    }
  end

  @doc false
  @spec track_historical_request_visibility(struct()) :: {struct(), reference()}
  def track_historical_request_visibility(request) do
    visibility = :atomics.new(1, [])
    observer = request.frame_observer

    tracked_observer = fn frame, decoded ->
      cond do
        is_function(observer, 2) -> observer.(frame, decoded)
        is_function(observer, 1) -> observer.(frame)
        true -> :ok
      end

      unless CodexPooler.Gateway.Transports.Streaming.StreamProtocol.internal_control_event?(
               decoded
             ),
             do: :atomics.put(visibility, 1, 1)
    end

    {%{request | frame_observer: tracked_observer}, visibility}
  end

  @spec legacy_opts(pid()) :: keyword()
  def legacy_opts(notify) when is_pid(notify) do
    [
      upstream: %{
        start: fn -> send(notify, {:previous_release_callback_invoked, :upstream_start}) end,
        send: fn _pid, _request, _writer ->
          send(notify, {:previous_release_callback_invoked, :upstream_send})
        end,
        close: fn _pid -> send(notify, {:previous_release_callback_invoked, :upstream_close}) end
      }
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
      send: fn _upstream_pid, _request, writer ->
        send(notify, {:mixed_release_upstream_send, node()})

        Enum.each(terminal_messages, fn terminal ->
          discriminator =
            CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator.classify(
              terminal
            )

          writer.(terminal, discriminator)
        end)

        send(notify, {:mixed_release_request_materialized, :synthetic})

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

  @spec start_external_network_guard() :: {:ok, pid()}
  def start_external_network_guard do
    tracer = spawn(fn -> network_trace_loop(0) end)
    Enum.each(@external_network_calls, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])
    {:ok, tracer}
  end

  @spec flush_external_network_guard(pid()) :: {:ok, non_neg_integer()}
  def flush_external_network_guard(tracer) when is_pid(tracer) do
    :erlang.trace(:all, false, [:call])
    :erlang.trace(:new, false, [:call])
    Enum.each(@external_network_calls, &:erlang.trace_pattern(&1, false, [:local]))
    delivered_ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered_ref} -> :ok
    after
      10_000 -> raise "trace delivery barrier timeout"
    end

    ref = make_ref()
    send(tracer, {:flush, self(), ref})

    receive do
      {^ref, count} -> {:ok, count}
    after
      10_000 -> {:error, :trace_flush_timeout}
    end
  end

  @spec run_forced_failure_cleanup_probe(atom()) :: {:error, ExUnit.AssertionError.t()}
  def run_forced_failure_cleanup_probe(peer_name) when is_atom(peer_name) do
    try do
      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{
          name: peer_name,
          args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
        })

      Process.unlink(peer_pid)

      try do
        :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
        {:ok, _tracer} = :erpc.call(peer_node, __MODULE__, :start_external_network_guard, [])
        raise ExUnit.AssertionError, message: "forced peer cleanup probe"
      after
        if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
      end
    rescue
      error in ExUnit.AssertionError -> {:error, error}
    end
  end

  defp compile_forwarder do
    session = CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
    fixture = __MODULE__

    # Behavioral transcription of source commit @source_commit at @source_path:
    # remote_submit_request/4 -> ensure_remote_owner/4 -> submit_remote_owner_request/5.
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
            notify_protocol_form(fixture, :remote_submit_request_4),
            {:case, 1,
             {:call, 1, {:atom, 1, :ensure_remote_owner},
              [
                {:var, 1, :SessionId},
                {:var, 1, :Downstream},
                {:var, 1, :Request},
                {:var, 1, :Opts}
              ]},
             [
               {:clause, 1,
                [
                  {:tuple, 1,
                   [
                     {:atom, 1, :ok},
                     {:tuple, 1, [{:var, 1, :OwnerPid}, {:var, 1, :ResolvedDownstream}]}
                   ]}
                ], [],
                [
                  {:call, 1, {:atom, 1, :submit_remote_owner_request},
                   [
                     {:var, 1, :OwnerPid},
                     {:var, 1, :SessionId},
                     {:var, 1, :ResolvedDownstream},
                     {:var, 1, :Request},
                     {:var, 1, :Opts}
                   ]}
                ]},
               {:clause, 1, [{:var, 1, :Error}], [], [{:var, 1, :Error}]}
             ]}
          ]}
       ]},
      {:function, 1, :ensure_remote_owner, 4,
       [
         {:clause, 1,
          [
            {:var, 1, :SessionId},
            {:var, 1, :Downstream},
            {:var, 1, :Request},
            {:var, 1, :Opts}
          ], [],
          [
            notify_protocol_form(fixture, :ensure_remote_owner_4),
            {:case, 1,
             {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :lookup}},
              [{:var, 1, :SessionId}]},
             [
               {:clause, 1, [{:tuple, 1, [{:atom, 1, :ok}, {:var, 1, :OwnerPid}]}], [],
                [
                  {:tuple, 1,
                   [
                     {:atom, 1, :ok},
                     {:tuple, 1, [{:var, 1, :OwnerPid}, {:var, 1, :Downstream}]}
                   ]}
                ]},
               {:clause, 1, [{:var, 1, :Error}], [], [{:var, 1, :Error}]}
             ]}
          ]}
       ]},
      {:function, 1, :submit_remote_owner_request, 5,
       [
         {:clause, 1,
          [
            {:var, 1, :OwnerPid},
            {:var, 1, :SessionId},
            {:var, 1, :Downstream},
            {:var, 1, :Request},
            {:var, 1, :Opts}
          ], [],
          [
            notify_protocol_form(fixture, :submit_remote_owner_request_5),
            {:match, 1, {:tuple, 1, [{:var, 1, :TrackedRequest}, {:var, 1, :Visibility}]},
             {:call, 1,
              {:remote, 1, {:atom, 1, fixture}, {:atom, 1, :track_historical_request_visibility}},
              [{:var, 1, :Request}]}},
            {:call, 1, {:atom, 1, :do_submit_remote_owner_request},
             [
               {:var, 1, :OwnerPid},
               {:var, 1, :SessionId},
               {:var, 1, :Downstream},
               {:var, 1, :TrackedRequest},
               {:var, 1, :Visibility},
               {:var, 1, :Opts}
             ]}
          ]}
       ]},
      {:function, 1, :do_submit_remote_owner_request, 6,
       [
         {:clause, 1,
          [
            {:var, 1, :OwnerPid},
            {:var, 1, :SessionId},
            {:var, 1, :Downstream},
            {:var, 1, :Request},
            {:var, 1, :Visibility},
            {:var, 1, :Opts}
          ], [],
          [
            notify_protocol_form(fixture, :do_submit_remote_owner_request_6),
            {:call, 1, {:remote, 1, {:atom, 1, session}, {:atom, 1, :submit_request}},
             [{:var, 1, :OwnerPid}, {:var, 1, :Downstream}, {:var, 1, :Request}]}
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

  defp notify_protocol_form(fixture, stage) do
    {:call, 1, {:remote, 1, {:atom, 1, fixture}, {:atom, 1, :notify_protocol}},
     [{:atom, 1, stage}]}
  end

  @doc false
  @spec notify_protocol(atom()) :: :ok
  def notify_protocol(stage) when is_atom(stage) do
    send(
      :persistent_term.get({__MODULE__, :protocol_notify}),
      {:previous_release_protocol, stage}
    )

    :ok
  end

  defp load_owner_lookup_sentinel(node) do
    module = CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
    fixture = __MODULE__

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [lookup: 1]},
      {:function, 1, :lookup, 1,
       [
         {:clause, 1, [{:var, 1, :SessionId}], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, fixture}, {:atom, 1, :record_lookup_sentinel}},
             [{:atom, 1, :owner}]}
          ]}
       ]}
    ]

    load_compiled_forms(node, module, forms, ~c"owner_lookup_sentinel")
  end

  defp load_identity_lookup_sentinel(node) do
    module = CodexPooler.Upstreams
    fixture = __MODULE__

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [get_upstream_identity: 1]},
      {:function, 1, :get_upstream_identity, 1,
       [
         {:clause, 1, [{:var, 1, :IdentityId}], [],
          [
            {:call, 1, {:remote, 1, {:atom, 1, fixture}, {:atom, 1, :record_lookup_sentinel}},
             [{:atom, 1, :identity}]}
          ]}
       ]}
    ]

    load_compiled_forms(node, module, forms, ~c"identity_lookup_sentinel")
  end

  defp load_compiled_forms(node, module, forms, filename) do
    {:ok, ^module, beam} = compile_forms(forms)
    :erpc.call(node, :code, :purge, [module])
    :erpc.call(node, :code, :delete, [module])
    {:module, ^module} = :erpc.call(node, :code, :load_binary, [module, filename, beam])
  end

  defp network_trace_loop(count) do
    receive do
      {:trace, _pid, :call, {_module, _function, _args}} ->
        network_trace_loop(count + 1)

      {:flush, caller, ref} ->
        send(caller, {ref, count})

      _other ->
        network_trace_loop(count)
    end
  end
end
