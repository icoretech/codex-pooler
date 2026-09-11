defmodule CodexPooler.OpenAIStatus do
  @moduledoc "Postgres-backed, metadata-only OpenAI status feed boundary."

  import Ecto.Query
  alias CodexPooler.Repo
  alias CodexPooler.Status.Schemas.{Dismissal, FeedState, Incident}
  alias CodexPooler.Status.Sync

  @cap 500
  @retention_days 90

  @spec feed_state() :: FeedState.t() | nil
  def feed_state, do: Repo.get(FeedState, true)

  @spec sync(keyword()) :: Sync.result()
  defdelegate sync(opts \\ []), to: Sync
  @spec subscribe() :: :ok | {:error, term()}
  defdelegate subscribe(), to: Sync

  @spec list_incidents(keyword()) :: [Incident.t()]
  def list_incidents(opts \\ []) do
    limit = min(max(Keyword.get(opts, :limit, @cap), 0), @cap)
    from(i in Incident, order_by: [desc: i.last_seen_at, desc: i.id], limit: ^limit) |> Repo.all()
  end

  @spec active_incidents() :: [Incident.t()]
  def active_incidents do
    from(i in Incident,
      where: is_nil(i.resolved_at) and is_nil(i.retired_at),
      order_by: [desc: i.last_seen_at]
    )
    |> Repo.all()
  end

  @spec aggregate(keyword()) :: map()
  def aggregate(opts \\ []) do
    state = feed_state()
    active = active_incidents()
    operator_id = Keyword.get(opts, :operator_id)
    visible = visible_incidents(active, operator_id)

    %{
      incidents: visible,
      active_count: length(active),
      aggregate_revision: (state && state.aggregate_revision) || 0,
      last_success_at: state && state.last_success_at,
      last_attempt_at: state && state.last_attempt_at,
      last_error_code: state && state.last_error_code,
      stale?: stale?(state),
      cap_pressure: (state && state.cap_pressure) || "none"
    }
  end

  @spec upsert_feed_state(map()) :: {:ok, FeedState.t()} | {:error, Ecto.Changeset.t()}
  def upsert_feed_state(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      lock!()

      case upsert_feed_state_unlocked(attrs) do
        {:ok, state} -> state
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc false
  def upsert_feed_state_unlocked(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :singleton, true) |> Map.put_new(:updated_at, DateTime.utc_now())
    state = Repo.get(FeedState, true) || %FeedState{singleton: true}
    state |> FeedState.changeset(attrs) |> Repo.insert_or_update()
  end

  @spec upsert_incident(map(), DateTime.t()) ::
          {:ok, Incident.t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert_incident(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    Repo.transaction(fn ->
      lock!()

      case upsert_incident_unlocked(attrs, now) do
        {:ok, incident} ->
          _ = enforce_cap_unlocked()
          incident

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, incident} -> {:ok, incident}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc false
  @spec upsert_incident_unlocked(map(), DateTime.t()) ::
          {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def upsert_incident_unlocked(attrs, now \\ DateTime.utc_now()) do
    attrs = normalize_input(attrs)
    guid = attrs[:guid]
    existing = if is_binary(guid), do: Repo.get_by(Incident, guid: guid)
    normalized = normalize_incident_attrs(attrs, existing, now)
    (existing || %Incident{}) |> Incident.changeset(normalized) |> Repo.insert_or_update()
  end

  @doc false
  def lock!,
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "codex_pooler:openai_status_mutation"
      ])

  @doc false
  def enforce_cap_unlocked do
    total = Repo.aggregate(Incident, :count)
    excess = max(total - @cap, 0)

    if excess > 0 do
      ids =
        from(i in Incident,
          where: not is_nil(i.resolved_at) or not is_nil(i.retired_at),
          order_by: [asc: fragment("COALESCE(?, ?)", i.resolved_at, i.retired_at), asc: i.id],
          limit: ^excess,
          select: i.id
        )
        |> Repo.all()

      {count, _} = Repo.delete_all(from(i in Incident, where: i.id in ^ids))
      if count < excess, do: "active_over_cap", else: "none"
    else
      "none"
    end
  end

  @spec dismiss(binary(), binary(), integer(), DateTime.t()) ::
          {:ok, Dismissal.t()} | {:error, term()}
  def dismiss(operator_id, incident_id, revision, now \\ DateTime.utc_now()) do
    Repo.transaction(fn -> dismiss_transaction(operator_id, incident_id, revision, now) end)
    |> case do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dismiss_many(binary(), [{binary(), integer()}], DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def dismiss_many(operator_id, viewed, now \\ DateTime.utc_now()) when is_list(viewed) do
    Repo.transaction(fn -> dismiss_many_transaction(operator_id, viewed, now) end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def bump_revision_unlocked(now) do
    state = Repo.get(FeedState, true) || %FeedState{singleton: true}

    case upsert_feed_state_unlocked(%{
           singleton: true,
           aggregate_revision: (state.aggregate_revision || 0) + 1,
           active_count: state.active_count || 0,
           updated_at: now
         }) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @spec cleanup(DateTime.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(now \\ DateTime.utc_now(), opts \\ []) do
    cutoff =
      DateTime.add(now, -Keyword.get(opts, :retention_days, @retention_days) * 86_400, :second)

    batch_size = min(max(Keyword.get(opts, :batch_size, 100), 0), 100)

    Repo.transaction(fn ->
      lock!()

      ids =
        from(i in Incident,
          where:
            (not is_nil(i.resolved_at) and i.resolved_at < ^cutoff) or
              (not is_nil(i.retired_at) and i.retired_at < ^cutoff),
          order_by: [asc: fragment("COALESCE(?, ?)", i.resolved_at, i.retired_at), asc: i.id],
          limit: ^batch_size,
          select: i.id
        )
        |> Repo.all()

      {count, _} = Repo.delete_all(from(i in Incident, where: i.id in ^ids))
      if count > 0, do: bump_revision_unlocked(now)
      count
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_incident_attrs(attrs, nil, now) do
    status = attrs[:status]

    Map.merge(attrs, %{
      summary: attrs[:summary] || "",
      first_seen_at: now,
      last_seen_at: now,
      revision: 1,
      omission_count: 0,
      resolved_at: if(status == "Resolved", do: now),
      created_at: now,
      updated_at: now
    })
  end

  defp normalize_incident_attrs(attrs, existing, now) do
    material = [:title, :status, :summary, :component, :link, :published_at, :content_hash]

    status = attrs[:status] || existing.status

    changed? = incident_changed?(attrs, existing, material, status)

    resolved_at =
      cond do
        status == "Resolved" and existing.resolved_at == nil -> now
        status == "Resolved" -> existing.resolved_at
        true -> nil
      end

    attrs
    |> Map.merge(%{
      first_seen_at: existing.first_seen_at,
      last_seen_at: now,
      revision: if(changed?, do: existing.revision + 1, else: existing.revision),
      omission_count: 0,
      resolved_at: resolved_at,
      retired_at: nil,
      updated_at: if(changed?, do: now, else: existing.updated_at)
    })
  end

  defp dismiss_transaction(operator_id, incident_id, revision, now) do
    lock!()

    case Repo.get(Incident, incident_id) do
      %Incident{revision: ^revision} = incident ->
        insert_dismissal(operator_id, incident, revision, now)

      _ ->
        Repo.rollback(:invalid_revision)
    end
  end

  defp insert_dismissal(operator_id, incident, revision, now) do
    attrs = %{
      operator_id: operator_id,
      incident_id: incident.id,
      incident_revision: revision,
      dismissed_at: now
    }

    case %Dismissal{}
         |> Dismissal.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: [:operator_id, :incident_id, :incident_revision]
         ) do
      {:ok, receipt} ->
        bump_revision_unlocked(now)
        receipt

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp dismiss_many_transaction(operator_id, viewed, now) do
    lock!()
    ids = Enum.sort(Enum.uniq(viewed))
    incidents = load_incidents(ids)
    validate_revisions(ids, incidents)
    count = insert_dismissals(ids, operator_id, now)
    if count > 0, do: bump_revision_unlocked(now)
    count
  end

  defp load_incidents(ids) do
    Repo.all(from i in Incident, where: i.id in ^Enum.map(ids, &elem(&1, 0)))
    |> Map.new(&{&1.id, &1})
  end

  defp validate_revisions(ids, incidents) do
    if Enum.any?(ids, fn {id, rev} -> incidents[id] == nil or incidents[id].revision != rev end),
      do: Repo.rollback(:invalid_revision_set)
  end

  defp insert_dismissals(ids, operator_id, now) do
    Enum.count(ids, fn {id, rev} ->
      case %Dismissal{}
           |> Dismissal.changeset(%{
             operator_id: operator_id,
             incident_id: id,
             incident_revision: rev,
             dismissed_at: now
           })
           |> Repo.insert(
             on_conflict: :nothing,
             conflict_target: [:operator_id, :incident_id, :incident_revision]
           ) do
        {:ok, %{id: receipt_id}} when not is_nil(receipt_id) -> true
        _ -> false
      end
    end)
  end

  defp incident_changed?(attrs, existing, material, status) do
    existing.retired_at != nil or (existing.resolved_at != nil and status != "Resolved") or
      Enum.any?(material, &(Map.get(attrs, &1, Map.get(existing, &1)) != Map.get(existing, &1)))
  end

  defp normalize_input(attrs) do
    attrs =
      Map.new(attrs, fn {k, v} -> {if(is_atom(k), do: k, else: String.to_existing_atom(k)), v} end)

    Map.update(attrs, :status, "Unknown", &normalize_status/1)
  rescue
    _ -> attrs
  end

  defp normalize_status(v) do
    case String.downcase(String.trim(to_string(v))) do
      "investigating" -> "Investigating"
      "identified" -> "Identified"
      "monitoring" -> "Monitoring"
      "resolved" -> "Resolved"
      _ -> "Unknown"
    end
  end

  defp dismissed_ids(operator_id, incidents) do
    ids = Enum.map(incidents, & &1.id)

    from(d in Dismissal,
      where: d.operator_id == ^operator_id and d.incident_id in ^ids,
      select: {d.incident_id, d.incident_revision}
    )
    |> Repo.all()
    |> MapSet.new()
    |> then(fn set ->
      incidents |> Enum.filter(&MapSet.member?(set, {&1.id, &1.revision})) |> MapSet.new(& &1.id)
    end)
  end

  defp visible_incidents(incidents, nil), do: incidents

  defp visible_incidents(incidents, operator_id) do
    dismissed = dismissed_ids(operator_id, incidents)
    Enum.reject(incidents, &MapSet.member?(dismissed, &1.id))
  end

  defp stale?(nil), do: true
  defp stale?(%FeedState{last_success_at: nil}), do: true

  defp stale?(%FeedState{last_success_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) > 900
end
