defmodule CodexPooler.Dev.Seeds.DocsScreenshots do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Dev.Seeds.Full
  alias CodexPooler.Pools.Pool
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
