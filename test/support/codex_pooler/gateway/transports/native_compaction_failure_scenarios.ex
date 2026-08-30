defmodule CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios do
  @moduledoc false

  alias __MODULE__.{
    AccountingLifecycle,
    Context,
    DirectSessionBoundary,
    ForwardedOwnerBoundary,
    Observed,
    Row,
    RuntimeBoundary
  }

  defmodule AccountingLifecycle do
    @moduledoc false

    @enforce_keys [:requests, :attempts, :turns, :reservations, :settlements]
    defstruct [:requests, :attempts, :turns, :reservations, :settlements]

    @type t :: %__MODULE__{
            requests: non_neg_integer(),
            attempts: non_neg_integer(),
            turns: non_neg_integer(),
            reservations: non_neg_integer(),
            settlements: non_neg_integer()
          }
  end

  defmodule Context do
    @moduledoc false

    @enforce_keys [:test_pid, :scenario_namespace]
    defstruct [
      :test_pid,
      :sandbox_owner,
      :scenario_namespace,
      :runtime_fixture,
      :upstream,
      :peer,
      :cleanup_registry
    ]

    @type t :: %__MODULE__{
            test_pid: pid(),
            sandbox_owner: pid() | nil,
            scenario_namespace: String.t(),
            runtime_fixture: map() | nil,
            upstream: term() | nil,
            peer: term() | nil,
            cleanup_registry: pid() | reference() | nil
          }
  end

  defmodule AccountingHandle do
    @moduledoc false

    @enforce_keys [:correlation_id]
    defstruct [
      :correlation_id,
      :request_id,
      :attempt_id,
      :turn_id,
      :baseline,
      :resource,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            correlation_id: String.t(),
            request_id: Ecto.UUID.t() | nil,
            attempt_id: Ecto.UUID.t() | nil,
            turn_id: Ecto.UUID.t() | nil,
            baseline: AccountingLifecycle.t() | nil,
            resource: map() | nil,
            metadata: map()
          }
  end

  defmodule Observed do
    @moduledoc false

    @enforce_keys [
      :admission_phase,
      :upstream_send_count,
      :accounting_lifecycle,
      :owner_fate
    ]
    defstruct [
      :admission_phase,
      :upstream_send_count,
      :accounting_lifecycle,
      :owner_fate,
      metadata: %{}
    ]

    @type owner_fate :: :survived | :retired
    @type bounded_metadata_value :: atom() | boolean() | integer() | String.t() | nil
    @type t :: %__MODULE__{
            admission_phase: atom(),
            upstream_send_count: non_neg_integer(),
            accounting_lifecycle: AccountingLifecycle.t(),
            owner_fate: owner_fate(),
            metadata: %{optional(atom() | String.t()) => bounded_metadata_value()}
          }
  end

  defmodule Row do
    @moduledoc false

    @enforce_keys [:id, :family, :variant, :provider, :expected]
    defstruct [:id, :family, :variant, :provider, :expected]

    @type family :: :runtime_boundary | :direct_session_boundary | :forwarded_owner_boundary
    @type provider :: {module(), atom()}
    @type t :: %__MODULE__{
            id: atom(),
            family: family(),
            variant: atom(),
            provider: provider(),
            expected: Observed.t()
          }
  end

  @required_row_ids [
    :validation_admission_overload,
    :routing_denial,
    :saved_reset,
    :accounting_reservation_failure,
    :pre_commit_cancellation,
    :caller_death_before_accounting,
    :caller_death_after_accounting,
    :caller_death_after_send,
    :socket_disconnect,
    :owner_timeout,
    :owner_crash,
    :owner_drain,
    :pending_handoff,
    :handoff_soft_timeout,
    :handoff_absolute_timeout,
    :stale_lease,
    :stale_epoch,
    :stale_token,
    :stale_control,
    :reconnect_before_send,
    :generation_replacement_before_send,
    :send_failure,
    :terminal_failure,
    :finalization_failure,
    :compact_collection,
    :compact_ack_success,
    :compact_ack_failure,
    :final_success,
    :final_failure
  ]

  @spec required_row_ids() :: [atom()]
  def required_row_ids, do: @required_row_ids

  @spec rows() :: [Row.t()]
  def rows do
    [
      row(:validation_admission_overload, :runtime_boundary, RuntimeBoundary, :cleared, 0, 0),
      row(:routing_denial, :runtime_boundary, RuntimeBoundary, :cleared, 0, 0),
      row(:saved_reset, :runtime_boundary, RuntimeBoundary, :cleared, 0, 0),
      row(:accounting_reservation_failure, :runtime_boundary, RuntimeBoundary, :cleared, 0, 0),
      row(:caller_death_before_accounting, :runtime_boundary, RuntimeBoundary, :cleared, 0, 0),
      row(
        :pre_commit_cancellation,
        :direct_session_boundary,
        DirectSessionBoundary,
        :pending_compact,
        0,
        0
      ),
      row(
        :caller_death_after_send,
        :direct_session_boundary,
        DirectSessionBoundary,
        :cleared,
        1,
        1
      ),
      row(:stale_token, :direct_session_boundary, DirectSessionBoundary, :cleared, 0, 1),
      row(
        :reconnect_before_send,
        :direct_session_boundary,
        DirectSessionBoundary,
        :cleared,
        0,
        1
      ),
      row(
        :generation_replacement_before_send,
        :direct_session_boundary,
        DirectSessionBoundary,
        :cleared,
        0,
        1
      ),
      row(:send_failure, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(:terminal_failure, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(:finalization_failure, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(
        :compact_collection,
        :direct_session_boundary,
        DirectSessionBoundary,
        :collected_unconfirmed,
        1,
        1
      ),
      row(
        :compact_ack_success,
        :direct_session_boundary,
        DirectSessionBoundary,
        :pending_final,
        1,
        1
      ),
      row(:compact_ack_failure, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(:final_success, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(:final_failure, :direct_session_boundary, DirectSessionBoundary, :cleared, 1, 1),
      row(
        :caller_death_after_accounting,
        :forwarded_owner_boundary,
        ForwardedOwnerBoundary,
        :cleared,
        0,
        1
      ),
      row(:socket_disconnect, :forwarded_owner_boundary, ForwardedOwnerBoundary, :cleared, 0, 1),
      row(:owner_timeout, :forwarded_owner_boundary, ForwardedOwnerBoundary, :cleared, 0, 1),
      retired_row(:owner_crash, 0, 1),
      retired_row(:owner_drain, 0, 1),
      row(:pending_handoff, :forwarded_owner_boundary, ForwardedOwnerBoundary, :cleared, 0, 0),
      row(
        :handoff_soft_timeout,
        :forwarded_owner_boundary,
        ForwardedOwnerBoundary,
        :cleared,
        0,
        0
      ),
      retired_row(:handoff_absolute_timeout, 0, 1),
      retired_row(:stale_lease, 0, 0),
      row(:stale_epoch, :forwarded_owner_boundary, ForwardedOwnerBoundary, :cleared, 0, 0),
      row(:stale_control, :forwarded_owner_boundary, ForwardedOwnerBoundary, :cleared, 0, 0)
    ]
  end

  @spec context(map(), Row.t()) :: Context.t()
  def context(test_context, %Row{id: id}) when is_map(test_context) do
    unique = System.unique_integer([:positive, :monotonic])

    %Context{
      test_pid: self(),
      sandbox_owner: Map.get(test_context, :sandbox_owner),
      scenario_namespace: "#{id}-#{unique}",
      runtime_fixture: Map.get(test_context, :runtime_fixture),
      upstream: Map.get(test_context, :upstream),
      peer: Map.get(test_context, :peer),
      cleanup_registry: Map.get(test_context, :cleanup_registry)
    }
  end

  @spec run!(Row.t(), Context.t()) :: Observed.t()
  def run!(%Row{provider: {module, function}, variant: variant}, %Context{} = context) do
    unless callable?(module, function) do
      raise ArgumentError,
            "native compaction failure provider is not callable: #{inspect(module)}.#{function}/2"
    end

    module
    |> apply(function, [variant, context])
    |> validate_observed!()
  end

  @spec assert_complete!([Row.t()]) :: :ok
  def assert_complete!(rows \\ rows()) do
    ids = Enum.map(rows, & &1.id)

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "native compaction failure row registry contains duplicate ids"
    end

    if Enum.sort(ids) != Enum.sort(@required_row_ids) do
      raise ArgumentError, "native compaction failure row registry is incomplete"
    end

    Enum.each(rows, fn %Row{provider: {module, function}} ->
      unless callable?(module, function) do
        raise ArgumentError,
              "native compaction failure provider is not callable: #{inspect(module)}.#{function}/2"
      end
    end)

    :ok
  end

  @spec validate_observed!(term()) :: Observed.t()
  def validate_observed!(
        %Observed{
          admission_phase: phase,
          upstream_send_count: sends,
          accounting_lifecycle: %AccountingLifecycle{} = accounting,
          owner_fate: owner_fate,
          metadata: metadata
        } = observed
      )
      when is_atom(phase) and is_integer(sends) and sends >= 0 and
             owner_fate in [:survived, :retired] and is_map(metadata) do
    validate_accounting!(accounting)
    validate_metadata!(metadata)
    observed
  end

  def validate_observed!(observed) do
    raise ArgumentError, "malformed native compaction observation: #{inspect(observed)}"
  end

  defp row(id, family, provider, phase, sends, accounting_count) do
    %Row{
      id: id,
      family: family,
      variant: id,
      provider: {provider, :run},
      expected: observed(phase, sends, accounting_count, :survived)
    }
  end

  defp retired_row(id, sends, accounting_count) do
    %Row{
      id: id,
      family: :forwarded_owner_boundary,
      variant: id,
      provider: {ForwardedOwnerBoundary, :run},
      expected: observed(:destroyed_with_owner, sends, accounting_count, :retired)
    }
  end

  defp observed(phase, sends, accounting_count, owner_fate) do
    %Observed{
      admission_phase: phase,
      upstream_send_count: sends,
      accounting_lifecycle: lifecycle(accounting_count),
      owner_fate: owner_fate
    }
  end

  defp lifecycle(count) do
    %AccountingLifecycle{
      requests: count,
      attempts: count,
      turns: count,
      reservations: count,
      settlements: count
    }
  end

  defp validate_accounting!(%AccountingLifecycle{} = accounting) do
    accounting
    |> Map.from_struct()
    |> Enum.each(fn
      {_field, count} when is_integer(count) and count >= 0 -> :ok
      {field, count} -> raise ArgumentError, "invalid accounting delta #{field}=#{inspect(count)}"
    end)
  end

  defp validate_metadata!(metadata) when map_size(metadata) <= 8 do
    Enum.each(metadata, &validate_metadata_entry!/1)
  end

  defp validate_metadata!(metadata) do
    raise ArgumentError,
          "too many native compaction observation metadata fields: #{map_size(metadata)}"
  end

  defp validate_metadata_entry!({key, value} = entry) do
    unless bounded_metadata_key?(key) and bounded_metadata_value?(value) do
      raise ArgumentError, "unbounded native compaction observation metadata: #{inspect(entry)}"
    end
  end

  defp bounded_metadata_key?(key) when is_atom(key), do: true
  defp bounded_metadata_key?(key) when is_binary(key), do: byte_size(key) <= 80
  defp bounded_metadata_key?(_key), do: false

  defp bounded_metadata_value?(value)
       when is_atom(value) or is_boolean(value) or is_integer(value) or is_nil(value),
       do: true

  defp bounded_metadata_value?(value) when is_binary(value), do: byte_size(value) <= 160
  defp bounded_metadata_value?(_value), do: false

  defp callable?(module, function) do
    match?({:module, ^module}, Code.ensure_loaded(module)) and
      function_exported?(module, function, 2)
  end
end
