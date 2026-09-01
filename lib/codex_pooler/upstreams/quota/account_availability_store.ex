defmodule CodexPooler.Upstreams.Quota.AccountAvailabilityStore do
  @moduledoc false

  alias CodexPooler.Quotas.{AccountAvailability, Evidence}

  @metadata_key "quota_account_availability"
  @version 1
  @states [:available, :blocked, :unknown]
  @encoded_states Map.new(@states, &{Atom.to_string(&1), &1})
  @exact_keys MapSet.new(~w(version state observed_at credential_epoch))

  defmodule Snapshot do
    @moduledoc false
    @enforce_keys [:state, :observed_at, :credential_epoch]
    defstruct [:state, :observed_at, :credential_epoch]

    @type t :: %__MODULE__{
            state: :available | :blocked | :unknown,
            observed_at: DateTime.t(),
            credential_epoch: pos_integer()
          }
  end

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec encode!(:available | :blocked | :unknown, DateTime.t(), pos_integer()) :: map()
  def encode!(state, %DateTime{} = observed_at, credential_epoch)
      when state in @states and is_integer(credential_epoch) and credential_epoch > 0 do
    %{
      "version" => @version,
      "state" => Atom.to_string(state),
      "observed_at" => observed_at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601(),
      "credential_epoch" => credential_epoch
    }
  end

  @spec decode(term()) :: {:ok, Snapshot.t()} | :error
  def decode(%{} = encoded) when map_size(encoded) == 4 do
    with true <- MapSet.equal?(MapSet.new(Map.keys(encoded)), @exact_keys),
         @version <- encoded["version"],
         state when not is_nil(state) <- @encoded_states[encoded["state"]],
         credential_epoch when is_integer(credential_epoch) and credential_epoch > 0 <-
           encoded["credential_epoch"],
         observed_at when is_binary(observed_at) <- encoded["observed_at"],
         {:ok, parsed, 0} <- DateTime.from_iso8601(observed_at) do
      {:ok,
       %Snapshot{
         state: state,
         observed_at: DateTime.shift_zone!(parsed, "Etc/UTC"),
         credential_epoch: credential_epoch
       }}
    else
      _invalid -> :error
    end
  end

  def decode(_encoded), do: :error

  @spec decode!(map()) :: Snapshot.t()
  def decode!(encoded) do
    case decode(encoded) do
      {:ok, snapshot} -> snapshot
      :error -> raise ArgumentError, "invalid quota account availability snapshot"
    end
  end

  @spec load(map() | nil) :: {:ok, Snapshot.t()} | :error
  def load(metadata) when is_map(metadata), do: decode(metadata[@metadata_key])
  def load(_metadata), do: :error

  @spec available?(Snapshot.t(), pos_integer(), DateTime.t()) :: boolean()
  def available?(%Snapshot{state: :available} = snapshot, credential_epoch, %DateTime{} = as_of) do
    current_epoch?(snapshot, credential_epoch) and not future?(snapshot, as_of) and
      DateTime.compare(
        as_of,
        DateTime.add(snapshot.observed_at, Evidence.freshness_ttl_seconds(), :second)
      ) != :gt
  end

  def available?(_snapshot, _credential_epoch, _as_of), do: false

  @spec blocked?(Snapshot.t(), pos_integer(), DateTime.t()) :: boolean()
  def blocked?(%Snapshot{state: :blocked} = snapshot, credential_epoch, %DateTime{} = as_of) do
    current_epoch?(snapshot, credential_epoch) and not future?(snapshot, as_of)
  end

  def blocked?(_snapshot, _credential_epoch, _as_of), do: false

  @spec transition(map() | nil, AccountAvailability.t() | nil, DateTime.t(), pos_integer()) ::
          map()
  def transition(metadata, nil, _observed_at, _credential_epoch), do: normalize_metadata(metadata)

  def transition(
        metadata,
        %AccountAvailability{} = observation,
        %DateTime{} = observed_at,
        credential_epoch
      )
      when is_integer(credential_epoch) and credential_epoch > 0 do
    metadata = normalize_metadata(metadata)

    if preserve_current_blocked?(metadata, observation, credential_epoch) do
      metadata
    else
      Map.put(metadata, @metadata_key, encode!(observation.state, observed_at, credential_epoch))
    end
  end

  @spec clear(map() | nil) :: map()
  def clear(metadata), do: metadata |> normalize_metadata() |> Map.delete(@metadata_key)

  defp preserve_current_blocked?(
         metadata,
         %AccountAvailability{state: :unknown},
         credential_epoch
       ) do
    case load(metadata) do
      {:ok, %Snapshot{state: :blocked, credential_epoch: ^credential_epoch}} -> true
      _other -> false
    end
  end

  defp preserve_current_blocked?(_metadata, _observation, _credential_epoch), do: false

  defp current_epoch?(%Snapshot{credential_epoch: epoch}, epoch), do: true
  defp current_epoch?(_snapshot, _credential_epoch), do: false

  defp future?(%Snapshot{observed_at: observed_at}, as_of) do
    DateTime.compare(
      observed_at,
      DateTime.add(as_of, Evidence.future_observed_skew_seconds(), :second)
    ) == :gt
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
