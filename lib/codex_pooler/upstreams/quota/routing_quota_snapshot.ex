defmodule CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing

  alias CodexPooler.Upstreams.Quota.{
    AccountAvailabilityStore,
    AccountQuotaWindow,
    WindowSelector
  }

  alias CodexPooler.Upstreams.Quota.Windows.Routing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @enforce_keys [
    :upstream_identity_id,
    :raw_windows,
    :availability,
    :credential_epoch,
    :as_of
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          upstream_identity_id: Ecto.UUID.t(),
          raw_windows: [AccountQuotaWindow.t()],
          availability: AccountAvailabilityStore.Snapshot.t() | nil,
          credential_epoch: pos_integer(),
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
    %__MODULE__{
      upstream_identity_id: identity.id,
      raw_windows: raw_windows,
      availability: decode_availability(identity.metadata),
      credential_epoch:
        identity.metadata
        |> CredentialFencing.initialize_metadata()
        |> Map.fetch!("credential_epoch"),
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

  @spec time_visible_raw_windows(t()) :: [AccountQuotaWindow.t()]
  def time_visible_raw_windows(%__MODULE__{raw_windows: raw_windows, as_of: as_of}) do
    Enum.filter(raw_windows, fn %AccountQuotaWindow{observed_at: observed_at} ->
      DateTime.compare(observed_at, as_of) in [:lt, :eq]
    end)
  end

  @spec effective_windows(t()) :: [AccountQuotaWindow.t()]
  def effective_windows(%__MODULE__{as_of: as_of} = snapshot) do
    snapshot
    |> time_visible_raw_windows()
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
          window: window
        }
    )
  end

  defp snapshots_from_rows(rows, as_of) do
    rows
    |> Enum.group_by(& &1.upstream_identity_id)
    |> Map.new(fn {identity_id, identity_rows} ->
      metadata = identity_rows |> hd() |> Map.fetch!(:metadata)

      {identity_id,
       %__MODULE__{
         upstream_identity_id: identity_id,
         raw_windows: Enum.flat_map(identity_rows, &present_window/1),
         availability: decode_availability(metadata),
         credential_epoch:
           metadata |> CredentialFencing.initialize_metadata() |> Map.fetch!("credential_epoch"),
         as_of: as_of
       }}
    end)
  end

  defp present_window(%{window: %AccountQuotaWindow{} = window}), do: [window]
  defp present_window(%{window: nil}), do: []

  defp decode_availability(metadata) do
    case AccountAvailabilityStore.load(metadata) do
      {:ok, availability} -> availability
      :error -> nil
    end
  end
end
