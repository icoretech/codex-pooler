defmodule CodexPooler.Pools.ModelServingModes do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.{Audit, Events}
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Pools.{Authorization, ModelServingOverride, Pool}
  alias CodexPooler.Repo

  @active "active"
  @auto "auto"
  @transaction_conflict_codes [:deadlock_detected, :lock_not_available, :serialization_failure]

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type override_map :: %{optional(String.t()) => ModelServingOverride.t()}
  @type snapshot :: %{
          required(:overrides) => [ModelServingOverride.t()],
          required(:revision) => String.t()
        }
  @type update_result :: %{
          required(:overrides) => [ModelServingOverride.t()],
          required(:revision) => String.t(),
          required(:changed?) => boolean()
        }

  @spec snapshot(Scope.t(), Pool.t() | Ecto.UUID.t()) ::
          {:ok, snapshot()} | {:error, access_error()}
  def snapshot(%Scope{} = scope, pool_or_id) do
    with {:ok, pool_id} <- normalize_pool_id(pool_or_id),
         {:ok, _decision} <- authorize(scope, pool_id) do
      overrides = list_overrides(pool_id)
      {:ok, snapshot(overrides)}
    end
  end

  @spec by_pool_ids([Ecto.UUID.t() | nil]) :: %{optional(Ecto.UUID.t()) => override_map()}
  def by_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids =
      pool_ids
      |> Enum.flat_map(fn pool_id ->
        case normalize_pool_id(pool_id) do
          {:ok, normalized_pool_id} -> [normalized_pool_id]
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    overrides =
      case pool_ids do
        [] -> []
        ids -> Repo.all(from override in ModelServingOverride, where: override.pool_id in ^ids)
      end

    grouped =
      overrides
      |> Enum.group_by(& &1.pool_id)
      |> Map.new(fn {pool_id, rows} ->
        {pool_id, Map.new(rows, &{&1.exposed_model_id, &1})}
      end)

    Map.new(pool_ids, &{&1, Map.get(grouped, &1, %{})})
  end

  def by_pool_ids(_pool_ids), do: %{}

  @spec update(Scope.t(), Pool.t() | Ecto.UUID.t(), [map()], String.t()) ::
          {:ok, update_result()} | {:error, access_error()}
  def update(%Scope{} = scope, pool_or_id, submitted_rows, expected_revision)
      when is_list(submitted_rows) and is_binary(expected_revision) do
    with {:ok, pool_id} <- normalize_pool_id(pool_or_id),
         {:ok, _decision} <- authorize(scope, pool_id),
         {:ok, normalized_rows} <- normalize_submitted_rows(submitted_rows) do
      transact_update(scope, pool_id, normalized_rows, expected_revision)
    end
  end

  def update(%Scope{} = scope, pool_or_id, _submitted_rows, _expected_revision) do
    with {:ok, pool_id} <- normalize_pool_id(pool_or_id),
         {:ok, _decision} <- authorize(scope, pool_id) do
      {:error, error(:invalid_request, "model serving rows and revision are required")}
    end
  end

  defp update_locked(scope, pool_id, normalized_rows, expected_revision) do
    with {:ok, pool} <- lock_active_pool(pool_id),
         _locked_overrides <- lock_affected_overrides(pool_id, normalized_rows),
         {:ok, _decision} <- authorize(scope, pool_id),
         current_overrides <- list_overrides(pool_id),
         {:ok, known_model_ids} <- known_model_ids(pool, current_overrides),
         :ok <- require_revision(current_overrides, expected_revision),
         :ok <- validate_known_models(normalized_rows, known_model_ids),
         {result, transitions} <- persist_changes(pool_id, current_overrides, normalized_rows),
         :ok <- record_audit(scope, pool, transitions),
         :ok <- emit_event(pool, transitions) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_changes(pool_id, current_overrides, submitted_rows) do
    current_by_id = Map.new(current_overrides, &{&1.exposed_model_id, &1})

    delete_ids =
      for %{exposed_model_id: exposed_model_id, mode: @auto} <- submitted_rows,
          Map.has_key?(current_by_id, exposed_model_id),
          do: exposed_model_id

    upsert_rows =
      for %{exposed_model_id: exposed_model_id, mode: mode} <- submitted_rows,
          mode != @auto,
          not match?(
            %ModelServingOverride{mode: ^mode},
            Map.get(current_by_id, exposed_model_id)
          ),
          do: %{exposed_model_id: exposed_model_id, mode: mode}

    transitions = transitions(current_by_id, submitted_rows)
    changed? = transitions != []

    if changed?, do: write_changes(pool_id, delete_ids, upsert_rows)

    result =
      pool_id
      |> list_overrides()
      |> snapshot()
      |> Map.put(:changed?, changed?)

    {result, transitions}
  end

  defp write_changes(pool_id, delete_ids, upsert_rows) do
    delete_overrides(pool_id, Enum.sort(delete_ids))
    upsert_overrides(pool_id, Enum.sort_by(upsert_rows, & &1.exposed_model_id))
  end

  defp delete_overrides(_pool_id, []), do: :ok

  defp delete_overrides(pool_id, delete_ids) do
    Repo.delete_all(
      from override in ModelServingOverride,
        where: override.pool_id == ^pool_id and override.exposed_model_id in ^delete_ids
    )

    :ok
  end

  defp upsert_overrides(_pool_id, []), do: :ok

  defp upsert_overrides(pool_id, upsert_rows) do
    timestamp = now()

    rows =
      Enum.map(upsert_rows, fn row ->
        Map.merge(row, %{
          id: Ecto.UUID.generate(),
          pool_id: pool_id,
          created_at: timestamp,
          updated_at: timestamp
        })
      end)

    Repo.insert_all(ModelServingOverride, rows,
      on_conflict: {:replace, [:mode, :updated_at]},
      conflict_target: [:pool_id, :exposed_model_id]
    )

    :ok
  end

  defp normalize_submitted_rows(rows) do
    with {:ok, normalized} <- reduce_submitted_rows(rows, []),
         :ok <- reject_duplicates(normalized) do
      {:ok, Enum.sort_by(normalized, & &1.exposed_model_id)}
    end
  end

  defp reduce_submitted_rows([], normalized), do: {:ok, Enum.reverse(normalized)}

  defp reduce_submitted_rows([row | rest], normalized) when is_map(row) do
    exposed_model_id =
      row
      |> attr(:exposed_model_id)
      |> ModelServingOverride.canonical_exposed_model_id()

    mode = row |> attr(:mode) |> normalize_mode()

    cond do
      is_nil(exposed_model_id) ->
        {:error, error(:invalid_model, "model identifier is invalid")}

      mode not in [@auto | ModelServingOverride.modes()] ->
        {:error, error(:invalid_mode, "model serving mode is invalid")}

      true ->
        reduce_submitted_rows(rest, [
          %{exposed_model_id: exposed_model_id, mode: mode} | normalized
        ])
    end
  end

  defp reduce_submitted_rows(_rows, _normalized),
    do: {:error, error(:invalid_request, "model serving rows are invalid")}

  defp reject_duplicates(rows) do
    model_ids = Enum.map(rows, & &1.exposed_model_id)

    if length(model_ids) == length(Enum.uniq(model_ids)) do
      :ok
    else
      {:error, error(:duplicate_model, "model identifier was submitted more than once")}
    end
  end

  defp validate_known_models(rows, known_model_ids) do
    unknown_ids =
      rows
      |> Enum.map(& &1.exposed_model_id)
      |> Enum.reject(&MapSet.member?(known_model_ids, &1))

    if unknown_ids == [] do
      :ok
    else
      {:error, error(:unknown_model, "model identifier is not available for this Pool")}
    end
  end

  defp known_model_ids(%Pool{} = pool, current_overrides) do
    visible_model_ids =
      pool
      |> CandidateEligibility.hydrate_model_visibility()
      |> Map.fetch!(:visible_models)
      |> Enum.map(& &1.exposed_model_id)

    known_ids =
      visible_model_ids
      |> Kernel.++(Enum.map(current_overrides, & &1.exposed_model_id))
      |> Enum.map(&ModelServingOverride.canonical_exposed_model_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {:ok, known_ids}
  end

  defp lock_affected_overrides(_pool_id, []), do: []

  defp lock_affected_overrides(pool_id, normalized_rows) do
    exposed_model_ids = Enum.map(normalized_rows, & &1.exposed_model_id)

    Repo.all(
      from override in ModelServingOverride,
        where:
          override.pool_id == ^pool_id and
            override.exposed_model_id in ^exposed_model_ids,
        order_by: [asc: override.exposed_model_id],
        lock: "FOR UPDATE"
    )
  end

  defp lock_active_pool(pool_id) do
    case Repo.one(
           from pool in Pool,
             where: pool.id == ^pool_id and pool.status == ^@active,
             lock: "FOR UPDATE"
         ) do
      %Pool{} = pool -> {:ok, pool}
      nil -> {:error, error(:pool_not_found, "pool was not found")}
    end
  end

  defp require_revision(overrides, expected_revision) do
    if revision(overrides) == expected_revision do
      :ok
    else
      {:error, error(:stale_revision, "model serving modes changed since they were loaded")}
    end
  end

  defp list_overrides(pool_id) do
    Repo.all(
      from override in ModelServingOverride,
        where: override.pool_id == ^pool_id,
        order_by: [asc: override.exposed_model_id]
    )
  end

  defp snapshot(overrides), do: %{overrides: overrides, revision: revision(overrides)}

  defp transitions(current_by_id, submitted_rows) do
    Enum.flat_map(submitted_rows, fn %{exposed_model_id: exposed_model_id, mode: to_mode} ->
      from_mode = configured_mode(Map.get(current_by_id, exposed_model_id))

      if from_mode == to_mode do
        []
      else
        [%{exposed_model_id: exposed_model_id, from_mode: from_mode, to_mode: to_mode}]
      end
    end)
  end

  defp configured_mode(%ModelServingOverride{mode: mode}), do: mode
  defp configured_mode(nil), do: @auto

  defp record_audit(_scope, _pool, []), do: :ok

  defp record_audit(%Scope{user: user}, pool, transitions) do
    case Audit.record_model_serving_modes_update(user, pool, transitions) do
      {:ok, _audit_event} ->
        :ok

      :noop ->
        {:error, error(:audit_failed, "model serving mode audit could not be recorded")}

      {:error, _reason} ->
        {:error, error(:audit_failed, "model serving mode audit could not be recorded")}
    end
  end

  defp emit_event(_pool, []), do: :ok

  defp emit_event(pool, transitions) do
    case Events.broadcast_model_serving_modes_updated_after_commit(pool, length(transitions)) do
      {:ok, _event} ->
        :ok

      {:error, _reason} ->
        {:error, error(:event_failed, "model serving mode event could not be emitted")}

      :noop ->
        {:error, error(:event_failed, "model serving mode event could not be emitted")}
    end
  end

  defp transact_update(scope, pool_id, normalized_rows, expected_revision) do
    Repo.transaction(fn ->
      update_locked(scope, pool_id, normalized_rows, expected_revision)
    end)
  rescue
    exception in Postgrex.Error ->
      if transaction_conflict?(exception) do
        {:error,
         error(
           :transaction_conflict,
           "model serving modes could not be saved because of a database conflict"
         )}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp transaction_conflict?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @transaction_conflict_codes

  defp transaction_conflict?(_exception), do: false

  @doc false
  @spec revision([ModelServingOverride.t()]) :: String.t()
  def revision(overrides) do
    overrides
    |> Enum.sort_by(& &1.exposed_model_id)
    |> Enum.map_join("\n", &(&1.exposed_model_id <> "\0" <> &1.mode))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp authorize(scope, pool_id) do
    Authorization.require_capability(scope, Authorization.capability(:pool_operate),
      pool_id: pool_id
    )
  end

  defp attr(row, key), do: Map.get(row, key, Map.get(row, Atom.to_string(key)))

  defp normalize_mode(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_mode(value), do: value

  defp normalize_pool_id(%Pool{id: pool_id}), do: normalize_pool_id(pool_id)

  defp normalize_pool_id(pool_id) when is_binary(pool_id) do
    case Ecto.UUID.cast(pool_id) do
      {:ok, normalized_pool_id} -> {:ok, normalized_pool_id}
      :error -> {:error, error(:pool_not_found, "pool was not found")}
    end
  end

  defp normalize_pool_id(_pool_or_id),
    do: {:error, error(:pool_not_found, "pool was not found")}

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
