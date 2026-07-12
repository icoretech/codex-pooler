defmodule CodexPooler.Upstreams.Quota.Windows do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.{
    Quota,
    Quota.Windows.Attributes,
    Quota.Windows.EvidenceStore,
    Quota.Windows.Routing,
    Quota.WindowSelector
  }

  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias Ecto.Multi

  @fresh "fresh"
  @account_quota_key "account"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_conflict :: IdentityLifecycle.identity_conflict()
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec upsert_quota_windows(identity_ref(), [map()], keyword()) ::
          {:ok, [Quota.AccountQuotaWindow.t()]}
          | {:error, Ecto.Changeset.t() | lifecycle_error() | identity_conflict()}
  def upsert_quota_windows(identity_or_id, windows, opts \\ [delete_missing?: false])

  def upsert_quota_windows(identity_or_id, windows, opts) when is_list(windows) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        guarded_upsert_quota_windows(identity, windows, opts)

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp guarded_upsert_quota_windows(%UpstreamIdentity{} = identity, windows, opts) do
    with :ok <-
           IdentityLifecycle.guard_workspace_slot_mutation(
             identity,
             Keyword.get(opts, :identity_attrs, %{})
           ) do
      do_upsert_quota_windows(identity, windows, Keyword.delete(opts, :identity_attrs))
    end
  end

  defp do_upsert_quota_windows(%UpstreamIdentity{} = identity, windows, opts) do
    delete_missing? = Keyword.fetch!(opts, :delete_missing?)
    covered_descriptors = Keyword.get(opts, :covered_descriptors, MapSet.new())

    windows =
      Enum.map(windows, fn attrs ->
        attrs
        |> normalize_upsert_quota_window_attrs()
        |> put_default(:metadata, %{})
        |> put_default(:source, "local_reconciliation")
        |> put_default(:freshness_state, @fresh)
      end)

    window_keys = Enum.map(windows, &Evidence.identity_key/1)

    if Enum.uniq(window_keys) != window_keys do
      {:error,
       lifecycle_error(:duplicate_quota_window_kind, "quota window identities must be unique")}
    else
      Enum.reduce(windows, Multi.new(), fn attrs, multi ->
        Multi.run(multi, {:quota_window, Evidence.identity_key(attrs)}, fn _repo, _changes ->
          # Reason: Multi callback normalizes quota evidence errors at the boundary.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case EvidenceStore.record_evidence(identity, attrs, now()) do
            {:ok, window} -> {:ok, window}
            {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
            {:error, errors} -> {:error, quota_window_error_changeset(identity, attrs, errors)}
          end
        end)
      end)
      |> maybe_delete_missing_quota_windows(
        identity,
        windows,
        delete_missing?,
        covered_descriptors
      )
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          quota_windows =
            changes
            |> Map.values()
            |> Enum.filter(&match?(%Quota.AccountQuotaWindow{}, &1))
            |> Enum.sort_by(&{&1.quota_key, &1.window_kind})

          broadcast_upstream_change(%{identity: identity}, "upstream_quota_windows_updated")

          {:ok, quota_windows}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp normalize_upsert_quota_window_attrs(attrs) do
    attrs = Attributes.normalize(attrs)

    attrs
    |> Map.put(
      :quota_key,
      attrs |> Map.get(:quota_key, @account_quota_key) |> normalize_quota_key()
    )
    |> Map.update!(:window_kind, &normalize_token/1)
  end

  @spec evidence_changeset(identity_ref(), map(), DateTime.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, Evidence.errors() | map()}
  def evidence_changeset(identity_or_id, attrs, observed_at \\ now()) do
    EvidenceStore.evidence_changeset(identity_or_id, attrs, observed_at)
  end

  @spec record_evidence(identity_ref(), map(), DateTime.t()) ::
          {:ok, Quota.AccountQuotaWindow.t()}
          | {:error, Ecto.Changeset.t() | Evidence.errors() | map()}
  def record_evidence(identity_or_id, attrs, observed_at \\ now()) do
    EvidenceStore.record_evidence(identity_or_id, attrs, observed_at)
  end

  @spec list_evidence(identity_ref()) :: [Quota.AccountQuotaWindow.t()]
  def list_evidence(identity_or_id) do
    EvidenceStore.list_evidence(identity_or_id)
  end

  defp maybe_delete_missing_quota_windows(multi, _identity, _windows, false, _coverage),
    do: multi

  defp maybe_delete_missing_quota_windows(multi, _identity, [], true, _coverage), do: multi

  defp maybe_delete_missing_quota_windows(multi, _identity, _windows, true, coverage)
       when not is_struct(coverage, MapSet),
       do: multi

  defp maybe_delete_missing_quota_windows(multi, _identity, _windows, true, coverage)
       when map_size(coverage.map) == 0,
       do: multi

  defp maybe_delete_missing_quota_windows(multi, identity, windows, true, covered_descriptors) do
    Multi.run(multi, :delete_missing_quota_windows, fn repo, _changes ->
      incoming_identities =
        windows
        |> Enum.map(&Evidence.identity_key/1)
        |> MapSet.new()

      stale_ids =
        Quota.AccountQuotaWindow
        |> where([window], window.upstream_identity_id == ^identity.id)
        |> where([window], window.source == "codex_usage_api")
        |> repo.all()
        |> Enum.filter(&(Evidence.descriptor_key(&1) in covered_descriptors))
        |> Enum.reject(&(Evidence.identity_key(&1) in incoming_identities))
        |> Enum.map(& &1.id)

      {deleted_count, _rows} =
        from(window in Quota.AccountQuotaWindow, where: window.id in ^stale_ids)
        |> repo.delete_all()

      {:ok, deleted_count}
    end)
  end

  defp quota_window_error_changeset(identity, attrs, _errors) do
    timestamp = now()

    %Quota.AccountQuotaWindow{}
    |> Quota.AccountQuotaWindow.changeset(
      attrs
      |> Map.put(:upstream_identity_id, identity.id)
      |> put_default(:last_sync_at, timestamp)
      |> put_default(:created_at, timestamp)
      |> Map.put(:updated_at, timestamp)
    )
  end

  @spec list_quota_windows(identity_ref(), DateTime.t() | nil) :: [Quota.AccountQuotaWindow.t()]
  def list_quota_windows(identity_or_id, as_of \\ nil) do
    identity_or_id
    |> list_evidence()
    |> effective_windows(as_of || now())
  end

  @doc """
  Effective read-side view of a persisted evidence list: rows observed after
  `as_of` are excluded, logical windows are folded, and superseded primary
  shapes are rejected. Every read surface (operator projections, bulk stats,
  charts, alerts, usage compatibility responses) must consume this view so it
  agrees with routing about which windows exist at that instant.
  """
  @spec effective_quota_windows([Quota.AccountQuotaWindow.t()], DateTime.t() | nil) ::
          [Quota.AccountQuotaWindow.t()]
  def effective_quota_windows(windows, as_of \\ nil) when is_list(windows) do
    effective_windows(windows, as_of || now())
  end

  # A frozen 5h (or monthly) primary whose quota group kept syncing must not
  # render a stale card or timer after the provider stops reporting the shape.
  # Callers that evaluate at an explicit timestamp must pass it through so the
  # effective view is computed against the same clock as their own checks;
  # `WindowSelector.logical_windows/2` also drops evidence observed after that
  # timestamp so historical evaluations never rank against future rows.
  defp effective_windows(windows, %DateTime{} = as_of) do
    windows
    |> WindowSelector.logical_windows(as_of)
    |> Routing.reject_superseded_primary_windows(as_of)
  end

  defp list_persisted_quota_windows(identity_or_id) do
    case identity_id(identity_or_id) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from window in Quota.AccountQuotaWindow,
            where: window.upstream_identity_id == ^identity_id,
            order_by: [asc: window.quota_key, asc: window.window_kind]
        )

      nil ->
        []
    end
  end

  @spec list_quota_windows_by_identity_ids([Ecto.UUID.t()], DateTime.t() | nil) :: %{
          optional(Ecto.UUID.t()) => [Quota.AccountQuotaWindow.t()]
        }
  def list_quota_windows_by_identity_ids(identity_ids, as_of \\ nil)
      when is_list(identity_ids) do
    as_of = as_of || now()

    identity_ids
    |> list_evidence_by_identity_ids()
    |> Map.new(fn {identity_id, identity_windows} ->
      {identity_id, effective_windows(identity_windows, as_of)}
    end)
  end

  @spec list_evidence_by_identity_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => [Quota.AccountQuotaWindow.t()]
        }
  def list_evidence_by_identity_ids(identity_ids) when is_list(identity_ids) do
    identity_ids = Enum.filter(Enum.uniq(identity_ids), &is_binary/1)

    windows =
      if identity_ids == [] do
        []
      else
        Repo.all(
          from window in Quota.AccountQuotaWindow,
            where: window.upstream_identity_id in ^identity_ids,
            order_by: [
              asc: window.upstream_identity_id,
              asc: window.quota_key,
              asc: window.window_kind
            ]
        )
      end

    empty_snapshots = Map.new(identity_ids, &{&1, []})

    Map.merge(
      empty_snapshots,
      Enum.group_by(windows, & &1.upstream_identity_id)
    )
  end

  @spec quota_window_selection_data(identity_ref(), keyword()) :: map()
  def quota_window_selection_data(identity_or_id, opts \\ []) do
    # Selection applies `WindowSelector.logical_windows/2` itself with the
    # caller's `:at` timestamp, so it must receive raw evidence: pre-collapsing
    # through `list_quota_windows/1` would dedupe logical windows against the
    # wall clock and can pick a different representative than the timestamp
    # the caller is evaluating.
    windows = list_evidence(identity_or_id)

    quota_window_selection_data_from_windows(windows, opts)
  end

  @spec quota_window_selection_data_from_windows([Quota.AccountQuotaWindow.t()], keyword()) ::
          map()
  def quota_window_selection_data_from_windows(windows, opts \\ []) when is_list(windows) do
    Routing.selection_data_from_windows(windows, opts)
  end

  @spec routing_quota_eligibility(identity_ref(), keyword()) :: map()
  def routing_quota_eligibility(identity_or_id, opts \\ []) do
    selection = quota_window_selection_data(identity_or_id, opts)

    Routing.eligibility_from_selection(selection, opts)
  end

  @spec routing_quota_eligibility_from_windows([Quota.AccountQuotaWindow.t()], keyword()) :: map()
  def routing_quota_eligibility_from_windows(windows, opts \\ []) when is_list(windows) do
    Routing.eligibility_from_windows(windows, opts)
  end

  @spec reject_superseded_primary_windows([Quota.AccountQuotaWindow.t()], DateTime.t()) ::
          [Quota.AccountQuotaWindow.t()]
  def reject_superseded_primary_windows(windows, timestamp \\ now()) when is_list(windows) do
    Routing.reject_superseded_primary_windows(windows, timestamp)
  end

  @spec fresh_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def fresh_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Routing.fresh_window?(window, timestamp)
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Routing.usable_window?(window, timestamp)
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t(), keyword()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp, opts) when is_list(opts) do
    Routing.usable_window?(window, timestamp, opts)
  end

  @spec routing_window_exclusion(Quota.AccountQuotaWindow.t(), DateTime.t()) :: map()
  def routing_window_exclusion(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Routing.window_exclusion(window, timestamp)
  end

  @spec routing_window_reason_codes(Quota.AccountQuotaWindow.t(), DateTime.t()) :: [String.t()]
  def routing_window_reason_codes(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Routing.window_reason_codes(window, timestamp)
  end

  @spec codex_usage_quota_windows_from_payload(term(), DateTime.t()) ::
          {:ok, [map()]} | {:error, lifecycle_error()}
  def codex_usage_quota_windows_from_payload(payload, synced_at \\ now())

  def codex_usage_quota_windows_from_payload(payload, synced_at) do
    case Quota.Evidence.codex_usage_windows_from_payload(payload, synced_at) do
      {:ok, windows} -> {:ok, windows}
      {:error, %{code: code, message: message}} -> {:error, lifecycle_error(code, message)}
    end
  end

  @spec upsert_quota_windows_from_codex_usage_payload(identity_ref(), term(), DateTime.t()) ::
          {:ok, [Quota.AccountQuotaWindow.t()]}
          | {:error, Ecto.Changeset.t() | lifecycle_error() | identity_conflict()}
  def upsert_quota_windows_from_codex_usage_payload(identity_or_id, payload, synced_at \\ now()) do
    with {:ok, windows} <- codex_usage_quota_windows_from_payload(payload, synced_at),
         %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id) do
      guarded_upsert_quota_windows(identity, windows,
        delete_missing?: false,
        identity_attrs: identity_attrs_from_codex_usage_payload(payload)
      )
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  @spec upsert_quota_windows_from_codex_headers(identity_ref(), term(), DateTime.t()) ::
          {:ok, [Quota.AccountQuotaWindow.t()]} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  def upsert_quota_windows_from_codex_headers(identity_or_id, headers, synced_at \\ now()) do
    with [_ | _] = windows <- quota_windows_from_codex_headers(headers, synced_at),
         %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id) do
      guarded_upsert_quota_windows(identity, windows, delete_missing?: false)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      [] ->
        {:ok, []}
    end
  end

  @spec upsert_quota_windows_from_codex_rate_limit_event(identity_ref(), term(), DateTime.t()) ::
          {:ok, [Quota.AccountQuotaWindow.t()]} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  def upsert_quota_windows_from_codex_rate_limit_event(identity_or_id, event, synced_at \\ now()) do
    with [_ | _] = windows <- quota_windows_from_codex_rate_limit_event(event, synced_at),
         %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id) do
      guarded_upsert_quota_windows(identity, windows, delete_missing?: false)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      [] ->
        {:ok, []}
    end
  end

  @spec upsert_quota_windows_from_codex_rate_limit_error(identity_ref(), term(), DateTime.t()) ::
          {:ok, [Quota.AccountQuotaWindow.t()]} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  def upsert_quota_windows_from_codex_rate_limit_error(
        identity_or_id,
        payload,
        synced_at \\ now()
      ) do
    with [_ | _] = windows <- quota_windows_from_codex_rate_limit_error(payload, synced_at),
         %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id) do
      guarded_upsert_quota_windows(identity, windows, delete_missing?: false)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      [] ->
        {:ok, []}
    end
  end

  defp identity_attrs_from_codex_usage_payload(%{"plan_type" => plan_type})
       when is_binary(plan_type) do
    %{plan_family: normalize_plan_family(plan_type), plan_label: plan_type}
  end

  defp identity_attrs_from_codex_usage_payload(_payload), do: %{}

  defp normalize_plan_family(plan) do
    plan
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> present_string()
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp quota_windows_from_codex_headers(headers, synced_at) do
    Quota.Evidence.codex_header_windows(headers, synced_at)
  end

  defp quota_windows_from_codex_rate_limit_event(event, synced_at) do
    Quota.Evidence.codex_rate_limit_event_windows(event, synced_at)
  end

  defp quota_windows_from_codex_rate_limit_error(payload, synced_at) do
    Quota.Evidence.codex_rate_limit_error_windows(payload, synced_at)
  end

  @spec quota_windows_from_metadata(term()) :: [map()]
  def quota_windows_from_metadata(metadata), do: Attributes.from_metadata(metadata)

  @spec existing_quota_window_attrs(identity_ref()) :: [map()]
  def existing_quota_window_attrs(identity) do
    identity
    |> list_persisted_quota_windows()
    |> Attributes.from_windows()
  end

  defp normalize_quota_key(nil), do: nil

  defp normalize_quota_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_quota_key(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_quota_key()

  defp normalize_quota_key(value), do: value |> to_string() |> normalize_quota_key()

  defp broadcast_upstream_change(%{identity: %UpstreamIdentity{} = identity}, reason) do
    identity.id
    |> assignments_for_identity()
    |> Enum.each(&broadcast_upstream_assignment(&1, identity, reason))
  end

  defp broadcast_upstream_assignment(%PoolUpstreamAssignment{} = assignment, identity, reason) do
    Events.broadcast_upstreams(assignment.pool_id, reason, %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      upstream_status: identity.status,
      assignment_status: assignment.status
    })
  end

  defp assignments_for_identity(identity_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.upstream_identity_id == ^identity_id,
        order_by: [asc: assignment.created_at, asc: assignment.id]
    )
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp normalize_identity(%UpstreamIdentity{status: status} = identity) when is_binary(status),
    do: identity

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_token(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
