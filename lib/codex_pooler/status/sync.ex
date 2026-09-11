defmodule CodexPooler.Status.Sync do
  @moduledoc "Transactional OpenAI status feed synchronization."
  import Ecto.Query
  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Repo
  alias CodexPooler.Status.Events
  alias CodexPooler.Status.FeedClient
  alias CodexPooler.Status.Schemas.{FeedState, Incident}
  @retire_after 3
  @type result ::
          {:ok, map()} | {:not_modified, map()} | {:error, map() | Ecto.Changeset.t() | term()}
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Events.subscribe()

  @spec sync(keyword()) :: result()
  def sync(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
    fetcher = Keyword.get(opts, :fetcher, &FeedClient.fetch/2)
    state = OpenAIStatus.feed_state() || %FeedState{singleton: true}

    result =
      try do
        fetcher.(state_to_map(state), Keyword.put_new(opts, :now, now))
      rescue
        _ -> {:error, :sync_failed}
      catch
        _, _ -> {:error, :sync_failed}
      end

    case result do
      {:ok, parsed} ->
        case safe_persist_success(parsed, now) do
          {:ok, persisted} -> finish({:ok, persisted}, :ok)
          {:error, reason} -> finish(persist_failure(reason, now), :error)
        end

      {:not_modified, metadata} ->
        finish(persist_not_modified(metadata, now), :not_modified)

      {:error, reason} ->
        finish(persist_failure(reason, now), :error)

      _ ->
        finish(persist_failure(:sync_failed, now), :error)
    end
  end

  @spec cleanup(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(now \\ DateTime.utc_now(), opts \\ []), do: OpenAIStatus.cleanup(now, opts)

  defp persist_success(%{items: items} = parsed, now) when is_list(items) do
    Repo.transaction(fn -> persist_success_transaction(parsed, items, now) end)
  end

  defp persist_success(_parsed, _now), do: {:error, %{code: "sync_failed"}}

  defp safe_persist_success(parsed, now) do
    persist_success(parsed, now)
  rescue
    _error in Postgrex.Error -> {:error, :sync_failed}
  end

  defp persist_success_transaction(parsed, items, now) do
    OpenAIStatus.lock!()
    previous = Repo.get(FeedState, true)
    reject_stale(previous, now)
    existing = Repo.all(Incident)
    by_guid = Map.new(existing, &{&1.guid, &1})
    seen = MapSet.new(items, & &1.guid)
    changed_count = upsert_items(items, by_guid, now)
    omission_count = retire_omitted(existing, seen, now)
    active = active_count()
    state = persist_success_state(parsed, previous, active, now)

    %{
      changed_count: changed_count + omission_count,
      active_count: active,
      aggregate_revision: state.aggregate_revision,
      timestamp: now
    }
  end

  defp reject_stale(previous, now) do
    if stale_result?(previous, now), do: Repo.rollback(:stale_fetch)
  end

  defp upsert_items(items, by_guid, now) do
    Enum.reduce(items, 0, fn item, count ->
      previous_incident = by_guid[item.guid]

      case OpenAIStatus.upsert_incident_unlocked(incident_attrs(item), now) do
        {:ok, incident} -> count + changed_incident?(incident, previous_incident)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp changed_incident?(_incident, nil), do: 1

  defp changed_incident?(incident, previous),
    do: if(incident.revision != previous.revision, do: 1, else: 0)

  defp persist_success_state(parsed, previous, active, now) do
    {:ok, state} =
      OpenAIStatus.upsert_feed_state_unlocked(%{
        singleton: true,
        etag: Map.get(parsed, :etag),
        last_modified: Map.get(parsed, :last_modified),
        last_success_at: now,
        last_attempt_at: now,
        last_error_code: nil,
        last_error_at: nil,
        active_count: active,
        aggregate_revision: ((previous && previous.aggregate_revision) || 0) + 1,
        content_hash: Map.get(parsed, :content_hash),
        cap_pressure: OpenAIStatus.enforce_cap_unlocked(),
        updated_at: now
      })

    state
  end

  defp persist_not_modified(metadata, now) when is_map(metadata) do
    Repo.transaction(fn -> persist_not_modified_transaction(metadata, now) end)
  end

  defp persist_not_modified(_metadata, _now), do: {:error, %{code: "sync_failed"}}

  defp persist_not_modified_transaction(metadata, now) do
    OpenAIStatus.lock!()
    previous = Repo.get(FeedState, true) || %FeedState{singleton: true}
    reject_stale(previous, now)
    active = active_count()
    next_etag = Map.get(metadata, :etag, previous.etag)
    next_last_modified = Map.get(metadata, :last_modified, previous.last_modified)
    metadata_changed = metadata_changed?(previous, next_etag, next_last_modified, active, now)

    state =
      persist_not_modified_state(
        previous,
        next_etag,
        next_last_modified,
        active,
        metadata_changed,
        now
      )

    %{
      changed_count: 0,
      active_count: active,
      aggregate_revision: state.aggregate_revision,
      timestamp: now,
      notify?: metadata_changed
    }
  end

  defp metadata_changed?(previous, etag, last_modified, active, now) do
    previous.etag != etag or previous.last_modified != last_modified or
      previous.last_success_at != now or previous.last_attempt_at != now or
      previous.last_error_code != nil or previous.last_error_at != nil or
      (previous.active_count || 0) != active
  end

  defp persist_not_modified_state(previous, etag, last_modified, active, changed?, now) do
    {:ok, state} =
      OpenAIStatus.upsert_feed_state_unlocked(%{
        singleton: true,
        etag: etag,
        last_modified: last_modified,
        last_success_at: now,
        last_attempt_at: now,
        last_error_code: nil,
        last_error_at: nil,
        active_count: active,
        aggregate_revision: (previous.aggregate_revision || 0) + if(changed?, do: 1, else: 0),
        content_hash: previous.content_hash,
        cap_pressure: previous.cap_pressure || "none",
        updated_at: now
      })

    state
  end

  defp persist_failure(reason, now) do
    code = error_code(reason)

    case Repo.transaction(fn ->
           OpenAIStatus.lock!()
           previous = Repo.get(FeedState, true) || %FeedState{singleton: true}
           reject_stale(previous, now)

           {:ok, state} =
             OpenAIStatus.upsert_feed_state_unlocked(%{
               singleton: true,
               last_attempt_at: now,
               last_error_code: code,
               last_error_at: now,
               active_count: previous.active_count || active_count(),
               aggregate_revision: (previous.aggregate_revision || 0) + 1,
               content_hash: previous.content_hash,
               cap_pressure: previous.cap_pressure || "none",
               updated_at: now
             })

           %{
             changed_count: 0,
             active_count: state.active_count,
             aggregate_revision: state.aggregate_revision,
             timestamp: now,
             code: code
           }
         end) do
      {:ok, result} -> {:error, %{code: code, result: result}}
      {:error, reason} -> {:error, %{code: "sync_failed", reason: reason}}
    end
  end

  defp finish({:ok, result}, tag) do
    {notify?, result} = Map.pop(result, :notify?, true)

    event =
      Map.take(result, [:changed_count, :active_count, :aggregate_revision])
      |> Map.put(:event_version, 1)
      |> Map.put(:emitted_at, result.timestamp)

    if notify?, do: _ = Events.broadcast(event)
    {tag, result}
  end

  defp finish({:error, %{code: code, result: result}}, :error) when is_map(result) do
    if Map.has_key?(result, :aggregate_revision) do
      _ =
        Events.broadcast(%{
          event_version: 1,
          changed_count: 0,
          active_count: result.active_count,
          aggregate_revision: result.aggregate_revision,
          emitted_at: result.timestamp
        })
    end

    {:error, %{code: code}}
  end

  defp finish({:error, %{code: code}}, :error), do: {:error, %{code: code}}

  defp finish({:error, _}, tag),
    do:
      {tag,
       %{
         changed_count: 0,
         active_count: active_count(),
         aggregate_revision: 0,
         timestamp: DateTime.utc_now()
       }}

  defp stale_result?(nil, _), do: false
  defp stale_result?(%FeedState{last_attempt_at: nil}, _), do: false
  defp stale_result?(%FeedState{last_attempt_at: at}, now), do: DateTime.compare(at, now) != :lt

  defp retire_omitted(existing, seen, now) do
    existing
    |> Enum.filter(
      &(is_nil(&1.retired_at) and is_nil(&1.resolved_at) and not MapSet.member?(seen, &1.guid))
    )
    |> Enum.reduce(0, fn incident, count ->
      omission = min(incident.omission_count + 1, @retire_after)

      attrs = %{
        omission_count: omission,
        retired_at: if(omission >= @retire_after, do: now),
        updated_at: now
      }

      update_omitted(incident, attrs, omission, count)
    end)
  end

  defp update_omitted(incident, attrs, omission, count) do
    case incident |> Incident.changeset(attrs) |> Repo.update() do
      {:ok, _} -> count + retired_count(omission)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp retired_count(omission), do: if(omission >= @retire_after, do: 1, else: 0)

  defp incident_attrs(item),
    do:
      item
      |> Map.take([:guid, :title, :status, :summary, :component, :link, :published_at])
      |> Map.put(:content_hash, hash(item))

  defp hash(item),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          Map.take(item, [:guid, :title, :status, :summary, :component, :link, :published_at])
        )
      )
      |> Base.encode16(case: :lower)

  defp active_count,
    do:
      Repo.aggregate(
        from(i in Incident, where: is_nil(i.resolved_at) and is_nil(i.retired_at)),
        :count
      )

  defp state_to_map(%FeedState{} = state), do: Map.from_struct(state)
  defp state_to_map(state), do: state

  defp error_code(%{code: code})
       when code in [
              :body_too_large,
              :malformed_xml,
              :unsafe_xml,
              :invalid_body,
              :upstream_unavailable,
              :timeout,
              :not_modified,
              :invalid_feed
            ],
       do: Atom.to_string(code)

  defp error_code(%Ecto.Changeset{}), do: "invalid_feed"
  defp error_code(:invalid_feed), do: "invalid_feed"
  defp error_code(code) when code in [:sync_failed], do: "sync_failed"
  defp error_code(_), do: "sync_failed"
end
