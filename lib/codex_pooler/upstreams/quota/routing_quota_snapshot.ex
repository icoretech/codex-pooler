defmodule CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing

  alias CodexPooler.Upstreams.Quota.{
    AccountAvailabilityStore,
    AccountQuotaWindow,
    CapacityFactsStore,
    CreditBalanceStore,
    WindowSelector
  }

  alias CodexPooler.Upstreams.Quota.Windows.ResetRecoverySelection
  alias CodexPooler.Upstreams.Quota.Windows.Retention
  alias CodexPooler.Upstreams.Quota.Windows.Routing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @enforce_keys [
    :upstream_identity_id,
    :raw_windows,
    :availability,
    :credential_epoch,
    :as_of
  ]
  defstruct @enforce_keys ++ [credit_balance: nil, credit_balance_reported?: false, capacity_facts: nil, capacity_facts_reported?: false, capacity_blockers: [], capacity_blockers_overflowed?: false, capacity_blocker_reported?: false, allow_provider_credits: true, redemption: nil]

  @type t :: %__MODULE__{
          upstream_identity_id: Ecto.UUID.t(),
          raw_windows: [AccountQuotaWindow.t()],
          availability: AccountAvailabilityStore.Snapshot.t() | nil,
          credential_epoch: pos_integer(),
          credit_balance: CreditBalanceStore.snapshot() | nil,
          credit_balance_reported?: boolean(),
          capacity_facts: CodexPooler.Quotas.CapacityFacts.t() | nil,
          capacity_blockers: [CodexPooler.Quotas.CapacityFacts.t()],
          capacity_blockers_overflowed?: boolean(),
          capacity_facts_reported?: boolean(),
          capacity_blocker_reported?: boolean(),
          allow_provider_credits: boolean(),
          redemption: map() | nil,
          as_of: DateTime.t()
        }

  @type snapshot_map :: %{optional(Ecto.UUID.t()) => t()}

  defmodule LoadError do
    @moduledoc false
    defexception message: "routing quota snapshot load failed"
  end

  @doc false
  @spec from_identity(UpstreamIdentity.t(), [AccountQuotaWindow.t()], DateTime.t()) :: t()
  def from_identity(%UpstreamIdentity{} = identity, raw_windows, %DateTime{} = as_of)
      when is_list(raw_windows) do
    epoch = identity.metadata |> CredentialFencing.initialize_metadata() |> Map.fetch!("credential_epoch")
    {blockers, overflowed?} = decode_capacity_blockers(identity.metadata, epoch)

    %__MODULE__{
      upstream_identity_id: identity.id,
      raw_windows: raw_windows,
      availability: decode_availability(identity.metadata),
      credit_balance: credit_balance(identity.metadata, as_of),
      credit_balance_reported?: CreditBalanceStore.reported?(identity.metadata),
      capacity_facts: decode_capacity_facts(identity.metadata),
      capacity_blockers: blockers,
      capacity_blockers_overflowed?: overflowed?,
      capacity_facts_reported?: metadata_reported?(identity.metadata, "quota_capacity_facts"),
      capacity_blocker_reported?: metadata_reported?(identity.metadata, "quota_capacity_blocker"),
      allow_provider_credits: identity.allow_provider_credits,
      redemption: redemption(identity.metadata),
      credential_epoch: epoch,
      as_of: as_of
    }
  end

  @spec load_by_identity_ids([Ecto.UUID.t()], DateTime.t()) :: snapshot_map()
  def load_by_identity_ids(identity_ids, %DateTime{} = as_of) when is_list(identity_ids) do
    identity_ids = identity_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if identity_ids == [] do
      %{}
    else
      try do
        identity_ids
        |> load_rows()
        |> snapshots_from_rows(as_of)
      rescue
        _exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
          reraise LoadError, [message: "routing quota snapshot load failed"], __STACKTRACE__
      end
    end
  end

  # Rows past retention are invisible here exactly as they are after the
  # runtime-cleanup prune deletes them, so routing never depends on whether
  # that pass has run yet.
  @spec time_visible_raw_windows(t()) :: [AccountQuotaWindow.t()]
  def time_visible_raw_windows(%__MODULE__{raw_windows: raw_windows, as_of: as_of}) do
    raw_windows
    |> Enum.filter(fn %AccountQuotaWindow{observed_at: observed_at} ->
      DateTime.compare(observed_at, as_of) in [:lt, :eq]
    end)
    |> Retention.reject_past_retention(as_of)
  end

  @spec effective_windows(t()) :: [AccountQuotaWindow.t()]
  def effective_windows(%__MODULE__{as_of: as_of} = snapshot) do
    snapshot
    |> time_visible_raw_windows()
    |> ResetRecoverySelection.reject_recovered_prior_cycles(snapshot)
    |> Routing.reject_superseded_primary_windows(as_of)
    |> WindowSelector.logical_windows(as_of)
  end

  defp load_rows(identity_ids) do
    Repo.all(
      from identity in UpstreamIdentity,
        left_join: window in AccountQuotaWindow,
        on: window.upstream_identity_id == identity.id,
        where: identity.id in ^identity_ids,
        order_by: [
          asc: identity.id,
          asc: window.quota_key,
          asc: window.window_kind,
          asc: window.id
        ],
        select: %{
          upstream_identity_id: identity.id,
          metadata: identity.metadata,
          allow_provider_credits: identity.allow_provider_credits,
          window: window
        }
    )
  end

  defp snapshots_from_rows(rows, as_of) do
    rows
    |> Enum.group_by(& &1.upstream_identity_id)
    |> Map.new(fn {identity_id, identity_rows} ->
      metadata = identity_rows |> hd() |> Map.fetch!(:metadata)
      epoch = metadata |> CredentialFencing.initialize_metadata() |> Map.fetch!("credential_epoch")
      {blockers, overflowed?} = decode_capacity_blockers(metadata, epoch)

      {identity_id,
       %__MODULE__{
         upstream_identity_id: identity_id,
         raw_windows: Enum.flat_map(identity_rows, &present_window/1),
         availability: decode_availability(metadata),
         credit_balance: credit_balance(metadata, as_of),
         credit_balance_reported?: CreditBalanceStore.reported?(metadata),
         capacity_facts: decode_capacity_facts(metadata),
         capacity_blockers: blockers,
         capacity_blockers_overflowed?: overflowed?,
         capacity_facts_reported?: metadata_reported?(metadata, "quota_capacity_facts"),
         capacity_blocker_reported?: metadata_reported?(metadata, "quota_capacity_blocker"),
         allow_provider_credits: hd(identity_rows).allow_provider_credits,
         redemption: redemption(metadata),
         credential_epoch: epoch,
         as_of: as_of
       }}
    end)
  end

  defp present_window(%{window: %AccountQuotaWindow{} = window}), do: [window]
  defp present_window(%{window: nil}), do: []

  defp credit_balance(metadata, as_of) do
    epoch = metadata |> CredentialFencing.initialize_metadata() |> Map.fetch!("credential_epoch")
    CreditBalanceStore.current(metadata, epoch, as_of)
  end

  defp decode_availability(metadata) do
    case AccountAvailabilityStore.load(metadata) do
      {:ok, availability} -> availability
      :error -> nil
    end
  end

  defp decode_capacity_facts(metadata) do
    case CapacityFactsStore.load(metadata) do
      {:ok, facts} -> facts
      :error -> nil
    end
  end

  defp decode_capacity_blockers(metadata, epoch) do
    case CapacityFactsStore.load_blockers(metadata) do
      {:ok, %{credential_epoch: ^epoch, observations: observations, overflowed?: overflowed?}} -> {observations, overflowed?}
      {:ok, %{credential_epoch: previous}} when previous < epoch -> {[], false}
      {:ok, _future_epoch} -> {[], true}
      :error -> {[], metadata_reported?(metadata, "quota_capacity_blocker")}
    end
  end

  defp metadata_reported?(metadata, key) when is_map(metadata), do: Map.has_key?(metadata, key)
  defp metadata_reported?(_metadata, _key), do: false

  defp redemption(metadata) when is_map(metadata), do: Map.get(metadata, "saved_reset_redemption")
  defp redemption(_metadata), do: nil
end
