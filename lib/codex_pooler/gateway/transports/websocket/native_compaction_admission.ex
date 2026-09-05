defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission do
  @moduledoc false

  defmodule Topology.Direct do
    @moduledoc false
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Topology.Forwarded do
    @moduledoc false

    @enforce_keys [:owner_instance_digest, :downstream_epoch, :owner_lease_digest]
    defstruct [:owner_instance_digest, :downstream_epoch, :owner_lease_digest]

    @type t :: %__MODULE__{
            owner_instance_digest: <<_::256>>,
            downstream_epoch: non_neg_integer(),
            owner_lease_digest: <<_::256>>
          }
  end

  defmodule Binding do
    @moduledoc false

    @enforce_keys [
      :semantic_turn_key,
      :window_digest,
      :context_digest,
      :window_number,
      :serving_mode,
      :topology,
      :lifecycle_id,
      :generation
    ]
    defstruct [
      :semantic_turn_key,
      :window_digest,
      :context_digest,
      :window_number,
      :compaction_item_digest,
      :previous_response_digest,
      :serving_mode,
      :topology,
      :lifecycle_id,
      :generation,
      standalone_resolved_anchor?: false
    ]

    @type t :: %__MODULE__{
            semantic_turn_key: <<_::256>>,
            window_digest: <<_::256>>,
            context_digest: <<_::256>>,
            window_number: non_neg_integer() | nil,
            compaction_item_digest: <<_::256>> | nil,
            previous_response_digest: <<_::256>> | nil,
            serving_mode: atom(),
            topology: Topology.Direct.t() | Topology.Forwarded.t(),
            lifecycle_id: Ecto.UUID.t(),
            generation: pos_integer(),
            standalone_resolved_anchor?: boolean()
          }
  end

  defmodule CapabilityToken do
    @moduledoc false

    @token_bytes 32

    @spec issue() :: <<_::256>>
    def issue, do: :crypto.strong_rand_bytes(@token_bytes)

    @spec match?(binary(), binary()) :: boolean()
    def match?(expected, presented) do
      match?(expected, presented, &Plug.Crypto.secure_compare/2)
    end

    @doc false
    @spec match?(binary(), binary(), (binary(), binary() -> boolean())) :: boolean()
    def match?(expected, presented, comparator)
        when is_binary(expected) and is_binary(presented) and is_function(comparator, 2) do
      byte_size(expected) == @token_bytes and byte_size(presented) == @token_bytes and
        comparator.(expected, presented)
    end
  end

  defmodule Capability do
    @moduledoc false

    @enforce_keys [:phase, :binding, :control_ref, :token, :expires_at_ms]
    defstruct [:phase, :binding, :control_ref, :token, :expires_at_ms]

    @type t :: %__MODULE__{
            phase: :compact | :final,
            binding: Binding.t(),
            control_ref: reference(),
            token: <<_::256>>,
            expires_at_ms: non_neg_integer()
          }

    @doc false
    @spec replace_token(t(), binary()) :: t()
    def replace_token(%__MODULE__{} = capability, token) when is_binary(token) do
      %{capability | token: token}
    end
  end

  defmodule Confirmation do
    @moduledoc false

    @enforce_keys [:source_phase, :source_control_ref, :binding]
    defstruct [:source_phase, :source_control_ref, :binding]

    @type t :: %__MODULE__{
            source_phase: :compact | :first_full_history_compact,
            source_control_ref: reference(),
            binding: Binding.t()
          }
  end

  defmodule FirstCompactCollection do
    @moduledoc false

    @enforce_keys [:phase, :binding, :control_ref, :signature]
    defstruct [:phase, :binding, :control_ref, :signature]

    @type t :: %__MODULE__{
            phase: :first_full_history_compact,
            binding: Binding.t(),
            control_ref: reference(),
            signature: <<_::256>>
          }

    @salt "native_compaction_first_collection:v1"

    @spec issue(Binding.t(), reference()) :: t()
    def issue(%Binding{} = binding, control_ref) when is_reference(control_ref) do
      provenance = %__MODULE__{
        phase: :first_full_history_compact,
        binding: binding,
        control_ref: control_ref,
        signature: <<>>
      }

      %{provenance | signature: signature(provenance)}
    end

    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{signature: signature} = provenance) do
      byte_size(signature) == 32 and
        Plug.Crypto.secure_compare(signature, signature(%{provenance | signature: <<>>}))
    end

    @spec match?(t(), t()) :: boolean()
    def match?(%__MODULE__{} = expected, %__MODULE__{} = presented) do
      expected.phase == presented.phase and expected.binding == presented.binding and
        expected.control_ref == presented.control_ref and valid?(presented)
    end

    @doc false
    def replace_binding(%__MODULE__{} = provenance, %Binding{} = binding),
      do: %{provenance | binding: binding}

    @doc false
    def replace_control_ref(%__MODULE__{} = provenance, control_ref)
        when is_reference(control_ref),
        do: %{provenance | control_ref: control_ref}

    @doc false
    def replace_phase(%__MODULE__{} = provenance, phase), do: %{provenance | phase: phase}

    defp signature(provenance) do
      key = :crypto.hash(:sha256, secret_key_base() <> <<0>> <> @salt)

      :crypto.mac(
        :hmac,
        :sha256,
        key,
        :erlang.term_to_binary(
          {provenance.phase, provenance.binding, provenance.control_ref},
          [:deterministic]
        )
      )
    end

    defp secret_key_base do
      :codex_pooler
      |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)
    end
  end

  defmodule FirstCompactResult do
    @moduledoc false

    alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
    alias CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector
    alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission

    @enforce_keys [
      :owner,
      :result_ref,
      :request_id,
      :attempt_id,
      :binding,
      :model_digest,
      :item_digest
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            owner: pid(),
            result_ref: reference(),
            request_id: Ecto.UUID.t(),
            attempt_id: Ecto.UUID.t(),
            binding: Binding.t(),
            model_digest: <<_::256>>,
            item_digest: <<_::256>>
          }

    @spec from_collection(map(), map(), map()) :: {:ok, t()} | :error
    def from_collection(request, result, lifecycle) do
      with %{
             websocket_delivery_mode: :collect_full_history,
             native_compaction_metadata:
               %NativeCodexTurnMetadata{request_kind: :compaction} = metadata
           } <- request,
           {:ok, request_id} <- Ecto.UUID.cast(request.request_id),
           {:ok, attempt_id} <- Ecto.UUID.cast(request.attempt_id),
           {:ok, %{"model" => model}} when is_binary(model) <- Jason.decode(request.payload),
           {:ok, %{compaction_item: item}} <-
             CompactionResultCollector.collect_websocket_body(result.body),
           {:ok, serving_mode} <- mode(request.effective_serving_mode),
           binding = %Binding{
             semantic_turn_key: metadata.semantic_turn_key,
             window_digest: metadata.window_id_digest,
             context_digest: metadata.context_window_id_digest,
             window_number: metadata.window_number,
             serving_mode: serving_mode,
             topology: %Topology.Direct{},
             lifecycle_id: lifecycle.lifecycle_id,
             generation: lifecycle.generation
           },
           {:ok, _} <- NativeCompactionAdmission.ordinary_success(binding) do
        {:ok,
         %__MODULE__{
           owner: self(),
           result_ref: make_ref(),
           request_id: request_id,
           attempt_id: attempt_id,
           binding: binding,
           model_digest: model_digest(model),
           item_digest: NativeCodexTurnMetadata.compaction_item_digest(item)
         }}
      else
        _invalid -> :error
      end
    end

    @spec model_digest(binary()) :: <<_::256>>
    def model_digest(model), do: :crypto.hash(:sha256, ["native_compact_model:v1", 0, model])

    @spec binding_matches?(t(), Binding.t()) :: boolean()
    def binding_matches?(%__MODULE__{binding: expected}, %Binding{} = presented),
      do: expected == presented

    @spec request_identity(map()) :: tuple() | nil
    def request_identity(
          %{native_compaction_metadata: %NativeCodexTurnMetadata{} = metadata} = request
        ) do
      with {:ok, %{"model" => model}} when is_binary(model) <- Jason.decode(request.payload),
           {:ok, mode} <- mode(request.effective_serving_mode) do
        {request.request_id, request.attempt_id, metadata.semantic_turn_key,
         metadata.window_id_digest, metadata.context_window_id_digest, metadata.window_number,
         mode, model_digest(model)}
      else
        _invalid -> nil
      end
    end

    def request_identity(_request), do: nil

    @spec identity(t()) :: tuple()
    def identity(%__MODULE__{} = receipt) do
      binding = receipt.binding

      {receipt.request_id, receipt.attempt_id, binding.semantic_turn_key, binding.window_digest,
       binding.context_digest, binding.window_number, binding.serving_mode, receipt.model_digest}
    end

    defp mode("full"), do: {:ok, :full}
    defp mode("lite"), do: {:ok, :lite}
    defp mode(_mode), do: :error
  end

  @enforce_keys [:phase]
  defstruct [
    :phase,
    :binding,
    :capability,
    :first_compact_collection,
    :expires_at_ms,
    :compaction_item_digest
  ]

  @type phase ::
          :ordinary_success
          | :pending_compact
          | :reserved_compact
          | :accounting_started_compact
          | :consumed_compact
          | :collected_unconfirmed
          | :pending_final
          | :reserved_final
          | :accounting_started_final
          | :consumed_final
          | :cleared
  @type t :: %__MODULE__{
          phase: phase(),
          binding: Binding.t() | nil,
          capability: Capability.t() | nil,
          first_compact_collection: FirstCompactCollection.t() | nil,
          expires_at_ms: non_neg_integer() | nil,
          compaction_item_digest: <<_::256>> | nil
        }
  @type error ::
          :invalid_binding
          | :invalid_transition
          | :binding_mismatch
          | :capability_mismatch
          | :expired

  @spec ordinary_success(Binding.t()) :: {:ok, t()} | {:error, :invalid_binding}
  def ordinary_success(%Binding{} = binding) do
    if valid_binding?(binding) do
      {:ok, %__MODULE__{phase: :ordinary_success, binding: binding}}
    else
      {:error, :invalid_binding}
    end
  end

  @spec arm_compact(t(), non_neg_integer()) :: {:ok, t()} | {:error, :invalid_transition}
  def arm_compact(%__MODULE__{phase: :ordinary_success} = state, expires_at_ms)
      when is_integer(expires_at_ms) and expires_at_ms >= 0 do
    {:ok, %{state | phase: :pending_compact, expires_at_ms: expires_at_ms}}
  end

  def arm_compact(%__MODULE__{}, _expires_at_ms), do: {:error, :invalid_transition}

  @spec reserve(t(), :compact | :final, Binding.t(), reference(), non_neg_integer()) ::
          {:ok, t(), Capability.t()} | {:error, error()}
  def reserve(
        %__MODULE__{phase: pending_phase, binding: binding, expires_at_ms: expires_at_ms} = state,
        requested_phase,
        %Binding{} = requested_binding,
        control_ref,
        now_ms
      )
      when is_reference(control_ref) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- expected_pending_phase(pending_phase, requested_phase),
         :ok <- not_expired(expires_at_ms, now_ms),
         true <- reservation_binding_match?(requested_phase, binding, requested_binding) do
      capability = %Capability{
        phase: requested_phase,
        binding: requested_binding,
        control_ref: control_ref,
        token: CapabilityToken.issue(),
        expires_at_ms: expires_at_ms
      }

      {:ok,
       %{
         state
         | phase: reserved_phase(requested_phase),
           binding: requested_binding,
           capability: capability
       }, capability}
    else
      false -> {:error, :binding_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def reserve(%__MODULE__{}, _requested_phase, _binding, _control_ref, _now_ms),
    do: {:error, :invalid_transition}

  @spec mark_accounting_started(t(), Capability.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, error()}
  def mark_accounting_started(%__MODULE__{} = state, %Capability{} = capability, now_ms) do
    with {:ok, requested_phase} <- reserved_state_phase(state.phase),
         :ok <- valid_capability(state, capability, requested_phase, now_ms) do
      {:ok, %{state | phase: accounting_phase(requested_phase)}}
    end
  end

  @spec consume(t(), Capability.t(), non_neg_integer()) :: {:ok, t()} | {:error, error()}
  def consume(%__MODULE__{} = state, %Capability{} = capability, now_ms) do
    with {:ok, requested_phase} <- accounting_state_phase(state.phase),
         :ok <- valid_capability(state, capability, requested_phase, now_ms) do
      {:ok,
       %{
         state
         | phase: consumed_phase(requested_phase),
           capability: retained_capability(requested_phase, state.capability)
       }}
    end
  end

  @spec cancel(t(), Capability.t(), :pre_accounting, non_neg_integer()) ::
          {:ok, t()} | {:error, error()} | {:error, :committed, t()}
  def cancel(%__MODULE__{} = state, %Capability{} = capability, :pre_accounting, now_ms) do
    case reserved_state_phase(state.phase) do
      {:ok, requested_phase} ->
        with :ok <- valid_capability(state, capability, requested_phase, now_ms) do
          {:ok, %{state | phase: pending_phase(requested_phase), capability: nil}}
        end

      {:error, :invalid_transition} ->
        cond do
          state.phase not in [:accounting_started_compact, :accounting_started_final] ->
            {:error, :invalid_transition}

          owns_capability?(state, capability) ->
            {:error, :committed, cleared()}

          true ->
            {:error, :capability_mismatch}
        end
    end
  end

  @spec record_compact_collected(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def record_compact_collected(%__MODULE__{phase: :consumed_compact} = state) do
    {:ok, %{state | phase: :collected_unconfirmed, expires_at_ms: nil}}
  end

  def record_compact_collected(%__MODULE__{}), do: {:error, :invalid_transition}

  @spec authorize_first_compact_collection(t(), reference()) ::
          {:ok, t(), FirstCompactCollection.t()} | {:error, :invalid_transition}
  def authorize_first_compact_collection(
        %__MODULE__{phase: :ordinary_success, first_compact_collection: nil, binding: binding} =
          state,
        control_ref
      )
      when is_reference(control_ref) do
    provenance = FirstCompactCollection.issue(binding, control_ref)
    {:ok, %{state | first_compact_collection: provenance}, provenance}
  end

  def authorize_first_compact_collection(%__MODULE__{}, _control_ref),
    do: {:error, :invalid_transition}

  @spec record_first_compact_collected(t(), FirstCompactCollection.t()) ::
          {:ok, t()}
          | {:error, :invalid_transition | :invalid_provenance}
          | {:error, :provenance_mismatch, t()}
  def record_first_compact_collected(
        %__MODULE__{
          phase: :ordinary_success,
          first_compact_collection: %FirstCompactCollection{} = expected
        } = state,
        %FirstCompactCollection{} = presented
      ) do
    if FirstCompactCollection.match?(expected, presented) do
      {:ok, %{state | phase: :collected_unconfirmed}}
    else
      {:error, :provenance_mismatch, cleared()}
    end
  end

  def record_first_compact_collected(%__MODULE__{phase: :ordinary_success}, _provenance),
    do: {:error, :invalid_provenance}

  def record_first_compact_collected(%__MODULE__{}, _provenance),
    do: {:error, :invalid_transition}

  @spec confirm_compact(t(), <<_::256>>, Confirmation.t(), non_neg_integer()) ::
          {:ok, t()}
          | {:error, :invalid_transition | :invalid_binding}
          | {:error, :binding_mismatch, t()}
  def confirm_compact(
        %__MODULE__{
          phase: :collected_unconfirmed,
          binding: original_binding,
          capability: capability
        } = state,
        compaction_item_digest,
        %Confirmation{
          source_phase: source_phase,
          source_control_ref: source_control_ref,
          binding: binding
        },
        expires_at_ms
      )
      when byte_size(compaction_item_digest) == 32 and is_integer(expires_at_ms) and
             expires_at_ms >= 0 do
    cond do
      not valid_binding?(binding) ->
        {:error, :invalid_binding}

      source_phase != :compact ->
        confirm_first_compact(
          state,
          source_phase,
          source_control_ref,
          binding,
          expires_at_ms,
          compaction_item_digest
        )

      not match?(%Capability{phase: :compact}, capability) or
        capability.control_ref != source_control_ref or
          not compact_confirmation_binding_match?(
            original_binding,
            binding,
            compaction_item_digest
          ) ->
        {:error, :binding_mismatch, cleared()}

      true ->
        complete_compact_confirmation(
          state,
          original_binding,
          binding,
          compaction_item_digest,
          expires_at_ms
        )
    end
  end

  def confirm_compact(%__MODULE__{}, _digest, _binding, _expires_at_ms),
    do: {:error, :invalid_transition}

  defp complete_compact_confirmation(
         _state,
         %Binding{standalone_resolved_anchor?: true},
         _binding,
         _digest,
         _expires
       ),
       do: {:ok, cleared()}

  defp complete_compact_confirmation(
         state,
         _original,
         binding,
         compaction_item_digest,
         expires_at_ms
       ) do
    {:ok,
     %{
       state
       | phase: :pending_final,
         binding: binding,
         capability: nil,
         expires_at_ms: expires_at_ms,
         compaction_item_digest: compaction_item_digest
     }}
  end

  defp confirm_first_compact(
         %__MODULE__{
           binding: original_binding,
           first_compact_collection: %FirstCompactCollection{} = provenance
         } = state,
         :first_full_history_compact,
         source_control_ref,
         binding,
         expires_at_ms,
         compaction_item_digest
       ) do
    if provenance.binding == original_binding and
         (is_nil(state.compaction_item_digest) or
            state.compaction_item_digest == compaction_item_digest) and
         compact_confirmation_binding_match?(
           original_binding,
           binding,
           compaction_item_digest
         ) and
         provenance.control_ref == source_control_ref and
         FirstCompactCollection.valid?(provenance) do
      {:ok,
       %{
         state
         | phase: :pending_final,
           first_compact_collection: nil,
           expires_at_ms: expires_at_ms,
           binding: binding,
           compaction_item_digest: compaction_item_digest
       }}
    else
      {:error, :binding_mismatch, cleared()}
    end
  end

  defp confirm_first_compact(
         %__MODULE__{},
         _source_phase,
         _source_control_ref,
         _binding,
         _expires_at_ms,
         _compaction_item_digest
       ),
       do: {:error, :binding_mismatch, cleared()}

  @spec clear_consumed(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def clear_consumed(%__MODULE__{phase: :consumed_final}), do: {:ok, cleared()}
  def clear_consumed(%__MODULE__{}), do: {:error, :invalid_transition}

  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: cleared()

  @spec clear_owned(t(), Capability.t()) :: {:ok, t()} | {:error, :capability_mismatch}
  def clear_owned(
        %__MODULE__{capability: %Capability{} = expected, binding: binding},
        %Capability{} = capability
      ) do
    if Map.delete(expected, :token) == Map.delete(capability, :token) and
         CapabilityToken.match?(expected.token, capability.token) and
         binding == capability.binding do
      {:ok, cleared()}
    else
      {:error, :capability_mismatch}
    end
  end

  def clear_owned(%__MODULE__{}, %Capability{}), do: {:error, :capability_mismatch}

  @spec owns_capability?(t(), Capability.t()) :: boolean()
  def owns_capability?(
        %__MODULE__{capability: %Capability{} = expected, binding: binding},
        %Capability{} = capability
      ) do
    Map.delete(expected, :token) == Map.delete(capability, :token) and
      CapabilityToken.match?(expected.token, capability.token) and binding == capability.binding
  end

  def owns_capability?(_state, _capability), do: false

  @spec expire(t(), non_neg_integer()) :: {:active, t()} | {:expired, t()}
  def expire(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms)
      when is_integer(expires_at_ms) and is_integer(now_ms) and now_ms > expires_at_ms do
    {:expired, cleared()}
  end

  def expire(%__MODULE__{} = state, _now_ms), do: {:active, state}

  @spec phase(t()) :: phase()
  def phase(%__MODULE__{phase: phase}), do: phase

  @spec control_ref(Capability.t()) :: reference()
  def control_ref(%Capability{control_ref: control_ref}), do: control_ref

  defp valid_binding?(%Binding{} = binding) do
    valid_binding_digests?(binding) and valid_binding_identity?(binding)
  end

  defp valid_binding_digests?(binding) do
    digest?(binding.semantic_turn_key) and digest?(binding.window_digest) and
      digest?(binding.context_digest) and optional_digest?(binding.previous_response_digest) and
      optional_digest?(binding.compaction_item_digest)
  end

  defp valid_binding_identity?(binding) do
    valid_window_number?(binding.window_number) and is_atom(binding.serving_mode) and
      is_boolean(binding.standalone_resolved_anchor?) and
      valid_topology?(binding.topology) and
      match?({:ok, _uuid}, Ecto.UUID.cast(binding.lifecycle_id)) and
      is_integer(binding.generation) and binding.generation > 0
  end

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: digest?(value)
  defp valid_window_number?(nil), do: true
  defp valid_window_number?(value), do: is_integer(value) and value >= 0

  defp valid_topology?(%Topology.Direct{}), do: true

  defp valid_topology?(%Topology.Forwarded{} = topology) do
    digest?(topology.owner_instance_digest) and is_integer(topology.downstream_epoch) and
      topology.downstream_epoch >= 0 and digest?(topology.owner_lease_digest)
  end

  defp valid_topology?(_topology), do: false

  defp immutable_binding_match?(original, candidate) do
    original.semantic_turn_key == candidate.semantic_turn_key and
      original.serving_mode == candidate.serving_mode and original.topology == candidate.topology and
      original.lifecycle_id == candidate.lifecycle_id and
      original.generation == candidate.generation
  end

  defp reservation_binding_match?(:compact, original, candidate) do
    compact_identity_match?(original, candidate) and
      original.window_digest == candidate.window_digest and
      original.context_digest == candidate.context_digest and
      original.window_number == candidate.window_number and
      is_nil(candidate.compaction_item_digest) and
      previous_response_compatible?(original, candidate)
  end

  defp reservation_binding_match?(:final, original, candidate) do
    immutable_binding_match?(original, candidate) and
      original.window_digest != candidate.window_digest and
      original.context_digest != candidate.context_digest and
      final_window_number_match?(original.window_number, candidate.window_number) and
      digest_match?(state_compaction_item_digest(original), candidate.compaction_item_digest) and
      previous_response_compatible?(original, candidate)
  end

  defp compact_identity_match?(original, %Binding{standalone_resolved_anchor?: true} = candidate) do
    digest_match?(original.previous_response_digest, candidate.previous_response_digest) and
      immutable_binding_match?(
        %{original | semantic_turn_key: candidate.semantic_turn_key},
        candidate
      )
  end

  defp compact_identity_match?(original, candidate),
    do: immutable_binding_match?(original, candidate)

  defp compact_confirmation_binding_match?(original, candidate, compaction_item_digest) do
    immutable_binding_match?(original, candidate) and
      original.window_digest == candidate.window_digest and
      original.context_digest == candidate.context_digest and
      original.window_number == candidate.window_number and
      digest_match?(compaction_item_digest, candidate.compaction_item_digest)
  end

  defp final_window_number_match?(nil, _candidate), do: true
  defp final_window_number_match?(_original, nil), do: true
  defp final_window_number_match?(original, candidate), do: candidate > original

  defp state_compaction_item_digest(%Binding{compaction_item_digest: digest}), do: digest

  defp digest_match?(expected, candidate)
       when is_binary(expected) and byte_size(expected) == 32 and is_binary(candidate) and
              byte_size(candidate) == 32,
       do: Plug.Crypto.secure_compare(expected, candidate)

  defp digest_match?(_expected, _candidate), do: false

  defp previous_response_compatible?(_original, %{previous_response_digest: nil}), do: true

  defp previous_response_compatible?(original, candidate) do
    original.previous_response_digest == candidate.previous_response_digest
  end

  defp expected_pending_phase(:pending_compact, :compact), do: :ok
  defp expected_pending_phase(:pending_final, :final), do: :ok
  defp expected_pending_phase(_state_phase, _requested_phase), do: {:error, :invalid_transition}

  defp not_expired(expires_at_ms, now_ms) when now_ms <= expires_at_ms, do: :ok
  defp not_expired(_expires_at_ms, _now_ms), do: {:error, :expired}

  defp valid_capability(state, capability, requested_phase, now_ms) do
    with %Capability{} = expected <- state.capability,
         true <- expected.phase == requested_phase and capability.phase == requested_phase,
         true <- expected.binding == capability.binding and state.binding == capability.binding,
         true <- expected.control_ref == capability.control_ref,
         true <- expected.expires_at_ms == capability.expires_at_ms,
         true <- CapabilityToken.match?(expected.token, capability.token),
         true <- now_ms <= capability.expires_at_ms do
      :ok
    else
      false when now_ms > capability.expires_at_ms -> {:error, :expired}
      false -> {:error, :capability_mismatch}
      nil -> {:error, :capability_mismatch}
    end
  end

  defp retained_capability(:compact, capability), do: capability
  defp retained_capability(:final, _capability), do: nil

  defp reserved_state_phase(:reserved_compact), do: {:ok, :compact}
  defp reserved_state_phase(:reserved_final), do: {:ok, :final}
  defp reserved_state_phase(_phase), do: {:error, :invalid_transition}

  defp accounting_state_phase(:accounting_started_compact), do: {:ok, :compact}
  defp accounting_state_phase(:accounting_started_final), do: {:ok, :final}
  defp accounting_state_phase(_phase), do: {:error, :invalid_transition}

  defp pending_phase(:compact), do: :pending_compact
  defp pending_phase(:final), do: :pending_final
  defp reserved_phase(:compact), do: :reserved_compact
  defp reserved_phase(:final), do: :reserved_final
  defp accounting_phase(:compact), do: :accounting_started_compact
  defp accounting_phase(:final), do: :accounting_started_final
  defp consumed_phase(:compact), do: :consumed_compact
  defp consumed_phase(:final), do: :consumed_final

  defp cleared, do: %__MODULE__{phase: :cleared}
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactResult do
  def inspect(_result, _opts), do: "#NativeCompactionAdmission.FirstCompactResult<redacted>"
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission do
  def inspect(state, _opts), do: "#NativeCompactionAdmission<#{state.phase}:redacted>"
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding do
  def inspect(_binding, _opts), do: "#NativeCompactionAdmission.Binding<redacted>"
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability do
  def inspect(capability, _opts),
    do: "#NativeCompactionAdmission.Capability<#{capability.phase}:redacted>"
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactCollection do
  def inspect(provenance, _opts),
    do: "#NativeCompactionAdmission.FirstCompactCollection<#{provenance.phase}:redacted>"
end
