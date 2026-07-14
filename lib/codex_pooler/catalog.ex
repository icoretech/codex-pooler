defmodule CodexPooler.Catalog do
  @moduledoc """
  Model catalog sync, model, and pricing APIs.
  """

  import Ecto.Query

  alias CodexPooler.Catalog.{
    AssignmentModelSummaries,
    Model,
    ModelSelectorState,
    PricingSnapshot,
    Sync,
    SyncRun
  }

  alias CodexPooler.Catalog.OpenAIPricingImporter
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active "active"
  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_eligible PoolUpstreamAssignment.eligible_status()
  @identity_active UpstreamIdentity.active_status()
  @failed "failed"
  @fresh_catalog_seconds 86_400
  @health_excluded [
    PoolUpstreamAssignment.cooldown_health_status(),
    PoolUpstreamAssignment.disabled_health_status(),
    PoolUpstreamAssignment.errored_health_status()
  ]
  @running "running"
  @succeeded "succeeded"
  @suppressed "suppressed"
  @retired "retired"

  @type catalog_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type catalog_result ::
          {:ok, map()}
          | {:error, catalog_error() | Ecto.Changeset.t() | term()}
          | {:error, term(), catalog_error() | Ecto.Changeset.t() | term()}
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type pricing_bucket_map :: %{optional(String.t()) => [String.t()]}

  @spec list_assignment_model_summaries(term()) :: [AssignmentModelSummaries.summary()]
  defdelegate list_assignment_model_summaries(authorized_assignments),
    to: AssignmentModelSummaries,
    as: :list

  @spec sync_pool_catalog(pool_ref(), keyword()) :: catalog_result()
  defdelegate sync_pool_catalog(pool_or_id, opts \\ []), to: Sync

  @spec list_catalog_sync_assignments(pool_ref()) :: [map()]
  defdelegate list_catalog_sync_assignments(pool_or_id), to: Sync

  @spec list_models(pool_ref(), keyword()) :: [Model.t()]
  def list_models(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    status = Keyword.get(opts, :status)

    Model
    |> where([model], model.pool_id == ^pool_id)
    |> maybe_where_status(status)
    |> order_by([model], asc: model.exposed_model_id)
    |> Repo.all()
  end

  @spec list_visible_models(pool_ref(), keyword()) :: [Model.t()]
  def list_visible_models(pool_or_id, opts \\ []) do
    timestamp = Keyword.get(opts, :at, now())

    pool_or_id
    |> list_models(status: @active)
    |> Enum.filter(&visible_model?(&1, timestamp))
  end

  @spec model_source_identity([Model.t()] | nil) :: UpstreamIdentity.t() | nil
  def model_source_identity(nil), do: nil

  def model_source_identity(models) when is_list(models) do
    assignment_ids =
      models
      |> Enum.flat_map(&source_assignment_ids/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case assignment_ids do
      [] ->
        nil

      _ ->
        PoolUpstreamAssignment
        |> join(:inner, [assignment], identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id
        )
        |> where(
          [assignment, identity],
          assignment.id in ^assignment_ids and assignment.status == ^@assignment_active and
            assignment.eligibility_status == ^@assignment_eligible and
            identity.status == ^@identity_active
        )
        |> select([assignment, identity], {assignment, identity})
        |> Repo.all()
        |> Enum.max_by(&model_source_rank/1, fn -> nil end)
        |> case do
          {_assignment, %UpstreamIdentity{} = identity} -> identity
          nil -> nil
        end
    end
  end

  @spec model_source_snapshot(UpstreamIdentity.t() | nil) :: map() | nil
  def model_source_snapshot(nil), do: nil

  def model_source_snapshot(%UpstreamIdentity{} = identity) do
    %{
      "upstream_identity_id" => identity.id,
      "upstream_account_label" => identity.account_label,
      "upstream_account_plan_family" => identity.plan_family,
      "upstream_account_plan_label" => identity.plan_label
    }
  end

  @spec pricing_buckets_by_identifier([Model.t()]) :: pricing_bucket_map()
  def pricing_buckets_by_identifier(models) when is_list(models) do
    identifiers = models |> Enum.flat_map(&pricing_identifiers/1) |> Enum.uniq()

    if identifiers == [] do
      %{}
    else
      PricingSnapshot
      |> where([snapshot], snapshot.model_identifier in ^identifiers)
      |> where([snapshot], fragment("?->>'pricing_type'", snapshot.config) == "per_1m_tokens")
      |> select([snapshot], {
        snapshot.model_identifier,
        snapshot.effective_at,
        fragment("?->>'price_bucket'", snapshot.config)
      })
      |> Repo.all()
      |> latest_pricing_buckets()
    end
  end

  def pricing_buckets_by_identifier(_models), do: %{}

  @spec pricing_buckets_for_model(Model.t(), pricing_bucket_map()) :: [String.t()]
  def pricing_buckets_for_model(%Model{} = model, pricing_buckets) when is_map(pricing_buckets) do
    model
    |> pricing_identifiers()
    |> Enum.find_value([], &Map.get(pricing_buckets, &1))
  end

  def pricing_buckets_for_model(_model, _pricing_buckets), do: []

  @spec api_key_model_selector_state(pool_ref(), map(), keyword()) :: map()
  def api_key_model_selector_state(pool_or_id, attrs \\ %{}, opts \\ []) do
    timestamp = Keyword.get(opts, :at, now())
    catalog_state = catalog_read_state(pool_or_id, at: timestamp)
    visible_models = list_visible_models(pool_or_id, at: timestamp)
    ModelSelectorState.build(attrs, catalog_state, visible_models)
  end

  @spec validate_manual_model_identifier(term()) :: {:ok, String.t()} | {:error, catalog_error()}
  defdelegate validate_manual_model_identifier(value), to: ModelSelectorState

  @spec validate_manual_model_identifiers(term()) ::
          {:ok, [String.t()]} | {:error, catalog_error()}
  defdelegate validate_manual_model_identifiers(values), to: ModelSelectorState

  @spec validate_model_selector_acknowledgement(map(), map()) ::
          :ok | {:error, catalog_error()}
  def validate_model_selector_acknowledgement(selector_state, attrs \\ %{})

  def validate_model_selector_acknowledgement(selector_state, attrs) when is_map(attrs) do
    catalog_status = get_in(selector_state, [:catalog, :status])
    mode = Map.get(selector_state, :mode, :all_models)
    manual_identifiers = Map.get(selector_state, :manual_identifiers, [])

    cond do
      mode == :all_models ->
        :ok

      catalog_status in [:synced, nil] ->
        :ok

      manual_identifiers == [] ->
        :ok

      selector_acknowledged?(attrs) ->
        :ok

      true ->
        {:error,
         catalog_error(
           :catalog_acknowledgement_required,
           "manual model entries require catalog warning acknowledgement"
         )}
    end
  end

  def validate_model_selector_acknowledgement(_selector_state, _attrs),
    do: {:error, catalog_error(:invalid_model_selector, "model selector state is invalid")}

  @spec get_model_by_exposed_id(pool_ref(), String.t()) :: Model.t() | nil
  def get_model_by_exposed_id(pool_or_id, exposed_model_id) when is_binary(exposed_model_id) do
    pool_id = pool_id(pool_or_id)

    Repo.one(
      from model in Model,
        where:
          model.pool_id == ^pool_id and
            fragment("lower(?)", model.exposed_model_id) ==
              ^String.downcase(String.trim(exposed_model_id)),
        limit: 1
    )
  end

  def get_model_by_exposed_id(_pool_or_id, _exposed_model_id), do: nil

  @spec suppress_model(Model.t(), map()) :: {:ok, Model.t()} | {:error, Ecto.Changeset.t()}
  def suppress_model(%Model{} = model, attrs \\ %{}) do
    model
    |> Model.changeset(%{
      status: @suppressed,
      suppressed_at: Map.get(atomize_attrs(attrs), :suppressed_at, now()),
      metadata: Map.get(atomize_attrs(attrs), :metadata, model.metadata || %{})
    })
    |> Repo.update()
  end

  @spec retire_model(Model.t(), map()) :: {:ok, Model.t()} | {:error, Ecto.Changeset.t()}
  def retire_model(%Model{} = model, attrs \\ %{}) do
    model
    |> Model.changeset(%{
      status: @retired,
      retired_at: Map.get(atomize_attrs(attrs), :retired_at, now())
    })
    |> Repo.update()
  end

  @spec catalog_read_state(pool_ref(), keyword()) :: ModelSelectorState.catalog_state()
  # Reason: admin catalog read model combines sync state, counts, and filters.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def catalog_read_state(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    timestamp = Keyword.get(opts, :at, now())

    running? =
      Repo.exists?(
        from run in SyncRun,
          where: run.pool_id == ^pool_id and run.status in ["pending", @running]
      )

    latest_success = latest_sync_run(pool_id, @succeeded)
    latest_failed = latest_sync_run(pool_id, @failed)

    cond do
      running? ->
        %{status: :syncing, reason: nil}

      is_nil(latest_success) and not is_nil(latest_failed) ->
        %{status: :failed, reason: latest_failed.error_message}

      is_nil(latest_success) ->
        %{status: :unavailable, reason: :never_synced}

      latest_failed_after_success?(latest_failed, latest_success) ->
        %{status: :failed, reason: latest_failed.error_message}

      list_visible_models(pool_id, at: timestamp) == [] ->
        %{status: :empty, reason: nil}

      DateTime.diff(timestamp, latest_success.finished_at || latest_success.started_at, :second) >
          @fresh_catalog_seconds ->
        %{status: :stale, reason: :catalog_stale}

      true ->
        %{status: :synced, reason: nil}
    end
  end

  @spec list_recent_sync_runs(pool_ref(), keyword()) :: [SyncRun.t()]
  def list_recent_sync_runs(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(25)

    SyncRun
    |> where([run], run.pool_id == ^pool_id)
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec cleanup_stale_sync_runs(DateTime.t()) ::
          {:ok, %{required(:stale_catalog_sync_runs_failed) => non_neg_integer()}}
  defdelegate cleanup_stale_sync_runs(now), to: Sync

  @spec import_openai_pricing_from_priv() ::
          {:ok, OpenAIPricingImporter.import_result()}
          | {:error, OpenAIPricingImporter.importer_error()}
  def import_openai_pricing_from_priv do
    Application.app_dir(:codex_pooler, "priv/pricing/openai/pricing.json")
    |> OpenAIPricingImporter.import_file()
  end

  @spec import_openai_pricing_from_url(String.t()) ::
          {:ok, OpenAIPricingImporter.import_result()}
          | {:error, OpenAIPricingImporter.importer_error()}
  def import_openai_pricing_from_url(url) do
    OpenAIPricingImporter.import_url(url)
  end

  @spec catalog_error(atom(), String.t()) :: catalog_error()
  def catalog_error(code, message), do: %{code: code, message: message}

  defp visible_model?(%Model{} = model, timestamp) do
    ids = get_in(model.metadata || %{}, ["source_assignment_ids"]) || []

    Repo.exists?(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where:
          assignment.id in ^ids and assignment.status == ^@assignment_active and
            assignment.eligibility_status == ^@assignment_eligible and
            identity.status == ^@identity_active and
            assignment.health_status not in ^@health_excluded and
            (is_nil(assignment.cooldown_until) or assignment.cooldown_until <= ^timestamp)
    )
  end

  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> ids
      _ids -> []
    end
  end

  defp model_source_rank({%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity}) do
    {model_source_plan_rank(identity), assignment.created_at, assignment.id}
  end

  defp model_source_plan_rank(%UpstreamIdentity{} = identity) do
    plan = identity.plan_family || identity.plan_label || ""

    cond do
      plan =~ ~r/enterprise|team/i -> 4
      plan =~ ~r/pro/i -> 3
      plan =~ ~r/plus/i -> 2
      plan =~ ~r/free/i -> 1
      true -> 0
    end
  end

  defp selector_acknowledged?(attrs) do
    value =
      policy_input(attrs, [
        :acknowledge_catalog_warning,
        "acknowledge_catalog_warning",
        :acknowledge_stale_catalog,
        "acknowledge_stale_catalog",
        :allow_manual_models,
        "allow_manual_models"
      ])

    value in [true, "true", "1", "on", 1]
  end

  defp policy_input(source, keys) when is_map(source) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(source, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp latest_sync_run(pool_id, status) do
    Repo.one(
      from run in SyncRun,
        where: run.pool_id == ^pool_id and run.status == ^status,
        order_by: [desc: run.finished_at, desc: run.started_at],
        limit: 1
    )
  end

  defp latest_failed_after_success?(nil, _latest_success), do: false

  defp latest_failed_after_success?(latest_failed, latest_success) do
    failed_at = latest_failed.finished_at || latest_failed.started_at
    success_at = latest_success.finished_at || latest_success.started_at
    DateTime.compare(failed_at, success_at) == :gt
  end

  defp maybe_where_status(query, nil), do: query
  defp maybe_where_status(query, status), do: from(model in query, where: model.status == ^status)

  defp latest_pricing_buckets(rows) do
    rows
    |> Enum.group_by(fn {identifier, _effective_at, _bucket} -> identifier end)
    |> Map.new(fn {identifier, rows} ->
      {_identifier, latest_effective_at, _bucket} =
        Enum.max_by(rows, fn {_identifier, effective_at, _bucket} ->
          DateTime.to_unix(effective_at, :microsecond)
        end)

      buckets =
        rows
        |> Enum.filter(fn {_identifier, effective_at, _bucket} ->
          DateTime.compare(effective_at, latest_effective_at) == :eq
        end)
        |> Enum.map(fn {_identifier, _effective_at, bucket} -> bucket end)
        |> Enum.reject(&blank?/1)
        |> Enum.uniq()

      {identifier, buckets}
    end)
  end

  defp pricing_identifiers(%Model{} = model) do
    [model.pricing_ref, model.upstream_model_id, model.exposed_model_id]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp pricing_identifiers(_model), do: []

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_id), do: nil

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {key, value}
      {"suppressed_at", value} -> {:suppressed_at, value}
      {"retired_at", value} -> {:retired_at, value}
      {"metadata", value} -> {:metadata, value}
      {key, value} -> {key, value}
    end)
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
