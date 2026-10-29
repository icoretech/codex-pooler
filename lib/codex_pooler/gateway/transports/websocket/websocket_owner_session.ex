defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession do
  @moduledoc false

  use GenServer

  require Elixir.Logger

  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.Gateway.{OperationalSettings, OperationalStatus, OwnerRenewalSchedule}
  alias CodexPooler.Gateway.Payloads.NativeTurnContinuation
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.ExpiredOwnerGenerationCleanup
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Runtime.Finalization.RetainedUsage
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementRetry
  alias CodexPooler.Gateway.Runtime.NativeResponseSteering
  alias CodexPooler.Gateway.Transports.ProviderCreditsAdmission
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.AbandonedSubmissions
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult
  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.ResponseInterrupt
  alias CodexPooler.Gateway.Transports.Websocket.ResponseSteer
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.{
    Callbacks,
    DownstreamState,
    Logger,
    Persistence,
    Status
  }

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Gateway.Websocket.OwnerCleanup
  alias CodexPooler.Platform.ForwardedGenerationEnds
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.TransientDatabaseError
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Telemetry, as: WebTelemetry

  defmodule ForwardedSendWitnessState do
    @moduledoc false

    @enforce_keys [:digest, :binding, :control_ref, :downstream, :status]
    defstruct [:digest, :binding, :control_ref, :downstream, :status]
  end

  @registry __MODULE__.Registry
  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )
  @task_supervisor __MODULE__.TaskSupervisor
  @restore_downstream_keys [:correlation_id, :epoch, :pid]
  @stable_downstream_keys [:active_turn_reconnect? | @restore_downstream_keys]
  @public_per_call_downstream_keys [:owner_turn_id | @stable_downstream_keys]
  @terminal_delivery_timeout_ms 1_000
  @handoff_soft_timeout_ms 1_000
  @handoff_absolute_timeout_ms 5_000
  @compaction_retry_hold_timeout_ms 30_000
  @terminal_result_types ["response.completed", "response.failed", "response.incomplete", "error"]
  @drain_settlement_poll_ms 25

  # The one-shot collection result belongs to this existing owner lifecycle.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :receipt_registry,
    :first_compact_result,
    :ordinary_success_result,
    :codex_session_id,
    :turn_claim_session,
    :owner_lease_token,
    :owner_instance_id,
    :downstream,
    :downstream_monitor,
    :downstream_epoch,
    :process_generation,
    :next_turn_descriptor,
    :upstream_pid,
    :producer_identity,
    :expired_slot_receipt,
    :callbacks,
    :active_turn,
    :termination_cleanup_witness,
    :compact_delivery,
    :compact_delivery_read,
    :compact_activity_deadline,
    :terminal_winner_detach,
    :pending_handoff,
    :suspended_replay,
    :persistence,
    :request_id,
    :draining?,
    :retire_after_active_turn?,
    :owner_exit_cause,
    :idle_shutdown_ms,
    :idle_shutdown_ref,
    :owner_renewal_ms,
    :owner_renewal_delay,
    :owner_renewal_ref,
    :handoff_soft_timeout_ms,
    :handoff_absolute_timeout_ms,
    :output_commit_probe_timeout_ms,
    :native_compaction_trace_sensitivity,
    :native_compaction_admission,
    :native_compaction_admission_downstream,
    :forwarded_send_witness,
    :compaction_retry_submit_hold,
    :closed_downstream,
    :closing_downstream,
    :closed_inheritance,
    :drain_settlement,
    :drain_replies,
    :forwarded_terminal_request_id,
    :native_response_steering,
    owner_registry: @registry,
    terminal_delivery_timeout_ms: @terminal_delivery_timeout_ms,
    provisional_issuances: [],
    pending_admissions: %{},
    pending_admission_monitors: %{},
    abandoned_submissions: [],
    exit_interrupted?: false,
    drain_observers: %{},
    drain_requested?: false,
    drain_result: nil,
    drain_shutdown_failed?: false
  ]

  @type downstream :: %{
          required(:pid) => pid(),
          required(:epoch) => pos_integer(),
          required(:correlation_id) => binary(),
          optional(:active_turn_reconnect?) => boolean()
        }
  @type per_call_downstream :: %{
          required(:pid) => pid(),
          required(:epoch) => pos_integer(),
          required(:correlation_id) => binary(),
          required(:owner_turn_id) => pid(),
          optional(:active_turn_reconnect?) => boolean()
        }

  @type start_result :: {:ok, pid()} | {:ok, pid(), :existing} | {:error, term()}
  @type request_result ::
          :ok
          | {:ok, term()}
          | {:error, UpstreamWebsocketSession.request_failure()}
          | {:error, WebsocketOwnerContract.owner_error() | term()}
  @type submitted_request_result ::
          request_result() | {:websocket_owner_submission_accepted, request_result()}

  @type owner_status :: %{
          required(:codex_session_id) => binary(),
          required(:owner_lease_token) => binary(),
          required(:owner_instance_id) => binary(),
          required(:upstream_alive?) => boolean(),
          required(:draining?) => boolean(),
          required(:active_turn?) => boolean(),
          optional(:compact_delivery_status) => nil | :pending | :delivered | :terminal_error | :aborted | :skipped
        }

  # An owner is registered before its `init/1` runs and marks itself ready
  # once its upstream has started, the last step of `init/1`; a call sent
  # before then waits for the whole start (findings#206 row 206-216).
  #
  # The ready value is `{:ready, lease_digest, last_renewal_monotonic_ms}`:
  # the SHA-256 digest of the lease token the owner holds (its OTP status
  # keeps the token itself out of every report), and when it last started a
  # lease renewal, in milliseconds of this VM's monotonic clock. The owner
  # writes it when it becomes ready and at every renewal tick. It answers for
  # an owner that does not answer its status call in time
  # (`owner_reuse_status/2`, findings#285 row 270-247); it never grants
  # ownership, which stays with the lease in the database. Every other reader
  # stays value-agnostic, apart from the `:starting` checks.
  @registry_starting :starting
  @registry_ready :ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: registered_name(opts))
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts, name: registered_name(opts))
  end

  # `:registry` is a test seam, like `RolloutDrain`'s `:owner_registry`: a test
  # that drains real owners registers them in a registry of its own, so the drain
  # counts only that test's owners (findings#206 row 206-386). Every lookup,
  # `starting?/1` included, reads the application registry, so an owner
  # registered elsewhere is invisible to the runtime; production never passes it.
  defp registered_name(opts) do
    codex_session_id = Keyword.fetch!(opts, :codex_session_id)
    {:via, Registry, {owner_registry(opts), codex_session_id, @registry_starting}}
  end

  defp owner_registry(opts), do: Keyword.get(opts, :registry, @registry)

  @spec start_owner(keyword()) :: start_result()
  def start_owner(opts), do: start_owner(opts, 100)

  defp start_owner(opts, attempts) when attempts > 0 do
    if OperationalStatus.draining?() do
      {:error, :owner_drained}
    else
      case start(opts) do
        {:ok, pid} ->
          Logger.owner_started(pid, opts)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          existing_owner_result(pid, opts, attempts)

        {:error, {:already_registered, pid}} ->
          existing_owner_result(pid, opts, attempts)

        {:error, reason} ->
          Logger.owner_start_failed(reason, opts)
          {:error, reason}
      end
    end
  end

  defp start_owner(_opts, 0), do: {:error, :owner_unavailable}

  defp existing_owner_result(pid, opts, attempts) when is_pid(pid) do
    cond do
      OperationalStatus.draining?() ->
        {:error, :owner_drained}

      not Process.alive?(pid) ->
        Logger.owner_lookup_missed(Keyword.fetch!(opts, :codex_session_id), :dead_pid, pid, opts)
        :erlang.yield()
        start_owner(opts, attempts - 1)

      true ->
        reuse_or_replace(owner_reuse_status(pid, opts), pid, opts, attempts)
    end
  end

  defp reuse_or_replace(:draining, _pid, _opts, _attempts), do: {:error, :owner_drained}

  defp reuse_or_replace(:reusable, pid, opts, _attempts) do
    Logger.owner_reused(pid, opts)
    {:ok, pid, :existing}
  end

  defp reuse_or_replace({:busy, last_renewal_age_ms}, pid, opts, _attempts) do
    Logger.owner_busy_left(pid, opts, last_renewal_age_ms)
    {:error, :owner_forward_timeout}
  end

  defp reuse_or_replace({:stale, reuse_reason}, pid, opts, attempts) do
    Logger.owner_stale_replaced(pid, opts, reuse_reason)

    case stop_stale_owner(pid, opts) do
      :stopped ->
        :erlang.yield()
        start_owner(opts, attempts - 1)

      # A killed owner runs no `terminate/2`, so a socket attached to it takes
      # it for crashed and releases its lease. That is the lease a new owner
      # started here would share. The session goes through the takeover that
      # replaces an unavailable owner's lease instead: the new owner holds a
      # new lease, and the old lease's release no longer reaches it.
      :killed ->
        {:error, :owner_unavailable}
    end
  end

  @doc """
  Drains the owner and stops it. Answers `{:ok, :settled}` when the last turn
  whose terminal the owner forwarded had settled before it stopped, so a turn
  the rollout drain's deadline found active counts as completed
  (findings#287).
  """
  @spec drain_owner(GenServer.server()) :: :ok | {:ok, :settled} | {:error, term()}
  def drain_owner(owner), do: GenServer.call(owner, :drain, owner_call_timeout())

  @spec begin_drain(GenServer.server()) :: :ok
  def begin_drain(owner), do: GenServer.cast(owner, :begin_drain)

  @spec owner_status(GenServer.server()) :: {:ok, owner_status()}
  def owner_status(owner), do: GenServer.call(owner, :owner_status, owner_call_timeout())

  @doc false
  @spec local_drain_status(pid(), %{required(:at) => integer(), required(:now_ms) => (-> integer()), optional(:observer_ref) => reference()}, pos_integer()) :: {:ok, owner_status()}
  def local_drain_status(owner, deadline, timeout \\ owner_call_timeout())

  def local_drain_status(owner, %{at: at, now_ms: clock} = deadline, timeout) when is_pid(owner) and node(owner) == node() and is_integer(at) and is_function(clock, 0) and is_integer(timeout) and timeout > 0 do
    GenServer.call(owner, {:local_drain_status, deadline}, timeout)
  end

  @spec capture_downstream_idle_timeout(GenServer.server(), map(), String.t()) :: term()
  def capture_downstream_idle_timeout(owner, downstream, client_activity) when is_pid(owner) do
    deadline = System.monotonic_time(:millisecond) + 100
    # A rolling deployment can still have an older owner. Never send its
    # GenServer an unknown call merely to add optional diagnostic evidence.
    if node(owner) == node() or :erpc.call(node(owner), :erlang, :function_exported, [__MODULE__, :capture_downstream_idle_timeout, 3], 100),
      do: GenServer.call(owner, {:capture_downstream_idle_timeout, downstream, client_activity}, max(deadline - System.monotonic_time(:millisecond), 0)),
      else: {:error, :unsupported_owner}
  catch
    :exit, _reason -> {:error, :attribution_unavailable}
    :error, {:erpc, _reason} -> {:error, :attribution_unavailable}
  end

  @spec recover_expired_generation(map()) :: {:ok, term()} | {:error, term()}
  def recover_expired_generation(candidate) do
    if Repo.in_transaction?() do
      {:error, :caller_transaction}
    else
      case Enum.find([node() | Node.list()], &(Atom.to_string(&1) == candidate.owner_instance_id)) do
        nil -> {:error, :owner_unavailable}
        target when target == node() -> local_recover_expired_generation(candidate)
        target -> :erpc.call(target, __MODULE__, :local_recover_expired_generation, [candidate], owner_call_timeout())
      end
    end
  catch
    _, _reason -> {:error, :owner_unavailable}
  end

  @doc false
  @spec local_recover_expired_generation(map()) :: {:ok, term()} | {:error, term()}
  def local_recover_expired_generation(candidate) do
    if Repo.in_transaction?() do
      {:error, :caller_transaction}
    else
      case Registry.lookup(@registry, candidate.session_id) do
        [{owner, _value}] ->
          deadline = System.monotonic_time(:millisecond) + owner_call_timeout() - 1_000
          GenServer.call(owner, {:recover_expired_generation, candidate, deadline}, owner_call_timeout())

        [] ->
          {:error, :owner_unavailable}
      end
    end
  catch
    _, _reason -> {:error, :owner_unavailable}
  end

  @spec reserve_compaction_retry_submit(GenServer.server(), binary(), downstream(), pid()) ::
          {:ok, CompactionRetrySubmitHold.t()} | {:error, atom()}
  def reserve_compaction_retry_submit(owner, lease_token, downstream, requester)
      when is_binary(lease_token) and is_map(downstream) and is_pid(requester) do
    GenServer.call(
      owner,
      {:reserve_compaction_retry_submit, lease_token, downstream, requester},
      owner_call_timeout()
    )
  end

  @spec cancel_compaction_retry_submit(CompactionRetrySubmitHold.t()) :: :ok
  def cancel_compaction_retry_submit(%CompactionRetrySubmitHold{owner: owner} = hold) do
    GenServer.call(owner, {:cancel_compaction_retry_submit, hold}, owner_call_timeout())
  catch
    :exit, _reason -> :ok
  end

  @spec submit_compaction_retry(
          GenServer.server(),
          downstream(),
          UpstreamWebsocketSession.Request.t(),
          boolean(),
          CompactionRetrySubmitHold.t()
        ) :: submitted_request_result()
  def submit_compaction_retry(owner, downstream, request, submission_notification?, hold) do
    GenServer.call(
      owner,
      {:submit_compaction_retry, downstream, request, submission_notification?, hold},
      :infinity
    )
  end

  @spec touch_replay_liveness(GenServer.server(), map(), timeout()) ::
          :ok | {:error, :owner_unavailable}
  def touch_replay_liveness(owner, reference, timeout \\ owner_call_timeout()),
    do: GenServer.call(owner, {:touch_replay_liveness, reference}, timeout)

  @spec lookup(binary(), keyword()) :: {:ok, pid()} | {:error, :owner_unavailable}
  def lookup(codex_session_id, metadata \\ []) when is_binary(codex_session_id) do
    case Registry.lookup(@registry, codex_session_id) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Logger.owner_lookup_missed(codex_session_id, :dead_pid, pid, metadata)
          {:error, :owner_unavailable}
        end

      [] ->
        Logger.owner_lookup_missed(codex_session_id, :not_registered, nil, metadata)
        {:error, :owner_unavailable}
    end
  end

  @spec attach_downstream(GenServer.server(), map()) :: {:ok, downstream()} | {:error, term()}
  def attach_downstream(owner, downstream), do: attach_downstream(owner, downstream, [])

  @spec attach_downstream(GenServer.server(), map(), keyword()) ::
          {:ok, downstream()} | {:error, term()}
  def attach_downstream(owner, %{pid: pid, correlation_id: correlation_id}, opts)
      when is_pid(pid) and is_binary(correlation_id) and is_list(opts) do
    GenServer.call(
      owner,
      {:attach_downstream, pid, correlation_id, opts},
      owner_call_timeout()
    )
  end

  @doc """
  Detaches `downstream` when it is the attached one: its socket abandoned the
  attach after its call timed out, and the owner took the attach before the
  abandon's record (findings#270 row 270-248). The downstream it replaced is
  not restored; that socket meets `stale_owner` on its next request and
  attaches again on its retry.
  """
  @spec abandon_attach(GenServer.server(), map()) :: :ok
  def abandon_attach(owner, %{pid: pid, correlation_id: correlation_id})
      when is_pid(pid) and is_binary(correlation_id),
      do: GenServer.cast(owner, {:abandon_attach, pid, correlation_id})

  @spec restore_downstream(GenServer.server(), downstream()) ::
          {:ok, downstream()} | {:error, term()}
  def restore_downstream(
        owner,
        %{pid: pid, epoch: epoch, correlation_id: correlation_id} = downstream
      )
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    if exact_keys?(downstream, @restore_downstream_keys) do
      GenServer.call(owner, {:restore_downstream, downstream}, owner_call_timeout())
    else
      {:error, :stale_downstream}
    end
  end

  def restore_downstream(_owner, _downstream), do: {:error, :stale_downstream}

  @spec detach_downstream(GenServer.server(), map()) ::
          WebsocketOwnerContract.detach_result()
  def detach_downstream(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    GenServer.call(owner, {:detach_downstream, pid, epoch, correlation_id}, owner_call_timeout())
  end

  @doc """
  Suspends the active turn into its replay entitlement when `downstream` is
  its attached downstream and the turn is replay-active (a native turn with a
  replay binding and no visible output), and changes nothing otherwise.

  A closing socket calls this before it drains its response tasks, so a
  client resend that follows a pre-visible disconnect finds the entitlement
  armed instead of the predecessor still attached (findings#232, 232-100).
  Every other shape answers `:not_previsible` and stays with the ordinary
  detach after the drain.

  An owner that is still starting answers `:not_previsible` without a call.
  Its first state has no downstream, no turn and no replay, and a call queued
  during its start is answered before anything a caller sends once the start
  returns (a recovery restores the downstream and re-submits only then), so
  that is the answer the call would get; making it waited for the whole
  upstream start, up to the call timeout, while the closing socket's drains
  and delivery acknowledgements queued behind it (findings#206 row 206-216).
  """
  @spec detach_previsible_downstream(GenServer.server(), map()) ::
          :suspended | :detached | :not_previsible | {:error, WebsocketOwnerContract.owner_error()}
  def detach_previsible_downstream(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    if starting?(owner) do
      :not_previsible
    else
      GenServer.call(
        owner,
        {:detach_previsible_downstream, pid, epoch, correlation_id},
        owner_call_timeout()
      )
    end
  end

  @doc false
  @spec starting?(GenServer.server()) :: boolean()
  def starting?(owner) when is_pid(owner) do
    @registry
    |> Registry.keys(owner)
    |> Enum.any?(&(Registry.values(@registry, &1, owner) == [@registry_starting]))
  end

  def starting?(_owner), do: false

  @spec cancel_downstream(GenServer.server(), per_call_downstream(), :owner_drained) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_downstream(
        owner,
        %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          owner_turn_id: owner_turn_id
        },
        :owner_drained = reason
      )
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) and
             is_pid(owner_turn_id) do
    GenServer.call(
      owner,
      {:cancel_downstream, pid, epoch, correlation_id, owner_turn_id, reason},
      owner_call_timeout()
    )
  end

  @doc """
  Stops the active turn that `downstream` (a per-call downstream naming its
  turn) submitted, and keeps the downstream attached.

  A remote submission whose forward budget expired sends this: the proxy told
  the client the turn failed, but the owner-node process carrying the
  submission outlives the abandoned erpc reply, so the owner may still take
  the turn. The detach a closing socket sends was used before and also cleared
  the still connected socket's downstream, so every later turn on it was
  refused `stale_owner` (findings#206 row 206-299). Only a turn this exact
  downstream and turn id own is stopped, its output is no longer delivered, and
  anything else answers `stale_downstream` without a change. A socket that
  really went away is still detached by its own cleanup and by the owner's
  monitor on it.
  """
  @spec abandon_turn(GenServer.server(), per_call_downstream()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def abandon_turn(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id, owner_turn_id: owner_turn_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) and is_pid(owner_turn_id) do
    GenServer.call(owner, {:abandon_turn, pid, epoch, correlation_id, owner_turn_id}, owner_call_timeout())
  end

  @doc """
  Cancels the running turn that `downstream` inherited when it attached, as its
  close would, and keeps the downstream attached.

  The released client drops a socket in the middle of a streaming response and
  opens a new one at once; the new socket attaches while the dropped turn is
  still running, and the attach hands that turn to it. Its next request was
  refused (`409 duplicate_turn` for the same turn, `409 owner_busy` for
  another) until the client closed the socket in reaction, which is what
  cancelled the inherited turn (findings#206 rows 206-359 and 206-362). Only a
  turn that is already visible, that this exact downstream received through an
  active-turn attach, and that has no terminal, pending handoff, compaction
  phase or collected delivery is cancelled; its task is stopped and it settles
  `client_disconnected` through its submitter exactly as after the close. The
  answer carries the turn's semantic digest so the caller can wait for that
  settlement. Anything else answers an error and changes nothing.

  A turn that has shown nothing yet and that no replay serves (a native
  compaction is never armed for replay) is taken over the same way when this
  downstream inherited it from a socket that had already closed: one that
  announced its close (`detach_previsible_downstream/2`) or whose exit the
  owner had handled. That socket's own detach cancels the turn only when its
  cleanup gets there, and the released client retries on a new connection
  about 200 ms after the cut, so the retry met the running turn and was
  refused until its own close cancelled it (findings#206 row 206-436).
  """
  @spec take_over_inherited_turn(GenServer.server(), downstream()) ::
          {:ok, %{semantic_turn_digest: <<_::256>>}} | {:error, WebsocketOwnerContract.owner_error()}
  def take_over_inherited_turn(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id})
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) do
    GenServer.call(owner, {:take_over_inherited_turn, pid, epoch, correlation_id}, owner_call_timeout())
  end

  @doc """
  Hands a client's `response.interrupt` (`ResponseInterrupt`, findings#270 row
  270-272) to the upstream session of the running turn, when that turn belongs
  to `downstream` and its frames are relayed as they come; that session writes
  it only while the response it names runs there. Any other interrupt is
  dropped with its one line: no running turn, another downstream's turn, or a
  collected one (a compaction). The owner answers `:ok` in every case.
  """
  @spec interrupt_turn(GenServer.server(), downstream(), ResponseInterrupt.t()) :: :ok
  def interrupt_turn(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id}, %{response_id: response_id, mode: mode} = interrupt)
      when is_pid(pid) and is_integer(epoch) and epoch > 0 and is_binary(correlation_id) and is_binary(response_id) and is_binary(mode) do
    GenServer.call(owner, {:interrupt_turn, pid, epoch, correlation_id, interrupt}, owner_call_timeout())
  end

  @spec steer_turn(GenServer.server(), downstream(), ResponseSteer.t()) :: :ok
  def steer_turn(owner, %{pid: pid, epoch: epoch, correlation_id: correlation_id}, steer), do: GenServer.call(owner, {:steer_turn, pid, epoch, correlation_id, steer}, owner_call_timeout())

  @spec begin_steering_successor(GenServer.server(), pid(), pid(), NativeResponseSteering.identity(), Ecto.UUID.t()) :: :ok | {:error, :owner_busy | :owner_unavailable}
  def begin_steering_successor(owner, lane, socket, identity, turn_id), do: GenServer.call(owner, {:begin_steering_successor, lane, socket, identity, turn_id}, owner_call_timeout())

  @spec relay_steering_frame(GenServer.server(), pid(), NativeResponseSteering.identity(), binary(), TerminalDiscriminator.t()) :: :ok | {:error, term()}
  def relay_steering_frame(owner, lane, identity, data, discriminator), do: GenServer.call(owner, {:relay_steering_frame, lane, identity, data, discriminator}, owner_call_timeout())

  @spec complete_steering_successor(GenServer.server(), pid(), NativeResponseSteering.identity(), term()) :: :ok
  def complete_steering_successor(owner, lane, identity, result), do: GenServer.call(owner, {:complete_steering_successor, lane, identity, result}, owner_call_timeout())

  @spec complete_steering_original(GenServer.server(), Ecto.UUID.t(), map()) :: :ok
  def complete_steering_original(owner, request_id, result), do: GenServer.call(owner, {:complete_steering_original, request_id, result}, owner_call_timeout())

  @type reconnect_preflight_result ::
          {:ok, :dispatch | :same_turn_replay}
          | {:ok, :replacement_handoff | :duplicate_replacement, reference()}
          | {:error, WebsocketOwnerContract.owner_error()}

  @spec preflight_reconnect(GenServer.server(), downstream(), <<_::256>>, reference()) ::
          reconnect_preflight_result()
  def preflight_reconnect(owner, downstream, semantic_turn_key, control_ref)
      when is_map(downstream) and is_binary(semantic_turn_key) and
             byte_size(semantic_turn_key) == 32 and is_reference(control_ref) do
    GenServer.call(
      owner,
      {:preflight_reconnect, downstream, semantic_turn_key, control_ref},
      owner_call_timeout()
    )
  end

  def preflight_reconnect(_owner, _downstream, _semantic_turn_key, _control_ref),
    do: {:error, :owner_busy}

  @spec cancel_reconnect(GenServer.server(), downstream(), reference()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error()}
  def cancel_reconnect(owner, downstream, control_ref)
      when is_map(downstream) and is_reference(control_ref) do
    GenServer.call(owner, {:cancel_reconnect, downstream, control_ref}, owner_call_timeout())
  end

  def cancel_reconnect(_owner, _downstream, _control_ref), do: {:error, :stale_downstream}

  @spec reconnect_control_v2(GenServer.server(), RemoteReconnectControlV2.t()) :: term()
  def reconnect_control_v2(owner, %RemoteReconnectControlV2{} = control),
    do: GenServer.call(owner, {:reconnect_control_v2, control}, owner_call_timeout())

  def reconnect_control_v2(_owner, _control), do: {:error, :owner_unavailable}

  @spec begin_suspend(GenServer.server(), map()) :: :ok | {:error, atom()}
  def begin_suspend(owner, descriptor) when is_map(descriptor),
    do: GenServer.call(owner, {:begin_suspend, descriptor}, owner_call_timeout())

  @spec record_active_downstream_loss(GenServer.server(), downstream()) ::
          :reattachable | {:error, atom()}
  def record_active_downstream_loss(owner, downstream) when is_map(downstream),
    do: GenServer.call(owner, {:record_active_downstream_loss, downstream}, owner_call_timeout())

  @spec prepare_next_replay_descriptor(GenServer.server(), downstream(), map()) ::
          :ok | {:error, atom()}
  def prepare_next_replay_descriptor(owner, downstream, descriptor)
      when is_map(downstream) and is_map(descriptor),
      do:
        GenServer.call(
          owner,
          {:prepare_next_replay_descriptor, downstream, descriptor},
          owner_call_timeout()
        )

  @type admission_result ::
          {:ok,
           NativeCompactionAdmission.t()
           | NativeCompactionAdmission.Capability.t()
           | NativeCompactionAdmission.FirstCompactCollection.t()
           | nil}
          | {:error, atom()}

  @spec admission_control(GenServer.server(), WebsocketOwnerAdmissionControlV1.t()) ::
          admission_result()
  def admission_control(owner, %WebsocketOwnerAdmissionControlV1{} = control) do
    GenServer.call(owner, {:admission_control_v1, control}, owner_call_timeout())
  end

  def admission_control(_owner, _control), do: {:error, :owner_unavailable}

  @spec issue_forwarded_send_witness(
          GenServer.server(),
          downstream(),
          NativeCompactionAdmission.Capability.t(),
          non_neg_integer()
        ) :: {:ok, ForwardedSendWitnessV1.t()} | {:error, atom()}
  def issue_forwarded_send_witness(owner, downstream, capability, now_ms)
      when is_map(downstream) and is_integer(now_ms) and now_ms >= 0 do
    GenServer.call(
      owner,
      {:issue_forwarded_send_witness_v1, downstream, capability, now_ms},
      owner_call_timeout()
    )
  end

  def issue_forwarded_send_witness(_owner, _downstream, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec redeem_forwarded_send(
          GenServer.server(),
          ForwardedSendWitnessV1.t(),
          UpstreamWebsocketSession.connection_lifecycle_state(),
          :full | :lite
        ) :: :ok | {:error, atom()}
  def redeem_forwarded_send(owner, witness, live_lifecycle_snapshot, serving_mode)
      when is_map(live_lifecycle_snapshot) and serving_mode in [:full, :lite] do
    redeem_forwarded_send(
      owner,
      witness,
      live_lifecycle_snapshot,
      serving_mode,
      owner_call_timeout()
    )
  end

  def redeem_forwarded_send(_owner, _witness, _snapshot, _mode),
    do: {:error, :invalid_input}

  @doc false
  @spec redeem_forwarded_send(
          GenServer.server(),
          ForwardedSendWitnessV1.t(),
          UpstreamWebsocketSession.connection_lifecycle_state(),
          :full | :lite,
          pos_integer()
        ) :: :ok | {:error, atom()}
  def redeem_forwarded_send(
        owner,
        witness,
        live_lifecycle_snapshot,
        serving_mode,
        timeout_ms
      )
      when is_map(live_lifecycle_snapshot) and serving_mode in [:full, :lite] and
             is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      owner,
      {:redeem_forwarded_send_v1, witness, live_lifecycle_snapshot, serving_mode},
      timeout_ms
    )
  catch
    :exit, reason ->
      if expected_redemption_call_exit?(reason) do
        {:error, :forwarded_send_witness_rejected}
      else
        :erlang.raise(:exit, reason, __STACKTRACE__)
      end
  end

  def redeem_forwarded_send(_owner, _witness, _snapshot, _mode, _timeout_ms),
    do: {:error, :invalid_input}

  defp expected_redemption_call_exit?({reason, {GenServer, :call, _details}}),
    do: expected_redemption_call_exit?(reason)

  defp expected_redemption_call_exit?(reason)
       when reason in [:noproc, :normal, :shutdown, :timeout, :nodedown],
       do: true

  defp expected_redemption_call_exit?({:shutdown, _details}), do: true
  defp expected_redemption_call_exit?({:nodedown, _node}), do: true
  defp expected_redemption_call_exit?({:timeout, _details}), do: true
  defp expected_redemption_call_exit?({:noproc, _details}), do: true
  defp expected_redemption_call_exit?(_reason), do: false

  defp apply_admission_control(state, %WebsocketOwnerAdmissionControlV1{} = control) do
    with :ok <- validate_admission_control(control),
         :ok <- require_admission_downstream(state, control.downstream) do
      execute_admission_control(state, control)
    else
      {:error, reason} ->
        observe_admission(state, state, :reject, reason)
        {:error, reason, state}
    end
  end

  defp apply_admission_control(state, _control),
    do: {:error, :owner_unavailable, clear_native_compaction_admission(state, :invalid_input)}

  defp execute_admission_control(state, %{action: :snapshot}) do
    {:ok, state.native_compaction_admission, state}
  end

  defp execute_admission_control(state, %{
         action: :record_ordinary_success,
         binding: binding,
         expires_at_ms: expires_at_ms,
         first_compact_collection: %OrdinarySuccessResult{} = receipt,
         downstream: downstream
       }) do
    with :ok <- require_forwarded_binding(state, downstream, binding),
         true <- state.ordinary_success_result == receipt and receipt.owner == self(),
         true <- OrdinarySuccessResult.binding_matches?(receipt, binding),
         true <- is_nil(state.active_turn),
         true <-
           is_nil(state.native_compaction_admission) or
             state.native_compaction_admission.phase in [
               :cleared,
               :ordinary_success,
               :pending_compact,
               :consumed_final
             ],
         true <-
           UpstreamWebsocketSession.connection_lifecycle_snapshot(state.upstream_pid) ==
             receipt.lifecycle,
         {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
         {:ok, admission} <- NativeCompactionAdmission.arm_compact(admission, expires_at_ms) do
      {:ok, admission,
       %{
         put_admission(state, admission)
         | first_compact_result: nil,
           ordinary_success_result: nil,
           native_compaction_admission_downstream: stable_downstream(downstream)
       }}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_transition, state}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :reserve} = control
       ) do
    with :ok <- require_forwarded_binding(state, control.downstream, control.binding),
         :ok <- require_live_admission_connection(state, admission),
         {:ok, next, capability} <-
           NativeCompactionAdmission.reserve(
             admission,
             control.phase,
             control.binding,
             control.control_ref,
             control.now_ms
           ) do
      :ok = emit_reservation_observations(capability)
      {:ok, capability, put_admission(state, next)}
    else
      {:error, :connection_closed} -> {:error, :invalid_transition, clear_native_compaction_admission(state, :connection_closed)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{
         action: :authorize_first_compact_collection,
         binding: binding,
         control_ref: control_ref,
         first_compact_collection: %NativeCompactionAdmission.FirstCompactResult{} = receipt,
         downstream: downstream
       }) do
    with :ok <- require_forwarded_binding(state, downstream, binding),
         true <- state.first_compact_result == receipt and receipt.owner == self(),
         true <- receipt.result_ref == control_ref,
         true <- NativeCompactionAdmission.FirstCompactResult.binding_matches?(receipt, binding),
         true <- is_nil(state.active_turn),
         true <-
           is_nil(state.native_compaction_admission) or
             state.native_compaction_admission.phase in [
               :cleared,
               :ordinary_success,
               :pending_compact
             ],
         true <-
           UpstreamWebsocketSession.connection_lifecycle_snapshot(state.upstream_pid) == %{
             lifecycle_id: binding.lifecycle_id,
             generation: binding.generation
           },
         {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
         {:ok, admission, provenance} <-
           NativeCompactionAdmission.authorize_first_compact_collection(
             admission,
             control_ref
           ) do
      {:ok, provenance,
       %{
         put_admission(state, %{admission | compaction_item_digest: receipt.item_digest})
         | first_compact_result: nil,
           native_compaction_admission_downstream: stable_downstream(downstream)
       }}
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_transition, state}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :record_first_compact_collected} = control
       ) do
    case NativeCompactionAdmission.record_first_compact_collected(
           admission,
           control.first_compact_collection,
           System.system_time(:millisecond)
         ) do
      {:ok, next} ->
        {:ok, next, put_admission(state, next)}

      {:error, reason} ->
        {:error, reason, state}

      {:error, reason, next} ->
        {:error, reason,
         if(admission.first_compact_collection == control.first_compact_collection,
           do: put_admission(state, next),
           else: state
         )}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :mark_accounting_started} = control
       ) do
    case NativeCompactionAdmission.mark_accounting_started(
           admission,
           control.capability,
           control.now_ms
         ) do
      {:ok, next} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            control.capability,
            :accounting_started
          )

        _trace =
          NativeCompactionTrace.emit_capability(:accounting_started, control.capability, %{
            pid_role: :owner_session,
            owner_pid: self()
          })

        {:ok, next, put_admission(state, next)}

      {:error, reason} ->
        :ok =
          NativeCompactionAuthorizationObservation.log_accounting_rejection(
            admission,
            control.capability,
            :forwarded,
            reason
          )

        {:error, reason, clear_rejected_capability(state, control.capability, reason)}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: nil} = state,
         %{action: :mark_accounting_started, capability: capability}
       ) do
    :ok =
      NativeCompactionAuthorizationObservation.log_accounting_rejection(
        nil,
        capability,
        :forwarded,
        :invalid_transition
      )

    {:error, :invalid_transition, clear_native_compaction_admission(state, :invalid_transition)}
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :cancel} = control
       ) do
    case NativeCompactionAdmission.cancel(
           admission,
           control.capability,
           control.disposition,
           control.now_ms
         ) do
      {:ok, next} ->
        {:ok, next, put_admission(state, next)}

      {:error, :committed, next} ->
        {:error, :committed, put_admission(state, next)}

      {:error, reason} ->
        {:error, reason, clear_rejected_capability(state, control.capability, reason)}
    end
  end

  defp execute_admission_control(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         %{action: :finalization_ack, success?: true} = control
       ) do
    compact_capability = admission.capability

    case NativeCompactionAdmission.confirm_compact(
           admission,
           control.compaction_item_digest,
           control.confirmation,
           control.expires_at_ms
         ) do
      {:ok, next} ->
        :ok = emit_compact_acknowledged(compact_capability)
        confirmed_admission(state, next)

      {:error, reason, next} ->
        {:error, reason,
         if(owns_confirmation?(admission, control.confirmation),
           do: put_admission(state, next),
           else: state
         )}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{action: :finalization_ack, success?: false}) do
    {:ok, nil, clear_native_compaction_admission(state, :compact_failure)}
  end

  defp execute_admission_control(state, %{
         action: :clear,
         capability: %NativeCompactionAdmission.Capability{} = capability
       }) do
    case NativeCompactionAdmission.clear_owned(
           state.native_compaction_admission || %NativeCompactionAdmission{phase: :cleared},
           capability
         ) do
      {:ok, _cleared} ->
        {:ok, nil, clear_native_compaction_admission(state, :request_rejected)}

      {:error, reason} ->
        observe_admission(state, state, :reject, :stale_capability)
        {:error, reason, state}
    end
  end

  defp execute_admission_control(state, %{action: :clear}) do
    {:ok, nil, clear_native_compaction_admission(state, :request_rejected)}
  end

  defp execute_admission_control(state, _control),
    do: {:error, :invalid_transition, clear_native_compaction_admission(state, :invalid_transition)}

  # The confirmation names the connection the compaction ran on. When the
  # provider closed it between the collection and this confirmation, the
  # confirmation ends the admission (`connection_closed`) instead of arming
  # a final that could never reach the provider: the client gets its
  # compaction and the final runs as an ordinary turn on the next connection,
  # as with owner forwarding off (findings#275).
  defp confirmed_admission(state, %NativeCompactionAdmission{phase: :pending_final} = next) do
    case require_live_admission_connection(state, next) do
      :ok -> {:ok, next, put_admission(state, next)}
      {:error, :connection_closed} -> {:ok, NativeCompactionAdmission.clear(next), clear_native_compaction_admission(state, :connection_closed)}
    end
  end

  defp confirmed_admission(state, next), do: {:ok, next, put_admission(state, next)}

  # An admission is used (reserved, or confirmed into its final) only on the
  # connection it names. The session answers which connection is open now,
  # so a close the owner has not heard of yet counts too (findings#275). A
  # session that cannot answer, or names another lifecycle, keeps today's
  # checks. The session serves a request inside its call handler, so it is
  # read only while the owner runs no turn: a reservation that reaches the
  # owner during one (a reconnected socket inheriting a running turn) keeps
  # today's checks instead of stalling the owner on its session (findings#270
  # row 270-199).
  defp require_live_admission_connection(%{active_turn: active_turn}, _admission) when not is_nil(active_turn), do: :ok

  defp require_live_admission_connection(state, %NativeCompactionAdmission{binding: %NativeCompactionAdmission.Binding{lifecycle_id: lifecycle_id, generation: generation}}) do
    case state.callbacks.connection_reader.(state.upstream_pid) do
      {:ok, %{lifecycle_id: ^lifecycle_id, generation: ^generation}} -> :ok
      {:ok, %{lifecycle_id: ^lifecycle_id}} -> {:error, :connection_closed}
      _unknown -> :ok
    end
  end

  defp require_live_admission_connection(_state, _admission), do: :ok

  defp validate_admission_control(control) do
    case WebsocketOwnerAdmissionControlV1.validate(control) do
      :ok -> :ok
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  defp require_admission_downstream(state, downstream) do
    if admission_downstream_matches?(state.downstream, downstream) and
         admission_downstream_matches?(state.native_compaction_admission_downstream, downstream) do
      :ok
    else
      {:error, :stale_downstream}
    end
  end

  defp admission_downstream_matches?(nil, _downstream), do: true

  defp admission_downstream_matches?(stored, downstream) do
    stored.pid == downstream.pid and stored.epoch == downstream.epoch
  end

  defp require_forwarded_binding(state, downstream, %NativeCompactionAdmission.Binding{
         topology: %NativeCompactionAdmission.Topology.Forwarded{} = topology
       }) do
    if WebsocketOwnerAdmissionControlV1.topology_matches?(
         topology,
         state.owner_instance_id,
         state.owner_lease_token,
         downstream.epoch
       ) do
      :ok
    else
      {:error, :binding_mismatch}
    end
  end

  defp require_forwarded_binding(_state, _downstream, _binding),
    do: {:error, :binding_mismatch}

  defp stable_downstream(downstream), do: Map.take(downstream, @restore_downstream_keys)

  defp put_admission(state, %NativeCompactionAdmission{} = admission) do
    next = %{state | native_compaction_admission: admission}

    operation =
      case admission.phase do
        phase when phase in [:reserved_compact, :reserved_final] ->
          :reserve

        phase when phase in [:accounting_started_compact, :accounting_started_final] ->
          :accounting

        phase when phase in [:consumed_compact, :consumed_final] ->
          :consume

        :collected_unconfirmed ->
          :collect

        :pending_final ->
          :confirm

        :cleared ->
          :clear

        _ ->
          :ordinary_success
      end

    observation = observe_admission(state, next, operation, :success)

    if admission.phase == :cleared,
      do: remember_last_clear(next, observation),
      else: next
  end

  defp emit_reservation_observations(%NativeCompactionAdmission.Capability{} = capability) do
    # One successful owner reserve operation proves both issuance and the
    # immediately stored reserved state. Neither fact is emitted on failure.
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :owner_issued)
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :reserved)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_reserved, capability, %{
        pid_role: :owner_session,
        owner_pid: self(),
        branch: :forwarded_owner
      })

    :ok
  end

  defp emit_final_completed(%{
         native_compaction_admission: %NativeCompactionAdmission{phase: :consumed_final}
       }),
       do: NativeCompactionAuthorizationObservation.emit(:final_acknowledged, :forwarded)

  defp emit_final_completed(_state), do: :ok

  defp clear_rejected_capability(state, capability, reason) do
    if NativeCompactionAdmission.owns_capability?(state.native_compaction_admission, capability),
      do: clear_native_compaction_admission(state, reason),
      else: state
  end

  defp owns_confirmation?(%{capability: %{control_ref: ref}}, %{source_control_ref: ref}),
    do: true

  defp owns_confirmation?(%{first_compact_collection: %{control_ref: ref}}, %{
         source_control_ref: ref
       }),
       do: true

  defp owns_confirmation?(_admission, _confirmation), do: false

  # A collection that no acknowledgement confirmed within its bound, or a
  # final that did not come within its bound, is spent before the next
  # admission control reads it. An acknowledgement lost with its caller used
  # to keep `collected_unconfirmed` for as long as the socket stayed attached,
  # and the next ordinary success and first full-history compaction were
  # refused after the provider had served and billed them (findings#270 row
  # 270-249). A final that came after its bound ran as an ordinary turn but
  # left `pending_final`, which refused that turn's ordinary success and every
  # later one, so each compaction on the socket was refused `503` (row
  # 270-289). Only the admission ends; the results the last turn left
  # (`first_compact_result`, `ordinary_success_result`) belong to a newer turn
  # and stay.
  defp expire_stale_admission(%{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state) do
    case NativeCompactionAdmission.expire_unconsumed(admission, System.system_time(:millisecond)) do
      {:expired, _cleared} ->
        next = %{state | native_compaction_admission: nil, native_compaction_admission_downstream: nil, forwarded_send_witness: nil}
        observation = observe_admission(state, next, :clear, :expired)
        remember_last_clear(next, observation)

      {:active, _admission} ->
        state
    end
  end

  defp expire_stale_admission(state), do: state

  defp expired_by_snapshot?(%WebsocketOwnerAdmissionControlV1{action: :snapshot}, %{native_compaction_admission: %NativeCompactionAdmission{}}, %{native_compaction_admission: nil}), do: true
  defp expired_by_snapshot?(_control, _state, _unexpired), do: false

  # Every clear names why it happened, from the fixed lifecycle vocabulary
  # (findings#258 rows 258-23 and 258-50): a default made drains, stale owners,
  # upstream exits and capability rejections read as rejected requests.
  defp clear_native_compaction_admission(state, reason) do
    next = %{
      state
      | native_compaction_admission: nil,
        first_compact_result: nil,
        ordinary_success_result: nil,
        native_compaction_admission_downstream: nil,
        forwarded_send_witness: nil
    }

    observation = observe_admission(state, next, :clear, reason)
    remember_last_clear(next, observation)
  end

  defp remember_last_clear(state, observation) do
    Process.put({__MODULE__, :native_compaction_last_clear}, observation)
    state
  end

  defp observe_admission(before_state, after_state, operation, reason) do
    observation =
      NativeCompactionLifecycleObservation.observe(
        before_state.native_compaction_admission,
        after_state.native_compaction_admission,
        operation,
        reason,
        :forwarded
      )

    Elixir.Logger.debug(fn -> "native compaction lifecycle " <> inspect(observation) end)

    :telemetry.execute(
      [:codex_pooler, :gateway, :native_compaction, :lifecycle],
      %{count: 1},
      observation
    )

    observation
  end

  defp issue_forwarded_send_witness_now(
         %{native_compaction_admission: %NativeCompactionAdmission{} = admission} = state,
         downstream,
         %NativeCompactionAdmission.Capability{} = capability,
         now_ms
       ) do
    with :ok <- require_admission_downstream(state, downstream),
         {:ok, consumed} <- NativeCompactionAdmission.consume(admission, capability, now_ms),
         {:ok, witness} <- ForwardedSendWitnessV1.issue(capability, downstream, now_ms) do
      :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :consumed)

      _trace =
        NativeCompactionTrace.emit_capability(:capability_consumed, capability, %{
          pid_role: :owner_session,
          owner_pid: self(),
          branch: :forwarded_owner
        })

      {:ok, witness,
       %{
         put_admission(state, consumed)
         | forwarded_send_witness: %ForwardedSendWitnessState{
             digest: ForwardedSendWitnessV1.digest(witness),
             binding: capability.binding,
             control_ref: capability.control_ref,
             downstream: stable_downstream(downstream),
             status: :issued
           }
       }}
    else
      {:error, reason} -> {:error, reason, clear_native_compaction_admission(state, reason)}
    end
  end

  defp issue_forwarded_send_witness_now(state, _downstream, _capability, _now_ms),
    do: {:error, :invalid_transition, clear_native_compaction_admission(state, :invalid_transition)}

  defp redeem_forwarded_send_now(
         %{
           forwarded_send_witness: %ForwardedSendWitnessState{
             status: :issued,
             digest: expected_digest,
             binding: binding,
             control_ref: control_ref,
             downstream: downstream
           }
         } = state,
         %ForwardedSendWitnessV1{} = witness,
         live_lifecycle_snapshot,
         serving_mode
       ) do
    now_ms = System.system_time(:millisecond)

    if secure_digest_match?(expected_digest, ForwardedSendWitnessV1.digest(witness)) and
         ForwardedSendWitnessV1.authorizes?(
           witness,
           binding,
           control_ref,
           downstream,
           live_lifecycle_snapshot,
           serving_mode,
           now_ms
         ) and current_owner_binding?(state, binding, downstream) do
      {:ok, put_in(state.forwarded_send_witness.status, :redeemed)}
    else
      {:error, :forwarded_send_witness_rejected, clear_native_compaction_admission(state, :send_witness_rejected)}
    end
  end

  defp redeem_forwarded_send_now(state, _witness, _snapshot, _mode),
    do: {:error, :forwarded_send_witness_rejected, clear_native_compaction_admission(state, :send_witness_rejected)}

  defp current_owner_binding?(state, %NativeCompactionAdmission.Binding{} = binding, downstream) do
    require_forwarded_binding(state, downstream, binding) == :ok and
      admission_downstream_matches?(state.native_compaction_admission_downstream, downstream)
  end

  defp secure_digest_match?(expected, presented)
       when is_binary(expected) and is_binary(presented) and byte_size(expected) == 32 and
              byte_size(presented) == 32,
       do: Plug.Crypto.secure_compare(expected, presented)

  defp secure_digest_match?(_expected, _presented), do: false

  @spec submit_frame(GenServer.server(), downstream(), binary()) ::
          :ok | {:error, WebsocketOwnerContract.owner_error() | term()}
  def submit_frame(owner, downstream, payload)
      when is_map(downstream) and is_binary(payload) do
    submit_upstream(owner, downstream, payload)
  end

  @spec submit_request(GenServer.server(), downstream(), UpstreamWebsocketSession.Request.t()) ::
          submitted_request_result()
  def submit_request(owner, downstream, %UpstreamWebsocketSession.Request{} = request)
      when is_map(downstream) do
    submit_request(owner, downstream, request, submission_observer?(request))
  end

  @spec submit_request(
          GenServer.server(),
          downstream(),
          UpstreamWebsocketSession.Request.t(),
          boolean()
        ) :: submitted_request_result()
  def submit_request(
        owner,
        downstream,
        %UpstreamWebsocketSession.Request{} = request,
        submission_notification?
      )
      when is_map(downstream) and is_boolean(submission_notification?) do
    GenServer.call(
      owner,
      {:submit_upstream, downstream, request, submission_notification?},
      :infinity
    )
  end

  @spec authorize_generation_send(GenServer.server(), UpstreamWebsocketSession.Request.t(), ProviderCreditsAdmission.Receipt.t()) :: {:ok, UpstreamWebsocketSession.Request.t()} | {:error, :owner_unavailable}
  def authorize_generation_send(owner, request, receipt) do
    GenServer.call(owner, {:authorize_generation_send_v1, request, receipt}, owner_call_timeout())
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp submit_upstream(owner, downstream, upstream_payload)
       when is_map(downstream) do
    GenServer.call(owner, {:submit_upstream, downstream, upstream_payload}, :infinity)
  end

  @spec push_downstream(GenServer.server(), WebsocketOwnerContract.downstream_payload()) ::
          :ok | {:error, :invalid_downstream_message | :owner_unavailable}
  def push_downstream(owner, payload) do
    GenServer.call(owner, {:push_downstream, payload}, owner_call_timeout())
  end

  @doc false
  @spec consume_reserve_receipt(GenServer.server(), map()) ::
          {:ok, reference()} | {:error, :invalid}
  def consume_reserve_receipt(owner, proof) when is_map(proof),
    do: GenServer.call(owner, {:consume_reserve_receipt, proof}, owner_call_timeout())

  @doc false
  @spec validate_consumed_reserve_receipt(GenServer.server(), map(), reference()) ::
          :ok | {:error, :invalid}
  def validate_consumed_reserve_receipt(owner, proof, consume_fence)
      when is_map(proof) and is_reference(consume_fence),
      do:
        GenServer.call(
          owner,
          {:validate_consumed_reserve_receipt, proof, consume_fence},
          owner_call_timeout()
        )

  @doc false
  @spec release_consumed_reserve_receipt(GenServer.server(), map(), reference()) ::
          :ok | {:error, :invalid}
  def release_consumed_reserve_receipt(owner, proof, consume_fence)
      when is_map(proof) and is_reference(consume_fence),
      do:
        GenServer.call(
          owner,
          {:release_consumed_reserve_receipt, proof, consume_fence},
          owner_call_timeout()
        )

  @doc false
  @spec register_pre_attempt_admission_v1(pid(), DirectCleanup.t()) :: :ok | {:error, atom()}
  def register_pre_attempt_admission_v1(owner, %DirectCleanup{} = context),
    do: GenServer.call(owner, {:register_pre_attempt_admission_v1, context}, owner_call_timeout())

  @impl GenServer
  def init(opts) do
    sensitivity = NativeCompactionTrace.configure_process_sensitivity(:owner_session)
    Process.flag(:trap_exit, true)
    _trace = NativeCompactionTrace.enroll(:owner_session, self())

    codex_session_id = Keyword.fetch!(opts, :codex_session_id)
    owner_lease_token = Keyword.fetch!(opts, :owner_lease_token)
    owner_instance_id = Keyword.fetch!(opts, :owner_instance_id)
    request_id = Keyword.get(opts, :request_id)
    idle_shutdown_ms = Keyword.get(opts, :idle_shutdown_ms, 300_000)
    owner_renewal_ms = Keyword.get(opts, :owner_renewal_ms, owner_renewal_ms())

    monotonic_now_ms =
      Keyword.get(opts, :monotonic_now_ms, fn -> System.monotonic_time(:millisecond) end)

    handoff_soft_timeout_ms =
      Keyword.get(opts, :handoff_soft_timeout_ms, @handoff_soft_timeout_ms)

    handoff_absolute_timeout_ms =
      Keyword.get(opts, :handoff_absolute_timeout_ms, @handoff_absolute_timeout_ms)

    output_commit_probe_timeout_ms = output_commit_probe_timeout_ms(opts)
    terminal_delivery_timeout_ms = terminal_delivery_timeout_ms(opts)

    owner_renewal_delay =
      Keyword.get(opts, :owner_renewal_delay, &jittered_owner_renewal_delay/1)

    upstream = upstream_boundary(opts)
    persistence = persistence_boundary(opts)

    with {:ok, upstream_pid} <- upstream.start.() do
      _marked = Registry.update_value(owner_registry(opts), codex_session_id, fn _starting -> ready_registry_value(owner_lease_token) end)

      {:ok,
       %__MODULE__{
         receipt_registry: Keyword.get(opts, :receipt_registry, ActivityRegistry),
         codex_session_id: codex_session_id,
         turn_claim_session: turn_claim_session(codex_session_id, opts),
         owner_lease_token: owner_lease_token,
         owner_instance_id: owner_instance_id,
         owner_registry: owner_registry(opts),
         upstream_pid: upstream_pid,
         producer_identity: Map.get(upstream, :producer_identity, fn _pid -> :unknown end).(upstream_pid),
         callbacks: %Callbacks{
           upstream_sender: upstream.send,
           upstream_closer: upstream.close,
           upstream_invalidator: Map.get(upstream, :invalidate, &invalidate_owner_upstream/1),
           connection_reader: Map.get(upstream, :live_connection, &unknown_live_connection/1),
           downstream_sender: Keyword.get(opts, :downstream_sender, &send_downstream_message/2),
           monotonic_now_ms: monotonic_now_ms,
           replay_suspender: Keyword.get(opts, :replay_suspender, &CodexPooler.Accounting.arm_request_replay/1),
           replay_status_reader:
             Keyword.get(
               opts,
               :replay_status_reader,
               &CodexPooler.Accounting.replay_provisional_token_status/1
             ),
           replay_retirer: Keyword.get(opts, :replay_retirer, &CodexPooler.Accounting.supersede_request_replay/1)
         },
         persistence: persistence,
         request_id: request_id,
         idle_shutdown_ms: idle_shutdown_ms,
         owner_renewal_ms: owner_renewal_ms,
         owner_renewal_delay: owner_renewal_delay,
         native_compaction_trace_sensitivity: sensitivity,
         handoff_soft_timeout_ms: handoff_soft_timeout_ms,
         handoff_absolute_timeout_ms: handoff_absolute_timeout_ms,
         output_commit_probe_timeout_ms: output_commit_probe_timeout_ms,
         terminal_delivery_timeout_ms: terminal_delivery_timeout_ms,
         draining?: false,
         retire_after_active_turn?: false,
         native_compaction_admission: nil,
         native_compaction_admission_downstream: nil,
         forwarded_send_witness: nil,
         downstream_epoch: 0,
         process_generation: System.unique_integer([:positive, :monotonic]),
         suspended_replay: nil
       }
       |> schedule_owner_renewal()}
    end
  end

  @impl GenServer
  @spec format_status(Status.projection()) :: Status.projection()
  def format_status(status), do: Status.format(status)

  @impl GenServer
  def handle_call(:native_compaction_trace_cooperative?, _from, state),
    do: {:reply, true, state}

  def handle_call(
        {:reserve_compaction_retry_submit, lease_token, downstream, requester},
        _from,
        state
      ) do
    state = expire_compaction_retry_submit_hold(state)

    with true <- lease_token == state.owner_lease_token,
         false <- state.draining?,
         true <- Process.alive?(state.upstream_pid),
         nil <- state.active_turn,
         nil <- state.pending_handoff,
         nil <- state.suspended_replay,
         nil <- state.compaction_retry_submit_hold,
         {:ok, _downstream} <- active_turn_downstream(state.downstream, downstream) do
      token = CompactionRetrySubmitHold.new()

      hold = %{
        token: token,
        downstream: Map.take(downstream, @public_per_call_downstream_keys),
        monitor: Process.monitor(requester),
        expires_at: System.monotonic_time(:millisecond) + @compaction_retry_hold_timeout_ms,
        timer:
          Process.send_after(
            self(),
            {:compaction_retry_submit_hold_expired, token.ref},
            @compaction_retry_hold_timeout_ms
          )
      }

      {:reply, {:ok, token}, %{state | compaction_retry_submit_hold: hold}}
    else
      _unavailable -> {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:cancel_compaction_retry_submit, token}, _from, state) do
    state =
      case state.compaction_retry_submit_hold do
        %{token: ^token} -> clear_compaction_retry_submit_hold(state)
        _hold -> state
      end

    {:reply, :ok, state}
  end

  def handle_call(
        {:submit_compaction_retry, downstream, request, submission_notification?, token},
        from,
        state
      ) do
    state = expire_compaction_retry_submit_hold(state)

    with nil <- state.active_turn,
         %{token: ^token, downstream: held_downstream} <- state.compaction_retry_submit_hold,
         true <- held_downstream == Map.take(downstream, @public_per_call_downstream_keys) do
      state
      |> clear_compaction_retry_submit_hold()
      |> accept_or_consume_upstream_submission(
        from,
        downstream,
        request,
        submission_notification?
      )
    else
      _unavailable -> {:reply, {:error, :owner_unavailable}, state}
    end
  end

  # A submission from a downstream the owner detached while nothing of it was
  # accepted: its client left before the turn started, so it never starts
  # (`detach_idle_closing_downstream/2`, findings#232 rows 232-171 and 232-175);
  # its replay-descriptor preparation, the step before, is refused the same way.
  def handle_call(
        {:submit_upstream, %{pid: pid, epoch: epoch, correlation_id: correlation_id}, _payload},
        _from,
        %{closed_downstream: %{pid: pid, epoch: epoch, correlation_id: correlation_id}} = state
      ),
      do: {:reply, {:error, :client_disconnected}, state}

  def handle_call(
        {:submit_upstream, %{pid: pid, epoch: epoch, correlation_id: correlation_id}, _payload, _submission_notification?},
        _from,
        %{closed_downstream: %{pid: pid, epoch: epoch, correlation_id: correlation_id}} = state
      ),
      do: {:reply, {:error, :client_disconnected}, state}

  def handle_call(message, _from, %{compaction_retry_submit_hold: hold} = state)
      when not is_nil(hold) and is_tuple(message) and
             elem(message, 0) in [
               :submit_upstream,
               :attach_downstream,
               :restore_downstream,
               :preflight_reconnect,
               :reconnect_control_v2
             ] do
    {:reply, {:error, :owner_busy}, state}
  end

  if @dev_features_build_enabled do
    def handle_call(
          {:native_compaction_trace_sensitivity, :observe, generation, authorization, restorer},
          _from,
          state
        ) do
      case NativeCompactionTrace.configure_existing_process_sensitivity(
             :owner_session,
             generation,
             authorization,
             restorer
           ) do
        {:ok, sensitivity} ->
          {:reply, :ok, %{state | native_compaction_trace_sensitivity: sensitivity}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  else
    def handle_call(
          {:native_compaction_trace_sensitivity, :observe, _generation, _authorization, _restorer},
          _from,
          state
        ),
        do: {:reply, {:error, :full_trace_unavailable}, state}
  end

  def handle_call({:recover_expired_generation, candidate, deadline}, _from, state) do
    case ExpiredOwnerGenerationCleanup.within_deadline(deadline, fn -> recover_expired_slot(state, candidate) end) do
      {result, %__MODULE__{} = next_state} -> {:reply, result, next_state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:owner_identity, _from, state) do
    {:reply,
     {:ok,
      %{
        codex_session_id: state.codex_session_id,
        owner_lease_token: state.owner_lease_token,
        owner_instance_id: state.owner_instance_id
      }}, state}
  end

  def handle_call({:register_pre_attempt_admission_v1, context}, _from, state) do
    binding = context.owner_binding

    if not state.draining? and context.session_id == state.codex_session_id and
         binding.owner_instance_id == state.owner_instance_id and
         binding.owner_lease_token == state.owner_lease_token and
         match?(
           %{pid: pid, epoch: epoch}
           when pid == context.parent and epoch == binding.downstream_epoch,
           state.downstream
         ) do
      state = forget_pending_admission(state, context.task)
      monitor = Process.monitor(context.task)
      state = put_in(state.pending_admissions[context.task], context)
      {:reply, :ok, put_in(state.pending_admission_monitors[context.task], monitor)}
    else
      {:reply, {:error, if(state.draining?, do: :owner_drained, else: :stale_owner)}, state}
    end
  end

  def handle_call({:local_drain_status, %{at: at, now_ms: clock} = deadline}, from, state) when is_integer(at) and is_function(clock, 0) do
    state = register_drain_observer(state, from, Map.get(deadline, :observer_ref))
    deadline = Map.delete(deadline, :observer_ref)
    deadline = if state.compact_activity_deadline && state.compact_activity_deadline.at <= at, do: state.compact_activity_deadline, else: deadline
    handle_call(:owner_status, from, %{state | compact_activity_deadline: deadline})
  end

  def handle_call(:owner_status, _from, state) do
    state = refresh_compact_delivery(state)

    {:reply,
     {:ok,
      %{
        codex_session_id: state.codex_session_id,
        owner_lease_token: state.owner_lease_token,
        owner_instance_id: state.owner_instance_id,
        upstream_alive?: Process.alive?(state.upstream_pid),
        draining?: state.draining?,
        compact_delivery_status: if(state.compact_delivery, do: state.compact_delivery.status, else: nil),
        active_turn?:
          DownstreamState.active_turn?(state) or
            not is_nil(state.compaction_retry_submit_hold) or
            (state.draining? and pending_owner_finalization?(state))
      }}, state}
  end

  def handle_call({:touch_replay_liveness, reference}, _from, state) do
    case state.suspended_replay do
      %{provisional_status: :started, consume_binding: ^reference} ->
        case CodexPooler.Accounting.touch_request_replay_liveness(reference) do
          {:ok, _entitlement} -> {:reply, :ok, state}
          {:error, _reason} -> {:reply, {:error, :owner_unavailable}, state}
        end

      _state ->
        {:reply, {:error, :owner_unavailable}, state}
    end
  end

  # A turn whose terminal the owner forwarded is over for the client, and only
  # its settlement, which the downstream's task runs, is left (findings#287).
  # The drain then waits for that settlement before the owner stops: stopping
  # at once interrupted the request the client had completed
  # (`failed/owner_drained`, its usage lost) and put an error frame after its
  # terminal. Once the turn settled the owner stops without an `owner_drained`
  # to its downstream, which learns of the exit from its monitor. The wait ends
  # inside the drain call's budget: a settlement still pending then is cut as
  # it always was (`drain_now/2`), so the recovery guarantee stays.
  def handle_call(:drain, from, state), do: drain(from, state)

  def handle_call(
        {:attach_downstream, _pid, _correlation_id, _opts},
        _from,
        %{draining?: true} = state
      ) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:preflight_reconnect, _downstream, _semantic_turn_key, _control_ref},
        _from,
        %{draining?: true} = state
      ) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:preflight_reconnect, downstream, semantic_turn_key, control_ref},
        _from,
        state
      ) do
    case preflight_reconnect_now(state, downstream, semantic_turn_key, control_ref) do
      {:reply, reply, next_state} -> {:reply, reply, next_state}
    end
  end

  def handle_call({:cancel_reconnect, downstream, control_ref}, _from, state) do
    {:reply, :ok, cancel_pending_handoff_by_ref(state, downstream, control_ref)}
  end

  def handle_call({:reconnect_control_v2, control}, _from, state) do
    case apply_reconnect_control_v2(state, control) do
      {:ok, result, next_state} -> {:reply, flatten_v2_result(result), next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_reserve_receipt, proof}, _from, state) do
    with :ok <- validate_reserve_receipt_proof(proof),
         true <- proof.owner_lease_token == state.owner_lease_token,
         true <- proof.owner_process_generation == state.process_generation,
         %{
           provisional_status: :consume_reserved,
           reserve_receipt_digest: digest,
           reserve_receipt_used?: false,
           owner_process_generation: generation,
           downstream: %{epoch: epoch},
           lifecycle: lifecycle
         } = replay <- state.suspended_replay,
         true <- generation == proof.owner_process_generation,
         true <- epoch == proof.downstream_epoch,
         true <- reserve_lifecycle_matches?(lifecycle, proof),
         true <- secure_digest_match?(digest, proof.reserve_receipt_digest) do
      consume_fence = make_ref()
      consume_monitor = Process.monitor(proof.consumer_pid)

      replay = %{
        replay
        | reserve_receipt_used?: true,
          consume_fence: consume_fence,
          consume_pid: proof.consumer_pid,
          consume_monitor: consume_monitor
      }

      {:reply, {:ok, consume_fence}, %{state | suspended_replay: replay}}
    else
      _invalid -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:release_consumed_reserve_receipt, proof, consume_fence}, _from, state) do
    case validate_consumed_reserve_receipt_now(state, proof, consume_fence) do
      :ok ->
        {:reply, :ok, clear_consume_reservation(state)}

      {:error, :invalid} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:validate_consumed_reserve_receipt, proof, consume_fence}, _from, state) do
    {:reply, validate_consumed_reserve_receipt_now(state, proof, consume_fence), state}
  end

  def handle_call({:begin_suspend, descriptor}, _from, state) do
    case cas_active_status(state, descriptor, :suspending) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_active_downstream_loss, downstream}, _from, state) do
    case mark_active_downstream_lost(state, downstream) do
      {:ok, next_state} -> {:reply, :reattachable, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:prepare_next_replay_descriptor, %{pid: pid, epoch: epoch, correlation_id: correlation_id}, _descriptor},
        _from,
        %{closed_downstream: %{pid: pid, epoch: epoch, correlation_id: correlation_id}} = state
      ),
      do: {:reply, {:error, :client_disconnected}, state}

  def handle_call({:prepare_next_replay_descriptor, downstream, descriptor}, _from, state) do
    if DownstreamState.downstream_status(state.downstream, downstream) == :active and
         valid_next_replay_descriptor?(descriptor) do
      next = Map.put(descriptor, :downstream, Map.take(downstream, @restore_downstream_keys))
      {:reply, :ok, %{state | next_turn_descriptor: next}}
    else
      {:reply, {:error, :owner_busy}, state}
    end
  end

  def handle_call({:admission_control_v1, control}, _from, %{draining?: true} = state) do
    if WebsocketOwnerAdmissionControlV1.validate(control) == :ok do
      {:reply, {:error, :owner_drained}, drain_native_compaction_admission(state, :owner_drained)}
    else
      {:reply, {:error, :owner_unavailable}, drain_native_compaction_admission(state, :invalid_input)}
    end
  end

  # A snapshot that ends an admission past its bound answers `expired`, the
  # reason it ended, not the empty admission it leaves: the socket logged the
  # reservation it refused `cause=no_admission` (findings#270 row 270-334).
  # The answer is in the refusal vocabulary a remote caller passes through,
  # and a socket of an earlier release reads any error of the snapshot as a
  # refusal.
  def handle_call({:admission_control_v1, control}, _from, state) do
    unexpired = expire_stale_admission(state)

    case apply_admission_control(unexpired, control) do
      {:ok, nil, next_state} ->
        if expired_by_snapshot?(control, state, unexpired),
          do: {:reply, {:error, :expired}, next_state},
          else: {:reply, {:ok, nil}, next_state}

      {:ok, reply, next_state} ->
        {:reply, {:ok, reply}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:authorize_generation_send_v1, request, %ProviderCreditsAdmission.Receipt{} = receipt}, {caller, _tag}, %{upstream_pid: caller, active_turn: active} = state) when not is_nil(active) do
    if receipt.context == request.provider_credits_context and
         receipt.context.request_id == active.admission_request_id and
         receipt.context.attempt_id == active.admission_attempt_id do
      case authorize_owner_generation_now(state, request) do
        {:ok, authorized, next_state} -> {:reply, {:ok, authorized}, next_state}
        {:error, _reason, next_state} -> {:reply, {:error, :owner_unavailable}, next_state}
      end
    else
      {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:authorize_generation_send_v1, _request, _receipt}, _from, state), do: {:reply, {:error, :owner_unavailable}, state}

  def handle_call(
        {:issue_forwarded_send_witness_v1, downstream, capability, now_ms},
        _from,
        state
      ) do
    case issue_forwarded_send_witness_now(state, downstream, capability, now_ms) do
      {:ok, witness, next_state} -> {:reply, {:ok, witness}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call(
        {:redeem_forwarded_send_v1, witness, live_lifecycle_snapshot, serving_mode},
        _from,
        state
      ) do
    case redeem_forwarded_send_now(state, witness, live_lifecycle_snapshot, serving_mode) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  # A bridged HTTP turn must never steal another turn's downstream. Each bridge
  # turn attaches a fresh downstream and detaches when done, so an already
  # attached downstream (or an active turn) means another bridge turn owns the
  # session: reject the attach atomically so the caller falls back to plain HTTP
  # instead of redirecting the running turn's frames.
  def handle_call({:attach_downstream, pid, correlation_id, opts}, _from, state) do
    cond do
      abandoned_attach?(state, pid, correlation_id) ->
        {:reply, {:error, :stale_downstream}, state}

      # Provider-created successors belong to the original socket's lane and
      # cannot inherit a replacement downstream through the ordinary attach.
      ordinary_attach_busy?(state, opts) ->
        {:reply, {:error, :owner_busy}, state}

      replay_active?(state, state.downstream) or native_collection_active?(state) ->
        epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

        candidate = %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          active_turn_reconnect?: true
        }

        {:reply, {:ok, candidate}, state}

      suspended_replay_attachable?(state.suspended_replay) ->
        epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

        candidate = %{
          pid: pid,
          epoch: epoch,
          correlation_id: correlation_id,
          active_turn_reconnect?: true
        }

        {:reply, {:ok, candidate}, state}

      true ->
        attach_downstream_now(state, pid, correlation_id)
    end
  end

  def handle_call({:restore_downstream, _downstream}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:restore_downstream, downstream},
        _from,
        %{downstream: nil, active_turn: nil} = state
      ) do
    attach_downstream_now(state, downstream)
  end

  def handle_call({:restore_downstream, downstream}, _from, state) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active -> {:reply, {:ok, state.downstream}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach_downstream, pid, epoch, correlation_id}, from, state) do
    requested_downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id}

    case detach_downstream_status(state, requested_downstream) do
      :active ->
        cond do
          replay_active?(state, requested_downstream) ->
            detach_replay_downstream(state, requested_downstream, from)

          terminal_forwarded_to?(state, requested_downstream) ->
            detach_after_forwarded_terminal(state)

          true ->
            detach_active_downstream(state, requested_downstream)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:capture_downstream_idle_timeout, downstream, _client_activity}, {caller, _tag}, state) do
    result =
      with %{pid: ^caller} <- downstream,
           :active <- DownstreamState.downstream_status(state.downstream, downstream),
           false <- terminal_forwarded_to?(state, downstream),
           %{cleanup_witness: %OwnerCleanup{} = witness, downstream: active_downstream} <- state.active_turn,
           :active <- DownstreamState.downstream_status(active_downstream, downstream) do
        {{:ok, :ok}, witness}
      else
        _stale -> {:ok, :stale}
      end

    {:reply, result, state}
  end

  def handle_call({:detach_previsible_downstream, pid, epoch, correlation_id}, _from, state) do
    requested_downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id}

    with :active <- DownstreamState.downstream_status(state.downstream, requested_downstream),
         true <- replay_active?(state, requested_downstream),
         {:suspended, suspended} <- suspend_replay_downstream(state) do
      {:reply, :suspended, DownstreamState.demonitor_downstream(suspended)}
    else
      # A terminal that already won, or a suspension that failed and restored
      # the descriptor, keeps the attached downstream: the socket's ordinary
      # detach settles it after the drain, exactly as before.
      {outcome, unchanged} when outcome in [:terminal_won, :failed] ->
        {:reply, :not_previsible, unchanged}

      _not_replay_active ->
        if idle_closing_downstream?(state, requested_downstream),
          do: detach_idle_closing_downstream(state, requested_downstream),
          else: {:reply, :not_previsible, mark_closing_downstream(state, requested_downstream)}
    end
  end

  def handle_call(
        {:cancel_downstream, pid, epoch, correlation_id, owner_turn_id, reason},
        _from,
        state
      ) do
    downstream = %{
      pid: pid,
      epoch: epoch,
      correlation_id: correlation_id,
      owner_turn_id: owner_turn_id
    }

    case DownstreamState.cancellation_status(state, downstream) do
      :active ->
        state =
          state
          |> clear_compaction_retry_submit_hold()
          |> DownstreamState.demonitor_downstream()
          |> DownstreamState.schedule_idle_shutdown()
          |> DownstreamState.cancel_active_turn_downstream(downstream, reason)
          |> Map.put(:downstream, nil)

        state =
          state
          |> clear_native_compaction_admission(:downstream_cancelled)
          |> settle_cancelled_active_turn(reason)

        reply_or_retire(state, :ok)

      {:error, status_reason} ->
        {:reply, {:error, status_reason}, state}
    end
  end

  # The turn's output goes nowhere from here on (its downstream is cleared on
  # the turn only), its task is stopped and settles through the ordinary
  # cancelled-turn path, and the owner's downstream and its monitor stay.
  def handle_call({:abandon_turn, pid, epoch, correlation_id, owner_turn_id}, _from, state) do
    downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id, owner_turn_id: owner_turn_id}

    case DownstreamState.cancellation_status(state, downstream) do
      :active ->
        state =
          state
          |> DownstreamState.cancel_active_turn_downstream(downstream, :owner_forward_timeout)
          |> clear_native_compaction_admission(:downstream_cancelled)
          |> maybe_settle_cancelled_without_pending_handoff(:owner_forward_timeout)

        reply_or_retire(state, :ok)

      {:error, reason} ->
        {:reply, {:error, reason}, remember_abandoned_submission(state, downstream)}
    end
  end

  # The inherited turn is cancelled as the socket's close cancels it (its task
  # stopped, `client_disconnected`, settled through its submitter); unlike the
  # close, the downstream and its monitor stay, so the socket's next request
  # meets an owner with nothing running.
  def handle_call({:take_over_inherited_turn, pid, epoch, correlation_id}, _from, state) do
    downstream = %{pid: pid, epoch: epoch, correlation_id: correlation_id}

    case inherited_turn(state, downstream) do
      {:ok, semantic_turn_digest} ->
        state =
          state
          |> DownstreamState.cancel_active_turn_downstream(downstream, :client_disconnected)
          |> clear_native_compaction_admission(:downstream_cancelled)
          |> maybe_settle_cancelled_without_pending_handoff(:client_disconnected)

        :ok = Logger.inherited_turn_taken_over(state, epoch)

        reply_or_retire(state, {:ok, %{semantic_turn_digest: semantic_turn_digest}})

      {:error, reason} ->
        case closed_socket_collection(state, downstream) do
          {:ok, bound, semantic_turn_digest} -> take_over_closed_socket_collection(state, bound, downstream, semantic_turn_digest)
          :error -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:interrupt_turn, pid, epoch, correlation_id, interrupt}, _from, state) do
    case state.active_turn do
      %{downstream: %{pid: ^pid, epoch: ^epoch, correlation_id: ^correlation_id}, collect?: false, upstream_pid: upstream_pid} when is_pid(upstream_pid) ->
        :ok = UpstreamWebsocketSession.interrupt(upstream_pid, interrupt)

      %{downstream: %{pid: ^pid, epoch: ^epoch, correlation_id: ^correlation_id}} ->
        :ok = ResponseInterrupt.log(:owner_turn_not_relay, :owner)

      %{} ->
        :ok = ResponseInterrupt.log(:owner_not_downstream, :owner)

      nil ->
        :ok = ResponseInterrupt.log(:no_running_turn, :owner)
    end

    {:reply, :ok, state}
  end

  def handle_call({:steer_turn, pid, epoch, correlation_id, steer}, _from, state) do
    requested = %{pid: pid, epoch: epoch, correlation_id: correlation_id}

    cond do
      DownstreamState.downstream_status(state.downstream, requested) != :active -> ResponseSteer.log(:owner_not_downstream, :owner)
      is_map(state.active_turn) and state.active_turn.collect? -> ResponseSteer.log(:owner_turn_not_relay, :owner)
      true -> UpstreamWebsocketSession.steer(state.upstream_pid, steer)
    end

    {:reply, :ok, state}
  end

  def handle_call({:complete_steering_original, request_id, result}, _from, %{active_turn: %{admission_request_id: request_id}} = state) do
    {reply, state} = retain_ordinary_success_result({:ok, result}, state)
    state = settle_active_turn(state, reply)
    state = apply_native_steering_owner_success(state, Map.get(result, :native_response_steering_finalized))
    {:reply, :ok, state}
  end

  def handle_call({:complete_steering_original, _request_id, _result}, _from, state), do: {:reply, :ok, state}

  def handle_call({:begin_steering_successor, lane, socket, identity, turn_id}, _from, %{native_response_steering: lane, downstream: %{pid: socket} = downstream, active_turn: nil, draining?: false} = state) do
    cleanup = OwnerCleanup.capture(state, identity, downstream, identity.replay_generation)

    case begin_owner_receipt_producer(state, cleanup) do
      {:ok, producer} ->
        # Provider-created generations have no client replay payload or replay
        # entitlement. The tagged descriptor keeps identity/lease cleanup but is
        # deliberately excluded from inherited-turn and replay controls.
        descriptor = Map.merge(identity, %{kind: :native_response_steering, codex_turn_id: turn_id, downstream_status: :attached, visible_output?: false})
        descriptor = Map.merge(descriptor, %{semantic_turn_key: nil, semantic_turn_digest: nil, replay_claim_digest: nil, authorization_snapshot: nil, model_id: nil, endpoint: "/backend-api/codex/responses"})
        active = %{ref: make_ref(), writer_capability: make_ref(), task_pid: lane, task_ref: nil, native_steering_monitor: Process.monitor(lane), submitter_monitor: nil, reply_to: nil, downstream: downstream, terminal_forwarded?: false, pending_result: nil, terminal_delivery_timeout: nil, terminal_delivery_timer_ref: nil, output_commit_probe: nil, collect?: false, submission_observed?: false, descriptor: descriptor, cleanup_witness: cleanup, visible_output?: false, upstream_pid: state.upstream_pid, admission_phase: nil, admission_request_id: identity.request_id, admission_attempt_id: identity.attempt_id, first_compact_request_identity: nil, ordinary_request_identity: nil, task_settled?: false, submitter_exited?: false, reply_sent?: false, native_response_steering: lane}
        active = Map.merge(active, %{receipt_producer: producer, receipt_registry: state.receipt_registry, receipt_settlement: nil})
        state.callbacks.downstream_sender.(socket, {:native_response_steering_open, lane, identity})
        {:reply, :ok, %{state | active_turn: active}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin_steering_successor, _lane, _socket, _identity, _turn}, _from, state), do: {:reply, {:error, :owner_busy}, state}

  def handle_call({:relay_steering_frame, lane, identity, data, discriminator}, _from, %{active_turn: %{native_response_steering: lane, descriptor: descriptor, downstream: downstream}} = state) do
    if Map.take(descriptor, [:request_id, :attempt_id, :replay_generation]) == identity and DownstreamState.downstream_status(state.downstream, downstream) == :active do
      result = state.callbacks.downstream_sender.(downstream.pid, {:native_response_steering_frame, lane, identity, data})
      state = if TerminalDiscriminator.terminal?(discriminator), do: put_in(state.active_turn.terminal_forwarded?, true), else: state
      {:reply, result, state}
    else
      {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:relay_steering_frame, _lane, _identity, _data, _discriminator}, _from, state), do: {:reply, {:error, :stale_generation}, state}

  def handle_call({:complete_steering_successor, lane, identity, result}, _from, %{active_turn: %{native_response_steering: lane, descriptor: descriptor}} = state) do
    if Map.take(descriptor, [:request_id, :attempt_id, :replay_generation]) == identity do
      if downstream = state.active_turn.downstream, do: state.callbacks.downstream_sender.(downstream.pid, {:native_response_steering_done, lane, identity, result})
      state = %{state | termination_cleanup_witness: state.active_turn.cleanup_witness}
      state = %{state | forwarded_terminal_request_id: forwarded_terminal_request_id(state)}
      {:reply, :ok, state |> clear_active_turn() |> apply_native_steering_owner_success(result)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:complete_steering_successor, _lane, _identity, _result}, _from, state), do: {:reply, :ok, state}

  def handle_call({:submit_upstream, _downstream, _payload}, _from, %{draining?: true} = state) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call(
        {:submit_upstream, _downstream, _payload, _submission_notification?},
        _from,
        %{draining?: true} = state
      ) do
    {:reply, {:error, :owner_drained}, state}
  end

  def handle_call({:submit_upstream, downstream, upstream_payload}, from, state) do
    accept_or_consume_upstream_submission(state, from, downstream, upstream_payload, false)
  end

  def handle_call(
        {:submit_upstream, downstream, upstream_payload, submission_notification?},
        from,
        state
      )
      when is_boolean(submission_notification?) do
    accept_or_consume_upstream_submission(
      state,
      from,
      downstream,
      upstream_payload,
      submission_notification?
    )
  end

  def handle_call({:writer_lifecycle_barrier, ref}, _from, %{active_turn: %{ref: ref}} = state) do
    result = Map.get(state.active_turn, :lifecycle_authorization_result, :ok)
    {:reply, result, state}
  end

  def handle_call({:writer_lifecycle_barrier, _ref}, _from, state), do: {:reply, {:error, :stale_generation}, state}

  def handle_call({:push_downstream, payload}, _from, state) do
    case send_downstream(state, state.downstream, payload) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_upstream_submission(
         state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    submitted_payload = upstream_payload
    state = if is_struct(upstream_payload, UpstreamWebsocketSession.Request) and is_pid(upstream_payload.native_response_steering), do: %{state | native_response_steering: upstream_payload.native_response_steering}, else: state

    with {:ok, active_turn_downstream} <- active_turn_downstream(state.downstream, downstream),
         {:ok, upstream_payload, state, admission_phase} <-
           prepare_owner_admission_submission(state, active_turn_downstream, upstream_payload) do
      # The submission as it arrived: the admission it carries, validated just
      # above, still names its turn (`admission_turn_descriptor/1`).
      {descriptor, state} =
        take_next_turn_descriptor(state, active_turn_downstream, submitted_payload)

      cleanup_witness =
        OwnerCleanup.capture(
          state,
          if(is_struct(upstream_payload), do: Map.from_struct(upstream_payload), else: %{}),
          active_turn_downstream,
          cleanup_replay_generation(upstream_payload, descriptor)
        )

      case begin_owner_receipt_producer(state, cleanup_witness) do
        {:ok, receipt_producer} -> install_upstream_submission(state, from, active_turn_downstream, upstream_payload, descriptor, {cleanup_witness, receipt_producer}, admission_phase, submission_notification?)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp install_upstream_submission(state, from, active_turn_downstream, upstream_payload, descriptor, {cleanup_witness, receipt_producer}, admission_phase, submission_notification?) do
    ref = make_ref()
    writer_capability = make_ref()
    {submitter_pid, _tag} = from
    task = start_upstream_task(state, ref, upstream_payload, descriptor, writer_capability)

    if cleanup_witness do
      send(active_turn_downstream.pid, {
        :websocket_owner_cleanup_witness,
        active_turn_downstream.correlation_id,
        active_turn_downstream.epoch,
        Map.get(active_turn_downstream, :owner_turn_id),
        cleanup_witness
      })
    end

    active_turn = %{
      ref: ref,
      writer_capability: writer_capability,
      compaction_pending_context: Map.get(state.pending_admissions, Map.get(active_turn_downstream, :owner_turn_id)),
      compaction_pending_sequence: 0,
      compaction_pending_probe: nil,
      task_pid: task.pid,
      task_ref: task.ref,
      submitter_monitor: Process.monitor(submitter_pid),
      reply_to: from,
      downstream: active_turn_downstream,
      terminal_forwarded?: false,
      pending_result: nil,
      terminal_delivery_timeout: nil,
      terminal_delivery_timer_ref: nil,
      output_commit_probe: nil,
      collect?: collect_request?(upstream_payload),
      submission_observed?: submission_notification?,
      descriptor: descriptor,
      cleanup_witness: cleanup_witness,
      receipt_producer: receipt_producer,
      receipt_registry: state.receipt_registry,
      receipt_settlement: nil,
      visible_output?: false,
      upstream_pid: state.upstream_pid,
      admission_phase: admission_phase,
      admission_request_id: admission_request_id(upstream_payload),
      admission_attempt_id: admission_attempt_id(upstream_payload),
      first_compact_request_identity: NativeCompactionAdmission.FirstCompactResult.request_identity(upstream_payload),
      ordinary_request_identity: ordinary_request_identity(upstream_payload),
      task_settled?: false,
      submitter_exited?: false,
      reply_sent?: false
    }

    if context = Map.get(state.pending_admissions, Map.get(active_turn_downstream, :owner_turn_id)),
      do: ActivityRegistry.handoff_direct_cleanup(context)

    state = forget_pending_admission(state, Map.get(active_turn_downstream, :owner_turn_id))

    {:noreply,
     %{
       state
       | active_turn: active_turn,
         first_compact_result: nil,
         ordinary_success_result: nil
     }}
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_replay_binding: %NativeReplayAdmission.Binding{} = binding,
           native_replay_proof: %RuntimeAdmissionProof{
             kind: :native_replay
           },
           provisional_token: token,
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         } = request
       )
       when is_binary(token) and byte_size(token) == 32 do
    with %{
           provisional_status: :committed_not_started,
           consume_binding: consume,
           provisional_token: expected_token,
           owner_process_generation: generation
         }
         when generation == binding.owner_process_generation <- state.suspended_replay,
         true <- secure_digest_match?(expected_token, token),
         true <- consume == NativeReplayAdmission.consume_binding(binding) do
      {:ok, %{request | forwarded_owner: self()}, state, :native_replay}
    else
      _invalid -> {:error, :owner_unavailable, state}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: %NativeCompactionAdmission.Capability{} = capability,
           forwarded_owner_send_handoff: nil
         } = request
       ) do
    with :ok <- require_admission_downstream(state, downstream),
         true <- capability.binding == state.native_compaction_admission.binding do
      request = %{request | native_compaction_capability: nil, expected_connection_lifecycle: nil, forwarded_owner_capability: capability, forwarded_owner: self()}
      {:ok, request, state, capability.phase}
    else
      _rejected -> {:error, :native_compaction_capability_rejected, state}
    end
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         }
       )
       when not is_nil(expected_lifecycle) do
    {:error, :native_compaction_capability_rejected, clear_native_compaction_admission(state, :capability_rejected)}
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         } = request
       ) do
    {:ok, request, state, nil}
  end

  defp prepare_owner_admission_submission(
         state,
         _downstream,
         %UpstreamWebsocketSession.Request{}
       ) do
    {:error, :native_compaction_capability_rejected, clear_native_compaction_admission(state, :capability_rejected)}
  end

  defp prepare_owner_admission_submission(state, _downstream, upstream_payload),
    do: {:ok, upstream_payload, state, nil}

  defp authorize_owner_generation_now(state, %UpstreamWebsocketSession.Request{forwarded_owner_capability: %NativeCompactionAdmission.Capability{} = capability} = request) do
    case issue_forwarded_send_witness_now(state, state.active_turn.downstream, capability, System.system_time(:millisecond)) do
      {:ok, witness, next_state} ->
        handoff = ForwardedOwnerRequestHandoff.new(self(), witness)
        {:ok, %{request | forwarded_owner_send_handoff: handoff, forwarded_owner_capability: nil, forwarded_owner: nil}, next_state}

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp authorize_owner_generation_now(state, %UpstreamWebsocketSession.Request{native_replay_binding: %NativeReplayAdmission.Binding{} = binding} = request) do
    case mark_owner_replay_started(state, request, NativeReplayAdmission.consume_binding(binding)) do
      {:ok, authorized, next_state, :native_replay} -> {:ok, %{authorized | forwarded_owner: nil}, next_state}
      {:error, reason, next_state} -> {:error, reason, next_state}
    end
  end

  defp authorize_owner_generation_now(state, request), do: {:ok, %{request | forwarded_owner: nil}, state}

  defp mark_owner_replay_started(state, request, consume) do
    case CodexPooler.Accounting.mark_request_replay_started(consume) do
      {:ok, _entitlement} ->
        suspended = %{state.suspended_replay | provisional_status: :started}
        next_state = %{state | suspended_replay: suspended}
        {:ok, request, next_state, :native_replay}

      {:error, _reason} ->
        _result = CodexPooler.Accounting.compensate_request_replay_no_send(consume)
        {:error, :owner_unavailable, state}
    end
  end

  # An abandon can reach the owner before the submission it abandons: the
  # owner-node process that carries a remote submission may still be before
  # its owner call (recovering the owner, restoring the downstream) when the
  # proxy's budget expires, and the abandon then finds no turn to stop
  # (findings#206 row 206-307). It leaves the exact per-call downstream it
  # named here, and that submission is refused before any dispatch when it
  # arrives. The turn id is the proxy's response task, so a later turn, even on
  # the same socket, never matches. The list is bounded: an abandoned
  # submission that never arrives is forgotten after the newer ones.
  @abandoned_submission_limit 16

  defp remember_abandoned_submission(state, downstream) do
    abandoned = [abandoned_submission_key(downstream) | state.abandoned_submissions]
    %{state | abandoned_submissions: Enum.take(Enum.uniq(abandoned), @abandoned_submission_limit)}
  end

  defp abandoned_submission_key(%{pid: pid, epoch: epoch, correlation_id: correlation_id, owner_turn_id: owner_turn_id})
       when is_pid(owner_turn_id),
       do: {pid, epoch, correlation_id, owner_turn_id}

  defp abandoned_submission_key(_downstream), do: nil

  defp accept_or_consume_upstream_submission(state, from, downstream, upstream_payload, submission_notification?) do
    key = abandoned_submission_key(downstream)

    if is_tuple(key) and key in state.abandoned_submissions do
      {:reply, {:error, :stale_downstream}, %{state | abandoned_submissions: List.delete(state.abandoned_submissions, key)}}
    else
      accept_or_consume_live_submission(state, from, downstream, upstream_payload, submission_notification?)
    end
  end

  defp accept_or_consume_live_submission(%{active_turn: active_turn} = state, _from, downstream, _payload, _notification?) when not is_nil(active_turn),
    do: {:reply, DownstreamState.stale_or_busy(state.downstream, downstream), state}

  defp accept_or_consume_live_submission(
         %{pending_handoff: %{status: :ready} = pending} = state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    descriptor = pending_submission_descriptor(state, pending, downstream, upstream_payload)

    if handoff_downstream?(pending, downstream) and
         descriptor == %{kind: :native, semantic_turn_key: pending.semantic_turn_key} do
      state =
        state
        |> put_next_turn_descriptor(downstream, pending.semantic_turn_key)
        |> clear_pending_handoff()

      accept_upstream_submission(
        state,
        from,
        downstream,
        upstream_payload,
        submission_notification?
      )
    else
      {:reply, {:error, :owner_busy}, state}
    end
  end

  defp accept_or_consume_live_submission(
         state,
         from,
         downstream,
         upstream_payload,
         submission_notification?
       ) do
    accept_upstream_submission(
      state,
      from,
      downstream,
      upstream_payload,
      submission_notification?
    )
  end

  defp preflight_reconnect_now(
         %{active_turn: nil, pending_handoff: nil} = state,
         downstream,
         semantic_turn_key,
         _ref
       ) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active ->
        {:reply, {:ok, :dispatch}, put_next_turn_descriptor(state, downstream, semantic_turn_key)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp preflight_reconnect_now(
         %{pending_handoff: pending} = state,
         downstream,
         semantic_turn_key,
         _control_ref
       )
       when is_map(pending) do
    cond do
      not handoff_downstream?(pending, downstream) ->
        {:reply, {:error, :owner_busy}, state}

      pending.semantic_turn_key == semantic_turn_key ->
        {:reply, {:ok, :duplicate_replacement, pending.control_ref}, state}

      true ->
        {:reply, {:error, :owner_busy}, state}
    end
  end

  defp preflight_reconnect_now(
         %{active_turn: active_turn} = state,
         downstream,
         semantic_turn_key,
         control_ref
       )
       when is_map(active_turn) do
    descriptor = Map.get(active_turn, :descriptor, :unknown)
    cancelled? = Map.has_key?(active_turn, :canceled_result)

    case descriptor do
      %{kind: :native, semantic_turn_key: ^semantic_turn_key} when not cancelled? ->
        {:reply, {:ok, :same_turn_replay}, state}

      %{kind: :native, semantic_turn_key: active_key}
      when cancelled? and active_key != semantic_turn_key ->
        begin_pending_handoff(state, downstream, semantic_turn_key, control_ref)

      _descriptor ->
        {:reply, {:error, :owner_busy}, state}
    end
  end

  defp begin_pending_handoff(state, downstream, semantic_turn_key, control_ref) do
    case DownstreamState.downstream_status(state.downstream, downstream) do
      :active ->
        soft_token = make_ref()
        absolute_token = make_ref()

        pending = %{
          pid: downstream.pid,
          epoch: downstream.epoch,
          correlation_id: downstream.correlation_id,
          control_ref: control_ref,
          semantic_turn_key: semantic_turn_key,
          owner_turn_id: active_turn_owner_turn_id(state.active_turn),
          status: :waiting,
          soft_token: soft_token,
          soft_timer_ref:
            Process.send_after(
              self(),
              {:websocket_owner_handoff_soft_timeout, control_ref, soft_token},
              state.handoff_soft_timeout_ms
            ),
          absolute_token: absolute_token,
          absolute_timer_ref:
            Process.send_after(
              self(),
              {:websocket_owner_handoff_absolute_timeout, control_ref, absolute_token},
              state.handoff_absolute_timeout_ms
            )
        }

        state = %{state | pending_handoff: pending}
        state = put_next_turn_descriptor(state, downstream, semantic_turn_key)
        {:reply, {:ok, :replacement_handoff, control_ref}, maybe_ready_pending_handoff(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast({:finish_pre_attempt_admission_v1, task, ref}, state) do
    state =
      case Map.get(state.pending_admissions, task) do
        %{ref: ^ref} -> forget_pending_admission(state, task)
        _ -> state
      end

    {:noreply, state}
  end

  # The abandoned attach is the attached downstream: it is lost the way a
  # downstream that exits is, through the same monitor path, and its monitor
  # is dropped first so the exit of the socket that gave up is not taken a
  # second time. The attach was taken already, so its record has nothing left
  # to refuse.
  def handle_cast({:abandon_attach, pid, correlation_id}, %{downstream: %{pid: pid, correlation_id: correlation_id}, downstream_monitor: monitor} = state)
      when is_reference(monitor) do
    AbandonedSubmissions.consume(AbandonedSubmissions.attach_key(state.codex_session_id, state.downstream))
    Process.demonitor(monitor, [:flush])
    handle_info({:DOWN, monitor, :process, pid, :abandoned_attach}, state)
  end

  def handle_cast({:abandon_attach, _pid, _correlation_id}, state), do: {:noreply, state}

  def handle_cast({:cancel_drain_observation, observer, ref}, state) do
    {:noreply, remove_drain_observer(state, observer, ref)}
  end

  def handle_cast(:begin_drain, state), do: {:noreply, begin_drain_state(state)}

  @impl GenServer
  def handle_info({:drain_settlement_poll, ref}, %{drain_settlement: %{ref: ref} = settlement} = state) do
    state = refresh_compact_delivery(state)

    case forwarded_turn_settlement(state) do
      :settled ->
        finish_drain_settlement(state, :settled)

      :pending ->
        if System.monotonic_time(:millisecond) < settlement.deadline_ms do
          Process.send_after(self(), {:drain_settlement_poll, ref}, @drain_settlement_poll_ms)
          {:noreply, state}
        else
          finish_drain_settlement(state, :cut)
        end

      :none ->
        finish_drain_settlement(state, :cut)
    end
  end

  def handle_info({:drain_settlement_poll, _stale_ref}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{compact_delivery_read: %{ref: ref, witness: witness, deadline: deadline}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | compact_delivery_read: nil}
    state = if accept_compact_delivery_result?(state, witness, deadline), do: put_in(state.compact_delivery.status, result), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{compact_delivery_read: %{ref: ref}} = state),
    do: {:noreply, %{state | compact_delivery_read: nil}}

  def handle_info(
        {:compaction_retry_submit_hold_expired, ref},
        %{compaction_retry_submit_hold: %{token: %{ref: ref}}} = state
      ),
      do: {:noreply, clear_compaction_retry_submit_hold(state)}

  def handle_info(
        {:DOWN, monitor, :process, _requester, _reason},
        %{compaction_retry_submit_hold: %{monitor: monitor}} = state
      ),
      do: {:noreply, clear_compaction_retry_submit_hold(state)}

  def handle_info(
        {:websocket_owner_upstream_frame, ref, _payload},
        %{active_turn: %{ref: ref, collect?: true}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload},
        %{active_turn: %{ref: ref}} = state
      ) do
    handle_upstream_frame(state, payload, terminal_frame?(payload))
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, _payload, %TerminalDiscriminator{} = _discriminator},
        %{active_turn: %{ref: ref, collect?: true}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:websocket_owner_upstream_frame, ref, payload, %TerminalDiscriminator{} = discriminator},
        %{active_turn: %{ref: ref}} = state
      ) do
    handle_upstream_frame(state, payload, TerminalDiscriminator.terminal?(discriminator))
  end

  # The private turn ref binds this frame to the writer this owner started.
  # Database authorization runs in that writer, never in the owner mailbox.
  def handle_info(
        {:websocket_owner_authorized_frame, ref, capability, authority, payload, %TerminalDiscriminator{} = discriminator, visibility},
        %{active_turn: %{ref: ref, writer_capability: capability, descriptor: descriptor}} = state
      ) do
    expected = if is_map(descriptor), do: Map.take(descriptor, [:request_id, :attempt_id, :replay_generation]), else: %{}
    if authority == expected, do: relay_writer_authorized_frame(state, payload, discriminator, visibility), else: {:noreply, state}
  end

  def handle_info({:websocket_owner_authorized_frame, _ref, _capability, _authority, _payload, _discriminator, _visibility}, state), do: {:noreply, state}

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload, _discriminator}, state),
    do: {:noreply, state}

  def handle_info({:websocket_owner_upstream_frame, _ref, _payload}, state), do: {:noreply, state}

  def handle_info({:owner_compaction_pending, ref, capability, event}, %{active_turn: %{ref: ref, writer_capability: capability} = active} = state) do
    if pending_compaction_current?(state, event) and event.sequence > active.compaction_pending_sequence do
      context = active.compaction_pending_context
      source = {self(), active.downstream.correlation_id, active.downstream.epoch}
      send(context.parent, {:native_compaction_pending, context.task, context.ref, source, event})
      {:noreply, put_in(state.active_turn.compaction_pending_sequence, event.sequence)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:owner_compaction_pending, _ref, _capability, _event}, state), do: {:noreply, state}

  def handle_info({:owner_compaction_pending_probe, task, ref, source, event, challenge, caller}, state) when is_reference(challenge) and is_pid(caller) do
    with %{compaction_pending_context: %DirectCleanup{task: ^task, ref: ^ref, parent: ^caller}, downstream: downstream} = active <- state.active_turn,
         true <- source == {self(), downstream.correlation_id, downstream.epoch},
         true <- pending_compaction_current?(state, event),
         true <- event.sequence == active.compaction_pending_sequence do
      send(event.upstream_pid, {:compaction_pending_probe, self(), challenge, event.token, event.request_id, event.attempt_id, event.sequence})
      probe = %{challenge: challenge, caller: caller, event: event, started_at: System.monotonic_time(:millisecond)}
      {:noreply, put_in(state.active_turn.compaction_pending_probe, probe)}
    else
      _stale -> {:noreply, state}
    end
  end

  def handle_info({:compaction_pending_ack, challenge, token, request_id, attempt_id, sequence, remaining_ms} = ack, state) do
    with %{compaction_pending_probe: %{challenge: ^challenge, event: %{token: ^token, request_id: ^request_id, attempt_id: ^attempt_id, sequence: ^sequence} = event, caller: caller, started_at: started_at}} <- state.active_turn,
         true <- is_integer(remaining_ms) and remaining_ms > 0,
         true <- System.monotonic_time(:millisecond) - started_at < min(1_000, remaining_ms),
         true <- pending_compaction_current?(state, event) do
      send(caller, ack)
      {:noreply, put_in(state.active_turn.compaction_pending_probe, nil)}
    else
      _stale -> {:noreply, state}
    end
  end

  def handle_info({:websocket_owner_receipt_settled, turn_ref, ref, token, disposition}, %{active_turn: %{ref: turn_ref, receipt_settlement: %{ref: ref, token: token, monitor: monitor}}} = state) do
    Process.demonitor(monitor, [:flush])
    state |> complete_owner_receipt(disposition) |> continue_or_retire()
  end

  def handle_info({:websocket_owner_receipt_settled, _turn_ref, _ref, _token, _disposition}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{active_turn: %{receipt_settlement: %{monitor: monitor, pid: pid}}} = state) do
    # Registry independently observes this failure; it cannot become a committed receipt.
    state |> complete_owner_receipt(:failed) |> continue_or_retire()
  end

  def handle_info({ref, result}, %{active_turn: %{task_ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = put_in(state.active_turn.task_ref, nil)
    state = retain_cancelled_task_receipt(state, result)
    result = DownstreamState.effective_active_turn_result(state.active_turn, result)
    {result, state} = retain_first_compact_result(result, state)
    {result, state} = retain_ordinary_success_result(result, state)
    {result, state} = settle_owner_admission_transport(state, result)

    if Process.alive?(state.upstream_pid) do
      if is_map(state.pending_handoff) do
        state
        |> settle_predecessor_task(result)
        |> maybe_ready_pending_handoff()
        |> continue_or_retire()
      else
        state
        |> resolve_active_turn_result(result)
        |> continue_or_retire()
      end
    else
      retire_current_upstream(state, :owner_crashed)
    end
  end

  def handle_info(
        {:websocket_owner_output_commit_ack, _correlation_id, _epoch, _owner_turn_id, _active_turn_ref, _probe_ref, _committed?} = message,
        %{active_turn: %{output_commit_probe: probe}} = state
      )
      when is_map(probe) do
    case WebsocketOwnerContract.accept_output_commit_ack(
           message,
           probe.epoch,
           probe.correlation_id,
           probe.owner_turn_id,
           probe.active_turn_ref,
           probe.probe_ref
         ) do
      {:ok, committed?} ->
        state
        |> settle_output_commit_probe(committed?)
        |> continue_or_retire()

      _stale_or_invalid ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:websocket_owner_output_commit_timeout, active_turn_ref, probe_ref},
        %{
          active_turn: %{
            output_commit_probe: %{
              active_turn_ref: active_turn_ref,
              probe_ref: probe_ref
            }
          }
        } = state
      ) do
    state
    |> timeout_output_commit_probe()
    |> continue_or_retire()
  end

  def handle_info({:EXIT, upstream_pid, reason}, %{upstream_pid: upstream_pid} = state) do
    retire_current_upstream(clear_native_compaction_admission(state, :upstream_exited), reason)
  end

  # The successor's executor is the socket-node lane, not an owner-side Task.
  # Its own completion clears this monitor; only a DOWN for this exact active
  # generation can compensate a lane that cannot return that completion.
  def handle_info(
        {:DOWN, monitor, :process, lane, reason},
        %{active_turn: %{native_response_steering: lane, native_steering_monitor: monitor}} = state
      ) do
    state
    |> retire_lost_native_steering_lane(reason)
    |> continue_or_retire()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_turn: %{task_ref: ref}} = state) do
    if Process.alive?(state.upstream_pid) do
      result =
        DownstreamState.effective_active_turn_result(
          state.active_turn,
          {:error, owner_error(reason)}
        )

      if is_map(state.pending_handoff) do
        state
        |> put_in([Access.key(:active_turn), Access.key(:task_ref)], nil)
        |> settle_predecessor_task(result)
        |> maybe_ready_pending_handoff()
        |> continue_or_retire()
      else
        state
        |> settle_active_turn(result)
        |> continue_or_retire()
      end
    else
      retire_current_upstream(state, :owner_crashed)
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active_turn: %{submitter_monitor: ref} = active_turn} = state
      ) do
    if is_map(state.pending_handoff) do
      state
      |> put_in([Access.key(:active_turn), Access.key(:submitter_monitor)], nil)
      |> put_in([Access.key(:active_turn), Access.key(:submitter_exited?)], true)
      |> maybe_ready_pending_handoff()
      |> continue_or_retire()
    else
      DownstreamState.cancel_active_turn_task(active_turn)

      state
      |> clear_native_compaction_admission(:caller_exit)
      |> settle_active_turn({:error, :client_disconnected})
      |> continue_or_retire()
    end
  end

  def handle_info(
        {:websocket_owner_handoff_soft_timeout, control_ref, soft_token},
        %{
          pending_handoff: %{control_ref: control_ref, soft_token: soft_token, status: :waiting}
        } = state
      ) do
    pending = %{state.pending_handoff | soft_timer_ref: nil, soft_token: nil}
    # The predecessor's task goes first (findings#206 row 206-327). The upstream
    # session serves one call at a time and holds the task's request call until
    # its turn settles, so an invalidation sent while the task still ran waited
    # out the session's one-second call bound with this owner blocked, and ran
    # only after the task was gone anyway. The session ends a request whose
    # caller died at once, so after the task's exit the invalidation is served
    # right away.
    :ok = terminate_predecessor_task_and_await(state.active_turn)
    _result = invalidate_upstream(state)

    {:noreply,
     state
     |> clear_native_compaction_admission(:handoff_timeout)
     |> Map.put(:pending_handoff, pending)}
  end

  def handle_info(
        {:websocket_owner_handoff_absolute_timeout, control_ref, absolute_token},
        %{
          pending_handoff: %{
            control_ref: control_ref,
            absolute_token: absolute_token
          }
        } = state
      ) do
    state =
      state |> clear_native_compaction_admission(:handoff_timeout) |> fail_pending_handoff(:owner_forward_timeout)

    state = settle_predecessor_before_retire(state)
    {:stop, :normal, %{state | draining?: true}}
  end

  def handle_info(
        {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token},
        %{
          active_turn: %{
            ref: turn_ref,
            pending_result: pending_result,
            terminal_forwarded?: false,
            terminal_delivery_timeout: {turn_ref, timer_token}
          }
        } = state
      )
      when not is_nil(pending_result) do
    result =
      case invalidate_upstream(state) do
        :ok -> terminal_delivery_timeout_result()
        {:error, reason} -> {:error, reason}
      end

    state
    |> put_in([Access.key(:active_turn), :receipt_failure], receipt_failure(:upstream_websocket_terminal_delivery_timeout))
    |> settle_active_turn(result)
    |> continue_or_retire()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{downstream_monitor: ref} = state) do
    state =
      state
      |> clear_compaction_retry_submit_hold()
      |> handle_monitored_downstream_loss(reason)
      |> reconcile_disconnected_provisional()

    state =
      case state.active_turn do
        %{output_commit_probe: %{result: result}} ->
          settle_active_turn_without_downstream_delivery(state, result)

        %{pending_result: pending_result} when not is_nil(pending_result) ->
          settle_active_turn(state, pending_result)

        _active_turn ->
          state
      end

    state
    |> recheck_lease_after_unreachable_downstream(reason)
    |> continue_or_retire()
  end

  def handle_info(
        {:DOWN, ref, :process, consumer_pid, _reason},
        %{
          suspended_replay: %{
            provisional_status: :consume_reserved,
            reserve_receipt_used?: true,
            consume_pid: consumer_pid,
            consume_monitor: ref
          }
        } = state
      ) do
    state = clear_consume_reservation(state, demonitor?: false)
    suspended = state.suspended_replay

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        {:noreply, clear_terminal_reconciliation(state)}

      {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:ok, :consume_reserved, reconciled} ->
        {:noreply, retire_replay_state(%{state | suspended_replay: reconciled})}

      {:ok, status, reconciled} ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:error, _reason} ->
        {:noreply, schedule_replay_reconciliation(%{state | suspended_replay: suspended})}
    end
  end

  def handle_info(
        {:websocket_owner_replay_reconcile, token},
        %{
          suspended_replay: %{
            provisional_status: :consume_reserved,
            reconciliation_token: token
          }
        } = state
      ) do
    state = cancel_replay_reconciliation(state)
    suspended = state.suspended_replay

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        {:noreply, clear_terminal_reconciliation(state)}

      {:ok, :consume_reserved, reconciled} ->
        next_state =
          if Map.get(reconciled, :reserve_receipt_used?, false) do
            schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
          else
            retire_replay_state(%{state | suspended_replay: reconciled})
          end

        {:noreply, next_state}

      {:ok, status, reconciled} ->
        {:noreply, maybe_cancel_replay_reconciliation(state, status, reconciled)}

      {:error, _reason} ->
        {:noreply, schedule_replay_reconciliation(%{state | suspended_replay: suspended})}
    end
  end

  def handle_info({:websocket_owner_replay_reconcile, _token}, state), do: {:noreply, state}

  def handle_info(:idle_shutdown, %{downstream: nil, active_turn: nil} = state) do
    {:stop, :normal, %{state | idle_shutdown_ref: nil, draining?: true, owner_exit_cause: :idle_expiry}}
  end

  def handle_info(:idle_shutdown, state) do
    {:noreply, %{state | idle_shutdown_ref: nil}}
  end

  def handle_info(:renew_owner_lease, state) do
    renew_owner_lease(%{state | owner_renewal_ref: nil}, &schedule_owner_renewal/1)
  end

  # The early lease checks after a downstream became unreachable
  # (`recheck_lease_after_unreachable_downstream/2`). A regular renewal that
  # fired just before that DOWN may have scheduled its successor since, so the
  # current timer is cancelled rather than forgotten: one renewal chain stays.
  def handle_info({:renew_owner_lease, :unreachable_downstream, tries_left}, state) do
    next =
      if tries_left > 0,
        do: &schedule_unreachable_downstream_lease_check(&1, tries_left - 1),
        else: &schedule_owner_renewal/1

    renew_owner_lease(cancel_owner_renewal(state), next)
  end

  def handle_info(
        {:native_compaction_trace_sensitivity, :restore, generation, authorization, restorer},
        state
      ) do
    sensitivity = state.native_compaction_trace_sensitivity

    if NativeCompactionTrace.authorized_restore?(
         sensitivity,
         generation,
         authorization,
         restorer
       ) do
      :ok = NativeCompactionTrace.restore_process_sensitivity(sensitivity)
      {:noreply, %{state | native_compaction_trace_sensitivity: :sensitive}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, task, reason}, state)
      when is_map_key(state.pending_admissions, task) do
    if Map.get(state.pending_admission_monitors, task) == monitor do
      cancel_admitted_context(
        state,
        Map.fetch!(state.pending_admissions, task),
        pending_admission_exit_reason(reason)
      )

      {:noreply, forget_pending_admission(state, task)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, observer, _reason}, %{drain_observers: observers} = state) when is_map_key(observers, observer) do
    case Map.fetch!(observers, observer) do
      %{monitor: ^monitor, ref: ref} -> {:noreply, remove_drain_observer(state, observer, ref)}
      _other_monitor -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, restorer, _reason}, state) do
    sensitivity = state.native_compaction_trace_sensitivity

    case NativeCompactionTrace.restore_on_restorer_down(sensitivity, monitor, restorer) do
      :restored ->
        {:noreply, %{state | native_compaction_trace_sensitivity: :sensitive}}

      :unchanged ->
        {:noreply, state}
    end
  end

  # The owner's own upstream session closed a connection that carried a
  # request, between requests and for a cause that ends every anchor it
  # produced (findings#270). A signal from any other session falls through to
  # the catch-all below.
  def handle_info({:upstream_websocket_connection_closed, upstream_pid, signal}, %{upstream_pid: upstream_pid} = state) do
    case WebsocketOwnerContract.upstream_closed_signal(signal) do
      {:ok, signal} -> {:noreply, note_upstream_connection_closed(state, signal)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    if state.compact_delivery_read, do: Task.shutdown(state.compact_delivery_read.task, :brutal_kill)
    :ok = log_abandoned_upstream_close(state, :draining)
    state = cancel_owner_renewal(state)
    state = cancel_pending_admissions(state, Atom.to_string(owner_exit_reason(reason, state)))
    terminate_predecessor_task(state.active_turn)
    _state = clear_pending_handoff(state)
    owner_exit_reason = owner_exit_reason(reason, state)
    owner_exit_cause = owner_exit_cause(reason, state)
    Logger.owner_terminated(reason, owner_exit_reason, owner_exit_cause, state)

    if reason == :normal and state.drain_requested? and map_size(state.drain_observers) > 0 do
      complete_observed_drain(state, owner_exit_reason, owner_exit_cause)
    else
      try do
        state = OwnerCleanup.resolve_owner_state(state)

        case exit_interruption(state, owner_exit_reason) do
          :ok -> Persistence.release_owner_lease(state, owner_exit_reason, owner_exit_cause)
          {:error, _reason} -> :ok
        end
      after
        close_upstream(state.callbacks.upstream_closer, state.upstream_pid)
        answer_drain_waiters(state)
      end
    end

    :ok
  end

  # The observing rollout worker may lose a race to a different drain caller.
  # Its private ref is acknowledged only after this exact owner completed all
  # shutdown obligations. A normal exit alone is never this evidence.
  defp register_drain_observer(state, {observer, _tag}, ref) when is_reference(ref) do
    case Map.get(state.drain_observers, observer) do
      %{ref: ^ref} ->
        state

      previous ->
        if previous, do: Process.demonitor(previous.monitor, [:flush])
        entry = %{ref: ref, monitor: Process.monitor(observer)}
        send(observer, {:websocket_owner_drain_observing, self(), ref})
        %{state | drain_observers: Map.put(state.drain_observers, observer, entry)}
    end
  end

  defp register_drain_observer(state, _from, _ref), do: state

  defp remove_drain_observer(state, observer, ref) do
    case Map.get(state.drain_observers, observer) do
      %{ref: ^ref, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        %{state | drain_observers: Map.delete(state.drain_observers, observer)}

      _stale ->
        state
    end
  end

  defp complete_observed_drain(state, reason, cause) do
    persisted = checked_owner_exit(state, reason, cause)
    closed = checked_upstream_close(state)
    complete? = persisted == :ok and closed == :ok and not state.drain_shutdown_failed? and is_nil(state.active_turn) and map_size(state.pending_admissions) == 0
    result = if complete?, do: state.drain_result, else: {:error, :shutdown_incomplete}
    Enum.each(state.drain_observers, fn {observer, %{ref: ref}} -> send(observer, {:websocket_owner_drain_finished, self(), ref, result}) end)
    answer_drain_waiters(state)
  end

  defp checked_owner_exit(state, reason, cause) do
    state = OwnerCleanup.resolve_owner_state(state)
    with :ok <- exit_interruption(state, reason), do: Persistence.release_owner_lease_checked(state, reason, cause)
  rescue
    _exception -> {:error, :shutdown_incomplete}
  catch
    _kind, _reason -> {:error, :shutdown_incomplete}
  end

  defp checked_upstream_close(state) do
    close_upstream(state.callbacks.upstream_closer, state.upstream_pid)
    if is_pid(state.upstream_pid) and Process.alive?(state.upstream_pid), do: {:error, :upstream_alive}, else: :ok
  rescue
    _exception -> {:error, :upstream_close_failed}
  catch
    _kind, _reason -> {:error, :upstream_close_failed}
  end

  # A retiring owner persisted its exit when it settled the turn it held
  # (`settle_retiring_turn/1`), so the exit interrupts the session once.
  defp exit_interruption(%{exit_interrupted?: true}, _owner_exit_reason), do: :ok
  defp exit_interruption(state, owner_exit_reason), do: Persistence.interrupt_codex_session(state, owner_exit_reason)

  defp cancel_pending_admissions(state, reason) do
    failed? =
      Enum.reduce(state.pending_admissions, state.drain_shutdown_failed?, fn {_task, context}, failed? ->
        result = DirectCleanup.terminate_admission(context, reason)
        log_admitted_cleanup(result, state)
        failed? or match?({:error, _}, result)
      end)

    Enum.reduce(Map.keys(state.pending_admissions), %{state | drain_shutdown_failed?: failed?}, &forget_pending_admission(&2, &1))
  end

  defp cancel_admitted_context(state, context, reason) do
    log_admitted_cleanup(DirectCleanup.cancel(context, reason), state)
  end

  defp log_admitted_cleanup(result, state) do
    case result do
      {:error, failure} ->
        Logger.owner_exit_persistence_failure(
          :interrupt_codex_session,
          state,
          :owner_drained,
          failure
        )

      _ ->
        :ok
    end
  end

  defp forget_pending_admission(state, task) do
    if monitor = Map.get(state.pending_admission_monitors, task),
      do: Process.demonitor(monitor, [:flush])

    %{
      state
      | pending_admissions: Map.delete(state.pending_admissions, task),
        pending_admission_monitors: Map.delete(state.pending_admission_monitors, task)
    }
  end

  defp pending_admission_exit_reason({:shutdown, :owner_drained}), do: "owner_drained"
  defp pending_admission_exit_reason(_reason), do: "client_disconnected"

  # A live owner can be slower than its status call's budget: a turn's
  # database writes against a slow database, a backlog of provider frames.
  # Stopping it for that killed its provider connection, with the response
  # anchor and cache on it, and the turn it was running for another socket.
  # When it was blocked inside a callback, the stop timed out and crashed the
  # new socket's init, and the queued stop still ended the owner afterwards
  # (findings#285 row 270-247). An owner that does not answer in time is now
  # judged from its registry value:
  #
  #   * still starting (`init/1` only starts the upstream session): busy;
  #   * holding another lease than this socket's: stale, stopped as before.
  #     The socket took the lease over once it had expired;
  #   * a renewal started within the lease TTL: busy. The socket gets
  #     `owner_forward_timeout`, nothing is written, and the client's retry
  #     asks again;
  #   * no renewal started for longer than the lease TTL: unresponsive,
  #     stopped. A live owner starts one at least once per TTL. The renewal
  #     interval is at most a third of the TTL, and the TTL covers a renewal
  #     statement at its full budget (`OwnerRenewalSchedule`). An owner that
  #     did not could not have kept its lease on its own renewals. The lease
  #     row cannot tell: every socket that starts its session on this VM
  #     renews it (`OwnerLease.acquire!/5`).
  #
  # Every other exit means the owner is gone.
  defp owner_reuse_status(pid, opts) do
    expected = %{
      codex_session_id: Keyword.fetch!(opts, :codex_session_id),
      owner_lease_token: Keyword.fetch!(opts, :owner_lease_token),
      owner_instance_id: Keyword.fetch!(opts, :owner_instance_id)
    }

    case GenServer.call(pid, :owner_status, owner_call_timeout()) do
      {:ok, %{draining?: true}} ->
        :draining

      {:ok, status} when not is_map_key(status, :draining?) ->
        {:stale, :answered_stale}

      {:ok, status} ->
        cond do
          not uuid?(expected.codex_session_id) -> :reusable
          status.upstream_alive? and Map.take(status, Map.keys(expected)) == expected -> :reusable
          true -> {:stale, :answered_stale}
        end

      _other ->
        {:stale, :answered_stale}
    end
  catch
    :exit, {:timeout, _call} -> unanswered_owner_status(pid, opts)
    :exit, _reason -> {:stale, :owner_exited}
  end

  defp unanswered_owner_status(pid, opts) do
    case Registry.lookup(owner_registry(opts), Keyword.fetch!(opts, :codex_session_id)) do
      [{^pid, @registry_starting}] ->
        {:busy, nil}

      [{^pid, {@registry_ready, lease_digest, last_renewal_monotonic_ms}}] ->
        last_renewal_age_ms = System.monotonic_time(:millisecond) - last_renewal_monotonic_ms

        cond do
          lease_digest != lease_digest(Keyword.fetch!(opts, :owner_lease_token)) -> {:stale, :lease_replaced}
          last_renewal_age_ms > owner_lease_ttl_ms() -> {:stale, :unresponsive}
          true -> {:busy, last_renewal_age_ms}
        end

      [{^pid, _value}] ->
        {:stale, :unrecognized_registration}

      _another_owner_or_none ->
        {:stale, :owner_exited}
    end
  end

  defp ready_registry_value(owner_lease_token),
    do: {@registry_ready, lease_digest(owner_lease_token), System.monotonic_time(:millisecond)}

  defp lease_digest(owner_lease_token) when is_binary(owner_lease_token), do: :crypto.hash(:sha256, owner_lease_token)
  defp lease_digest(_owner_lease_token), do: nil

  defp start_upstream_task(state, ref, upstream_payload, descriptor, writer_capability) do
    reservation = %{
      owner: self(),
      ref: ref,
      upstream_pid: state.upstream_pid,
      upstream_sender: state.callbacks.upstream_sender,
      collect?: collect_request?(upstream_payload),
      forward_error_body?: forward_error_body?(upstream_payload),
      descriptor: descriptor,
      writer_capability: writer_capability
    }

    Task.Supervisor.async_nolink(@task_supervisor, fn ->
      Process.flag(:sensitive, true)
      send_upstream(reservation, upstream_payload)
    end)
  end

  # An owner blocked inside a callback cannot handle the stop within the
  # budget. The timeout used to crash the caller while the queued stop still
  # ended the owner later; such an owner is killed instead. Its linked
  # upstream session goes with it, and a socket attached to it meets its
  # crash. Every other exit means the owner is already gone.
  defp stop_stale_owner(pid, opts) do
    :ok = GenServer.stop(pid, {:shutdown, :stale_owner}, owner_call_timeout())
    :stopped
  catch
    :exit, {:timeout, _stop} ->
      Process.exit(pid, :kill)
      Logger.owner_stale_killed(pid, opts, owner_call_timeout())
      :killed

    :exit, _gone ->
      :stopped
  end

  defp submission_observer?(%UpstreamWebsocketSession.Request{submission_observer: observer}),
    do: is_function(observer, 0)

  defp handle_upstream_frame(state, payload, terminal?) do
    case classify_terminal_delivery_frame(state.active_turn.terminal_forwarded?, terminal?) do
      :duplicate_terminal ->
        {:noreply, state}

      {:forward, terminal?} ->
        case authorize_visible_delivery(state, payload) do
          {:ok, %{active_turn: %{visible_output?: true, lost_to_unreachable_node?: true, descriptor: %{downstream_status: :lost}}} = state} ->
            cancel_unreachable_lost_turn(state)

          {:ok, state} ->
            relay_authorized_frame(state, payload, terminal?)

          {:error, state} ->
            {:noreply, state}
        end
    end
  end

  defp relay_authorized_frame(state, payload, terminal?, authority \\ :owner_authorized) do
    delivery = if authority == :writer_authorized, do: send_downstream(state, DownstreamState.active_turn_downstream(state), {:data, payload}), else: deliver_authorized_frame(state, payload)

    case delivery do
      :ok ->
        state
        |> record_terminal_delivered_to_reattached(terminal?)
        |> maybe_complete_terminal_delivery(terminal?)
        |> continue_or_retire()

      {:error, reason} ->
        state
        |> fail_terminal_delivery(terminal?, reason, payload)
        |> continue_or_retire()

      :stale_generation ->
        {:noreply, state}

      :visible_output_unavailable ->
        {:noreply, %{state | active_turn: Map.put(state.active_turn, :lifecycle_authorization_result, {:error, :visible_output_unavailable})}}
    end
  end

  defp deliver_authorized_frame(
         %{active_turn: %{visible_output?: true}} = state,
         payload
       ) do
    send_downstream(state, DownstreamState.active_turn_downstream(state), {:data, payload})
  end

  defp deliver_authorized_frame(
         %{active_turn: %{descriptor: %{request_id: request_id, attempt_id: attempt_id}}} = state,
         payload
       )
       when is_binary(request_id) and is_binary(attempt_id) do
    # A lifecycle frame before any output does not commit visibility, so it is
    # delivered under the same current-generation check as a control frame.
    if StreamProtocol.lifecycle_only_event?(payload) do
      deliver_internal_frame(state, request_id, attempt_id, payload)
    else
      send_downstream(
        state,
        DownstreamState.active_turn_downstream(state),
        {:data, payload}
      )
    end
  end

  defp deliver_authorized_frame(state, payload) do
    send_downstream(state, DownstreamState.active_turn_downstream(state), {:data, payload})
  end

  defp deliver_internal_frame(state, request_id, attempt_id, payload) do
    started_at = System.monotonic_time()
    descriptor = state.active_turn.descriptor

    request = %CodexPooler.Accounting.Request{id: request_id}

    attempt = %CodexPooler.Accounting.Attempt{
      id: attempt_id,
      request_id: request_id,
      replay_generation: descriptor.replay_generation
    }

    try do
      case CodexPooler.Accounting.with_current_lifecycle_generation(request, attempt, fn ->
             send_downstream(
               state,
               DownstreamState.active_turn_downstream(state),
               {:data, payload}
             )
           end) do
        {:ok, result} ->
          WebTelemetry.emit_lifecycle_authorization(:internal_delivery, :authorized, started_at)
          result

        {:error, :stale_generation} ->
          WebTelemetry.emit_lifecycle_authorization(:internal_delivery, :stale_generation, started_at)
          :stale_generation
      end
    rescue
      Ecto.NoResultsError ->
        WebTelemetry.emit_lifecycle_authorization(:internal_delivery, :missing_row, started_at)
        :stale_generation

      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        if TransientDatabaseError.transient?(error) do
          WebTelemetry.emit_lifecycle_authorization(:internal_delivery, :transient_db_error, started_at)
          :visible_output_unavailable
        else
          WebTelemetry.emit_lifecycle_authorization(:internal_delivery, :other, started_at)
          reraise(error, __STACKTRACE__)
        end
    end
  end

  defp authorize_visible_delivery(
         %{active_turn: %{visible_output?: true}} = state,
         _payload
       ),
       do: {:ok, state}

  defp authorize_visible_delivery(
         %{
           active_turn: %{
             descriptor: %{request_id: request_id, attempt_id: attempt_id} = descriptor
           }
         } = state,
         payload
       )
       when is_binary(request_id) and is_binary(attempt_id) do
    # Only output or a terminal commits visibility: a cut after nothing but
    # `response.created`/`response.in_progress` showed the client nothing, and
    # its resend must still find the turn replay-active (findings#232 row
    # 232-161).
    if Map.has_key?(descriptor, :replay_claim_digest) and
         StreamProtocol.client_visible_output_event?(payload) do
      attempt = %{
        id: attempt_id,
        request_id: request_id,
        replay_generation: descriptor.replay_generation
      }

      case SessionContinuity.authorize_codex_turn_visibility(request_id, attempt) do
        {:ok, :committed} ->
          state = put_in(state.active_turn.descriptor.visible_output?, true)
          {:ok, %{state | active_turn: %{state.active_turn | visible_output?: true}}}

        {:ok, _not_committed} ->
          {:ok, state}

        _failure ->
          {:error, state}
      end
    else
      {:ok, state}
    end
  end

  defp authorize_visible_delivery(state, _payload), do: {:ok, state}

  defp send_upstream(
         %{
           owner: owner,
           ref: ref,
           upstream_pid: upstream_pid,
           upstream_sender: sender,
           collect?: collect?,
           forward_error_body?: forward_error_body?,
           descriptor: descriptor,
           writer_capability: writer_capability
         },
         upstream_payload
       ) do
    writer = owner_writer(collect?, owner, ref, writer_capability, descriptor)
    upstream_payload = upstream_payload |> bind_native_steering_owner(owner) |> bind_compaction_pending_observer(owner, ref, writer_capability)

    case sender.(upstream_pid, upstream_payload, writer) do
      {:error, response} when is_map(response) ->
        {:error, Map.put(response, :forward_error_body?, forward_error_body?)}

      result ->
        result
    end
  end

  defp pending_compaction_current?(%{draining?: false, active_turn: %{collect?: true, terminal_forwarded?: false, task_settled?: false, pending_result: nil, compaction_pending_context: %DirectCleanup{} = context, downstream: downstream, upstream_pid: upstream, admission_request_id: request_id, admission_attempt_id: attempt_id} = active, downstream: current}, %{request_id: request_id, attempt_id: attempt_id, upstream_pid: upstream, token: token, sequence: sequence, remaining_ms: remaining_ms}) do
    pending_compaction_event_valid?(token, sequence, remaining_ms) and not Map.has_key?(active, :canceled_result) and is_map(current) and
      current.pid == downstream.pid and current.epoch == downstream.epoch and current.correlation_id == downstream.correlation_id and
      context.parent == downstream.pid and context.task == Map.get(downstream, :owner_turn_id)
  end

  defp pending_compaction_current?(_state, _event), do: false

  defp pending_compaction_event_valid?(token, sequence, remaining_ms),
    do: is_reference(token) and is_integer(sequence) and sequence > 0 and is_integer(remaining_ms) and remaining_ms > 0

  defp bind_compaction_pending_observer(%UpstreamWebsocketSession.Request{} = request, owner, ref, capability) do
    %{request | compaction_pending_observer: fn event -> send(owner, {:owner_compaction_pending, ref, capability, event}) end}
  end

  defp bind_compaction_pending_observer(request, _owner, _ref, _capability), do: request

  defp bind_native_steering_owner(%UpstreamWebsocketSession.Request{native_response_steering: lane} = request, owner) when is_pid(lane),
    do: %{request | native_response_steering: {lane, owner}}

  defp bind_native_steering_owner(request, _owner), do: request

  defp ordinary_attach_busy?(state, opts) do
    match?(%{descriptor: %{kind: :native_response_steering}}, state.active_turn) or
      (Keyword.get(opts, :reject_if_busy, false) and owner_occupied?(state) and
         not suspended_replay_attachable?(state.suspended_replay))
  end

  defp owner_writer(true, _owner, _ref, _capability, _descriptor), do: nil

  defp owner_writer(false, owner, ref, capability, descriptor) do
    authority = if is_map(descriptor), do: Map.take(descriptor, [:request_id, :attempt_id, :replay_generation]), else: %{}
    fn frame, discriminator -> write_owner_frame(owner, ref, capability, authority, frame, discriminator) end
  end

  defp write_owner_frame(owner, ref, capability, authority, frame, discriminator) do
    deliver = fn visibility ->
      if visibility == :committed, do: Process.put({__MODULE__, ref, :visible}, authority)
      send_authorized_writer_frame(owner, ref, capability, authority, frame, discriminator, visibility)
    end

    if Process.get({__MODULE__, ref, :visible}) == authority do
      deliver.(:committed)
    else
      case authorize_writer_frame(authority, frame, deliver) do
        {:ok, :delivered} -> :ok
        {:ok, visibility} -> deliver.(visibility)
        {:error, :stale_generation} -> :ok
        {:error, :visible_output_unavailable} -> raise DBConnection.ConnectionError, message: "lifecycle delivery authorization unavailable"
        {:error, :settlement_retry_exhausted} -> raise DBConnection.ConnectionError, message: "visible output authorization unavailable"
      end
    end
  end

  defp relay_writer_authorized_frame(state, payload, discriminator, visibility) do
    state = if visibility == :committed, do: put_in(state.active_turn.visible_output?, true), else: state
    state = if visibility == :committed, do: put_in(state.active_turn.descriptor.visible_output?, true), else: state

    case classify_terminal_delivery_frame(state.active_turn.terminal_forwarded?, TerminalDiscriminator.terminal?(discriminator)) do
      :duplicate_terminal -> {:noreply, state}
      {:forward, terminal?} -> relay_writer_current_frame(state, payload, terminal?)
    end
  end

  defp relay_writer_current_frame(%{active_turn: %{visible_output?: true, lost_to_unreachable_node?: true, descriptor: %{downstream_status: :lost}}} = state, _payload, _terminal?), do: cancel_unreachable_lost_turn(state)
  defp relay_writer_current_frame(state, payload, terminal?), do: relay_authorized_frame(state, payload, terminal?, :writer_authorized)

  defp authorize_writer_frame(%{request_id: request_id, attempt_id: attempt_id} = authority, frame, deliver)
       when is_binary(request_id) and is_binary(attempt_id) do
    request = %CodexPooler.Accounting.Request{id: request_id, transport: "websocket"}
    attempt = %CodexPooler.Accounting.Attempt{id: attempt_id, request_id: request_id, replay_generation: Map.get(authority, :replay_generation, 0)}

    if StreamProtocol.lifecycle_only_event?(frame) do
      authorize_writer_lifecycle_frame(request, attempt, deliver)
    else
      SettlementRetry.run(:visible_output, request, attempt, fn -> SessionContinuity.authorize_codex_turn_visibility(request_id, attempt) end, subject: "visible output mark", fallback: "withheld_output", exhaustion: :return)
    end
  end

  defp authorize_writer_frame(_authority, _frame, _deliver), do: {:ok, :not_committed}

  defp authorize_writer_lifecycle_frame(request, attempt, deliver) do
    started_at = System.monotonic_time()

    try do
      case CodexPooler.Accounting.with_current_lifecycle_generation(request, attempt, fn ->
             deliver.(:not_committed)
             :delivered
           end) do
        {:ok, _result} = ok ->
          WebTelemetry.emit_lifecycle_authorization(:writer_delivery, :authorized, started_at)
          ok

        {:error, :stale_generation} = stale ->
          WebTelemetry.emit_lifecycle_authorization(:writer_delivery, :stale_generation, started_at)
          stale
      end
    rescue
      Ecto.NoResultsError ->
        WebTelemetry.emit_lifecycle_authorization(:writer_delivery, :missing_row, started_at)
        {:error, :stale_generation}

      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        if TransientDatabaseError.transient?(error) do
          WebTelemetry.emit_lifecycle_authorization(:writer_delivery, :transient_db_error, started_at)
          {:error, :visible_output_unavailable}
        else
          WebTelemetry.emit_lifecycle_authorization(:writer_delivery, :other, started_at)
          reraise(error, __STACKTRACE__)
        end
    end
  end

  defp send_authorized_writer_frame(owner, ref, capability, authority, frame, discriminator, :not_committed) do
    if tracked_lifecycle_frame?(authority, frame) do
      send(owner, {:websocket_owner_authorized_frame, ref, capability, authority, frame, discriminator, :not_committed})
    else
      send(owner, {:websocket_owner_upstream_frame, ref, frame, discriminator})
    end
  end

  defp send_authorized_writer_frame(owner, ref, capability, authority, frame, discriminator, visibility) do
    send(owner, {:websocket_owner_authorized_frame, ref, capability, authority, frame, discriminator, visibility})
  end

  defp tracked_lifecycle_frame?(%{request_id: request_id, attempt_id: attempt_id}, frame)
       when is_binary(request_id) and is_binary(attempt_id), do: StreamProtocol.lifecycle_only_event?(frame)

  defp tracked_lifecycle_frame?(_authority, _frame), do: false

  defp send_downstream(_state, nil, _payload), do: {:error, :owner_unavailable}

  defp send_downstream(
         state,
         %{
           pid: pid,
           epoch: epoch,
           correlation_id: correlation_id,
           owner_turn_id: owner_turn_id
         },
         payload
       )
       when is_pid(owner_turn_id) do
    message = {:websocket_owner_frame, correlation_id, epoch, owner_turn_id, payload}

    if WebsocketOwnerContract.downstream_message?(message) do
      state.callbacks.downstream_sender.(pid, message)
    else
      {:error, :invalid_downstream_message}
    end
  end

  defp send_downstream(_state, %{owner_turn_id: _invalid_owner_turn_id}, _payload),
    do: {:error, :invalid_downstream_message}

  defp send_downstream(
         state,
         %{pid: pid, epoch: epoch, correlation_id: correlation_id},
         payload
       ) do
    message = {:websocket_owner_frame, correlation_id, epoch, payload}

    if WebsocketOwnerContract.downstream_message?(message) do
      state.callbacks.downstream_sender.(pid, message)
    else
      {:error, :invalid_downstream_message}
    end
  end

  defp drain_now(state, how) do
    state =
      state
      |> clear_compaction_retry_submit_hold()
      |> drop_deferred_upstream_close(:draining)

    state = %{
      state
      | termination_cleanup_witness: OwnerCleanup.from_owner_state(state)
    }

    state = state |> clear_native_compaction_admission(:owner_drained) |> fail_pending_handoff(:owner_drained)

    state =
      if DownstreamState.active_turn?(state) do
        terminate_predecessor_task(state.active_turn)
        state = put_in(state.active_turn[:receipt_failure], %{receipt_failure(:owner_drained) | response_status_code: 499})

        case retain_interrupted_receipt(state, {:error, :owner_drained}) do
          {:started, next} -> next
          :none -> state |> record_drain_interruption() |> settle_active_turn({:error, :owner_drained})
        end
      else
        :ok = notify_drained_downstream(state, how)
        state
      end

    state = if match?(%{receipt_settlement: receipt} when is_map(receipt), state.active_turn), do: state, else: cancel_pending_admissions(state, "owner_drained")
    %{state | draining?: true, owner_exit_cause: :drain_cut}
  end

  defp record_drain_interruption(state) do
    case Persistence.interrupt_codex_session(state, :owner_drained) do
      :ok -> put_in(state.active_turn[:receipt_failure], %{receipt_failure(:owner_drained) | response_status_code: 499})
      {:error, _reason} -> state
    end
  end

  # After a forwarded turn that settled, its downstream may still be taking
  # the task's result: an `owner_drained` then met a turn whose terminal went
  # out and put an error frame after it (findings#287). That downstream learns
  # of the exit from its monitor instead.
  defp notify_drained_downstream(_state, :settled), do: :ok

  # A collected provider terminal may already have reached the client even
  # when persisting its delivery receipt failed. Cut conservatively without
  # manufacturing another terminal or declaring successful delivery.
  defp notify_drained_downstream(%{compact_delivery: %{witness: %OwnerCleanup{}}}, :cut), do: :ok

  defp notify_drained_downstream(state, :cut) do
    _result = send_owner_error(state, state.downstream, :owner_drained)
    :ok
  end

  # Where the last turn whose terminal the owner forwarded stands for a drain:
  # `:pending` while the turn waits only for its result from the provider's
  # session, or the owner already finished it and the request it witnessed is
  # still settling; `:settled` once that request settled; `:none` for any
  # other owner, which the drain cuts at once as it always did.
  defp forwarded_turn_settlement(%{suspended_replay: nil, active_turn: nil, compact_delivery: %{status: :pending}}), do: :pending
  defp forwarded_turn_settlement(%{suspended_replay: nil, active_turn: nil, compact_delivery: %{status: :delivered}}), do: :settled
  defp forwarded_turn_settlement(%{suspended_replay: nil, active_turn: nil, compact_delivery: delivery}) when is_map(delivery), do: :none

  defp forwarded_turn_settlement(%{suspended_replay: nil} = state) do
    cond do
      forwarded_turn_awaiting_result?(state.active_turn) -> :pending
      DownstreamState.active_turn?(state) or not forwarded_turn_witness?(state) -> :none
      Persistence.pending_finalization?(state) -> :pending
      true -> :settled
    end
  end

  defp forwarded_turn_settlement(_state), do: :none

  defp forwarded_turn_awaiting_result?(%{terminal_forwarded?: true, collect?: false}), do: true
  defp forwarded_turn_awaiting_result?(_active_turn), do: false

  # The owner keeps serving its mailbox while it waits, so a call the settling
  # task makes to it still gets its answer. The drain has begun from the first
  # instant, as `begin_drain/1` begins it, whether or not that came first.
  defp await_forwarded_turn_settlement(state, waiter) do
    ref = make_ref()
    Process.send_after(self(), {:drain_settlement_poll, ref}, @drain_settlement_poll_ms)
    deadline_ms = System.monotonic_time(:millisecond) + drain_settlement_budget_ms()
    refresh_compact_delivery(%{begin_drain_state(state) | drain_settlement: %{waiters: [waiter], ref: ref, deadline_ms: deadline_ms}})
  end

  defp begin_drain_state(state) do
    state
    |> drain_native_compaction_admission(:owner_drained)
    |> fail_pending_handoff(:owner_drained)
    |> drop_deferred_upstream_close(:draining)
    |> Map.put(:draining?, true)
  end

  # Drain refuses submission controls but does not revoke the collection
  # already consumed by this exact active turn. Its result still needs the
  # original admission; no successor or new final is authorized here.
  defp drain_native_compaction_admission(state, reason) do
    if active_compaction_collection?(state),
      do: state,
      else: clear_native_compaction_admission(state, reason)
  end

  defp active_compaction_collection?(
         %{
           active_turn: %{admission_phase: :compact, collect?: true, downstream: downstream} = active,
           native_compaction_admission: %NativeCompactionAdmission{phase: :consumed_compact, binding: binding, capability: %{control_ref: control_ref}},
           forwarded_send_witness: %ForwardedSendWitnessState{status: :redeemed, binding: binding, control_ref: control_ref, downstream: witnessed_downstream}
         } = state
       )
       when is_map(downstream) do
    not Map.has_key?(active, :canceled_result) and
      DownstreamState.downstream_status(state.downstream, downstream) == :active and
      DownstreamState.downstream_status(witnessed_downstream, downstream) == :active and
      current_owner_binding?(state, binding, downstream)
  end

  defp active_compaction_collection?(_state), do: false

  # Inside the drain call's own timeout (`drain_owner/1`), so the drain always
  # gets its answer before it gives up on the owner.
  defp drain_settlement_budget_ms, do: max(owner_call_timeout() - 1_000, div(owner_call_timeout(), 2))

  defp drain(from, %{drain_settlement: %{waiters: waiters} = settlement} = state),
    do: {:noreply, %{state | drain_settlement: %{settlement | waiters: [from | waiters]}}}

  defp drain(from, state) do
    state = begin_drain_state(%{state | drain_requested?: true})

    case forwarded_turn_settlement(state) do
      :pending -> {:noreply, await_forwarded_turn_settlement(state, from)}
      :settled -> finish_or_defer_owner_drain(state, from, :settled)
      :none -> finish_or_defer_owner_drain(state, from, :cut)
    end
  end

  defp finish_or_defer_owner_drain(state, from, how) do
    state = drain_now(%{state | drain_result: drain_reply(how)}, how)

    if match?(%{receipt_settlement: receipt} when is_map(receipt), state.active_turn) do
      {:noreply, append_receipt_drain_waiter(state, from, how)}
    else
      {:stop, :normal, drain_reply(how), state}
    end
  end

  defp append_receipt_drain_waiter(%{drain_replies: {waiters, reply}} = state, from, _how), do: %{state | drain_replies: {[from | waiters], reply}}
  defp append_receipt_drain_waiter(state, from, how), do: %{state | drain_replies: {[from], drain_reply(how)}}

  # A waiting drain is answered once the owner's exit is persisted
  # (`terminate/2`), as `{:stop, _, reply, _}` answers a drain that does not
  # wait: its caller, the rollout drain or a closing downstream, goes on to
  # what follows the owner's exit.
  defp finish_drain_settlement(%{drain_settlement: %{waiters: waiters}} = state, how) do
    state = drain_now(%{state | drain_settlement: nil, drain_result: drain_reply(how)}, how)
    state = %{state | drain_replies: {Enum.reverse(waiters), drain_reply(how)}}
    if match?(%{receipt_settlement: receipt} when is_map(receipt), state.active_turn), do: {:noreply, state}, else: {:stop, :normal, state}
  end

  defp answer_drain_waiters(%{drain_replies: {waiters, reply}}), do: Enum.each(waiters, &GenServer.reply(&1, reply))
  defp answer_drain_waiters(_state), do: :ok

  defp drain_reply(:settled), do: {:ok, :settled}
  defp drain_reply(:cut), do: :ok

  # The request of the turn `finish_active_turn/2` ends, when the owner
  # forwarded that turn's terminal to its downstream.
  defp forwarded_terminal_request_id(%{active_turn: %{terminal_forwarded?: true, collect?: false}, termination_cleanup_witness: %OwnerCleanup{request_id: request_id}}),
    do: request_id

  defp forwarded_terminal_request_id(_state), do: nil

  # The request the owner's exit would interrupt is still that forwarded
  # turn's, and no later turn took its place.
  defp forwarded_turn_witness?(%{forwarded_terminal_request_id: request_id} = state) when is_binary(request_id),
    do: match?(%OwnerCleanup{request_id: ^request_id}, OwnerCleanup.from_owner_state(state))

  defp forwarded_turn_witness?(_state), do: false

  defp send_owner_error(state, downstream, reason) do
    error = owner_error(reason)

    with {:ok, payload} <- WebsocketOwnerContract.safe_error_payload(error, nil) do
      send_downstream(state, downstream, {:error, error, payload})
    end
  end

  defp send_downstream_message(pid, message) do
    send(pid, message)
    :ok
  end

  # A `previous_response_id` resolves only on the upstream connection that
  # produced it. When the provider ends an idle connection (its 60-minute
  # limit, a restart), the client's socket to the Pooler stays open, so its
  # next request carries an anchor the fresh connection must refuse
  # (`previous_response_not_found`) before the client resends the full
  # history. Told of the close, the attached downstream closes its idle client
  # socket instead, and the client resends the full history on its own, as it
  # does when it talks to the provider directly (findings#270).
  #
  # The owner tells only the downstream attached to it, and only while nothing
  # it holds could be cut by that close; every signal it does not pass on
  # leaves one line with a fixed skip reason. A relayed turn whose terminal
  # already reached that downstream is waiting only for its task's result, and
  # the client already holds its response as an anchor: the instruction then
  # waits on the turn and goes out once the turn ended, after its `:complete`,
  # so the downstream always sees the turn end first. It lives on the active
  # turn, so it can never outlive the turn it waits for.
  defp note_upstream_connection_closed(state, signal) do
    state
    |> pass_on_upstream_close(signal)
    |> clear_closed_connection_admission(signal)
  end

  defp pass_on_upstream_close(state, signal) do
    case upstream_close_gate(state, signal) do
      :forward ->
        forward_upstream_close(state, signal)

      :defer ->
        deferred = %{downstream: Map.take(state.downstream, @restore_downstream_keys), signal: signal}
        %{state | active_turn: Map.put(state.active_turn, :upstream_close, deferred)}

      {:skip, reason} ->
        :ok = Logger.upstream_close_kept_open(signal, reason, state.codex_session_id)
        state
    end
  end

  defp upstream_close_gate(state, signal) do
    case upstream_close_skip_reason(state, signal, nil) do
      nil -> state.active_turn |> active_turn_upstream_close_gate(state.downstream) |> unless_superseded(state, signal)
      reason -> {:skip, reason}
    end
  end

  # A close the owner hears only after its session opened a newer connection
  # names a connection nothing depends on any more: the anchor of the
  # downstream's last response lives on the open one (findings#270 row
  # 270-199). Read only when the instruction would go out, with no turn
  # running, so the idle session answers at once; a session that cannot
  # answer counts as not superseded.
  defp unless_superseded(:forward, state, signal),
    do: if(superseded_connection?(state, signal), do: {:skip, :superseded_connection}, else: :forward)

  defp unless_superseded(decision, _state, _signal), do: decision

  defp superseded_connection?(state, %{lifecycle_id: lifecycle_id, generation: closed_generation}) do
    case state.callbacks.connection_reader.(state.upstream_pid) do
      {:ok, %{lifecycle_id: ^lifecycle_id, generation: open_generation}} when is_integer(open_generation) -> open_generation > closed_generation
      _unknown -> false
    end
  end

  # `deferred_for` is the downstream a deferred instruction was meant for: the
  # one its turn's terminal reached.
  defp upstream_close_skip_reason(state, signal, deferred_for) do
    owner_upstream_close_skip(state, signal) || downstream_upstream_close_skip(state, deferred_for) ||
      held_work_upstream_close_skip(state)
  end

  # Only the owner invalidates its upstream session: a handoff soft timeout
  # or a terminal delivery timeout, failures it has already answered on its
  # own terms, so its own invalidation never closes a downstream.
  defp owner_upstream_close_skip(state, signal) do
    cond do
      signal.cause == :invalidated -> :owner_invalidation
      # A retiring owner (its upstream exited) is draining too.
      state.draining? -> :draining
      true -> nil
    end
  end

  defp downstream_upstream_close_skip(%{downstream: nil}, _deferred_for), do: :no_downstream

  defp downstream_upstream_close_skip(state, deferred_for) do
    cond do
      is_map(deferred_for) and DownstreamState.downstream_status(state.downstream, deferred_for) != :active -> :downstream_replaced
      DownstreamState.downstream_status(state.closing_downstream, state.downstream) == :active -> :downstream_closing
      true -> nil
    end
  end

  defp held_work_upstream_close_skip(state) do
    cond do
      is_map(state.pending_handoff) -> :handoff
      is_map(state.suspended_replay) -> :replay_armed
      native_compaction_in_progress?(state) -> :compaction
      true -> nil
    end
  end

  # Every successful native turn arms `pending_compact` until its connection
  # closes (findings#270 row 270-317), and `ordinary_success`,
  # `consumed_final` and `cleared` hold nothing in flight, so those phases are
  # idle. So is `pending_final`: the compaction it follows
  # is over, and its binding names the closed connection, so its final request
  # can no longer be admitted (it failed `native_compaction_capability_rejected`
  # on the fresh connection); the owner drops that admission with the
  # connection and the final runs as an ordinary turn, on this socket or on
  # the client's new one. Any other phase is a compaction the close would
  # cut. So is a collected turn, a first full-history compaction the socket
  # has not authorized yet, a held compaction retry, and a send witness not
  # redeemed yet. A redeemed witness stays after its final until the
  # admission is cleared, so it proves nothing about the present.
  @upstream_close_idle_admission_phases [:ordinary_success, :pending_compact, :pending_final, :consumed_final, :cleared]
  @closed_connection_admission_phases List.delete(@upstream_close_idle_admission_phases, :cleared)

  # An admission names the connection its turn ran on, and only a request on
  # that connection can use it: a final or a next compaction bound to a
  # connection the provider closed failed without reaching the provider (502),
  # and a stale `pending_final` refused the next compaction on the socket
  # (503), whenever the socket stayed open after the close (findings#274). The
  # direct session drops its admission with its connection; the owner drops
  # its own on the same signal, after the gate above and whatever it decided,
  # with the same `connection_closed`. Only an idle phase bound to that very
  # connection goes, and only while no compaction is in flight: a collection
  # waiting for its confirmation (`collected_unconfirmed`, an authorized
  # first collection, a held first compact result, a send witness not
  # redeemed yet) keeps its admission.
  defp clear_closed_connection_admission(state, signal) do
    if closed_connection_admission?(state.native_compaction_admission, signal) and not native_compaction_in_progress?(state),
      do: clear_native_compaction_admission(state, :connection_closed),
      else: state
  end

  defp closed_connection_admission?(
         %NativeCompactionAdmission{phase: phase, first_compact_collection: nil, binding: %{lifecycle_id: lifecycle_id, generation: generation}},
         %{lifecycle_id: lifecycle_id, generation: generation}
       ),
       do: phase in @closed_connection_admission_phases

  defp closed_connection_admission?(_admission, _signal), do: false

  defp native_compaction_in_progress?(state) do
    admission_in_progress?(state.native_compaction_admission) or not is_nil(state.compaction_retry_submit_hold) or
      not is_nil(state.first_compact_result) or match?(%ForwardedSendWitnessState{status: :issued}, state.forwarded_send_witness) or
      match?(%{collect?: true}, state.active_turn)
  end

  defp admission_in_progress?(nil), do: false
  defp admission_in_progress?(%NativeCompactionAdmission{phase: phase}), do: phase not in @upstream_close_idle_admission_phases

  defp active_turn_upstream_close_gate(nil, _downstream), do: :forward

  # A websocket-bridged `/v1` relay reads only the frames it waits for, and a
  # public turn is outside the native route this close serves.
  defp active_turn_upstream_close_gate(%{descriptor: %{kind: :public}}, _downstream), do: {:skip, :public_turn}

  # A cancelled turn has no downstream any more, so it is never deferred.
  defp active_turn_upstream_close_gate(%{terminal_forwarded?: true, collect?: false} = active_turn, downstream) do
    if DownstreamState.downstream_status(downstream, Map.get(active_turn, :downstream)) == :active,
      do: :defer,
      else: {:skip, :turn_active}
  end

  defp active_turn_upstream_close_gate(_active_turn, _downstream), do: {:skip, :turn_active}

  defp forward_upstream_close(%{downstream: %{pid: pid, epoch: epoch, correlation_id: correlation_id}} = state, signal) do
    message = {:websocket_owner_upstream_closed, correlation_id, epoch, signal}

    if WebsocketOwnerContract.upstream_closed_message?(message) do
      _result = state.callbacks.downstream_sender.(pid, message)
    end

    state
  end

  defp deferred_upstream_close(%{upstream_close: deferred}), do: deferred
  defp deferred_upstream_close(_active_turn), do: nil

  # The turn the instruction waited for has ended and its `:complete` has
  # gone out: tell the downstream now, if it is still the one the turn's
  # terminal reached and nothing else holds it.
  defp apply_deferred_upstream_close(state, nil), do: state

  defp apply_deferred_upstream_close(state, %{downstream: deferred_for, signal: signal}) do
    case upstream_close_skip_reason(state, signal, deferred_for) || if(superseded_connection?(state, signal), do: :superseded_connection) do
      nil ->
        forward_upstream_close(state, signal)

      reason ->
        :ok = Logger.upstream_close_kept_open(signal, reason, state.codex_session_id)
        state
    end
  end

  defp drop_deferred_upstream_close(%{active_turn: %{upstream_close: _deferred} = active_turn} = state, reason) do
    :ok = log_abandoned_upstream_close(state, reason)
    %{state | active_turn: Map.delete(active_turn, :upstream_close)}
  end

  defp drop_deferred_upstream_close(state, _reason), do: state

  # The turn a deferred instruction waited for leaves without ending through
  # `finish_active_turn/2` or `clear_active_turn/1` (a handoff takes it over,
  # a replay suspends it, the owner stops): the instruction goes with it.
  defp log_abandoned_upstream_close(%{active_turn: %{upstream_close: %{signal: signal}}} = state, reason),
    do: Logger.upstream_close_kept_open(signal, reason, state.codex_session_id)

  defp log_abandoned_upstream_close(_state, _reason), do: :ok

  defp reply_active_turn(
         %{
           active_turn: %{reply_to: reply_to, submission_observed?: true}
         },
         result
       ) do
    GenServer.reply(reply_to, {:websocket_owner_submission_accepted, result})
  end

  defp reply_active_turn(%{active_turn: %{reply_to: reply_to}}, result) do
    if is_nil(reply_to), do: :ok, else: GenServer.reply(reply_to, result)
  end

  defp owner_occupied?(state) do
    DownstreamState.active_turn?(state) or not is_nil(state.downstream)
  end

  defp expire_compaction_retry_submit_hold(%{compaction_retry_submit_hold: nil} = state),
    do: state

  defp expire_compaction_retry_submit_hold(state) do
    if System.monotonic_time(:millisecond) >= state.compaction_retry_submit_hold.expires_at,
      do: clear_compaction_retry_submit_hold(state),
      else: state
  end

  defp clear_compaction_retry_submit_hold(%{compaction_retry_submit_hold: nil} = state), do: state

  defp clear_compaction_retry_submit_hold(%{compaction_retry_submit_hold: hold} = state) do
    Process.cancel_timer(hold.timer)
    Process.demonitor(hold.monitor, [:flush])
    %{state | compaction_retry_submit_hold: nil}
  end

  defp suspended_replay_attachable?(%{provisional_status: status}),
    do: status in [:armed, :provisional, :consume_reserved, :committed_not_started]

  defp suspended_replay_attachable?(_suspended), do: false

  # An attach its socket abandoned after its call timed out (findings#270 row
  # 270-248): the abandon recorded it on this node before this owner took it.
  defp abandoned_attach?(state, pid, correlation_id),
    do: AbandonedSubmissions.consume(AbandonedSubmissions.attach_key(state.codex_session_id, %{pid: pid, correlation_id: correlation_id}))

  defp attach_downstream_now(state, pid, correlation_id) do
    state = settle_probe_before_reconnect(state)
    epoch = DownstreamState.next_downstream_epoch(state.downstream_epoch)

    downstream = %{
      pid: pid,
      epoch: epoch,
      correlation_id: correlation_id
    }

    attach_downstream_now(state, downstream)
  end

  defp attach_downstream_now(state, downstream) do
    state = settle_probe_before_reconnect(state)

    downstream = Map.take(downstream, @restore_downstream_keys)

    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.cancel_idle_shutdown()
      |> clear_replaced_downstream_admission(downstream)

    monitor = Process.monitor(downstream.pid)

    downstream =
      Map.put(downstream, :active_turn_reconnect?, DownstreamState.active_turn?(state))

    closed_inheritance = if inherits_from_closed_downstream?(state), do: Map.take(downstream, @restore_downstream_keys)

    state =
      case state.active_turn do
        %{descriptor: %{downstream_status: :lost}} -> state
        _other -> DownstreamState.put_active_turn_downstream(state, downstream)
      end

    {:reply, {:ok, downstream},
     %{
       state
       | downstream: downstream,
         downstream_monitor: monitor,
         downstream_epoch: downstream.epoch,
         closed_inheritance: closed_inheritance
     }}
  end

  # The attach hands the running turn to the new socket, and the socket it
  # replaces had already closed: it announced its close before its drain
  # (`closing_downstream`), or the owner had handled its exit (no downstream).
  defp inherits_from_closed_downstream?(%{active_turn: %{descriptor: %{downstream_status: :lost}}}), do: false

  defp inherits_from_closed_downstream?(%{active_turn: active_turn} = state) when is_map(active_turn),
    do: not Map.has_key?(active_turn, :canceled_result) and (is_nil(state.downstream) or DownstreamState.downstream_status(state.closing_downstream, state.downstream) == :active)

  defp inherits_from_closed_downstream?(_state), do: false

  # A socket whose turn the owner still runs announces its close before its
  # 250 ms response-task drain; its ordinary detach comes only from its session
  # cleanup after that drain, which it waits on for 100 ms only (lease reads,
  # the owner call, the interrupt write).
  defp mark_closing_downstream(state, requested_downstream) do
    if DownstreamState.downstream_status(state.downstream, requested_downstream) == :active and is_map(state.active_turn),
      do: %{state | closing_downstream: Map.take(requested_downstream, @restore_downstream_keys)},
      else: state
  end

  # A socket that attaches while another is still attached replaces it without
  # a detach, and the demonitor above flushes the replaced socket's pending
  # DOWN, so nothing else would clear an admission armed for that socket. Its
  # binding names the replaced socket's epoch and every admission control
  # checks the downstream it was armed for, so the replacement could never use
  # it; kept, it refused the replacement's full-history compact collection
  # `stale_downstream` after the provider had served and billed it, and the
  # client received `invalid_compaction_response` (findings#206 row 206-265).
  # A restore of the downstream the admission belongs to keeps it.
  defp clear_replaced_downstream_admission(%{native_compaction_admission_downstream: nil} = state, _downstream), do: state

  defp clear_replaced_downstream_admission(state, downstream) do
    if admission_downstream_matches?(state.native_compaction_admission_downstream, downstream),
      do: state,
      else: clear_native_compaction_admission(state, :downstream_detached)
  end

  defp finish_active_turn(state, result) do
    downstream = DownstreamState.active_turn_downstream(state)
    deferred_upstream_close = deferred_upstream_close(state.active_turn)

    state = %{state | termination_cleanup_witness: OwnerCleanup.from_owner_state(state)}
    state = %{state | compact_delivery: completed_compact_delivery(state, result)}
    state = %{state | forwarded_terminal_request_id: forwarded_terminal_request_id(state)}

    clear_active_turn_resources(state.active_turn)
    state = clear_terminal_replay_state(state, result)

    state =
      if state.active_turn.collect? do
        state
        |> Map.put(:active_turn, nil)
        |> DownstreamState.maybe_schedule_idle_shutdown()
      else
        finish_relay_active_turn(state, downstream, result)
      end

    state
    |> apply_native_steering_owner_success(native_steering_finalized_result(result))
    |> complete_terminal_winner_detach()
    |> apply_deferred_upstream_close(deferred_upstream_close)
  end

  defp completed_compact_delivery(%{active_turn: %{collect?: true} = active, termination_cleanup_witness: %OwnerCleanup{} = witness}, result) do
    if completed_compaction_result?(result) and (active.admission_phase == :compact or not is_nil(active.first_compact_request_identity)),
      do: %{witness: witness, status: :pending},
      else: nil
  end

  defp completed_compact_delivery(_state, _result), do: nil

  defp compact_delivery_pending?(%{compact_delivery: %{status: :pending}}), do: true
  defp compact_delivery_pending?(_state), do: false

  defp accept_compact_delivery_result?(state, witness, deadline) do
    match?(%{witness: ^witness}, state.compact_delivery) and
      state.owner_instance_id == witness.owner_instance_id and state.owner_lease_token == witness.owner_lease_token and
      compact_read_phase(state) == deadline.phase and compact_read_deadline(state).at == deadline.at and deadline.now_ms.() < deadline.at
  end

  defp compact_read_phase(%{drain_settlement: settlement}) when is_map(settlement), do: :settlement
  defp compact_read_phase(_state), do: :activity

  defp compact_read_deadline(%{drain_settlement: %{deadline_ms: deadline}}), do: %{phase: :settlement, at: deadline, now_ms: fn -> System.monotonic_time(:millisecond) end}
  defp compact_read_deadline(%{compact_activity_deadline: deadline}) when is_map(deadline), do: Map.put(deadline, :phase, :activity)
  defp compact_read_deadline(_state), do: nil

  defp pending_owner_finalization?(%{compact_delivery: delivery} = state) when is_map(delivery), do: compact_delivery_pending?(state)
  defp pending_owner_finalization?(state), do: Persistence.pending_finalization?(state)

  # Read outside the mailbox: unavailable PostgreSQL must not hold status or
  # drain calls past the coordinator's deadline. One bounded read at a time;
  # the existing coordinator/settlement polls decide when to sample again.
  defp refresh_compact_delivery(%{draining?: true, active_turn: nil, compact_delivery: %{status: :pending, witness: witness}, compact_delivery_read: nil} = state) do
    if deadline = compact_read_deadline(state) do
      task = Task.Supervisor.async_nolink(@task_supervisor, fn -> read_compact_delivery(witness, deadline) end)

      %{state | compact_delivery_read: %{task: task, ref: task.ref, witness: witness, deadline: deadline}}
    else
      state
    end
  end

  defp refresh_compact_delivery(state), do: state

  defp read_compact_delivery(witness, deadline) do
    remaining = deadline.at - deadline.now_ms.()
    if remaining > 0, do: Persistence.compact_delivery_status(witness, min(remaining, min(100, owner_call_timeout() - 1))), else: :pending
  end

  defp native_steering_finalized_result({:ok, result}) when is_map(result), do: Map.get(result, :native_response_steering_finalized)
  defp native_steering_finalized_result(_result), do: nil

  defp clear_terminal_replay_state(
         %{active_turn: %{descriptor: %{replay_generation: 1}}} = state,
         _result
       ) do
    clear_replay_state(state)
  end

  defp clear_terminal_replay_state(state, _result), do: state

  # A compaction is collected only on the provider's completion, the terminals
  # the upstream session records a response by. A provider failure or the
  # connection-bound guard's refusal, which the owner consumed the capability
  # for before the session refused it, is a terminal result as well; counted as
  # collected, it left the admission `collected_unconfirmed`, and the released
  # client's full-history retry was served, billed and refused its
  # first-compact authorization (findings#281).
  defp settle_owner_admission_transport(
         %{active_turn: %{admission_phase: :compact}} = state,
         result
       ) do
    if completed_compaction_result?(result) do
      with true <- active_compaction_collection?(state),
           %NativeCompactionAdmission{} = current <- state.native_compaction_admission,
           {:ok, admission} <- NativeCompactionAdmission.record_compact_collected(current, System.system_time(:millisecond)) do
        {result, put_admission(state, admission)}
      else
        _revoked -> {{:error, :native_compaction_capability_rejected}, clear_native_compaction_admission(state, :capability_rejected)}
      end
    else
      {result, clear_native_compaction_admission(state, :compact_failure)}
    end
  end

  defp settle_owner_admission_transport(
         %{active_turn: %{admission_phase: :final}} = state,
         result
       ) do
    if successful_upstream_result?(result) do
      :ok = emit_final_completed(state)
      {result, state}
    else
      {result, clear_native_compaction_admission(state, :final_failure)}
    end
  end

  defp settle_owner_admission_transport(state, result), do: {result, state}

  defp retain_first_compact_result(
         {:ok,
          %{first_compact_result: %NativeCompactionAdmission.FirstCompactResult{} = receipt} =
            result},
         %{active_turn: active_turn} = state
       ) do
    receipt_module = NativeCompactionAdmission.FirstCompactResult

    if receipt.owner == state.upstream_pid and
         not is_nil(active_turn.first_compact_request_identity) and
         receipt_module.identity(receipt) == active_turn.first_compact_request_identity do
      topology =
        WebsocketOwnerAdmissionControlV1.forwarded_topology(
          state.owner_instance_id,
          state.owner_lease_token,
          active_turn.downstream.epoch
        )

      receipt = %{
        receipt
        | owner: self(),
          result_ref: make_ref(),
          binding: %{receipt.binding | topology: topology}
      }

      {{:ok, Map.put(result, :first_compact_result, receipt)}, %{state | first_compact_result: receipt}}
    else
      {{:ok, Map.delete(result, :first_compact_result)}, state}
    end
  end

  defp retain_first_compact_result(result, state), do: {result, state}

  # The lane has already settled this result and owns its success
  # acknowledgement. Never mint another ordinary witness from transport
  # success when settlement failed or this generation was superseded.
  defp retain_ordinary_success_result({:ok, %{native_response_steering_finalized: _finalized} = result}, state),
    do: {{:ok, Map.delete(result, :ordinary_success_result)}, state}

  defp retain_ordinary_success_result({:ok, %{native_response_steering_terminal_failure: _reason} = result}, state),
    do: {{:ok, Map.delete(result, :ordinary_success_result)}, state}

  defp retain_ordinary_success_result(
         {:ok, %{ordinary_success_result: %OrdinarySuccessResult{} = receipt} = result},
         %{active_turn: active} = state
       ) do
    # A downstream can detach after receiving its terminal but before this
    # result arrives. Its socket-bound admission was cleared by the detach.
    if is_map(active.downstream) and receipt.owner == state.upstream_pid and
         {receipt.request_id, receipt.attempt_id} == active.ordinary_request_identity do
      topology =
        WebsocketOwnerAdmissionControlV1.forwarded_topology(
          state.owner_instance_id,
          state.owner_lease_token,
          active.downstream.epoch
        )

      receipt = %{receipt | owner: self(), result_ref: make_ref(), topology: topology}

      {{:ok, Map.put(result, :ordinary_success_result, receipt)}, %{state | ordinary_success_result: receipt}}
    else
      {{:ok, Map.delete(result, :ordinary_success_result)}, state}
    end
  end

  defp retain_ordinary_success_result(result, state), do: {result, state}

  defp ordinary_request_identity(%{request_id: request_id, attempt_id: attempt_id}),
    do: {request_id, attempt_id}

  defp ordinary_request_identity(_payload), do: nil
  defp admission_request_id(%UpstreamWebsocketSession.Request{request_id: request_id}), do: request_id
  defp admission_request_id(_control_frame), do: nil

  defp admission_attempt_id(%UpstreamWebsocketSession.Request{attempt_id: attempt_id}), do: attempt_id
  defp admission_attempt_id(_control_frame), do: nil

  defp cleanup_replay_generation(
         %{native_replay_binding: %NativeReplayAdmission.Binding{replay_generation: generation}},
         _descriptor
       ),
       do: generation

  defp cleanup_replay_generation(_request, %{replay_generation: generation}), do: generation
  defp cleanup_replay_generation(_request, _descriptor), do: 0

  defp emit_compact_acknowledged(%NativeCompactionAdmission.Capability{} = capability) do
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :acknowledged)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_acknowledged, capability, %{
        pid_role: :owner_session,
        owner_pid: self()
      })

    :ok
  end

  defp emit_compact_acknowledged(nil),
    do: NativeCompactionAuthorizationObservation.emit(:compact_acknowledged, :forwarded)

  defp relay_final_result(_state, _downstream, :ok), do: :ok
  defp relay_final_result(_state, _downstream, {:ok, _result}), do: :ok

  defp relay_final_result(state, downstream, {:error, %{body: body, forward_error_body?: true, reason: _reason}})
       when is_binary(body) and body != "",
       do: send_downstream(state, downstream, {:data, body})

  # The terminal it could not deliver goes back to the task as the body; the
  # downstream still gets the owner's error, as with the bare reason.
  defp relay_final_result(state, downstream, {:error, %{undelivered_terminal?: true, reason: reason}}),
    do: send_owner_error(state, downstream, reason)

  defp relay_final_result(_state, _downstream, {:error, %{body: _body, reason: _reason}}), do: :ok
  defp relay_final_result(state, downstream, {:error, %{reason: reason}}), do: send_owner_error(state, downstream, reason)
  defp relay_final_result(state, downstream, {:error, reason}), do: send_owner_error(state, downstream, reason)
  defp relay_final_result(state, downstream, _other), do: send_owner_error(state, downstream, :owner_crashed)

  defp successful_upstream_result?(:ok), do: true
  defp successful_upstream_result?({:ok, _result}), do: true
  defp successful_upstream_result?(_result), do: false

  defp completed_compaction_result?({:ok, %{terminal: terminal}}) when terminal in ["response.completed", "response.done"], do: true
  defp completed_compaction_result?(_result), do: false

  defp finish_relay_active_turn(state, downstream, result) do
    _result = relay_final_result(state, downstream, result)
    _result = send_downstream(state, downstream, :complete)

    state
    |> Map.put(:active_turn, nil)
    |> DownstreamState.maybe_schedule_idle_shutdown()
  end

  defp begin_owner_receipt_producer(_state, nil), do: {:ok, nil}

  defp begin_owner_receipt_producer(state, %OwnerCleanup{} = cleanup) do
    ActivityRegistry.begin_receipt_producer(receipt_identity(cleanup), name: state.receipt_registry)
  end

  defp receipt_identity(cleanup), do: Map.take(cleanup, [:request_id, :attempt_id, :replay_generation])

  defp finish_owner_receipt_producer(%{receipt_producer: producer, receipt_registry: registry}) when is_reference(producer) do
    ActivityRegistry.finish_receipt_producer(producer, name: registry)
  end

  defp finish_owner_receipt_producer(_active), do: :ok

  defp retain_interrupted_receipt(%{active_turn: %{receipt_settlement: receipt}} = state, _result) when is_map(receipt), do: {:started, state}

  defp retain_interrupted_receipt(%{active_turn: active} = state, {:error, error} = cancellation) do
    held = active.pending_result || get_in(active, [:output_commit_probe, :result])
    failure = Map.get(active, :receipt_failure) || receipt_failure(if(is_map(error), do: error[:reason], else: error))

    with false <- active.terminal_forwarded?,
         {:ok, result} when is_map(result) <- held,
         false <- Map.has_key?(result, :native_response_steering_finalized),
         {:ok, snapshot} <- capture_owner_receipt(active.cleanup_witness, state.turn_claim_session, result[:response_usage], failure),
         producer when is_reference(producer) <- Map.get(active, :receipt_producer) do
      start_owner_receipt(state, producer, snapshot, cancellation)
    else
      _absent_or_invalid -> :none
    end
  end

  defp retain_interrupted_receipt(_state, _result), do: :none

  defp capture_owner_receipt(_cleanup, nil, %{status: "usage_known"}, _failure) do
    Elixir.Logger.warning("websocket retained receipt unavailable reason_class=legacy_principal_unavailable")
    {:error, :legacy_principal_unavailable}
  end

  defp capture_owner_receipt(cleanup, principal, usage, failure), do: RetainedUsage.capture(cleanup, principal, usage, failure)

  defp start_owner_receipt(state, producer, snapshot, {:error, error}) do
    owner = self()
    ref = make_ref()
    turn_ref = state.active_turn.ref
    registry = state.receipt_registry
    finalizer = Map.get(state.persistence, :retained_usage, &RetainedUsage.finalize/1)
    # This closure carries only process identities and the finalizer boundary.
    # The metadata-only snapshot arrives only after registry responsibility exists.
    {:ok, worker} = Task.Supervisor.start_child(@task_supervisor, fn -> receipt_worker(owner, turn_ref, ref, registry, finalizer) end)
    monitor = Process.monitor(worker)

    case ActivityRegistry.register_receipt_settlement(producer, receipt_identity(snapshot), worker, name: registry) do
      {:ok, token} ->
        :ok = ActivityRegistry.finish_receipt_producer(producer, name: registry)
        reply = {:error, %{body: "", headers: []} |> Map.merge(if(is_map(error), do: error, else: %{reason: error})) |> Map.put(:response_usage, snapshot.usage)}
        active = state.active_turn |> cancel_predecessor_delivery_timers() |> Map.put(:receipt_producer, nil) |> Map.put(:receipt_settlement, %{ref: ref, pid: worker, monitor: monitor, token: token, cancellation_reply: reply})
        state = %{state | active_turn: active}
        interruption = if state.draining? and snapshot.failure.error_code == "owner_drained", do: {state.active_turn.cleanup_witness, state.persistence.interrupt_codex_session}
        state = if state.retire_after_active_turn? or interruption, do: state, else: reply_receipt_cancellation(state, reply)
        send(worker, {:initialize_receipt, token, snapshot, interruption})
        {:started, state}

      {:error, _reason} ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        :none
    end
  end

  defp receipt_worker(owner, turn_ref, ref, registry, finalizer) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:initialize_receipt, token, snapshot, interruption} ->
        Process.demonitor(owner_monitor, [:flush])
        interrupted = interrupt_retained_drain(interruption)
        disposition = receipt_disposition(finalizer.(snapshot))
        :ok = ActivityRegistry.complete_receipt_settlement(token, disposition, name: registry)
        send(owner, {:websocket_owner_receipt_settled, turn_ref, ref, token, {disposition, interrupted}})

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp interrupt_retained_drain(nil), do: false
  defp interrupt_retained_drain({witness, callback}), do: Persistence.interrupt_owner_receipt(witness, :owner_drained, callback) == :ok

  defp receipt_disposition({:ok, %{finalization_disposition: disposition}}) when disposition in [:inserted, :reused, :replaced], do: disposition
  defp receipt_disposition({:stale_generation, _result}), do: :superseded
  defp receipt_disposition(_result), do: :failed

  defp complete_owner_receipt(state, {disposition, interrupted}) do
    complete_owner_receipt(%{state | exit_interrupted?: state.exit_interrupted? or interrupted}, disposition)
  end

  defp complete_owner_receipt(state, disposition) do
    state = %{state | drain_shutdown_failed?: state.drain_shutdown_failed? or disposition in [:failed, :aborted]}
    result = state.active_turn.receipt_settlement.cancellation_reply
    state = if state.retire_after_active_turn? and disposition in [:inserted, :reused, :replaced], do: %{state | exit_interrupted?: true}, else: state
    state = if state.active_turn.reply_sent?, do: state, else: state |> settle_retiring_turn() |> reply_receipt_cancellation(result)

    if is_map(state.pending_handoff) do
      state
      |> put_in([Access.key(:active_turn), :receipt_settlement], nil)
      |> settle_predecessor_without_receipt(result)
      |> maybe_ready_pending_handoff()
    else
      finish_active_turn(state, result)
    end
  end

  defp reply_receipt_cancellation(state, reply) do
    reply_active_turn(state, reply)
    put_in(state.active_turn.reply_sent?, true)
  end

  defp retain_cancelled_task_receipt(%{active_turn: %{canceled_result: _, pending_result: nil}} = state, {:ok, %{response_usage: %{status: "usage_known"}}} = result), do: put_in(state.active_turn.pending_result, result)
  defp retain_cancelled_task_receipt(state, _result), do: state

  defp reuse_finalized_steering_result(%{active_turn: %{pending_result: {:ok, %{native_response_steering_finalized: finalized}}}}, {:error, error}) do
    {:error, %{body: "", headers: []} |> Map.merge(if(is_map(error), do: error, else: %{reason: error})) |> Map.put(:native_response_steering_finalized, finalized)}
  end

  defp reuse_finalized_steering_result(_state, result), do: result

  defp receipt_failure(reason) when reason in [:client_disconnected, :owner_drained, :upstream_websocket_terminal_delivery_timeout, :owner_crashed, :owner_forward_timeout] do
    {:ok, payload} = WebsocketOwnerContract.safe_error_payload(reason, nil)
    %{status: "failed", response_status_code: payload.status, error_code: payload.code}
  end

  defp receipt_failure(_reason), do: nil

  defp settle_cancelled_active_turn(state, reason) do
    case state.active_turn do
      %{output_commit_probe: probe} when is_map(probe) ->
        settle_active_turn_without_downstream_delivery(state, {:error, reason})

      %{pending_result: pending_result} when not is_nil(pending_result) ->
        settle_active_turn(state, {:error, reason})

      _active_turn ->
        state
    end
  end

  defp maybe_settle_cancelled_without_pending_handoff(
         %{pending_handoff: pending} = state,
         _reason
       )
       when is_map(pending),
       do: state

  defp maybe_settle_cancelled_without_pending_handoff(state, reason),
    do: settle_cancelled_active_turn(state, reason)

  defp settle_active_turn(%{active_turn: %{receipt_settlement: receipt}} = state, _result) when is_map(receipt), do: state

  defp settle_active_turn(state, result) do
    result = reuse_finalized_steering_result(state, result)

    case retain_interrupted_receipt(state, result) do
      {:started, state} -> state
      :none -> settle_active_turn_without_receipt(state, result)
    end
  end

  defp settle_active_turn_without_receipt(state, result) do
    if output_commit_probe_required?(state, result) do
      retain_output_commit_probe(state, result)
    else
      state = settle_retiring_turn(state)
      reply_active_turn(state, result)
      finish_active_turn(state, result)
    end
  end

  # An owner retiring because its upstream connection process exited settles
  # the turn it holds as an owner crash, the interruption its exit would
  # write, before it answers the turn's task (findings#270 row 270-167). The
  # exit used to interrupt the turn while the task settled the owner's answer,
  # and whichever committed first recorded the request: `499` with the turn
  # interrupted, or `502` with the turn failed. Written before the answer, the
  # interruption precedes every other party that could settle the turn (the
  # task, and the socket once it sees the owner go), so the record is the same
  # on every run, and the exit does not interrupt the session again.
  defp settle_retiring_turn(%{retire_after_active_turn?: true, exit_interrupted?: false, active_turn: %{cleanup_witness: %OwnerCleanup{}}} = state) do
    case Persistence.interrupt_codex_session(state, :owner_crashed) do
      :ok -> %{state | exit_interrupted?: true}
      {:error, _reason} -> state
    end
  end

  defp settle_retiring_turn(state), do: state

  defp resolve_active_turn_result(%{active_turn: %{collect?: true}} = state, result),
    do: settle_active_turn(state, result)

  defp resolve_active_turn_result(state, result) do
    if terminal_bearing_result?(result) and not state.active_turn.terminal_forwarded? do
      retain_terminal_result(state, result)
    else
      settle_active_turn(state, result)
    end
  end

  defp continue_or_retire(%{drain_replies: {_waiters, _reply}, active_turn: nil} = state), do: {:stop, :normal, state}

  defp continue_or_retire(%{retire_after_active_turn?: true, active_turn: nil} = state),
    do: {:stop, :owner_crashed, state}

  defp continue_or_retire(state), do: {:noreply, state}

  defp reply_or_retire(%{retire_after_active_turn?: true, active_turn: nil} = state, reply),
    do: {:stop, :owner_crashed, reply, state}

  defp reply_or_retire(state, reply), do: {:reply, reply, state}

  defp retire_current_upstream(state, reason) do
    state = %{
      state
      | draining?: true,
        retire_after_active_turn?: true,
        termination_cleanup_witness: OwnerCleanup.from_owner_state(state)
    }

    case state.active_turn do
      %{output_commit_probe: probe} when is_map(probe) ->
        {:noreply, state}

      active_turn when is_map(active_turn) ->
        state = cancel_active_turn_for_upstream_exit(state)
        state = put_in(state.active_turn[:receipt_failure], %{receipt_failure(:owner_crashed) | response_status_code: 499})

        state
        |> settle_active_turn(upstream_exit_result(state, reason))
        |> continue_or_retire()

      nil ->
        {:stop, :owner_crashed, state}
    end
  end

  defp cancel_active_turn_for_upstream_exit(state) do
    %{task_ref: task_ref} = state.active_turn
    if is_reference(task_ref), do: Process.demonitor(task_ref, [:flush])
    DownstreamState.cancel_active_turn_task(state.active_turn)
    put_in(state.active_turn.task_ref, nil)
  end

  defp upstream_exit_result(
         %{active_turn: %{downstream: %{owner_turn_id: owner_turn_id}}},
         reason
       )
       when is_pid(owner_turn_id) do
    {:error,
     %{
       body: "",
       reason: owner_error(reason),
       transport_failure: %{"reason" => "owner_crashed"}
     }}
  end

  defp upstream_exit_result(_state, reason), do: {:error, owner_error(reason)}

  defp retain_output_commit_probe(state, result) do
    downstream = DownstreamState.active_turn_downstream(state)
    active_turn_ref = state.active_turn.ref
    probe_ref = make_ref()

    probe =
      {:websocket_owner_output_commit_probe, downstream.correlation_id, downstream.epoch, downstream.owner_turn_id, active_turn_ref, self(), probe_ref}

    # The timer only bounds a live downstream that never acks. A downstream
    # that is provably gone (monitor DOWN, detach, or a reconnect on a newer
    # epoch) settles the retained result immediately through its own path.
    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_output_commit_timeout, active_turn_ref, probe_ref},
        state.output_commit_probe_timeout_ms
      )

    output_commit_probe = %{
      result: result,
      correlation_id: downstream.correlation_id,
      epoch: downstream.epoch,
      owner_turn_id: downstream.owner_turn_id,
      active_turn_ref: active_turn_ref,
      probe_ref: probe_ref,
      timer_ref: timer_ref
    }

    state = put_in(state.active_turn.output_commit_probe, output_commit_probe)

    case state.callbacks.downstream_sender.(downstream.pid, probe) do
      :ok -> state
      {:error, _reason} -> settle_active_turn_without_downstream_delivery(state, result)
    end
  end

  # The probe follows owner->socket frames on the same sender/receiver pair.
  # Retaining the result until the ack preserves that ordering; an unsolicited
  # socket notification would race in the opposite direction.
  defp settle_output_commit_probe(state, committed?) do
    %{result: result} = state.active_turn.output_commit_probe
    downstream = DownstreamState.active_turn_downstream(state)
    cancel_output_commit_probe_timer(state.active_turn)

    if committed? do
      _result = send_owner_error(state, downstream, :upstream_stream_error)
    end

    _result = send_downstream(state, downstream, :complete)
    state = settle_retiring_turn(state)
    reply_active_turn(state, result)
    clear_active_turn(state)
  end

  defp timeout_output_commit_probe(state) do
    %{result: result} = state.active_turn.output_commit_probe
    downstream = DownstreamState.active_turn_downstream(state)
    cancel_output_commit_probe_timer(state.active_turn)
    _result = send_owner_error(state, downstream, :owner_forward_timeout)
    _result = send_downstream(state, downstream, :complete)
    state = settle_retiring_turn(state)
    reply_active_turn(state, result)
    clear_active_turn(state)
  end

  defp settle_active_turn_without_downstream_delivery(state, result) do
    case retain_interrupted_receipt(state, result) do
      {:started, state} ->
        state

      :none ->
        state = settle_retiring_turn(state)
        reply_active_turn(state, result)
        clear_active_turn(state)
    end
  end

  defp settle_probe_before_reconnect(%{active_turn: %{output_commit_probe: %{result: result}}} = state) do
    settle_active_turn_without_downstream_delivery(state, result)
  end

  defp settle_probe_before_reconnect(state), do: state

  defp clear_active_turn(state) do
    deferred_upstream_close = deferred_upstream_close(state.active_turn)
    clear_active_turn_resources(state.active_turn)

    state
    |> Map.put(:active_turn, nil)
    |> DownstreamState.maybe_schedule_idle_shutdown()
    |> apply_deferred_upstream_close(deferred_upstream_close)
  end

  defp clear_active_turn_resources(active_turn) do
    finish_owner_receipt_producer(active_turn)
    cancel_terminal_delivery_timer(active_turn)
    cancel_output_commit_probe_timer(active_turn)
    DownstreamState.clear_active_turn_monitors(active_turn)
  end

  defp settle_predecessor_task(state, result) do
    case retain_interrupted_receipt(state, result) do
      {:started, state} -> state
      :none -> settle_predecessor_without_receipt(state, result)
    end
  end

  defp settle_predecessor_without_receipt(state, result) do
    active_turn =
      state.active_turn
      |> cancel_predecessor_delivery_timers()
      |> Map.put(:task_settled?, true)
      |> Map.put(:pending_result, nil)
      |> Map.put(:output_commit_probe, nil)

    state = %{state | active_turn: active_turn}
    reply_predecessor_once(state, result)
  end

  defp reply_predecessor_once(%{active_turn: %{reply_sent?: true}} = state, _result), do: state

  defp reply_predecessor_once(state, result) do
    state = settle_retiring_turn(state)
    reply_active_turn(state, result)
    put_in(state.active_turn.reply_sent?, true)
  end

  defp cancel_predecessor_delivery_timers(active_turn) do
    cancel_terminal_delivery_timer(active_turn)
    cancel_output_commit_probe_timer(active_turn)

    active_turn
    |> Map.put(:terminal_delivery_timeout, nil)
    |> Map.put(:terminal_delivery_timer_ref, nil)
  end

  defp maybe_ready_pending_handoff(%{active_turn: %{receipt_settlement: receipt}} = state) when is_map(receipt), do: state

  defp maybe_ready_pending_handoff(
         %{
           pending_handoff: %{status: :waiting} = pending,
           active_turn: %{
             task_settled?: true,
             submitter_exited?: true,
             downstream: nil,
             terminal_delivery_timer_ref: nil,
             output_commit_probe: nil
           }
         } = state
       ) do
    clear_active_turn_resources(state.active_turn)
    :ok = log_abandoned_upstream_close(state, :handoff)
    pending = %{pending | status: :ready}

    message =
      {:websocket_owner_handoff_ready, pending.correlation_id, pending.epoch, pending.owner_turn_id, pending.pid, pending.control_ref}

    _result = state.callbacks.downstream_sender.(pending.pid, message)
    %{state | active_turn: nil, pending_handoff: pending}
  end

  defp maybe_ready_pending_handoff(state), do: state

  defp handoff_downstream?(pending, downstream) do
    Map.take(pending, @restore_downstream_keys) == Map.take(downstream, @restore_downstream_keys)
  end

  defp cancel_pending_handoff(%{pending_handoff: nil} = state, _downstream, _reason), do: state

  defp cancel_pending_handoff(%{pending_handoff: pending} = state, downstream, _reason) do
    if is_map(downstream) and handoff_downstream?(pending, downstream) do
      state
      |> abort_pending_predecessor()
      |> clear_pending_handoff()
    else
      state
    end
  end

  defp cancel_pending_handoff_by_ref(
         %{pending_handoff: %{control_ref: control_ref} = pending} = state,
         downstream,
         control_ref
       ) do
    if is_map(downstream) and handoff_downstream?(pending, downstream) do
      state
      |> abort_pending_predecessor()
      |> clear_pending_handoff()
    else
      state
    end
  end

  defp cancel_pending_handoff_by_ref(state, _downstream, _control_ref), do: state

  defp abort_pending_predecessor(%{active_turn: active_turn} = state) when is_map(active_turn) do
    terminate_predecessor_task(active_turn)

    state
    |> reply_predecessor_once({:error, :client_disconnected})
    |> clear_active_turn()
  end

  defp abort_pending_predecessor(state), do: state

  defp fail_pending_handoff(%{pending_handoff: nil} = state, _reason), do: state

  defp fail_pending_handoff(%{pending_handoff: pending} = state, reason) do
    message =
      {:websocket_owner_handoff_failed, pending.correlation_id, pending.epoch, pending.owner_turn_id, pending.pid, pending.control_ref, reason}

    _result = state.callbacks.downstream_sender.(pending.pid, message)
    clear_pending_handoff(state)
  end

  defp clear_pending_handoff(%{pending_handoff: pending} = state) when is_map(pending) do
    Enum.each([pending.soft_timer_ref, pending.absolute_timer_ref], fn
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ref -> :ok
    end)

    %{state | pending_handoff: nil}
  end

  defp clear_pending_handoff(state), do: state

  defp terminate_predecessor_task(%{native_response_steering: lane}) when is_pid(lane), do: NativeResponseSteering.cancel(lane, :owner_drained)

  defp terminate_predecessor_task(%{task_pid: task_pid}) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
    :ok
  end

  defp terminate_predecessor_task(_active_turn), do: :ok

  # A killed process cannot trap the exit, so its DOWN follows at once; the
  # bound only keeps a lost signal from wedging the owner.
  @predecessor_exit_budget_ms 5_000

  defp terminate_predecessor_task_and_await(%{native_response_steering: lane}) when is_pid(lane), do: NativeResponseSteering.cancel(lane, :owner_drained)

  defp terminate_predecessor_task_and_await(%{task_pid: task_pid}) when is_pid(task_pid) do
    monitor = Process.monitor(task_pid)
    Process.exit(task_pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^task_pid, _reason} -> :ok
    after
      @predecessor_exit_budget_ms ->
        Process.demonitor(monitor, [:flush])
        :ok
    end
  end

  defp terminate_predecessor_task_and_await(_active_turn), do: :ok

  defp active_turn_owner_turn_id(%{task_pid: task_pid}) when is_pid(task_pid), do: task_pid

  defp settle_predecessor_before_retire(%{active_turn: active_turn} = state)
       when is_map(active_turn) do
    state
    |> reply_predecessor_once({:error, :client_disconnected})
    |> clear_active_turn()
  end

  defp settle_predecessor_before_retire(state), do: state

  defp upstream_turn_descriptor(
         state,
         %UpstreamWebsocketSession.Request{payload: payload, message_mapper: mapper} = request
       ) do
    if native_message_mapper?(mapper) do
      with {:ok, decoded} when is_map(decoded) <- CodexPooler.JSON.decode(payload),
           {:ok, %{semantic_turn_key: semantic_turn_key}} <-
             WebsocketTurnIdentity.resolve(decoded, turn_claim_scope(state, decoded)) do
        %{kind: :native, semantic_turn_key: semantic_turn_key}
      else
        _missing_or_invalid -> admission_turn_descriptor(request)
      end
    else
      %{kind: :public}
    end
  end

  defp upstream_turn_descriptor(_state, _payload), do: :unknown

  # A native compaction's upstream body carries no turn metadata, so the owner
  # cannot key it from the body. The released client sends a compaction the
  # moment the previous turn's `response.completed` arrives. When the socket
  # still tracks that turn's response task, it queues the compaction and
  # submits it at dequeue with no owner preflight to record its turn (the
  # anchored compaction is not replay-eligible). The owner then ran it as an
  # `:unknown` turn that no same-turn check (`same_turn_replay`, the take-over
  # digest, a handoff) could match. This was seen on the peer owner, where the
  # previous turn settles later (findings#206 row 206-455). The admission the
  # socket reserved for it names the turn under the socket's own claim scope
  # (the binding the owner checks against the frame's continuity key), and
  # the submission is refused before it runs unless that admission is valid,
  # so the turn is keyed from it: the key the owner preflight records for an
  # unqueued compaction.
  defp admission_turn_descriptor(%UpstreamWebsocketSession.Request{
         native_compaction_capability: %NativeCompactionAdmission.Capability{binding: %NativeCompactionAdmission.Binding{semantic_turn_key: key}}
       })
       when is_binary(key) and byte_size(key) == 32,
       do: %{kind: :native, semantic_turn_key: key}

  defp admission_turn_descriptor(_request), do: :unknown

  # The socket derives a native frame's semantic turn key under
  # `WebsocketCodec.native_turn_claim_scope/2`: an HMAC of Pool, key and thread
  # when the turn metadata names a thread, else the session id. A turn the owner
  # accepts without a preflight descriptor (a frame the socket queued behind a
  # running task and submitted at dequeue) must get the same key, or a
  # same-turn resend of a thread-naming client never matches the running turn
  # (findings#225, row 225-91). The owner has the upstream body only, so a
  # thread named solely in a forwarded header resolves under the session id, as
  # it did before; an owner started without the session's Pool and key (an
  # older start path) keeps the session scope too.
  defp turn_claim_scope(%{turn_claim_session: %{} = session}, decoded) do
    thread_id =
      case decoded do
        %{"client_metadata" => %{"x-codex-turn-metadata" => document}} ->
          NativeTurnContinuation.thread_identity(document)

        _no_turn_metadata ->
          nil
      end

    WebsocketTurnIdentity.claim_scope(session, thread_id)
  end

  defp turn_claim_scope(state, _decoded), do: state.codex_session_id

  defp turn_claim_session(codex_session_id, opts) do
    case {Keyword.get(opts, :pool_id), Keyword.get(opts, :api_key_id)} do
      {pool_id, api_key_id} when is_binary(pool_id) and is_binary(api_key_id) ->
        %{id: codex_session_id, pool_id: pool_id, api_key_id: api_key_id}

      _older_start_path ->
        nil
    end
  end

  defp put_next_turn_descriptor(state, downstream, semantic_turn_key)
       when is_map(downstream) and is_binary(semantic_turn_key) and
              byte_size(semantic_turn_key) == 32 do
    next_turn_descriptor = %{
      downstream: Map.take(downstream, @restore_downstream_keys),
      semantic_turn_key: semantic_turn_key
    }

    %{state | next_turn_descriptor: next_turn_descriptor}
  end

  defp valid_next_replay_descriptor?(descriptor) do
    Map.keys(descriptor) |> Enum.sort() ==
      Enum.sort([
        :semantic_turn_key,
        :replay_claim_digest,
        :authorization_snapshot,
        :request_id,
        :codex_turn_id,
        :model_id,
        :endpoint,
        :attempt_id,
        :replay_generation
      ]) and
      valid_replay_descriptor_identity?(descriptor) and
      valid_replay_descriptor_context?(descriptor)
  end

  defp valid_replay_descriptor_identity?(descriptor) do
    is_binary(descriptor.semantic_turn_key) and byte_size(descriptor.semantic_turn_key) == 32 and
      is_binary(descriptor.replay_claim_digest) and
      byte_size(descriptor.replay_claim_digest) == 32 and
      is_map(descriptor.authorization_snapshot)
  end

  defp valid_replay_descriptor_context?(descriptor) do
    is_binary(descriptor.request_id) and
      (is_nil(descriptor.codex_turn_id) or is_binary(descriptor.codex_turn_id)) and
      is_binary(descriptor.model_id) and is_binary(descriptor.endpoint) and
      is_binary(descriptor.attempt_id) and descriptor.replay_generation in [0, 1]
  end

  defp take_next_turn_descriptor(
         %{
           next_turn_descriptor: %{downstream: expected, semantic_turn_key: semantic_turn_key} = next
         } =
           state,
         downstream,
         upstream_payload
       ) do
    if expected == Map.take(downstream, @restore_downstream_keys) do
      {%{
         kind: :native,
         semantic_turn_key: semantic_turn_key,
         semantic_turn_digest: semantic_turn_key,
         replay_claim_digest: Map.get(next, :replay_claim_digest),
         authorization_snapshot: Map.get(next, :authorization_snapshot),
         request_id: Map.get(next, :request_id),
         codex_turn_id: Map.get(next, :codex_turn_id),
         model_id: Map.get(next, :model_id),
         endpoint: Map.get(next, :endpoint),
         attempt_id: Map.get(next, :attempt_id),
         replay_generation: Map.get(next, :replay_generation, 0),
         visible_output?: false,
         downstream_status: :attached
       }, %{state | next_turn_descriptor: nil}}
    else
      {upstream_turn_descriptor(state, upstream_payload), state}
    end
  end

  defp take_next_turn_descriptor(state, _downstream, upstream_payload),
    do: {upstream_turn_descriptor(state, upstream_payload), state}

  defp pending_submission_descriptor(
         %{next_turn_descriptor: %{downstream: expected, semantic_turn_key: semantic_turn_key}},
         pending,
         downstream,
         _upstream_payload
       ) do
    if expected == Map.take(downstream, @restore_downstream_keys) and
         pending.semantic_turn_key == semantic_turn_key do
      %{kind: :native, semantic_turn_key: semantic_turn_key}
    else
      :unknown
    end
  end

  defp pending_submission_descriptor(state, _pending, _downstream, upstream_payload),
    do: upstream_turn_descriptor(state, upstream_payload)

  defp apply_reconnect_control_v2(state, %RemoteReconnectControlV2{} = control) do
    with :ok <- RemoteReconnectControlV2.validate(control),
         true <- control.codex_session_id == state.codex_session_id,
         true <- control.owner_lease_token == state.owner_lease_token do
      apply_valid_reconnect_control_v2(state, control)
    else
      _invalid -> {:error, :stale_owner}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{active_turn: nil, suspended_replay: nil} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :fresh} = control
       ),
       do: {:ok, {:fresh_dispatch, control.downstream}, state}

  defp apply_valid_reconnect_control_v2(
         %{active_turn: %{descriptor: descriptor} = active_turn} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :active_reattach} = control
       )
       when is_map(descriptor) do
    with {:ok, epoch} <- active_reattach_epoch(state, control.downstream),
         true <- replay_descriptor_match?(descriptor, control),
         true <- descriptor.downstream_status == :lost,
         false <- descriptor.visible_output?,
         true <- Process.alive?(active_turn.task_pid),
         true <-
           active_turn.upstream_pid == state.upstream_pid and Process.alive?(state.upstream_pid),
         false <- active_turn.terminal_forwarded?,
         nil <- active_turn.pending_result,
         {:ok, state} <- cas_active_status(state, descriptor, :reattaching) do
      downstream =
        control.downstream
        |> Map.put(:epoch, epoch)
        |> Map.put(:active_turn_reconnect?, true)

      state = DownstreamState.demonitor_downstream(state)
      monitor = Process.monitor(downstream.pid)
      descriptor = %{state.active_turn.descriptor | downstream_status: :attached}

      active_turn = %{
        state.active_turn
        | downstream: Map.put(downstream, :owner_turn_id, active_turn.task_pid),
          descriptor: descriptor
      }

      {:ok, {:same_turn_reattach, downstream},
       %{
         state
         | active_turn: active_turn,
           downstream: downstream,
           downstream_monitor: monitor,
           downstream_epoch: epoch
       }}
    else
      _failure -> {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :armed} = armed} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if state.handoff_absolute_timeout_ms in 1_000..60_000 do
      issued_at_ms = state.callbacks.monotonic_now_ms.()
      state = prune_provisional_issuances(state, issued_at_ms)

      if length(state.provisional_issuances) < 6 and suspended_preflight_match?(armed, control) and
           control.downstream.epoch == state.downstream_epoch + 1 do
        token = :crypto.strong_rand_bytes(32)
        deadline = issued_at_ms + state.handoff_absolute_timeout_ms

        downstream = %{
          control.downstream
          | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
        }

        suspended =
          armed
          |> Map.put(:downstream, downstream)
          |> Map.put(:provisional_token, token)
          |> Map.put(:provisional_status, :provisional)
          |> Map.put(:deadline_ms, deadline)
          |> Map.put(:consume_binding, nil)
          |> Map.put(:reconciliation_timer_ref, nil)
          |> Map.put(:reconciliation_token, nil)

        next_state =
          state
          |> Map.update!(:provisional_issuances, &[issued_at_ms | &1])
          |> Map.put(:suspended_replay, suspended)
          |> attach_provisional_downstream(downstream)

        {:ok, {:provisional, token, 1, state.process_generation, downstream}, next_state}
      else
        {:error, :owner_busy}
      end
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :provisional} = suspended} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if suspended_preflight_match?(suspended, control) and
         control.downstream.epoch == state.downstream_epoch + 1 do
      downstream = %{
        control.downstream
        | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
      }

      {:ok, {:provisional, suspended.provisional_token, 1, suspended.owner_process_generation, downstream},
       state
       |> put_in([Access.key(:suspended_replay), Access.key(:downstream)], downstream)
       |> attach_provisional_downstream(downstream)}
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: %{provisional_status: :committed_not_started} = suspended} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :suspended_replay} = control
       ) do
    if suspended_preflight_match?(suspended, control) and
         control.downstream.epoch == state.downstream_epoch + 1 do
      downstream = %{
        control.downstream
        | epoch: DownstreamState.next_downstream_epoch(state.downstream_epoch)
      }

      {:ok, {:provisional, suspended.provisional_token, 1, suspended.owner_process_generation, downstream},
       state
       |> put_in([Access.key(:suspended_replay), Access.key(:downstream)], downstream)
       |> attach_provisional_downstream(downstream)}
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_reserve} = control
       )
       when is_map(suspended) do
    reserve_now_ms = state.callbacks.monotonic_now_ms.()

    cond do
      not provisional_match?(suspended, control) ->
        {:error, :owner_busy}

      suspended.provisional_status == :consume_reserved ->
        {:ok, {:consume_reserved, suspended.reserve_timeout_ms, suspended.reserve_receipt, suspended.reserve_receipt_digest}, state}

      suspended.provisional_status == :provisional and
          reserve_now_ms < suspended.deadline_ms ->
        reserve_timeout_ms = suspended.deadline_ms - reserve_now_ms

        if reserve_timeout_ms in 1..60_000 do
          reserve_receipt = :crypto.strong_rand_bytes(32)

          {:ok, reserve_receipt_digest} =
            RequestReplayEntitlement.reserve_receipt_digest(
              suspended.provisional_token,
              reserve_receipt,
              reserve_timeout_ms
            )

          suspended =
            suspended
            |> Map.put(:cleanup_downstream_epoch, suspended.downstream.epoch)
            |> Map.put(:provisional_status, :consume_reserved)
            |> Map.put(:consume_binding, token_reference(suspended))
            |> Map.put(:reserve_timeout_ms, reserve_timeout_ms)
            |> Map.put(:reserve_receipt, reserve_receipt)
            |> Map.put(:reserve_receipt_digest, reserve_receipt_digest)
            |> Map.put(:reserve_receipt_used?, false)
            |> Map.put(:consume_fence, nil)
            |> Map.put(:consume_pid, nil)
            |> Map.put(:consume_monitor, nil)

          next_state = schedule_replay_reconciliation(%{state | suspended_replay: suspended})

          {:ok, {:consume_reserved, reserve_timeout_ms, reserve_receipt, reserve_receipt_digest}, next_state}
        else
          {:error, :owner_busy}
        end

      true ->
        {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_commit} = control
       )
       when is_map(suspended) do
    with true <- provisional_match?(suspended, control),
         true <-
           suspended.provisional_status in [:consume_reserved, :committed_not_started, :started],
         reference = control.consume_binding,
         {:consumed, binding, phase, _abandon_at}
         when phase in [:committed_not_started, :started] <-
           CodexPooler.Accounting.replay_provisional_binding_status(reference),
         true <- binding == reference do
      suspended = %{suspended | provisional_status: phase, consume_binding: binding}

      next_state =
        state
        |> Map.put(:suspended_replay, suspended)
        |> clear_consume_reservation()
        |> cancel_replay_reconciliation()

      {:ok, {phase, binding}, next_state}
    else
      _not_consumed -> {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_query} = control
       )
       when is_map(suspended) do
    if provisional_match?(suspended, control) do
      case reconcile_provisional(state, suspended) do
        {:ok, :terminal, _reconciled} ->
          {:ok, :cancelled, clear_terminal_reconciliation(state)}

        {:ok, status, reconciled} ->
          next_state = maybe_cancel_replay_reconciliation(state, status, reconciled)
          {:ok, status, next_state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :owner_busy}
    end
  end

  defp apply_valid_reconnect_control_v2(
         %{suspended_replay: suspended} = state,
         %RemoteReconnectControlV2{action: :provisional_cancel} = control
       )
       when is_map(suspended) do
    if provisional_match?(suspended, control) do
      suspended = Map.put(suspended, :consume_binding, token_reference(suspended))

      case reconcile_provisional(state, suspended) do
        {:ok, :terminal, _reconciled} ->
          {:ok, :cancelled, clear_terminal_reconciliation(state)}

        {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
          {:ok, status, maybe_cancel_replay_reconciliation(state, status, reconciled)}

        {:ok, status, reconciled} when status in [:provisional, :consume_reserved] ->
          cancel_uncommitted_provisional(state, reconciled)

        {:ok, status, reconciled} when status in [:cancelled, :expired] ->
          {:ok, status, maybe_cancel_replay_reconciliation(state, status, reconciled)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :owner_busy}
    end
  end

  # An owner that holds nothing but the armed entitlement of a turn cut before
  # any output (its task already stopped, nothing in flight upstream, no resend
  # started) meets a different turn from the next socket of the session: the
  # client has moved on (a resumed process, or a new message after an
  # interrupt), and the released client never resends a turn after it started
  # another. The owner retires the entitlement, which settles the interrupted
  # request once (`failed 499`, unknown usage, reservation released), attaches
  # the new socket and lets the turn dispatch. Refusing it `owner_busy` for the
  # whole 30 s claim spent the released CLI's six websocket attempts in about
  # 6.5 s and moved it to HTTPS for the rest of the process (findings#206 row
  # 206-348, measured with Codex 0.156.1 in the P72 rig). The replay's own
  # resend (same semantic turn), a resend in progress, a control from any
  # other epoch and an owner with an active turn keep `owner_busy`; so does a
  # retirement the database refused. An owner node without this clause keeps
  # answering `owner_busy`, which every proxy already handles.
  defp apply_valid_reconnect_control_v2(
         %{active_turn: nil, suspended_replay: %{provisional_status: :armed} = armed} = state,
         %RemoteReconnectControlV2{action: :preflight, intent: :fresh} = control
       ) do
    if superseding_turn?(state, armed, control),
      do: retire_superseded_replay(state, armed, control),
      else: {:error, :owner_busy}
  end

  # A fresh intent means the runtime preflight matched the frame to no recorded
  # turn, and an owner still running or holding a turn cannot take it. That is
  # backpressure from a live owner, so it answers `owner_busy`, the code the
  # legacy preflight and the busy-owner contract give a different identity;
  # `owner_unavailable` stays for an owner that cannot be reached or has no
  # lease. The one exception is a frame that lost a race to its own winner: the
  # runtime read no predecessor, yet the running turn carries this frame's
  # semantic turn and replay claim, so it is a resend of the running turn and
  # the socket answers it as the counted duplicate it is (findings#225, row
  # 225-84). A continuation of the same turn has a different replay claim and
  # stays `owner_busy`.
  defp apply_valid_reconnect_control_v2(
         %{active_turn: active_turn, suspended_replay: suspended_replay},
         %RemoteReconnectControlV2{action: :preflight, intent: :fresh} = control
       )
       when is_map(active_turn) or is_map(suspended_replay) do
    if active_turn_same_request?(active_turn, control),
      do: {:error, :duplicate_active_turn},
      else: {:error, :owner_busy}
  end

  defp apply_valid_reconnect_control_v2(_state, _control), do: {:error, :owner_unavailable}

  # The replacement socket attaches to the owner when it starts, before it sends
  # its reconnect control, and the attach leaves a `:lost` turn detached
  # (`attach_downstream_now/2`); its control then names the downstream the owner
  # already holds at the current epoch, not the next one. Accepting only the
  # next epoch refused every real reattach `owner_busy`, and the lost turn,
  # whose next provider frame could not be delivered, settled
  # `failed owner_busy`, a shape no resend path admits (findings#232 row 232-221:
  # the socket process killed without terminate, local owner; the submitting
  # task survives it). A control sent before any attach keeps the next epoch.
  defp active_reattach_epoch(state, %{epoch: epoch} = downstream) do
    cond do
      epoch == state.downstream_epoch + 1 -> {:ok, DownstreamState.next_downstream_epoch(state.downstream_epoch)}
      epoch == state.downstream_epoch and attached_control_downstream?(state.downstream, downstream) -> {:ok, epoch}
      true -> :error
    end
  end

  defp attached_control_downstream?(%{pid: pid, epoch: epoch, correlation_id: correlation_id}, %{pid: pid, epoch: epoch, correlation_id: correlation_id}),
    do: true

  defp attached_control_downstream?(_attached, _control), do: false

  defp active_turn_same_request?(%{descriptor: %{} = descriptor}, control) do
    secure_digest_match?(Map.get(descriptor, :semantic_turn_digest), control.semantic_turn_digest) and
      secure_digest_match?(Map.get(descriptor, :replay_claim_digest), control.replay_claim_digest)
  end

  defp active_turn_same_request?(_active_turn, _control), do: false

  # The socket that sends the superseding turn is the replacement the owner
  # handed a candidate at the next epoch without attaching it (the armed replay
  # keeps the attach open for the resend), so only that epoch, from the same
  # key and Pool, with a different semantic turn and replay claim, qualifies.
  defp superseding_turn?(state, armed, %RemoteReconnectControlV2{downstream: downstream} = control) do
    is_nil(state.downstream) and is_nil(state.pending_handoff) and not state.draining? and
      downstream.epoch == state.downstream_epoch + 1 and downstream.epoch > armed.predecessor_epoch and
      same_replay_principal?(armed.authorization_snapshot, control.authorization_binding) and
      not secure_digest_match?(armed.semantic_turn_digest, control.semantic_turn_digest) and
      not secure_digest_match?(armed.replay_claim_digest, control.replay_claim_digest)
  end

  defp same_replay_principal?(%{api_key_id: api_key_id, pool_id: pool_id}, %{api_key_id: api_key_id, pool_id: pool_id})
       when is_binary(api_key_id) and is_binary(pool_id),
       do: true

  defp same_replay_principal?(_armed, _presented), do: false

  defp retire_superseded_replay(state, armed, %RemoteReconnectControlV2{downstream: downstream}) do
    case state.callbacks.replay_retirer.(armed.lifecycle) do
      {:ok, disposition} when disposition in [:closed, :noop] ->
        Logger.replay_superseded(state, armed, downstream.epoch, disposition)
        {:ok, {:fresh_dispatch, downstream}, state |> clear_replay_state() |> attach_superseding_downstream(downstream)}

      _refused ->
        {:error, :owner_busy}
    end
  end

  # The socket keeps the candidate the attach handed it while the replay was
  # armed, flagged as a reconnect, and every submission compares that whole
  # stable downstream, so the owner stores it exactly as the provisional
  # replay path does (`attach_provisional_downstream/2`).
  defp attach_superseding_downstream(state, downstream) do
    downstream = downstream |> Map.take(@restore_downstream_keys) |> Map.put(:active_turn_reconnect?, true)

    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.cancel_idle_shutdown()
      |> clear_replaced_downstream_admission(downstream)

    %{state | downstream: downstream, downstream_monitor: Process.monitor(downstream.pid), downstream_epoch: downstream.epoch}
  end

  defp cancel_uncommitted_provisional(state, reconciled) do
    if Map.get(reconciled, :reserve_receipt_used?, false) do
      next_state = schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
      {:ok, :consume_reserved, next_state}
    else
      cancelled = %{reconciled | provisional_status: :cancelled, downstream: nil}
      next_state = maybe_cancel_replay_reconciliation(state, :cancelled, cancelled)
      {:ok, :cancelled, next_state}
    end
  end

  defp reconcile_provisional(state, suspended) do
    case provisional_db_status(state, suspended) do
      {:consumed, binding, phase, _abandon_at}
      when phase in [:committed_not_started, :started] ->
        {:ok, phase, %{suspended | provisional_status: phase, consume_binding: binding}}

      :terminal ->
        {:ok, :terminal, suspended}

      status when status in [:armed, :absent] ->
        cond do
          suspended.provisional_status == :consume_reserved ->
            {:ok, :consume_reserved, suspended}

          suspended.provisional_status == :provisional and
              state.callbacks.monotonic_now_ms.() >= suspended.deadline_ms ->
            {:ok, :expired, %{suspended | provisional_status: :expired, downstream: nil}}

          true ->
            {:ok, suspended.provisional_status, suspended}
        end

      {:error, _reason} ->
        {:error, :owner_busy}
    end
  end

  defp provisional_db_status(
         %{callbacks: %{replay_status_reader: reader}},
         %{consume_binding: %{provisional_token: _token} = reference}
       ),
       do: reader.(reference)

  defp provisional_db_status(_state, %{consume_binding: binding}) when is_map(binding),
    do: CodexPooler.Accounting.replay_provisional_binding_status(binding)

  defp provisional_db_status(_state, _suspended), do: :armed

  defp schedule_replay_reconciliation(state) do
    state = cancel_replay_reconciliation(state)
    token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_replay_reconcile, token},
        state.suspended_replay.reserve_timeout_ms
      )

    suspended =
      state.suspended_replay
      |> Map.put(:reconciliation_timer_ref, timer_ref)
      |> Map.put(:reconciliation_token, token)

    %{state | suspended_replay: suspended}
  end

  defp cancel_replay_reconciliation(%{suspended_replay: suspended} = state)
       when is_map(suspended) do
    case Map.get(suspended, :reconciliation_timer_ref) do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _no_timer -> :ok
    end

    %{state | suspended_replay: clear_replay_reconciliation(suspended)}
  end

  defp cancel_replay_reconciliation(state), do: state

  defp clear_replay_reconciliation(suspended) do
    suspended
    |> Map.put(:reconciliation_timer_ref, nil)
    |> Map.put(:reconciliation_token, nil)
  end

  defp maybe_cancel_replay_reconciliation(state, status, reconciled)
       when status in [:committed_not_started, :started] do
    state
    |> Map.put(:suspended_replay, reconciled)
    |> clear_consume_reservation()
    |> cancel_replay_reconciliation()
  end

  defp maybe_cancel_replay_reconciliation(state, status, reconciled)
       when status in [:cancelled, :expired] do
    retire_replay_state(%{state | suspended_replay: reconciled})
  end

  defp maybe_cancel_replay_reconciliation(state, _status, reconciled),
    do: %{state | suspended_replay: reconciled}

  defp clear_terminal_reconciliation(state) do
    retire_replay_state(state)
  end

  defp retire_replay_state(state) do
    state
    |> clear_replay_state()
    |> DownstreamState.demonitor_downstream()
    |> Map.put(:downstream, nil)
    |> DownstreamState.schedule_idle_shutdown()
  end

  defp clear_replay_state(state) do
    state
    |> clear_native_compaction_admission(:replay_retired)
    |> clear_consume_reservation()
    |> cancel_replay_reconciliation()
    |> Map.put(:suspended_replay, nil)
  end

  defp reconcile_disconnected_provisional(%{suspended_replay: %{provisional_status: status} = suspended} = state)
       when status in [:provisional, :consume_reserved] do
    suspended =
      suspended
      |> Map.put(:consume_binding, token_reference(suspended))
      |> Map.put(:downstream, nil)

    case reconcile_provisional(state, suspended) do
      {:ok, :terminal, _reconciled} ->
        clear_terminal_reconciliation(state)

      {:ok, status, reconciled} when status in [:committed_not_started, :started] ->
        maybe_cancel_replay_reconciliation(state, status, reconciled)

      {:ok, status, reconciled} when status in [:consume_reserved, :provisional] ->
        if Map.get(reconciled, :reserve_receipt_used?, false) do
          schedule_replay_reconciliation(%{state | suspended_replay: reconciled})
        else
          cancel_replay_reconciliation(%{
            state
            | suspended_replay: %{reconciled | provisional_status: :cancelled}
          })
        end

      {:ok, status, reconciled} ->
        maybe_cancel_replay_reconciliation(state, status, reconciled)

      {:error, _reason} ->
        %{state | suspended_replay: suspended}
    end
  end

  defp reconcile_disconnected_provisional(state), do: state

  defp token_reference(%{lifecycle: lifecycle} = suspended) do
    %{
      request_id: lifecycle.request_id,
      codex_turn_id: lifecycle.codex_turn_id,
      eligible_attempt_id: lifecycle.eligible_attempt_id,
      replay_generation: 1,
      owner_lease_digest: lifecycle.owner_lease_digest,
      provisional_token: suspended.provisional_token
    }
  end

  defp flatten_v2_result({:fresh_dispatch, downstream}), do: {:ok, :fresh_dispatch, downstream}

  defp flatten_v2_result({:same_turn_reattach, downstream}),
    do: {:ok, :same_turn_reattach, downstream}

  defp flatten_v2_result({:provisional, token, 1, generation, downstream}),
    do: {:ok, :provisional, token, 1, generation, downstream}

  defp flatten_v2_result({:consume_reserved, timeout, receipt, digest}),
    do: {:ok, :consume_reserved, timeout, receipt, digest}

  defp flatten_v2_result({phase, binding}) when phase in [:committed_not_started, :started],
    do: {:ok, phase, binding}

  defp flatten_v2_result(status), do: {:ok, status}

  defp cas_active_status(%{active_turn: %{descriptor: current}} = state, expected, target)
       when target in [:reattaching, :suspending] do
    allowed_statuses = if target == :suspending, do: [:attached, :lost], else: [:lost]

    if current == expected and Map.get(current, :downstream_status) in allowed_statuses do
      {:ok, put_in(state.active_turn.descriptor.downstream_status, target)}
    else
      {:error, :owner_busy}
    end
  end

  defp cas_active_status(_state, _expected, _target), do: {:error, :owner_busy}

  defp mark_active_downstream_lost(
         %{active_turn: %{descriptor: %{downstream_status: :attached}} = active_turn} = state,
         downstream
       ) do
    if DownstreamState.downstream_status(state.downstream, downstream) == :active and
         active_turn.downstream.pid == downstream.pid and
         active_turn.downstream.epoch == downstream.epoch and
         active_turn.downstream.correlation_id == downstream.correlation_id do
      state =
        state
        |> DownstreamState.demonitor_downstream()
        |> put_in([Access.key(:active_turn), Access.key(:downstream)], nil)
        |> put_in(
          [Access.key(:active_turn), Access.key(:descriptor), Access.key(:downstream_status)],
          :lost
        )
        |> Map.put(:downstream, nil)

      {:ok, state}
    else
      {:error, :stale_downstream}
    end
  end

  defp mark_active_downstream_lost(_state, _downstream), do: {:error, :owner_busy}

  # A descriptor the owner derived itself (a turn accepted without a replay
  # preflight) carries no replay binding, so no control can match it; reading
  # the binding fields off it used to crash the owner with a KeyError
  # (findings#225, row 225-101).
  defp replay_descriptor_match?(descriptor, _control)
       when not is_map_key(descriptor, :authorization_snapshot),
       do: false

  defp replay_descriptor_match?(%{kind: :native_response_steering}, _control), do: false

  defp replay_descriptor_match?(descriptor, control),
    do:
      descriptor.authorization_snapshot == control.authorization_binding and
        secure_digest_match?(descriptor.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(descriptor.replay_claim_digest, control.replay_claim_digest) and
        lifecycle_control_match?(descriptor, control.consume_binding)

  defp lifecycle_control_match?(descriptor, %{
         request_id: request_id,
         codex_turn_id: turn_id,
         eligible_attempt_id: attempt_id,
         replay_generation: generation
       }) do
    descriptor.request_id == request_id and descriptor.codex_turn_id == turn_id and
      descriptor.attempt_id == attempt_id and descriptor.replay_generation == generation
  end

  defp lifecycle_control_match?(_descriptor, _binding), do: false

  defp provisional_match?(suspended, control),
    do:
      secure_digest_match?(suspended.provisional_token, control.provisional_token) and
        secure_digest_match?(suspended.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(suspended.replay_claim_digest, control.replay_claim_digest) and
        provisional_downstream_match?(suspended, control)

  defp provisional_downstream_match?(suspended, %{downstream: nil}),
    do: is_map(suspended)

  defp provisional_downstream_match?(%{downstream: downstream}, %{downstream: downstream}),
    do: true

  defp provisional_downstream_match?(_suspended, _control), do: false

  defp validate_reserve_receipt_proof(proof) do
    required = [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :entitlement_id,
      :owner_lease_token,
      :owner_process_generation,
      :downstream_epoch,
      :reserve_receipt_digest,
      :consumer_pid
    ]

    if Map.keys(proof) |> Enum.sort() == Enum.sort(required) and
         Enum.all?(
           [
             :request_id,
             :codex_turn_id,
             :eligible_attempt_id,
             :entitlement_id,
             :owner_lease_token
           ],
           &uuid?(proof[&1])
         ) and is_pid(proof.consumer_pid) and proof.owner_process_generation > 0 and
         proof.downstream_epoch > 0 and
         is_binary(proof.reserve_receipt_digest) and byte_size(proof.reserve_receipt_digest) == 32 do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp validate_consumed_reserve_receipt_now(state, proof, consume_fence) do
    with :ok <- validate_reserve_receipt_proof(proof),
         true <- proof.owner_lease_token == state.owner_lease_token,
         true <- proof.owner_process_generation == state.process_generation,
         %{
           provisional_status: :consume_reserved,
           reserve_receipt_digest: digest,
           reserve_receipt_used?: true,
           consume_fence: ^consume_fence,
           consume_pid: consumer_pid,
           owner_process_generation: generation,
           downstream: %{epoch: epoch},
           lifecycle: lifecycle
         } <- state.suspended_replay,
         true <- generation == proof.owner_process_generation,
         true <- consumer_pid == proof.consumer_pid,
         true <- epoch == proof.downstream_epoch,
         true <- reserve_lifecycle_matches?(lifecycle, proof),
         true <- secure_digest_match?(digest, proof.reserve_receipt_digest) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp reserve_lifecycle_matches?(lifecycle, proof) do
    lifecycle.request_id == proof.request_id and
      lifecycle.codex_turn_id == proof.codex_turn_id and
      lifecycle.eligible_attempt_id == proof.eligible_attempt_id and
      lifecycle.entitlement_id == proof.entitlement_id
  end

  defp clear_consume_reservation(state, opts \\ []) do
    case state.suspended_replay do
      suspended when is_map(suspended) ->
        demonitor_consume_reservation(suspended, Keyword.get(opts, :demonitor?, true))

        suspended =
          suspended
          |> Map.put(:reserve_receipt_used?, false)
          |> Map.put(:consume_fence, nil)
          |> Map.put(:consume_pid, nil)
          |> Map.put(:consume_monitor, nil)

        %{state | suspended_replay: suspended}

      _no_replay ->
        state
    end
  end

  defp demonitor_consume_reservation(%{consume_monitor: monitor}, demonitor?)
       when is_reference(monitor) and demonitor? not in [false, nil] do
    Process.demonitor(monitor, [:flush])
  end

  defp demonitor_consume_reservation(_suspended, _demonitor?), do: :ok

  defp suspended_preflight_match?(suspended, control),
    do:
      suspended.authorization_snapshot == control.authorization_binding and
        secure_digest_match?(suspended.semantic_turn_digest, control.semantic_turn_digest) and
        secure_digest_match?(suspended.replay_claim_digest, control.replay_claim_digest)

  defp attach_provisional_downstream(state, downstream) do
    state =
      state |> DownstreamState.demonitor_downstream() |> DownstreamState.cancel_idle_shutdown()

    state = put_in(state.suspended_replay[:cleanup_downstream_epoch], downstream.epoch)

    monitor = Process.monitor(downstream.pid)
    downstream = Map.put(downstream, :active_turn_reconnect?, true)

    %{
      state
      | downstream: downstream,
        downstream_monitor: monitor,
        downstream_epoch: downstream.epoch
    }
  end

  # Native collection returns a result bound to its original downstream. A
  # competing socket may be examined by preflight, but cannot steal that
  # binding merely by attaching, even before a replay descriptor is available.
  defp native_collection_active?(%{
         active_turn: %{collect?: true, first_compact_request_identity: identity}
       })
       when is_tuple(identity), do: true

  defp native_collection_active?(_state), do: false

  # A native compaction is never armed for replay (findings#206 row 206-333).
  # The released client resends a compaction it did not complete as full
  # history on new connections, then over HTTPS, and none of those resends
  # redeemed a replay armed for it: with owner forwarding on, a full-history
  # compaction cut before any output stayed `in_progress` for more than 118 s
  # while both websocket resends met `409 duplicate_turn` and the HTTPS
  # fallback bought it again. Left unarmed, it is settled when its socket's
  # detach arrives (about 300 ms after the cut, measured), `client_disconnected`
  # or `succeeded` if the provider finished first, and the resend is chained to
  # it by the compaction retry policy
  # (`ClientRetry.verified_unreceived_compaction?/3`), as with forwarding off.
  defp replay_active?(
         %{
           active_turn: %{
             descriptor:
               %{
                 downstream_status: :attached,
                 replay_claim_digest: digest,
                 authorization_snapshot: authorization,
                 visible_output?: false
               } = descriptor
           }
         },
         downstream
       )
       when is_binary(digest) and byte_size(digest) == 32 and is_map(authorization) and
              is_map(downstream),
       do: Map.get(descriptor, :endpoint) != "/backend-api/codex/responses/compact" and DownstreamState.downstream_status(downstream, downstream) == :active

  defp replay_active?(_state, _downstream), do: false

  # A closing downstream whose own turn the owner has not accepted yet: no
  # active turn, no suspended replay, no handoff or compaction submit hold. The
  # socket's response task may still be reserving or on its way to submit; the
  # ordinary detach only came after the socket's 250 ms drain, so that task was
  # accepted and dispatched to a client that was already gone, and the
  # released client's resend, about 200 ms after the cut, met the owner busy
  # with it (`409 duplicate_turn`) or held by the resend's own handoff, which
  # refused the task `owner_busy` and left a failed turn the resend could not
  # follow (findings#232 rows 232-175 and 232-171, measured at a cut 0 ms after
  # the frame: 30 of 32 runs refused the first resend, 1 of 20 failed the turn
  # over to HTTPS).
  defp idle_closing_downstream?(state, requested_downstream) do
    DownstreamState.downstream_status(state.downstream, requested_downstream) == :active and
      is_nil(state.active_turn) and is_nil(state.suspended_replay) and is_nil(state.pending_handoff) and
      is_nil(state.compaction_retry_submit_hold) and not state.draining?
  end

  # The turn a socket received through its attach (the attach's
  # `active_turn_reconnect?`), still bound to that socket, a native turn with no
  # terminal and nothing half-handed over: either already visible (an ordinary
  # relayed turn, findings#206 row 206-362), or showing nothing yet with no
  # replay to serve its resend (a native compaction), inherited from a socket
  # that had already closed (row 206-436). A pre-visible turn a replay serves is
  # left to that replay (the attach hands such a socket only a candidate, and a
  # lost turn stays detached); a turn taken from a socket that has not closed,
  # and a visible compaction or collected delivery, keep their own lifecycle.
  defp inherited_turn(%{draining?: true}, _requested_downstream), do: {:error, :owner_drained}

  defp inherited_turn(state, requested_downstream) do
    with :active <- DownstreamState.cancellation_status(state, requested_downstream),
         %{active_turn_reconnect?: true} <- state.downstream,
         %{terminal_forwarded?: false, pending_result: nil} = active_turn <- state.active_turn,
         {:ok, semantic_turn_key} <- inherited_turn_key(state, active_turn, requested_downstream),
         true <- not Map.has_key?(active_turn, :canceled_result),
         nil <- state.pending_handoff,
         nil <- state.compaction_retry_submit_hold do
      {:ok, semantic_turn_key}
    else
      {:error, reason} -> {:error, reason}
      _not_inherited -> {:error, :owner_busy}
    end
  end

  # A turn submitted without a preflight descriptor (a compaction dispatched on
  # its admission) keeps `:unknown` when the owner could not key its upstream
  # body; the socket then waits on its own request's semantic turn, which is
  # the one a resend of that turn carries, so the answer names no turn.
  @unknown_turn_key <<0::256>>

  defp inherited_turn_key(_state, %{visible_output?: true, collect?: false, admission_phase: nil, descriptor: %{kind: :native, semantic_turn_key: key}}, _requested_downstream)
       when is_binary(key) and byte_size(key) == 32,
       do: {:ok, key}

  defp inherited_turn_key(state, %{visible_output?: false, descriptor: descriptor}, requested_downstream) do
    if DownstreamState.downstream_status(state.closed_inheritance, requested_downstream) == :active and not replay_active?(state, requested_downstream) do
      case descriptor do
        %{kind: :native, semantic_turn_key: key} when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
        :unknown -> {:ok, @unknown_turn_key}
        _public_or_other -> :error
      end
    else
      :error
    end
  end

  defp inherited_turn_key(_state, _active_turn, _requested_downstream), do: :error

  # A native collection (a full-history compaction, collected with its request
  # identity) is never handed on at an attach: the next socket gets only a
  # candidate at `downstream_epoch + 1`, and the collecting socket stays the
  # downstream until its own detach. The released client sends a compaction
  # as full history on any connection that cannot resolve the anchor, and it
  # retries a failed compaction stream on a new connection about 200 ms after
  # the failure (`compact_remote_v2.rs`). The cut socket's detach comes from
  # its session cleanup, after a 250 ms drain and a cleanup it waits on for
  # only 100 ms. So both websocket retries met the owner busy (`409
  # duplicate_turn`), and the compaction was bought again over HTTPS
  # (findings#206 row 206-454). The requester is that candidate, and the
  # collecting socket has already closed: it announced its close
  # (`closing_downstream`), or the owner handled its exit (no downstream, the
  # collection still bound to it). The owner does what that pending detach
  # would do and attaches the requester. It never takes over a collection
  # whose socket it has not seen close, a visible or terminal one, a result
  # already back, a handoff, a suspended replay, a compaction submit hold or
  # a drain.
  defp closed_socket_collection(%{draining?: true}, _requester), do: :error

  defp closed_socket_collection(state, requester) do
    with %{collect?: true, first_compact_request_identity: identity, visible_output?: false, terminal_forwarded?: false, pending_result: nil, downstream: %{pid: bound_pid} = bound} = active_turn
         when is_tuple(identity) <- state.active_turn,
         false <- Map.has_key?(active_turn, :canceled_result),
         true <- closed_socket?(state, bound),
         true <- requester.epoch == DownstreamState.next_downstream_epoch(state.downstream_epoch) and requester.pid != bound_pid,
         nil <- state.pending_handoff,
         nil <- state.suspended_replay,
         nil <- state.compaction_retry_submit_hold do
      {:ok, bound, collection_turn_key(active_turn.descriptor)}
    else
      _live_or_other -> :error
    end
  end

  defp closed_socket?(%{downstream: nil}, _bound), do: true

  defp closed_socket?(state, bound),
    do: DownstreamState.downstream_status(state.downstream, bound) == :active and DownstreamState.downstream_status(state.closing_downstream, bound) == :active

  defp collection_turn_key(%{kind: :native, semantic_turn_key: key}) when is_binary(key) and byte_size(key) == 32, do: key
  defp collection_turn_key(_unkeyed), do: @unknown_turn_key

  # What the closed socket's own detach does (`detach_active_downstream/2`),
  # done at its retry's request. The retry is then attached as the downstream,
  # exactly as a candidate that retires a superseded replay is attached. The
  # closed socket's late detach then meets another downstream and stays
  # stale, and the cancelled collection settles through its submitter.
  defp take_over_closed_socket_collection(state, bound, requester, semantic_turn_digest) do
    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.cancel_active_turn_downstream(bound, :client_disconnected)
      |> Map.merge(%{downstream: nil, closing_downstream: nil})
      |> clear_native_compaction_admission(:downstream_detached)
      |> maybe_settle_cancelled_without_pending_handoff(:client_disconnected)
      |> attach_superseding_downstream(requester)

    :ok = Logger.closed_socket_collection_taken_over(state, bound.epoch, requester.epoch)

    reply_or_retire(state, {:ok, %{semantic_turn_digest: semantic_turn_digest}})
  end

  defp detach_active_downstream(state, requested_downstream) do
    state =
      state
      |> clear_compaction_retry_submit_hold()
      |> cancel_pending_handoff(requested_downstream, :socket_closed)
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.schedule_idle_shutdown()
      |> DownstreamState.cancel_active_turn_downstream(requested_downstream)
      |> Map.put(:downstream, nil)
      |> reconcile_disconnected_provisional()

    # The client left: after a post-turn compaction the admission is
    # still `pending_final`, and its clear is a detach, not a rejected
    # request (findings#258 row 258-23).
    state =
      state
      |> clear_native_compaction_admission(:downstream_detached)
      |> maybe_settle_cancelled_without_pending_handoff(:client_disconnected)

    reply_or_retire(state, :ok)
  end

  # The turn's terminal already went to this downstream: the client has it (a
  # final provider refusal Codex displayed, or a completed answer), and the
  # upstream task only has its result left to return. Cancelling the task here
  # replaced that result with `client_disconnected`, so a refusal the client
  # received was recorded `499` without its rejection fields when the result
  # was slow (findings#254 row 254-110, production, during a connection-checkout
  # stall). The downstream is detached and the task's own result settles the
  # turn; nothing more is sent upstream for it. The caller already matched
  # `requested` against the owner's current downstream; the active turn must
  # still be bound to that same downstream.
  defp terminal_forwarded_to?(%{active_turn: %{terminal_forwarded?: true, downstream: %{pid: pid, epoch: epoch}}}, %{pid: pid, epoch: epoch}),
    do: true

  defp terminal_forwarded_to?(_state, _requested), do: false

  # A closing socket detaches from its own session cleanup, which `terminate/2`
  # waits on for only 100 ms. A socket without a response task of its own (one
  # that inherited the running turn at its attach) exits right after that wait,
  # so when the cleanup was slower the owner handled the socket's exit first:
  # its monitor drops the downstream and keeps a post-visible turn running, as
  # it must for a socket that died without detaching, whose reconnect can still
  # inherit the turn. The socket's own detach then arrived as
  # `stale_downstream` and nothing cancelled the turn: it ran to the provider's
  # end, and every resend of it met the live predecessor (findings#206). A
  # detach from exactly the downstream the running turn is still bound to,
  # with no downstream attached since, is that socket's detach and is applied;
  # once another socket attached, the turn is that socket's and the late
  # detach stays stale.
  defp detach_downstream_status(state, requested_downstream) do
    case DownstreamState.downstream_status(state.downstream, requested_downstream) do
      {:error, :stale_downstream} = stale ->
        if exited_downstream_of_active_turn?(state, requested_downstream), do: :active, else: stale

      status ->
        status
    end
  end

  defp exited_downstream_of_active_turn?(%{downstream: nil, active_turn: %{downstream: %{} = bound}}, requested_downstream),
    do: DownstreamState.downstream_status(bound, requested_downstream) == :active

  defp exited_downstream_of_active_turn?(_state, _requested_downstream), do: false

  defp detach_after_forwarded_terminal(state) do
    state =
      state
      |> clear_compaction_retry_submit_hold()
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.schedule_idle_shutdown()
      |> put_in([Access.key(:active_turn), Access.key(:downstream)], nil)
      |> Map.put(:downstream, nil)
      |> clear_native_compaction_admission(:downstream_detached)

    reply_or_retire(state, :ok)
  end

  # Detaches it now, as the ordinary detach would after the drain, and fences
  # it: a later submission from it is refused `client_disconnected`, so the
  # task settles a client disconnect this owner sent nothing upstream for, and
  # the resend is admitted as that turn's successor. The downstream can also be
  # one a recovery restored here after the previous owner died with the turn
  # already sent upstream: the fence then stops the recovery's re-submit, the
  # turn settles `usage_unknown` (a settlement with no billed tokens, the same
  # as any dispatch whose owner died before the provider's usage came back)
  # and only the resend is billed, on its own request.
  defp detach_idle_closing_downstream(state, requested_downstream) do
    state =
      state
      |> DownstreamState.demonitor_downstream()
      |> DownstreamState.schedule_idle_shutdown()
      |> Map.put(:downstream, nil)
      |> Map.put(:closed_downstream, requested_downstream)
      |> clear_native_compaction_admission(:downstream_detached)

    reply_or_retire(state, :detached)
  end

  defp suspend_or_detach_downstream(state) do
    if replay_active?(state, state.downstream) do
      case suspend_replay_downstream(state) do
        {:suspended, suspended} ->
          suspended

        {:terminal_won, terminal} ->
          settle_terminal_winner(terminal)

        {:failed, failed} ->
          terminate_predecessor_task(failed.active_turn)
          reply_active_turn(failed, {:error, :client_disconnected})

          failed
          |> DownstreamState.cancel_active_turn_downstream(state.downstream, :client_disconnected)
          |> Map.put(:downstream, nil)
          |> finish_active_turn({:error, :client_disconnected})
      end
    else
      state
      |> clear_native_compaction_admission(:downstream_detached)
      |> cancel_pending_handoff(state.downstream, :socket_closed)
      |> Map.put(:downstream, nil)
      |> Map.put(:downstream_monitor, nil)
      |> DownstreamState.maybe_schedule_idle_shutdown()
    end
  end

  defp handle_monitored_downstream_loss(%{active_turn: %{native_response_steering: lane}} = state, _reason) when is_pid(lane) do
    reason = native_steering_loss_reason(state.active_turn, state.draining?)
    state = DownstreamState.cancel_active_turn_downstream(state, state.downstream, reason)
    state |> DownstreamState.demonitor_downstream() |> Map.put(:downstream, nil)
  end

  defp handle_monitored_downstream_loss(state, reason) do
    cond do
      replay_active?(state, state.downstream) ->
        case mark_active_downstream_lost(state, state.downstream) do
          {:ok, lost} -> remember_loss_reason(lost, reason)
          {:error, _reason} -> suspend_or_detach_downstream(state)
        end

      unreachable_downstream_turn?(state, reason) ->
        state
        |> cancel_turn_of_unreachable_downstream()
        |> suspend_or_detach_downstream()

      true ->
        suspend_or_detach_downstream(state)
    end
  end

  defp retire_lost_native_steering_lane(%{active_turn: active_turn} = state, loss_reason) do
    lane = active_turn.native_response_steering
    reason = native_steering_loss_reason(active_turn, state.draining?)

    # A disconnected lane cannot revoke its producing connection. Use the
    # same request/attempt-bound cancellation it would send, then close the
    # owner's upstream connection before making it available for another turn.
    send(state.upstream_pid, {:upstream_websocket_cancel_steering, lane, {active_turn.admission_request_id, active_turn.admission_attempt_id}, reason})
    _result = invalidate_upstream(state)

    if loss_reason == :noconnection and node(lane) != node(),
      do: record_generation_end(state, "unreachable_downstream_cancelled")

    # The surviving owner holds the admitted tuple and its lease witness. The
    # ordinary owner interruption applies its provenance and idempotency gates;
    # no lane result, delivery receipt or native acknowledgement is invented.
    _result = Persistence.interrupt_codex_session(state, reason)

    if downstream = active_turn.downstream,
      do: state.callbacks.downstream_sender.(downstream.pid, {:native_response_steering_close, lane, 1011, "native response steering unavailable"})

    state
    |> Map.put(:termination_cleanup_witness, active_turn.cleanup_witness)
    |> Map.put(:native_response_steering, nil)
    |> clear_native_compaction_admission(:downstream_cancelled)
    |> clear_active_turn()
  end

  defp native_steering_loss_reason(%{canceled_result: {:error, :owner_drained}}, _draining?), do: :owner_drained
  defp native_steering_loss_reason(_active_turn, true), do: :owner_drained
  defp native_steering_loss_reason(_active_turn, false), do: :client_disconnected

  # The downstream's node became unreachable (a partition, or its VM died)
  # while the turn it asked for was still generating, and no resend can
  # rejoin that turn: it showed output, carries no replay claim, or is a
  # compaction. The turn's executor ran on that node, so nobody can receive
  # the output or settle it. On a partition that node's socket has already
  # closed, interrupted the turn and released this owner's lease, and the
  # client's resend is served by a new owner meanwhile; after the node died,
  # the resend of a turn that showed output meets `lifecycle_conflict`. The
  # owner kept generating to the end, a second generation of the same turn
  # that nobody received or recorded (findings#286). It now cancels the turn
  # the way the socket that takes over an inherited turn does: the upstream
  # request's caller exits and the upstream session closes the request
  # (`request_caller_down`).
  #
  # A pre-visible turn a resend can still rejoin stays `:lost`, as for any
  # other downstream loss: after the node died, a resend that reaches this
  # owner before the turn's first output reattaches to it and receives the
  # whole turn from this one generation (measured). A replay in progress, and
  # a downstream that exits on a reachable node, keep their turn as before.
  defp unreachable_downstream_turn?(%{active_turn: active_turn, downstream: downstream} = state, :noconnection)
       when is_map(active_turn) and is_map(downstream),
       do: is_nil(Map.get(state, :suspended_replay)) and still_generating?(active_turn)

  defp unreachable_downstream_turn?(_state, _reason), do: false

  defp still_generating?(active_turn) do
    not Map.get(active_turn, :terminal_forwarded?, false) and is_nil(Map.get(active_turn, :pending_result)) and
      is_nil(Map.get(active_turn, :output_commit_probe))
  end

  # A `:lost` turn remembers whether its downstream's node became unreachable.
  # Each loss sets it again, so a turn reattached and then lost to a socket
  # that exits on a reachable node is not taken for one lost to a node.
  defp remember_loss_reason(%{active_turn: active_turn} = state, reason) when is_map(active_turn),
    do: %{state | active_turn: Map.put(active_turn, :lost_to_unreachable_node?, reason == :noconnection)}

  defp remember_loss_reason(state, _reason), do: state

  # A pre-visible turn kept `:lost` after its downstream's node became
  # unreachable waits for a resend that rejoins it. Its first client-visible
  # output ends that wait: the owner commits the turn's visibility, and from
  # then on a resend meets `lifecycle_conflict` instead of reattaching. The
  # owner used to generate the rest of the turn to nobody (findings#290). It
  # now cancels it there, as it cancels a turn that had already shown output
  # when its downstream's node went (`cancel_turn_of_unreachable_downstream/1`).
  # A turn lost to a socket that exited on a reachable node keeps generating:
  # that node's task can still settle it.
  defp cancel_unreachable_lost_turn(%{active_turn: active_turn} = state) do
    :ok = Logger.unreachable_lost_turn_cancelled(state)
    terminate_predecessor_task(active_turn)
    :ok = record_generation_end(state, "lost_turn_cancelled_at_output")
    reply_active_turn(state, {:error, :client_disconnected})

    state
    |> finish_active_turn({:error, :client_disconnected})
    |> continue_or_retire()
  end

  defp cancel_turn_of_unreachable_downstream(%{active_turn: active_turn, downstream: downstream} = state) do
    :ok = Logger.unreachable_downstream_turn_cancelled(state, downstream)
    terminate_predecessor_task(active_turn)
    :ok = record_generation_end(state, "unreachable_downstream_cancelled")
    reply_active_turn(state, {:error, :client_disconnected})

    state
    |> DownstreamState.cancel_active_turn_downstream(downstream, :client_disconnected)
    |> finish_active_turn({:error, :client_disconnected})
  end

  # A turn lost to an unreachable node that a resend reattached to delivers
  # its terminal to that socket, never to the attempt's executor on the
  # unreachable node: that executor cannot settle the attempt as a success.
  # A terminal delivered to the attempt's own socket is not recorded, since its
  # executor may still settle it.
  defp record_terminal_delivered_to_reattached(%{active_turn: %{lost_to_unreachable_node?: true, downstream: %{active_turn_reconnect?: true}}} = state, true) do
    :ok = record_generation_end(state, "terminal_delivered_to_reattached")
    state
  end

  defp record_terminal_delivered_to_reattached(state, _terminal?), do: state

  # The end of a generation this owner served for an executor on another
  # node, recorded as the evidence absent-instance recovery takes for a
  # replaced pod (`ForwardedGenerationEnds`, findings#290). A failed write only
  # leaves the attempt to the evidence it had before.
  defp record_generation_end(%{active_turn: %{descriptor: %{attempt_id: attempt_id}}} = state, reason) when is_binary(attempt_id) do
    case ForwardedGenerationEnds.record(attempt_id, reason) do
      :ok -> :ok
      {:error, failure} -> Logger.generation_end_not_recorded(state, reason, failure)
    end
  end

  defp record_generation_end(_state, _reason), do: :ok

  defp suspend_replay_downstream(%{active_turn: %{descriptor: descriptor}} = state) do
    if state.active_turn.terminal_forwarded? or not is_nil(state.active_turn.pending_result) do
      {:terminal_won, state}
    else
      case cas_active_status(state, descriptor, :suspending) do
        {:ok, suspending} -> arm_suspended_replay(suspending, descriptor)
        _failure -> {:failed, state}
      end
    end
  end

  defp arm_suspended_replay(suspending, descriptor) do
    case suspending.callbacks.replay_suspender.(suspend_input(suspending, descriptor)) do
      {:ok, lifecycle} ->
        reply_active_turn(suspending, {:error, :client_disconnected})
        terminate_predecessor_task(suspending.active_turn)
        clear_active_turn_resources(suspending.active_turn)
        :ok = log_abandoned_upstream_close(suspending, :replay_armed)

        suspended = %{
          cleanup_witness: OwnerCleanup.from_owner_state(suspending),
          semantic_turn_digest: descriptor.semantic_turn_digest,
          replay_claim_digest: descriptor.replay_claim_digest,
          authorization_snapshot: descriptor.authorization_snapshot,
          replay_generation: 1,
          downstream: nil,
          predecessor_epoch: suspending.downstream.epoch,
          owner_process_generation: suspending.process_generation,
          provisional_token: nil,
          provisional_status: :armed,
          deadline_ms: nil,
          consume_binding: nil,
          reserve_timeout_ms: nil,
          reserve_receipt: nil,
          reserve_receipt_digest: nil,
          reserve_receipt_used?: false,
          consume_fence: nil,
          consume_pid: nil,
          consume_monitor: nil,
          reconciliation_timer_ref: nil,
          reconciliation_token: nil,
          lifecycle: lifecycle
        }

        {:suspended,
         %{
           suspending
           | active_turn: nil,
             suspended_replay: suspended,
             downstream: nil,
             downstream_monitor: nil
         }}

      {:error, :terminal_won} ->
        {:terminal_won, restore_suspending_descriptor(suspending, descriptor)}

      {:error, _reason} ->
        {:failed, restore_suspending_descriptor(suspending, descriptor)}
    end
  end

  defp detach_replay_downstream(state, requested_downstream, from) do
    case suspend_replay_downstream(state) do
      {:suspended, %{suspended_replay: %{provisional_status: :armed}} = suspended} ->
        suspended = DownstreamState.demonitor_downstream(suspended)
        {:reply, :suspended, suspended}

      {:terminal_won, terminal} ->
        terminal =
          terminal
          |> Map.put(:terminal_winner_detach, %{
            reply_to: from,
            downstream: requested_downstream
          })
          |> settle_terminal_winner()

        {:noreply, terminal}

      {:failed, failed} ->
        terminate_predecessor_task(failed.active_turn)
        reply_active_turn(failed, {:error, :client_disconnected})

        failed =
          failed
          |> DownstreamState.demonitor_downstream()
          |> DownstreamState.cancel_active_turn_downstream(
            requested_downstream,
            :client_disconnected
          )
          |> Map.put(:downstream, nil)
          |> finish_active_turn({:error, :client_disconnected})

        reply_or_retire(failed, :ok)
    end
  end

  defp restore_suspending_descriptor(state, descriptor),
    do: put_in(state.active_turn.descriptor, descriptor)

  defp settle_terminal_winner(%{active_turn: %{pending_result: result}} = state)
       when not is_nil(result),
       do: settle_active_turn(state, result)

  defp settle_terminal_winner(state), do: state

  defp complete_terminal_winner_detach(%{terminal_winner_detach: %{reply_to: reply_to, downstream: downstream}} = state) do
    GenServer.reply(reply_to, :ok)

    state
    |> DownstreamState.demonitor_downstream()
    |> Map.put(:terminal_winner_detach, nil)
    |> Map.put(:downstream, nil)
    |> DownstreamState.cancel_active_turn_downstream(downstream)
    |> DownstreamState.schedule_idle_shutdown()
  end

  defp complete_terminal_winner_detach(state), do: state

  defp suspend_input(state, descriptor) do
    authorization = descriptor.authorization_snapshot

    %{
      api_key_id: authorization.api_key_id,
      pool_id: authorization.pool_id,
      codex_session_id: state.codex_session_id,
      request_id: descriptor.request_id,
      codex_turn_id: descriptor.codex_turn_id,
      eligible_attempt_id: descriptor.attempt_id,
      api_key_runtime_epoch: authorization.api_key_runtime_epoch,
      model_id: descriptor.model_id,
      model_identifier: authorization.model_identifier,
      endpoint: descriptor.endpoint,
      semantic_turn_digest: descriptor.semantic_turn_digest,
      replay_claim_digest: descriptor.replay_claim_digest,
      owner_instance_id: state.owner_instance_id,
      owner_lease_token: state.owner_lease_token,
      predecessor_epoch: state.downstream.epoch,
      failure_reason: :client_disconnected,
      pre_visible_output: true
    }
  end

  defp prune_provisional_issuances(state, now_ms) do
    cutoff = now_ms - 30_000
    %{state | provisional_issuances: Enum.filter(state.provisional_issuances, &(&1 >= cutoff))}
  end

  defp native_message_mapper?(mapper) do
    mapper == (&StreamProtocol.canonicalize_native_codex_responses_json_message/1) or
      mapper == (&StreamProtocol.canonicalize_codex_responses_json_message/1)
  end

  defp output_commit_probe_required?(
         %{active_turn: %{downstream: %{owner_turn_id: owner_turn_id}}},
         {:error, %{transport_failure: transport_failure}}
       )
       when is_pid(owner_turn_id) and is_map(transport_failure) and
              map_size(transport_failure) > 0,
       do: true

  defp output_commit_probe_required?(_state, _result), do: false

  defp collect_request?(%UpstreamWebsocketSession.Request{
         websocket_delivery_mode: mode,
         writer: nil
       })
       when mode in [:collect_compaction, :collect_full_history],
       do: true

  defp collect_request?(_request), do: false

  defp maybe_complete_terminal_delivery(state, terminal?) do
    if terminal? do
      state = put_in(state.active_turn.terminal_forwarded?, true)

      case state.active_turn.pending_result do
        nil -> state
        result -> settle_active_turn(state, result)
      end
    else
      state
    end
  end

  # A terminal the owner could not deliver (its downstream gone, or lost
  # while the turn kept generating for a socket that exited on a reachable
  # node) still carries the provider's verdict and usage. The response task
  # settles the turn from this reply, so the reply keeps the terminal as its
  # body and the settlement reads the usage from it; with the bare reason it
  # recorded the usage unknown and charged the reservation's estimate
  # (findings#270 row 270-293). The map carries the headers and the start flag
  # every task version destructures, so an older task settles it too.
  defp fail_terminal_delivery(state, true, reason, payload) when is_binary(payload),
    do: settle_active_turn(state, {:error, %{reason: reason, body: payload, headers: [], started: false, undelivered_terminal?: true}})

  defp fail_terminal_delivery(state, true, reason, _payload), do: settle_active_turn(state, {:error, reason})
  defp fail_terminal_delivery(state, false, _reason, _payload), do: state

  defp retain_terminal_result(state, result) do
    timer_token = make_ref()
    turn_ref = state.active_turn.ref

    timer_ref =
      Process.send_after(
        self(),
        {:websocket_owner_terminal_delivery_timeout, turn_ref, timer_token},
        state.terminal_delivery_timeout_ms
      )

    active_turn = %{
      state.active_turn
      | pending_result: result,
        terminal_delivery_timeout: {turn_ref, timer_token},
        terminal_delivery_timer_ref: timer_ref
    }

    %{state | active_turn: active_turn}
  end

  defp terminal_bearing_result?({:ok, %{terminal: terminal}}),
    do: terminal in @terminal_result_types

  defp terminal_bearing_result?(_result), do: false

  defp classify_terminal_delivery_frame(true, true), do: :duplicate_terminal
  defp classify_terminal_delivery_frame(true, false), do: {:forward, false}

  defp classify_terminal_delivery_frame(false, terminal?), do: {:forward, terminal?}

  defp terminal_frame?(payload) when is_binary(payload),
    do: match?({:ok, _outcome}, StreamProtocol.terminal_outcome(payload))

  defp terminal_frame?(_payload), do: false

  defp cancel_terminal_delivery_timer(%{terminal_delivery_timer_ref: ref})
       when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_terminal_delivery_timer(_active_turn), do: :ok

  defp cancel_output_commit_probe_timer(%{output_commit_probe: %{timer_ref: ref}})
       when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_output_commit_probe_timer(_active_turn), do: :ok

  defp invalidate_upstream(state) do
    state.callbacks.upstream_invalidator.(state.upstream_pid)
  catch
    :exit, _reason -> {:error, :upstream_websocket_not_connected}
  end

  defp invalidate_owner_upstream(upstream_pid),
    do: UpstreamWebsocketSession.invalidate_connection(upstream_pid)

  defp terminal_delivery_timeout_result do
    {:error,
     %{
       reason: :upstream_websocket_terminal_delivery_timeout,
       transport_failure: %{
         "phase" => "terminal_delivery",
         "reason_class" => "owner_terminal_delivery_timeout",
         "reason" => "upstream_websocket_terminal_delivery_timeout",
         "pre_visible_output" => false,
         "upstream_committed" => true,
         "terminal_seen" => true,
         "terminal_forwarded" => false
       }
     }}
  end

  defp schedule_owner_renewal(
         %{
           owner_renewal_ms: timeout,
           owner_renewal_delay: renewal_delay,
           codex_session_id: session_id
         } = state
       )
       when is_integer(timeout) and timeout > 0 and is_function(renewal_delay, 1) do
    if uuid?(session_id) do
      # The same ttl / 3 cap as the HTTP heartbeat, against the ttl the next
      # renewal writes, so no renewal setting or start option can let a live
      # owner's lease lapse between renewals (findings#206 row 206-499).
      interval = OwnerRenewalSchedule.base_interval_ms(timeout, owner_lease_ttl_ms())
      delay = OwnerRenewalSchedule.bounded_delay(renewal_delay.(interval), interval)

      %{state | owner_renewal_ref: Process.send_after(self(), :renew_owner_lease, delay)}
    else
      state
    end
  end

  defp schedule_owner_renewal(state), do: state

  defp renew_owner_lease(state, schedule_next) do
    :ok = record_renewal_tick(state)

    case Persistence.renew_owner_lease(state) do
      {:ok, state} ->
        state = touch_active_replay_liveness(state)
        {:noreply, schedule_next.(state)}

      {:error, reason} when reason in [:stale_owner, :owner_unavailable] ->
        Logger.owner_renewal_stale(reason, state)

        {:stop, {:shutdown, :stale_owner}, state |> clear_native_compaction_admission(:stale_owner) |> Map.put(:draining?, true)}

      {:error, reason} ->
        Logger.owner_renewal_failed(reason, state)
        {:noreply, schedule_next.(state)}
    end
  end

  # Each renewal tick the owner starts, the regular one and the early checks
  # after an unreachable downstream, is what a socket reads when this owner
  # does not answer its status call in time (`owner_reuse_status/2`). It
  # records that the owner handled the tick, whatever the renewal answers.
  defp record_renewal_tick(state) do
    _updated = Registry.update_value(state.owner_registry, state.codex_session_id, fn _value -> ready_registry_value(state.owner_lease_token) end)
    :ok
  end

  # A downstream on a node this owner can no longer reach (DOWN
  # `:noconnection`) is either a node that died or one cut off by a partition.
  # After a partition, that node's socket closes, interrupts its turn and
  # releases this owner's lease in the same leftovers, and the client's resend
  # is served by a new owner there (findings#286). The owner used to learn
  # that only at its next renewal, up to a renewal interval later, and a turn
  # it kept `:lost` for a resend went on generating to nobody until then. It
  # now checks its lease once that release, a single lease-row write, has had
  # the budget the code gives such a write, and once more after another
  # (`InstancePresence.heartbeat_write_budget_ms/0` each): a released lease
  # stops it as a stale renewal always has. After a node death nobody
  # releases the lease, both checks renew it, and a resend can still reattach
  # to the `:lost` turn.
  #
  # Only the owner's own DOWN starts the checks. A silent partition is noticed
  # on each side on its own, after the distribution tick timeout, so when this
  # owner notices it before the other node has released the lease, the checks
  # find the lease still its own and the regular renewal ends it later, as
  # before.
  defp recheck_lease_after_unreachable_downstream(%{owner_renewal_ref: ref} = state, :noconnection) when is_reference(ref) do
    state
    |> cancel_owner_renewal()
    |> schedule_unreachable_downstream_lease_check(1)
  end

  defp recheck_lease_after_unreachable_downstream(state, _reason), do: state

  defp schedule_unreachable_downstream_lease_check(state, tries_left) do
    message = {:renew_owner_lease, :unreachable_downstream, tries_left}
    %{state | owner_renewal_ref: Process.send_after(self(), message, InstancePresence.heartbeat_write_budget_ms())}
  end

  defp forward_error_body?(%UpstreamWebsocketSession.Request{forward_error_body?: value}),
    do: value

  defp forward_error_body?(_upstream_payload), do: false

  defp cancel_owner_renewal(%{owner_renewal_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | owner_renewal_ref: nil}
  end

  defp cancel_owner_renewal(state), do: state

  defp send_owner_upstream(upstream_pid, payload, _writer) when is_binary(payload) do
    case UpstreamWebsocketSession.send_request_frame(upstream_pid, payload) do
      {:ok, :sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_owner_upstream(upstream_pid, %UpstreamWebsocketSession.Request{} = request, writer) do
    request = %{request | writer: writer}

    case UpstreamWebsocketSession.request(upstream_pid, request) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{transport_failure: transport_failure} = response}
      when is_map(transport_failure) and map_size(transport_failure) > 0 ->
        {:error, response}

      {:error, %{upstream_websocket_connection: connection} = response}
      when is_map(connection) ->
        {:error, response}

      {:error, %{reason: :provider_credits_policy_denied} = denial} ->
        {:error, denial}

      {:error, %{reason: reason}} when is_atom(reason) ->
        {:error, reason}

      {:error, response} when is_map(response) ->
        {:error, response}
    end
  end

  defp close_upstream(close, upstream_pid) when is_function(close, 1) and is_pid(upstream_pid) do
    close.(upstream_pid)
  catch
    :exit, _reason -> :ok
  end

  defp close_upstream(_close, _upstream_pid), do: :ok

  defp owner_renewal_ms do
    OperationalSettings.current().bridge_owner_lease_renewal_seconds * 1_000
  end

  defp owner_lease_ttl_ms do
    OperationalSettings.current().bridge_owner_lease_ttl_seconds * 1_000
  end

  defp touch_active_replay_liveness(%{suspended_replay: %{consume_binding: binding}} = state)
       when is_map(binding) do
    _result = CodexPooler.Accounting.touch_request_replay_liveness(binding)
    state
  end

  defp touch_active_replay_liveness(state), do: state

  defp jittered_owner_renewal_delay(timeout), do: OwnerRenewalSchedule.staggered_delay(timeout)

  @doc false
  # The production upstream boundary, for a test boundary that wraps the real
  # upstream session around one of its steps instead of standing in for it.
  @spec default_upstream_boundary() :: map()
  def default_upstream_boundary, do: upstream_boundary([])

  # `start` runs inside `init/1`, so the session reports every anchor-ending
  # close between requests to this owner (findings#270).
  defp upstream_boundary(opts) do
    Keyword.get_lazy(opts, :upstream, fn ->
      %{
        start: fn -> UpstreamWebsocketSession.start_link(connection_close_subscriber: self(), admission_topology: :forwarded) end,
        send: fn upstream_pid, upstream_payload, writer ->
          send_owner_upstream(upstream_pid, upstream_payload, writer)
        end,
        close: &UpstreamWebsocketSession.close/1,
        live_connection: &UpstreamWebsocketSession.live_connection/1,
        producer_identity: &UpstreamWebsocketSession.producer_identity/1
      }
    end)
  end

  # A boundary without a live connection reader (a test double that is no
  # upstream session) answers as a session that cannot tell: every check that
  # reads the open connection keeps its previous behaviour.
  defp unknown_live_connection(_upstream_pid), do: {:error, :unavailable}

  defp persistence_boundary(opts) do
    Keyword.get_lazy(opts, :persistence, fn ->
      %{
        release_owner_lease: &SessionContinuity.release_owner_lease/4,
        renew_owner_token: &SessionContinuity.renew_owner_token/3,
        interrupt_codex_session: &Interruption.interrupt_codex_session/2
      }
    end)
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(
      value,
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    )
  end

  defp uuid?(_value), do: false

  defp owner_exit_reason(:owner_drained, _state), do: :owner_drained
  defp owner_exit_reason(:stale_owner, _state), do: :stale_owner
  defp owner_exit_reason({:shutdown, :stale_owner}, _state), do: :stale_owner
  defp owner_exit_reason(:normal, %{draining?: true}), do: :owner_drained
  defp owner_exit_reason(:normal, _state), do: :owner_drained
  defp owner_exit_reason(:shutdown, _state), do: :owner_drained
  defp owner_exit_reason({:shutdown, _details}, _state), do: :owner_drained
  defp owner_exit_reason(_reason, _state), do: :owner_crashed

  defp owner_exit_cause(:normal, %{owner_exit_cause: cause})
       when cause in [:idle_expiry, :drain_cut],
       do: cause

  defp owner_exit_cause(_reason, _state), do: nil

  defp owner_error(error)
       when error in [
              :owner_unavailable,
              :stale_owner,
              :owner_forward_timeout,
              :owner_crashed,
              :owner_busy,
              :owner_drained,
              :client_disconnected,
              :upstream_stream_error,
              :upstream_websocket_terminal_delivery_timeout
            ],
       do: error

  defp owner_error({:error, error}), do: owner_error(error)
  defp owner_error(:normal), do: :owner_unavailable
  defp owner_error(_reason), do: :owner_crashed

  defp active_turn_downstream(stable_downstream, downstream) do
    case DownstreamState.downstream_status(stable_downstream, downstream) do
      :active -> validate_active_turn_downstream(stable_downstream, downstream)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_active_turn_downstream(stable_downstream, downstream) do
    cond do
      exact_keys?(stable_downstream, @stable_downstream_keys) and
        exact_keys?(downstream, @public_per_call_downstream_keys) and
        is_pid(Map.get(downstream, :owner_turn_id)) and
          Map.take(downstream, @stable_downstream_keys) == stable_downstream ->
        {:ok, downstream}

      exact_keys?(stable_downstream, @stable_downstream_keys) and
          (exact_keys?(downstream, @stable_downstream_keys) or
             exact_keys?(downstream, @restore_downstream_keys)) ->
        {:ok, stable_downstream}

      true ->
        {:error, :stale_downstream}
    end
  end

  defp exact_keys?(map, keys) when is_map(map) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp exact_keys?(_map, _keys), do: false

  defp recover_expired_slot(%{expired_slot_receipt: receipt} = state, candidate) when is_map(receipt) do
    cleanup = ExpiredOwnerGenerationCleanup

    cond do
      cleanup.receipt_completed?(receipt) ->
        recover_expired_slot(%{state | expired_slot_receipt: nil}, candidate)

      receipt["session_id"] == candidate.session_id and receipt["lease_identity_digest"] == cleanup.digest(candidate.owner_lease_token) and receipt["session_deadline"] == DateTime.to_iso8601(candidate.owner_lease_expires_at) ->
        {recover_retained_expired_receipt(candidate, receipt), state}

      true ->
        {{:error, :owner_unavailable}, state}
    end
  rescue
    _exception -> {{:error, :owner_unavailable}, state}
  end

  defp recover_expired_slot(state, candidate) do
    cleanup = ExpiredOwnerGenerationCleanup

    case cleanup.authorize(state, candidate) do
      {:ok, witness} -> recover_authorized_expired_slot(state, candidate, witness)
      {:error, _reason} = error -> {error, state}
    end
  rescue
    _exception -> {{:error, :owner_unavailable}, state}
  end

  defp recover_retained_expired_receipt(candidate, receipt) do
    with {:ok, ended} <- ExpiredOwnerGenerationCleanup.record_end(receipt, "serialized_connection_closed") do
      ExpiredOwnerGenerationCleanup.sql_phase(fn -> Interruption.recover_stopped_owner_request(ended, expired_slot_options(candidate, receipt)) end) |> unwrap_expired_sql_result()
    end
  end

  defp recover_authorized_expired_slot(state, candidate, witness) do
    cleanup = ExpiredOwnerGenerationCleanup
    task = state.active_turn.task_pid
    monitor = Process.monitor(task)
    signal_key = {__MODULE__, :expired_slot_signal}
    proof_key = {__MODULE__, :expired_slot_proof}
    Process.put(signal_key, false)
    Process.put(proof_key, nil)

    try do
      signal = fn ->
        if not Process.alive?(task), do: Repo.rollback({:stale_owner, :task_before_signal})
        :ok = DownstreamState.cancel_active_turn_task(state.active_turn)
        cleanup.signal_issued()
      end

      result =
        with :ok <- cleanup.checkpoint(:authorized, witness),
             {:ok, :ok} <- cleanup.signal_authorized(state, candidate, witness, signal),
             :ok <- await_expired_slot_end(monitor, task, state.active_turn.task_ref, state.upstream_pid),
             {:ok, ended} <- record_expired_slot_end(witness, proof_key) do
          :ok = cleanup.checkpoint(:ended, ended)
          opts = expired_slot_options(candidate, witness)

          case cleanup.sql_phase(fn -> Interruption.recover_expired_owner_lifecycle(candidate, opts) end) do
            {:ok, {:ok, :stale_owner}} -> cleanup.sql_phase(fn -> Interruption.recover_stopped_owner_request(ended, opts) end) |> unwrap_expired_sql_result()
            {:ok, result} -> result
            result -> result
          end
        end

      case result do
        {:preserved_terminal, terminal} ->
          Process.demonitor(state.active_turn.task_ref, [:flush])
          send(self(), {state.active_turn.task_ref, terminal})
          {{:ok, :stale_owner}, state}

        result ->
          result = clear_failed_unsignalled_authorization(result, state, witness, Process.get(signal_key))
          {result, expired_slot_reply_state(state, witness, Process.get(signal_key))}
      end
    rescue
      _exception -> {{:error, :owner_unavailable}, expired_slot_reply_state(state, witness, Process.get(signal_key))}
    after
      Process.delete(signal_key)
      Process.delete(proof_key)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp clear_failed_unsignalled_authorization({:error, _reason} = error, state, witness, false) do
    case ExpiredOwnerGenerationCleanup.clear_unsignalled_authorization(state, witness) do
      {:ok, :cleared} -> error
      {:error, _unresolved} = failure -> failure
    end
  end

  defp clear_failed_unsignalled_authorization(result, _state, _witness, _signal_issued), do: result

  defp record_expired_slot_end(witness, proof_key) do
    Process.put(proof_key, witness)
    :ok = ExpiredOwnerGenerationCleanup.checkpoint(:physical_end, witness)
    ExpiredOwnerGenerationCleanup.record_end(witness, "serialized_connection_closed")
  end

  defp expired_slot_options(candidate, witness) do
    %{}
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_transport(websocket_owner_lease_token: candidate.owner_lease_token)
    |> RequestOptions.put_runtime_context(reason_held_request_id: witness["request_id"])
  end

  defp await_expired_slot_end(monitor, task, task_ref, upstream) do
    case exact_queued_success(task_ref) do
      {:ok, _response} = terminal -> {:preserved_terminal, terminal}
      :none -> await_expired_task_down(monitor, task, task_ref, upstream)
    end
  end

  defp await_expired_task_down(monitor, task, task_ref, upstream) do
    cleanup = ExpiredOwnerGenerationCleanup

    receive do
      {:DOWN, ^monitor, :process, ^task, _reason} ->
        case exact_queued_success(task_ref) do
          {:ok, _response} = terminal ->
            {:preserved_terminal, terminal}

          :none ->
            case if(cleanup.remaining_ms() >= 1_000, do: UpstreamWebsocketSession.live_connection(upstream), else: {:error, :unavailable}) do
              {:ok, %{generation: nil}} -> :ok
              _unproved -> {:error, :owner_unavailable}
            end
        end
    after
      max(cleanup.remaining_ms() - 1_250, 0) ->
        case exact_queued_success(task_ref) do
          {:ok, _response} = terminal -> {:preserved_terminal, terminal}
          :none -> {:error, :owner_unavailable}
        end
    end
  end

  defp exact_queued_success(task_ref) do
    receive do
      {^task_ref, {:ok, %{terminal: terminal}} = result} when terminal in ["response.completed", "response.done"] -> result
    after
      0 -> :none
    end
  end

  defp unwrap_expired_sql_result({:ok, result}), do: result
  defp unwrap_expired_sql_result(error), do: error

  defp expired_slot_reply_state(state, witness, true) do
    error = %{body: "", reason: :owner_unavailable, headers: [], started: false, expired_owner_stop_disposition: ExpiredOwnerGenerationCleanup.disposition(witness)}
    %{state | active_turn: Map.put(state.active_turn, :canceled_result, {:error, error}), expired_slot_receipt: Process.get({__MODULE__, :expired_slot_proof})}
  end

  defp expired_slot_reply_state(state, _witness, _not_signalled), do: state

  defp owner_call_timeout, do: WebsocketOwnerContract.default_owner_call_timeout_ms()

  # Test-facing knob for the output-commit probe budget; production callers
  # never pass it, so the owner keeps the forward timeout unless the override
  # is a positive integer.
  defp output_commit_probe_timeout_ms(opts) do
    case Keyword.get(opts, :output_commit_probe_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _absent_or_invalid -> WebsocketOwnerContract.default_forward_timeout_ms()
    end
  end

  # Test-facing knob for how long a retained terminal-bearing task result waits
  # for its terminal frame to reach the downstream; production callers never
  # pass it, so the owner keeps the one second default unless the override is
  # a positive integer.
  defp terminal_delivery_timeout_ms(opts) do
    case Keyword.get(opts, :terminal_delivery_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _absent_or_invalid -> @terminal_delivery_timeout_ms
    end
  end

  defp apply_native_steering_owner_success(state, {:ok, %{native_response_steering_acknowledgement: {:ok, binding, %OrdinarySuccessResult{} = receipt}}}) do
    if receipt.owner == state.upstream_pid and is_nil(state.active_turn) and is_map(state.downstream) do
      topology = WebsocketOwnerAdmissionControlV1.forwarded_topology(state.owner_instance_id, state.owner_lease_token, state.downstream.epoch)
      binding = %{binding | topology: topology}

      with {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
           {:ok, admission} <- NativeCompactionAdmission.arm_compact(admission, System.system_time(:millisecond) + NativeCompactionAdmission.reservation_ttl_ms()) do
        %{put_admission(state, admission) | ordinary_success_result: nil, native_compaction_admission_downstream: stable_downstream(state.downstream)}
      else
        _invalid -> state
      end
    else
      state
    end
  end

  defp apply_native_steering_owner_success(state, _result), do: state
end
