defmodule CodexPooler.Dev.Seeds.DocsScreenshots do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.{Model, SyncRun}
  alias CodexPooler.Dev.Seeds.Full
  alias CodexPooler.Pools.{ModelServingOverride, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @pool_names ["Example Production", "Example Secondary", "Example Standby"]

  @api_key_specs [
    {"Build automation", "sk-cxp-docs00000001"},
    {"Release assistant", "sk-cxp-docs00000002"},
    {"Paused client", "sk-cxp-docs00000003"},
    {"Retired client", "sk-cxp-docs00000004"}
  ]

  @identity_specs [
    {"sample-account-01", "Example Primary Pro"},
    {"sample-account-02", "Example Quota Ready"},
    {"sample-account-03", "Example Quota Exhausted"},
    {"sample-account-04", "Example Refresh Due"},
    {"sample-account-05", "Example Reauthentication"},
    {"sample-account-06", "Example Paused Account"}
  ]

  @assignment_labels [
    "Example Primary Assignment",
    "Example Ready Assignment",
    "Example Exhausted Assignment",
    "Example Cooldown Assignment",
    "Example Reauthentication Assignment",
    "Example Paused Assignment",
    "Example Secondary Assignment"
  ]

  @spec run(map()) :: map()
  def run(context) do
    result = Full.run(context)
    pools = update_pools!(result.pools)
    api_keys = update_api_keys!(result.api_keys)
    upstream_identities = update_identities!(result.upstream_identities)
    assignments = update_assignments!(result.assignments)
    models = update_models!(result.models, pools)
    catalog_sync_runs = seed_catalog_sync_runs!(pools, models)
    model_serving_overrides = seed_model_serving_overrides!(pools)

    request_logs =
      update_request_logs!(
        result.request_logs,
        result.upstream_identities,
        upstream_identities
      )

    audit_events = update_audit_events!(result.audit_events, List.first(api_keys))

    Map.merge(result, %{
      pools: pools,
      api_keys: api_keys,
      upstream_identities: upstream_identities,
      assignments: assignments,
      models: models,
      catalog_sync_runs: catalog_sync_runs,
      model_serving_overrides: model_serving_overrides,
      request_logs: request_logs,
      audit_events: audit_events
    })
  end

  defp update_pools!(pools) do
    update_ordered!(pools, @pool_names, fn pool, name ->
      pool
      |> Pool.changeset(%{name: name})
      |> Repo.update!()
    end)
  end

  defp update_api_keys!(api_keys) do
    update_ordered!(api_keys, @api_key_specs, fn api_key, {display_name, key_prefix} ->
      metadata =
        api_key.metadata
        |> Map.delete(:operator_notes)
        |> Map.put(
          "operator_notes",
          "Generated for public documentation screenshots"
        )

      api_key
      |> APIKey.changeset(%{
        display_name: display_name,
        key_prefix: key_prefix,
        metadata: metadata
      })
      |> Repo.update!()
    end)
  end

  defp update_identities!(identities) do
    update_ordered!(identities, @identity_specs, fn identity, {account_id, account_label} ->
      identity
      |> UpstreamIdentity.changeset(%{
        chatgpt_account_id: account_id,
        account_label: account_label
      })
      |> Repo.update!()
    end)
  end

  defp update_assignments!(assignments, labels \\ @assignment_labels) do
    update_ordered!(assignments, labels, fn assignment, label ->
      assignment
      |> PoolUpstreamAssignment.changeset(%{assignment_label: label})
      |> Repo.update!()
    end)
  end

  defp update_models!(models, pools) do
    primary_pool = pool_by_name!(pools, "Example Production")

    Enum.map(models, fn model ->
      if model.pool_id == primary_pool.id and model.exposed_model_id == "gpt-5.4-mini" do
        source_models =
          model.metadata
          |> Map.fetch!("source_assignment_models")
          |> Map.new(fn {assignment_id, source_metadata} ->
            {assignment_id, Map.put(source_metadata, "use_responses_lite", true)}
          end)

        model
        |> Model.changeset(%{
          metadata: Map.put(model.metadata, "source_assignment_models", source_models)
        })
        |> Repo.update!()
      else
        model
      end
    end)
  end

  defp seed_catalog_sync_runs!(pools, models) do
    finished_at = DateTime.utc_now()

    Enum.map(pools, fn pool ->
      model_count = Enum.count(models, &(&1.pool_id == pool.id))

      %SyncRun{}
      |> SyncRun.changeset(%{
        pool_id: pool.id,
        trigger_kind: "bootstrap",
        status: "succeeded",
        started_at: DateTime.add(finished_at, -1, :second),
        finished_at: finished_at,
        discovered_model_count: model_count,
        upserted_model_count: model_count,
        stale_marked_count: 0,
        retired_count: 0,
        stats: %{"seed" => "docs_screenshots"}
      })
      |> Repo.insert!()
    end)
  end

  defp seed_model_serving_overrides!(pools) do
    primary_pool = pool_by_name!(pools, "Example Production")
    timestamp = DateTime.utc_now()

    [
      {"gpt-5.4", "full"},
      {"gpt-5.5-pro", "lite"}
    ]
    |> Enum.map(fn {exposed_model_id, mode} ->
      %ModelServingOverride{
        pool_id: primary_pool.id,
        created_at: timestamp,
        updated_at: timestamp
      }
      |> ModelServingOverride.changeset(%{
        exposed_model_id: exposed_model_id,
        mode: mode
      })
      |> Repo.insert!()
    end)
  end

  defp pool_by_name!(pools, name) do
    Enum.find(pools, &(&1.name == name)) ||
      raise "documentation screenshot seed is missing #{name}"
  end

  defp update_request_logs!(request_logs, original_identities, identities) do
    labels_by_original =
      original_identities
      |> Enum.zip(identities)
      |> Map.new(fn {original, updated} ->
        {original.account_label, updated.account_label}
      end)

    Enum.map(request_logs, fn request ->
      updated_label =
        Map.get(
          labels_by_original,
          request.upstream_account_label,
          request.upstream_account_label
        )

      request
      |> Ecto.Changeset.change(%{upstream_account_label: updated_label})
      |> Repo.update!()
    end)
  end

  defp update_audit_events!(audit_events, api_key) do
    Enum.map(audit_events, fn event ->
      details =
        if Map.has_key?(event.details, "key_prefix") do
          Map.put(event.details, "key_prefix", api_key.key_prefix)
        else
          event.details
        end

      event
      |> Ecto.Changeset.change(%{details: details})
      |> Repo.update!()
    end)
  end

  defp update_ordered!(records, specs, update) do
    if length(records) != length(specs) do
      raise "documentation screenshot seed shape changed"
    end

    records
    |> Enum.zip(specs)
    |> Enum.map(fn {record, spec} -> update.(record, spec) end)
  end
end
