defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1 do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult
  alias NativeCompactionAdmission.{Binding, Capability, Confirmation}
  alias NativeCompactionAdmission.Topology.Forwarded

  @version 1
  @actions [
    :snapshot,
    :record_ordinary_success,
    :authorize_first_compact_collection,
    :record_first_compact_collected,
    :reserve,
    :mark_accounting_started,
    :cancel,
    :finalization_ack,
    :clear
  ]
  @fields [
    :version,
    :action,
    :downstream,
    :binding,
    :phase,
    :control_ref,
    :capability,
    :disposition,
    :success?,
    :compaction_item_digest,
    :confirmation,
    :first_compact_collection,
    :expires_at_ms,
    :now_ms
  ]
  @downstream_fields [:pid, :epoch, :correlation_id]

  @enforce_keys @fields
  defstruct @fields

  @type action ::
          :snapshot
          | :record_ordinary_success
          | :authorize_first_compact_collection
          | :record_first_compact_collected
          | :reserve
          | :mark_accounting_started
          | :cancel
          | :finalization_ack
          | :clear

  @type t :: %__MODULE__{
          version: 1,
          action: action(),
          downstream: map(),
          binding: Binding.t() | nil,
          phase: :compact | :final | nil,
          control_ref: reference() | nil,
          capability: Capability.t() | nil,
          disposition: :pre_accounting | nil,
          success?: boolean() | nil,
          compaction_item_digest: <<_::256>> | nil,
          confirmation: Confirmation.t() | nil,
          first_compact_collection:
            NativeCompactionAdmission.FirstCompactCollection.t()
            | NativeCompactionAdmission.FirstCompactResult.t()
            | OrdinarySuccessResult.t()
            | nil,
          expires_at_ms: non_neg_integer() | nil,
          now_ms: non_neg_integer() | nil
        }

  @type validation_error :: {:unknown_fields, [atom() | String.t()]} | {:invalid_field, atom()}

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) do
    with false <- is_struct(attrs),
         :ok <- reject_unknown_fields(attrs),
         :ok <- require_fields(attrs),
         control = struct!(__MODULE__, attrs),
         :ok <- validate(control) do
      {:ok, control}
    else
      true -> {:error, {:invalid_field, :envelope}}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = control) do
    with :ok <- reject_unknown_fields(Map.delete(control, :__struct__)),
         :ok <- validate_common(control),
         do: validate_action(control)
  end

  def validate(_control), do: {:error, {:invalid_field, :envelope}}

  @spec actions() :: [action()]
  def actions, do: @actions

  @spec forwarded_topology(binary(), binary(), pos_integer()) :: Forwarded.t()
  def forwarded_topology(owner_instance_id, owner_lease_token, downstream_epoch)
      when is_binary(owner_instance_id) and is_binary(owner_lease_token) and
             is_integer(downstream_epoch) and downstream_epoch > 0 do
    %Forwarded{
      owner_instance_digest: owner_digest(:owner_instance, owner_instance_id),
      downstream_epoch: downstream_epoch,
      owner_lease_digest: owner_digest(:owner_lease, owner_lease_token)
    }
  end

  @spec topology_matches?(Forwarded.t(), binary(), binary(), pos_integer()) :: boolean()
  def topology_matches?(%Forwarded{} = topology, owner_instance_id, owner_lease_token, epoch)
      when is_binary(owner_instance_id) and is_binary(owner_lease_token) and is_integer(epoch) do
    topology.downstream_epoch == epoch and
      secure_digest_match?(
        owner_digest(:owner_instance, owner_instance_id),
        topology.owner_instance_digest
      ) and
      secure_digest_match?(
        owner_digest(:owner_lease, owner_lease_token),
        topology.owner_lease_digest
      )
  end

  def topology_matches?(_topology, _owner_instance_id, _owner_lease_token, _epoch), do: false

  defp validate_common(%__MODULE__{version: @version, action: action, downstream: downstream})
       when action in @actions do
    if valid_downstream?(downstream), do: :ok, else: {:error, {:invalid_field, :downstream}}
  end

  defp validate_common(%__MODULE__{version: version}) when version != @version,
    do: {:error, {:invalid_field, :version}}

  defp validate_common(_control), do: {:error, {:invalid_field, :action}}

  defp validate_action(%__MODULE__{action: :snapshot} = control),
    do: require_nil(control, @fields -- [:version, :action, :downstream])

  defp validate_action(%__MODULE__{action: :record_ordinary_success} = control) do
    with :ok <- require_binding(control.binding),
         :ok <- require_ordinary_success_result(control.first_compact_collection),
         :ok <- require_non_neg_integer(control.expires_at_ms, :expires_at_ms) do
      require_nil(
        control,
        [
          :phase,
          :control_ref,
          :capability,
          :disposition,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :now_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :reserve} = control) do
    with :ok <- require_binding(control.binding),
         :ok <- require_member(control.phase, [:compact, :final], :phase),
         :ok <- require_reference(control.control_ref, :control_ref),
         :ok <- require_non_neg_integer(control.now_ms, :now_ms) do
      require_nil(
        control,
        [
          :capability,
          :disposition,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :first_compact_collection,
          :expires_at_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :authorize_first_compact_collection} = control) do
    with :ok <- require_binding(control.binding),
         :ok <- require_reference(control.control_ref, :control_ref),
         :ok <- require_first_compact_result(control.first_compact_collection) do
      require_nil(
        control,
        [
          :phase,
          :capability,
          :disposition,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :expires_at_ms,
          :now_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :record_first_compact_collected} = control) do
    with :ok <- require_first_compact_collection(control.first_compact_collection) do
      require_nil(
        control,
        [
          :binding,
          :phase,
          :control_ref,
          :capability,
          :disposition,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :expires_at_ms,
          :now_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :mark_accounting_started} = control) do
    with :ok <- require_capability(control.capability),
         :ok <- require_non_neg_integer(control.now_ms, :now_ms) do
      require_nil(
        control,
        [
          :binding,
          :phase,
          :control_ref,
          :disposition,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :first_compact_collection,
          :expires_at_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :cancel} = control) do
    with :ok <- require_capability(control.capability),
         :ok <- require_member(control.disposition, [:pre_accounting], :disposition),
         :ok <- require_non_neg_integer(control.now_ms, :now_ms) do
      require_nil(
        control,
        [
          :binding,
          :phase,
          :control_ref,
          :success?,
          :compaction_item_digest,
          :confirmation,
          :first_compact_collection,
          :expires_at_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :finalization_ack, success?: true} = control) do
    with :ok <- require_digest(control.compaction_item_digest, :compaction_item_digest),
         :ok <- require_confirmation(control.confirmation),
         :ok <- require_non_neg_integer(control.expires_at_ms, :expires_at_ms) do
      require_nil(
        control,
        [
          :binding,
          :phase,
          :control_ref,
          :capability,
          :disposition,
          :first_compact_collection,
          :now_ms
        ]
      )
    end
  end

  defp validate_action(%__MODULE__{action: :finalization_ack, success?: false} = control) do
    require_nil(
      control,
      [
        :binding,
        :phase,
        :control_ref,
        :capability,
        :disposition,
        :compaction_item_digest,
        :confirmation,
        :first_compact_collection,
        :expires_at_ms,
        :now_ms
      ]
    )
  end

  defp validate_action(%__MODULE__{action: :finalization_ack}),
    do: {:error, {:invalid_field, :success?}}

  defp validate_action(%__MODULE__{action: :clear, capability: %Capability{}} = control),
    do: require_nil(control, @fields -- [:version, :action, :downstream, :capability])

  defp validate_action(%__MODULE__{action: :clear} = control),
    do: require_nil(control, @fields -- [:version, :action, :downstream])

  defp require_nil(control, fields) do
    case Enum.find(fields, &(not is_nil(Map.fetch!(control, &1)))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end

  defp require_binding(%Binding{}), do: :ok
  defp require_binding(_binding), do: {:error, {:invalid_field, :binding}}
  defp require_capability(%Capability{}), do: :ok
  defp require_capability(_capability), do: {:error, {:invalid_field, :capability}}
  defp require_confirmation(%Confirmation{}), do: :ok
  defp require_confirmation(_confirmation), do: {:error, {:invalid_field, :confirmation}}

  defp require_first_compact_collection(%NativeCompactionAdmission.FirstCompactCollection{}),
    do: :ok

  defp require_first_compact_collection(_value),
    do: {:error, {:invalid_field, :first_compact_collection}}

  defp require_first_compact_result(%NativeCompactionAdmission.FirstCompactResult{}), do: :ok

  defp require_first_compact_result(_value),
    do: {:error, {:invalid_field, :first_compact_collection}}

  defp require_ordinary_success_result(%OrdinarySuccessResult{}), do: :ok

  defp require_ordinary_success_result(_value),
    do: {:error, {:invalid_field, :first_compact_collection}}

  defp require_reference(value, _field) when is_reference(value), do: :ok
  defp require_reference(_value, field), do: {:error, {:invalid_field, field}}

  defp require_non_neg_integer(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp require_non_neg_integer(_value, field), do: {:error, {:invalid_field, field}}

  defp require_member(value, values, field) do
    if value in values, do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp require_digest(value, _field) when is_binary(value) and byte_size(value) == 32, do: :ok
  defp require_digest(_value, field), do: {:error, {:invalid_field, field}}

  defp valid_downstream?(downstream) when is_map(downstream) and not is_struct(downstream) do
    MapSet.new(Map.keys(downstream)) == MapSet.new(@downstream_fields) and
      is_pid(downstream.pid) and is_integer(downstream.epoch) and downstream.epoch > 0 and
      is_binary(downstream.correlation_id)
  end

  defp valid_downstream?(_downstream), do: false

  defp owner_digest(domain, value) do
    :crypto.hash(:sha256, ["websocket_owner_admission:v1", 0, Atom.to_string(domain), 0, value])
  end

  defp secure_digest_match?(expected, presented)
       when is_binary(presented) and byte_size(presented) == 32,
       do: Plug.Crypto.secure_compare(expected, presented)

  defp secure_digest_match?(_expected, _presented), do: false

  defp reject_unknown_fields(attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @fields))
      |> Enum.map(fn field ->
        if is_atom(field) or is_binary(field), do: field, else: :unsupported
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&to_string/1)

    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp require_fields(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1 do
  def inspect(control, _opts), do: "#WebsocketOwnerAdmissionControlV1<#{control.action}:redacted>"
end
