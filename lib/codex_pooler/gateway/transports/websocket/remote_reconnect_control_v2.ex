defmodule CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2 do
  @moduledoc false

  @fields [
    :version,
    :action,
    :intent,
    :codex_session_id,
    :downstream,
    :semantic_turn_digest,
    :replay_claim_digest,
    :provisional_token,
    :replay_generation,
    :owner_lease_token,
    :control_ref,
    :authorization_binding,
    :consume_binding
  ]
  @actions [
    :preflight,
    :provisional_reserve,
    :provisional_commit,
    :provisional_query,
    :provisional_cancel
  ]
  @intents [:fresh, :active_reattach, :suspended_replay]
  @authorization_fields [
    :api_key_id,
    :api_key_runtime_epoch,
    :pool_id,
    :codex_session_id,
    :model_identifier
  ]
  @consume_fields [
    :request_id,
    :codex_turn_id,
    :eligible_attempt_id,
    :replay_attempt_id,
    :replay_generation,
    :provisional_binding_digest,
    :owner_lease_digest
  ]
  @downstream_fields [:pid, :epoch, :correlation_id]

  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}
  @type validation_error :: {:unknown_fields, [atom() | String.t()]} | {:invalid_field, atom()}

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_keys(attrs, @fields),
         control = struct!(__MODULE__, attrs),
         :ok <- validate(control) do
      {:ok, control}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = control) do
    with :ok <- exact_keys(Map.from_struct(control), @fields),
         :ok <- common(control) do
      matrix(control)
    end
  end

  def validate(_control), do: {:error, {:invalid_field, :envelope}}

  defp common(control) do
    checks = [
      version: control.version == 2,
      action: control.action in @actions,
      intent: control.intent in @intents,
      codex_session_id: uuid?(control.codex_session_id),
      semantic_turn_digest: digest?(control.semantic_turn_digest),
      replay_claim_digest: digest?(control.replay_claim_digest),
      owner_lease_token: uuid?(control.owner_lease_token),
      control_ref: is_reference(control.control_ref)
    ]

    case Enum.find(checks, fn {_key, ok?} -> not ok? end) do
      nil -> :ok
      {field, false} -> {:error, {:invalid_field, field}}
    end
  end

  defp matrix(%__MODULE__{action: :preflight} = control) do
    require_matrix(control,
      downstream: true,
      authorization: true,
      token: false,
      generation: false,
      consume: control.intent == :active_reattach
    )
  end

  defp matrix(%__MODULE__{action: :provisional_reserve, intent: :suspended_replay} = control) do
    require_matrix(control,
      downstream: true,
      authorization: false,
      token: true,
      generation: true,
      consume: false
    )
  end

  defp matrix(%__MODULE__{action: :provisional_commit, intent: :suspended_replay} = control) do
    require_matrix(control,
      downstream: true,
      authorization: false,
      token: true,
      generation: true,
      consume: true
    )
  end

  defp matrix(%__MODULE__{action: action, intent: :suspended_replay} = control)
       when action in [:provisional_query, :provisional_cancel] do
    require_matrix(control,
      downstream: false,
      authorization: false,
      token: true,
      generation: true,
      consume: false
    )
  end

  defp matrix(_control), do: {:error, {:invalid_field, :intent}}

  defp require_matrix(control, expected) do
    checks = [
      downstream:
        presence(
          valid_downstream?(control.downstream),
          is_nil(control.downstream),
          expected[:downstream]
        ),
      authorization_binding:
        presence(
          valid_authorization?(control.authorization_binding),
          is_nil(control.authorization_binding),
          expected[:authorization]
        ),
      provisional_token:
        presence(
          token?(control.provisional_token),
          is_nil(control.provisional_token),
          expected[:token]
        ),
      replay_generation:
        presence(
          control.replay_generation == 1,
          is_nil(control.replay_generation),
          expected[:generation]
        ),
      consume_binding:
        presence(
          valid_action_binding?(control),
          is_nil(control.consume_binding),
          expected[:consume]
        )
    ]

    case Enum.find(checks, fn {_key, ok?} -> not ok? end) do
      nil -> :ok
      {field, false} -> {:error, {:invalid_field, field}}
    end
  end

  defp presence(present_valid?, _absent?, true), do: present_valid?
  defp presence(_present_valid?, absent?, false), do: absent?

  defp valid_downstream?(value),
    do:
      exact_shape?(value, @downstream_fields) and is_pid(value.pid) and positive?(value.epoch) and
        is_binary(value.correlation_id)

  defp valid_authorization?(value),
    do:
      exact_shape?(value, @authorization_fields) and uuid?(value.api_key_id) and
        is_integer(value.api_key_runtime_epoch) and value.api_key_runtime_epoch >= 0 and
        uuid?(value.pool_id) and uuid?(value.codex_session_id) and
        is_binary(value.model_identifier) and
        byte_size(value.model_identifier) in 1..255

  defp valid_consume?(value),
    do:
      exact_shape?(value, @consume_fields) and
        Enum.all?(
          [
            value.request_id,
            value.codex_turn_id,
            value.eligible_attempt_id,
            value.replay_attempt_id
          ],
          &uuid?/1
        ) and value.replay_generation == 1 and
        digest?(value.provisional_binding_digest) and digest?(value.owner_lease_digest)

  defp valid_action_binding?(%__MODULE__{
         action: :preflight,
         intent: :active_reattach,
         consume_binding: value
       }),
       do: valid_active_lifecycle?(value)

  defp valid_action_binding?(%__MODULE__{consume_binding: value}), do: valid_consume?(value)

  defp valid_active_lifecycle?(value),
    do:
      exact_shape?(value, @consume_fields) and uuid?(value.request_id) and
        uuid?(value.codex_turn_id) and uuid?(value.eligible_attempt_id) and
        is_nil(value.replay_attempt_id) and value.replay_generation == 0 and
        is_nil(value.provisional_binding_digest) and digest?(value.owner_lease_digest)

  defp exact_shape?(value, fields),
    do:
      is_map(value) and not is_struct(value) and MapSet.new(Map.keys(value)) == MapSet.new(fields)

  defp exact_keys(attrs, fields) do
    unknown = Map.keys(attrs) -- fields
    missing = fields -- Map.keys(attrs)

    cond do
      unknown != [] -> {:error, {:unknown_fields, Enum.sort_by(unknown, &to_string/1)}}
      missing != [] -> {:error, {:invalid_field, hd(missing)}}
      true -> :ok
    end
  end

  defp uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) == {:ok, value}
  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp token?(value), do: digest?(value)
  defp positive?(value), do: is_integer(value) and value > 0
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2 do
  def inspect(control, _opts),
    do:
      "#RemoteReconnectControlV2<version: 2, action: #{control.action}, intent: #{control.intent}, token: redacted>"
end
