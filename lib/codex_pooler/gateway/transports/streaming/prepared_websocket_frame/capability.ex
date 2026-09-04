defmodule CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof

  @timeout_ms 30_000

  @enforce_keys [:server, :reference]
  defstruct [:server, :reference]

  @type t :: %__MODULE__{server: pid(), reference: reference()}

  @spec issue() :: t()
  def issue do
    reference = make_ref()
    {:ok, server} = GenServer.start(__MODULE__, {self(), reference})
    %__MODULE__{server: server, reference: reference}
  end

  @spec seal(t(), binary(), <<_::256>> | nil, :native_compaction | :native_replay | nil) :: :ok
  def seal(
        %__MODULE__{server: server, reference: reference},
        frame_token,
        binding_digest \\ nil,
        kind \\ nil
      )
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:seal, reference, frame_token, binding_digest, kind}, 1_000)
  end

  @spec consume(t(), binary()) :: :ok | {:error, :consumed | :invalid}
  def consume(%__MODULE__{server: server, reference: reference}, frame_token)
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:consume, reference, frame_token}, 1_000)
  catch
    :exit, _reason -> {:error, :invalid}
  end

  @spec validate(t(), binary()) :: :ok | {:error, :consumed | :invalid}
  def validate(%__MODULE__{server: server, reference: reference}, frame_token)
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:validate, reference, frame_token}, 1_000)
  catch
    :exit, _reason -> {:error, :invalid}
  end

  @spec consume_for_dispatch(t(), binary()) ::
          {:ok, RuntimeAdmissionProof.t() | nil} | {:error, :consumed | :invalid}
  def consume_for_dispatch(%__MODULE__{server: server, reference: reference}, frame_token)
      when is_pid(server) and is_reference(reference) and is_binary(frame_token) do
    GenServer.call(server, {:consume_for_dispatch, reference, frame_token}, 1_000)
  catch
    :exit, _reason -> {:error, :invalid}
  end

  @spec redeem_runtime_admission(RuntimeAdmissionProof.t(), <<_::256>>) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid | :replayed}
  @spec redeem_runtime_admission(
          RuntimeAdmissionProof.t(),
          <<_::256>>,
          :native_compaction | :native_replay
        ) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid | :replayed}
  def redeem_runtime_admission(
        %RuntimeAdmissionProof{
          server: server,
          reference: reference,
          nonce: nonce,
          binding_digest: proof_digest,
          kind: kind
        },
        expected_digest,
        expected_kind \\ :native_compaction
      )
      when is_binary(expected_digest) and byte_size(expected_digest) == 32 and
             expected_kind in [:native_compaction, :native_replay] do
    if kind == expected_kind do
      GenServer.call(
        server,
        {:redeem_runtime_admission, reference, nonce, proof_digest, expected_digest},
        1_000
      )
    else
      {:error, :invalid}
    end
  catch
    :exit, _reason -> {:error, :invalid}
  end

  @spec digest_identity(t()) :: {pid(), reference()}
  def digest_identity(%__MODULE__{server: server, reference: reference}),
    do: {server, reference}

  @impl true
  def init({owner, reference}) do
    owner_monitor = Process.monitor(owner)

    {:ok,
     %{
       owner_monitor: owner_monitor,
       reference: reference,
       frame_token: nil,
       consumed?: false,
       runtime_binding_digest: nil,
       runtime_proof_kind: nil,
       runtime_proof_nonce: nil,
       runtime_proof_redeemed?: false,
       authorized_correlation_id: nil
     }, @timeout_ms}
  end

  @impl true
  def handle_call(
        {:seal, reference, frame_token, binding_digest, kind},
        _from,
        %{reference: reference, frame_token: nil, consumed?: false} = state
      ) do
    if valid_binding_digest?(binding_digest) and valid_kind?(binding_digest, kind) do
      {:reply, :ok,
       %{
         state
         | frame_token: frame_token,
           runtime_binding_digest: binding_digest,
           runtime_proof_kind: kind
       }, @timeout_ms}
    else
      {:reply, {:error, :invalid}, state, @timeout_ms}
    end
  end

  def handle_call(
        {:validate, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: false} = state
      ) do
    {:reply, :ok, state, @timeout_ms}
  end

  def handle_call(
        {:validate, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: true} = state
      ) do
    {:reply, {:error, :consumed}, state}
  end

  def handle_call({:validate, _reference, _frame_token}, _from, state) do
    {:reply, {:error, :invalid}, state, @timeout_ms}
  end

  def handle_call(
        {:consume, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: false} = state
      ) do
    {:reply, :ok, %{state | consumed?: true}}
  end

  def handle_call(
        {:consume, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: true} = state
      ) do
    {:reply, {:error, :consumed}, state}
  end

  def handle_call({:consume, _reference, _frame_token}, _from, state) do
    {:reply, {:error, :invalid}, state, @timeout_ms}
  end

  def handle_call(
        {:consume_for_dispatch, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: false} = state
      ) do
    case state.runtime_binding_digest do
      nil ->
        {:reply, {:ok, nil}, %{state | consumed?: true}}

      binding_digest ->
        nonce = make_ref()
        correlation_id = Ecto.UUID.generate()

        proof =
          RuntimeAdmissionProof.new(
            self(),
            reference,
            nonce,
            binding_digest,
            state.runtime_proof_kind
          )

        {:reply, {:ok, proof},
         %{
           state
           | consumed?: true,
             runtime_proof_nonce: nonce,
             authorized_correlation_id: correlation_id
         }}
    end
  end

  def handle_call(
        {:consume_for_dispatch, reference, frame_token},
        _from,
        %{reference: reference, frame_token: frame_token, consumed?: true} = state
      ) do
    {:reply, {:error, :consumed}, state}
  end

  def handle_call({:consume_for_dispatch, _reference, _frame_token}, _from, state) do
    {:reply, {:error, :invalid}, state, @timeout_ms}
  end

  def handle_call(
        {:redeem_runtime_admission, reference, nonce, proof_digest, expected_digest},
        _from,
        %{
          reference: reference,
          runtime_binding_digest: binding_digest,
          runtime_proof_nonce: nonce,
          runtime_proof_redeemed?: false,
          authorized_correlation_id: correlation_id
        } = state
      ) do
    if secure_digest_match?(binding_digest, proof_digest) and
         secure_digest_match?(binding_digest, expected_digest) and is_binary(correlation_id) do
      {:reply, {:ok, correlation_id}, %{state | runtime_proof_redeemed?: true}}
    else
      {:reply, {:error, :invalid}, %{state | runtime_proof_redeemed?: true}}
    end
  end

  def handle_call(
        {:redeem_runtime_admission, reference, _nonce, _proof_digest, _expected_digest},
        _from,
        %{reference: reference, runtime_proof_redeemed?: true} = state
      ) do
    {:reply, {:error, :replayed}, state}
  end

  def handle_call(
        {:redeem_runtime_admission, _reference, _nonce, _proof, _expected},
        _from,
        state
      ) do
    {:reply, {:error, :invalid}, state, @timeout_ms}
  end

  @impl true
  def handle_info({:DOWN, owner_monitor, :process, _owner, _reason}, %{
        owner_monitor: owner_monitor
      }) do
    {:stop, :normal, %{}}
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp valid_binding_digest?(nil), do: true
  defp valid_binding_digest?(digest), do: is_binary(digest) and byte_size(digest) == 32
  defp valid_kind?(nil, nil), do: true

  defp valid_kind?(digest, kind),
    do: valid_binding_digest?(digest) and kind in [:native_compaction, :native_replay]

  defp secure_digest_match?(expected, presented)
       when is_binary(expected) and is_binary(presented) and
              byte_size(expected) == byte_size(presented),
       do: Plug.Crypto.secure_compare(expected, presented)

  defp secure_digest_match?(_expected, _presented), do: false
end
