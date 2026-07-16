defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel do
  @moduledoc false

  alias CodexPooler.Admin.{UpstreamQuotaReadiness, UpstreamRoutingReadiness}
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.AssignmentModelSummaries
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.OAuth, as: UpstreamOAuth
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.{
    Filter,
    Formatting,
    QuotaProjection,
    SavedResetProjection,
    TokenBurnProjection
  }

  alias CodexPoolerWeb.DateTimeDisplay

  @type assignment_advertised_state :: :advertised | :not_advertised
  @type assignment_model_freshness :: :observed | :preserved | :mixed | :not_advertised
  @type assignment_model :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          required(:exposed_model_id) => String.t(),
          required(:capabilities) => AssignmentModelSummaries.capabilities(),
          required(:provenance) => AssignmentModelSummaries.provenance()
        }
  @type assignment_snapshot :: %{
          required(:id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_label) => String.t(),
          optional(:stored_assignment_label) => String.t() | nil,
          required(:status) => String.t(),
          required(:health_status) => String.t(),
          required(:eligibility_status) => String.t(),
          required(:quota_priming_status) => String.t(),
          required(:quota_priming_label) => String.t(),
          required(:last_successful_refresh_at) => DateTime.t() | nil,
          optional(:last_reconciliation) => map() | nil,
          required(:pool_label) => String.t(),
          required(:models) => [assignment_model()],
          required(:model_count) => non_neg_integer(),
          required(:advertised_state) => assignment_advertised_state(),
          required(:model_freshness) => assignment_model_freshness()
        }
  @type quota_limit_row :: QuotaProjection.quota_limit_row()
  @type quota_readiness :: UpstreamQuotaReadiness.t()
  @type routing_readiness :: UpstreamRoutingReadiness.t()
  @type reconciliation_projection :: %{
          required(:status) => String.t() | nil,
          required(:code) => String.t() | nil,
          required(:message) => String.t() | nil,
          required(:finished_at) => DateTime.t() | nil,
          required(:attempt_age) => String.t() | nil
        }
  @type credential_expiry_projection :: %{
          required(:state) => String.t(),
          required(:expires_at) => DateTime.t() | nil,
          required(:age) => String.t() | nil
        }
  @type identity_observability :: %{
          required(:reconciliation) => reconciliation_projection(),
          required(:last_successful_quota_refresh_at) => DateTime.t() | nil,
          required(:last_successful_quota_refresh_age) => String.t() | nil,
          required(:quota_evidence_at) => DateTime.t() | nil,
          required(:quota_evidence_age) => String.t() | nil,
          required(:credential_expiry) => credential_expiry_projection()
        }
  @type token_burn :: TokenBurnProjection.token_burn()
  @type saved_reset_snapshot :: SavedResetProjection.snapshot()
  @type action :: SavedResetProjection.action()
  @type account_snapshot :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:label) => String.t(),
          required(:workspace_ref) => String.t(),
          required(:workspace_label) => String.t() | nil,
          required(:subject_ref) => String.t() | nil,
          required(:plan_label) => String.t(),
          required(:plan_reported?) => boolean(),
          required(:refresh_status) => String.t(),
          required(:token_refresh_label) => String.t(),
          required(:refresh_job_state) => String.t() | nil,
          required(:quota_refresh_status) => String.t(),
          required(:auth_fresh_label) => String.t(),
          required(:auth_verified_label) => String.t(),
          required(:access_token_label) => String.t(),
          required(:reauth_required?) => boolean(),
          required(:reauth_reason_code) => String.t() | nil,
          required(:reauth_reason_message) => String.t() | nil,
          required(:saved_resets) => saved_reset_snapshot(),
          required(:saved_reset_policy) => SavedResets.auto_policy_projection(),
          required(:saved_reset_redemption_action) => action(),
          required(:token_burn) => token_burn(),
          required(:assignments) => [assignment_snapshot()],
          required(:quota_readiness) => quota_readiness(),
          required(:routing_readiness) => routing_readiness(),
          required(:quota_limits) => [quota_limit_row()],
          required(:identity_observability) => identity_observability()
        }

  @terminal_reconciliation_statuses ~w(succeeded partial failed)
  @safe_reconciliation_messages %{
    "catalog_refreshed" => "catalog refreshed",
    "catalog_sync_failed" => "catalog sync failed",
    "catalog_sync_in_progress" => "catalog sync in progress",
    "catalog_sync_partial" => "catalog sync partially completed",
    "catalog_sync_skipped" => "catalog sync skipped",
    "health_preserved" => "assignment health preserved",
    "health_refreshed" => "assignment health refreshed",
    "health_skipped" => "assignment health skipped",
    "quota_refreshed" => "quota refreshed",
    "quota_refresh_auth_unavailable" => "quota refresh authentication unavailable",
    "quota_refresh_failed" => "quota refresh failed",
    "quota_refresh_superseded" => "quota refresh superseded",
    "quota_refresh_unavailable" => "quota refresh unavailable",
    "quota_reused_fresh" => "fresh quota evidence reused",
    "workspace_identity_mismatch" => "workspace identity mismatch"
  }
  @type oauth_flow_state :: %{
          required(:items) => [Upstreams.oauth_flow_summary()],
          required(:count) => non_neg_integer(),
          required(:pending_count) => non_neg_integer(),
          required(:empty?) => boolean(),
          required(:degraded?) => boolean()
        }

  @spec list_visible_accounts(term(), [term()]) :: [account_snapshot()]
  def list_visible_accounts(scope, pools) when is_list(pools) do
    list_visible_accounts(scope, pools, %{}, DateTimeDisplay.preferences_for_user(nil))
  end

  @spec list_visible_accounts(term(), [term()], map()) :: [account_snapshot()]
  def list_visible_accounts(scope, pools, filters) when is_list(pools) and is_map(filters) do
    list_visible_accounts(scope, pools, filters, DateTimeDisplay.preferences_for_user(nil))
  end

  @spec list_visible_accounts(term(), [term()], map(), DateTimeDisplay.preferences()) :: [
          account_snapshot()
        ]
  def list_visible_accounts(scope, pools, filters, datetime_preferences)
      when is_list(pools) and is_map(filters) and is_map(datetime_preferences) do
    pools = intersect_visible_pools(scope, pools)
    pool_lookup = Map.new(pools, &{&1.id, &1})
    assignments = active_assignment_snapshots(pools, pool_lookup)
    model_inventory = assignment_model_inventory(assignments)
    assignments = attach_assignment_model_inventory(assignments, model_inventory)

    identities =
      if pool_filter_selected?(filters) do
        visible_assigned_identities(scope, assignments)
      else
        case Upstreams.list_upstream_identities_for_pool_management(scope,
               exclude_status: UpstreamIdentity.deleted_status()
             ) do
          {:ok, identities} -> identities
          {:error, _reason} -> visible_assigned_identities(scope, assignments)
        end
      end

    token_burns = TokenBurnProjection.summaries(identities)

    identities
    |> Enum.map(&account_snapshot(&1, assignments, token_burns, datetime_preferences))
    |> Filter.apply(filters)
  end

  defp intersect_visible_pools(scope, pools) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> MapSet.new(& &1.id)
    Enum.filter(pools, &MapSet.member?(visible_pool_ids, &1.id))
  end

  defp visible_assigned_identities(scope, assignments) do
    scope
    |> Upstreams.list_visible_upstream_identities()
    |> Enum.filter(&Map.has_key?(assignments, &1.id))
  end

  defp pool_filter_selected?(%{"pool_id" => pool_id})
       when is_binary(pool_id) and pool_id != "",
       do: true

  defp pool_filter_selected?(_filters), do: false

  @spec oauth_flow_state(term(), [term()], DateTimeDisplay.preferences(), keyword()) ::
          oauth_flow_state()
  def oauth_flow_state(scope, pools, datetime_preferences, opts \\ [])

  def oauth_flow_state(scope, pools, _datetime_preferences, opts) when is_list(pools) do
    items =
      UpstreamOAuth.list_visible_oauth_flow_summaries(
        scope,
        opts
        |> Keyword.put(:pool_ids, pool_ids(pools))
        |> Keyword.put_new(:limit, 50)
      )

    %{
      items: items,
      count: length(items),
      pending_count: Enum.count(items, &(&1.status == "pending")),
      empty?: items == [],
      degraded?: false
    }
  end

  def oauth_flow_state(_scope, _pools, _datetime_preferences, _opts),
    do: empty_oauth_flow_state()

  @spec empty_oauth_flow_state() :: oauth_flow_state()
  def empty_oauth_flow_state do
    %{items: [], count: 0, pending_count: 0, empty?: true, degraded?: false}
  end

  defp pool_ids(pools) do
    pools
    |> Enum.map(fn
      %{id: id} when is_binary(id) -> id
      %{pool_id: pool_id} when is_binary(pool_id) -> pool_id
      pool_id when is_binary(pool_id) -> pool_id
      _pool -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp active_assignment_snapshots(pools, pool_lookup) do
    pools
    |> Enum.flat_map(&UpstreamAssignments.list_pool_assignments/1)
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.map(&assignment_snapshot(&1, pool_lookup))
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp assignment_snapshot(%PoolUpstreamAssignment{} = assignment, pool_lookup) do
    pool = Map.get(pool_lookup, assignment.pool_id)

    %{
      id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      pool_id: assignment.pool_id,
      assignment_label: assignment.assignment_label || "Pool assignment",
      stored_assignment_label: Formatting.present_string(assignment.assignment_label),
      status: assignment.status,
      health_status: assignment.health_status,
      eligibility_status: assignment.eligibility_status,
      quota_priming_status: QuotaProjection.assignment_priming_status(assignment),
      quota_priming_label: QuotaProjection.assignment_priming_label(assignment),
      last_successful_refresh_at: assignment.last_successful_refresh_at,
      last_reconciliation: nested_map(assignment.metadata, "last_reconciliation"),
      pool_label: pool_label(pool),
      models: [],
      model_count: 0,
      advertised_state: :not_advertised,
      model_freshness: :not_advertised
    }
  end

  defp assignment_model_inventory(assignments) do
    authorized_assignments =
      for {_identity_id, identity_assignments} <- assignments,
          assignment <- identity_assignments do
        {assignment.pool_id, assignment.id}
      end

    authorized_assignments
    |> Catalog.list_assignment_model_summaries()
    |> Enum.group_by(&{&1.pool_id, &1.assignment_id})
  end

  defp attach_assignment_model_inventory(assignments, model_inventory) do
    Map.new(assignments, fn {identity_id, identity_assignments} ->
      snapshots = Enum.map(identity_assignments, &attach_assignment_models(&1, model_inventory))
      {identity_id, snapshots}
    end)
  end

  defp attach_assignment_models(assignment, model_inventory) do
    models =
      model_inventory
      |> Map.get({assignment.pool_id, assignment.id}, [])
      |> Enum.sort_by(& &1.exposed_model_id)

    Map.merge(assignment, %{
      models: models,
      model_count: length(models),
      advertised_state: if(models == [], do: :not_advertised, else: :advertised),
      model_freshness: model_freshness(models)
    })
  end

  defp model_freshness([]), do: :not_advertised

  defp model_freshness(models) do
    provenances = models |> Enum.map(& &1.provenance) |> Enum.uniq()

    case provenances do
      [:observed] -> :observed
      [:preserved] -> :preserved
      _mixed -> :mixed
    end
  end

  defp account_snapshot(identity, assignments, token_burns, datetime_preferences) do
    # one explicit snapshot instant for the effective window load so the
    # readiness and card projections below reason about the same view
    snapshot_at = DateTime.utc_now()
    quota_windows = QuotaWindows.list_quota_windows(identity, snapshot_at)
    quota_readiness = QuotaProjection.readiness(quota_windows)
    identity_assignments = identity_assignments(identity, assignments, quota_readiness)

    identity_observability =
      identity_observability(
        identity,
        Map.get(assignments, identity.id, []),
        quota_windows,
        snapshot_at
      )

    routing_readiness =
      UpstreamRoutingReadiness.from_inputs(identity, identity_assignments, quota_readiness)

    refresh_job = identity |> Jobs.list_recent_token_refresh_jobs(limit: 1) |> List.first()

    account = %{
      identity: identity,
      label: account_label(identity),
      workspace_ref: workspace_ref(identity.workspace_id),
      workspace_label: safe_workspace_label(identity.workspace_label),
      subject_ref: subject_ref(identity.chatgpt_user_id),
      plan_label: account_plan_label(identity),
      plan_reported?: account_plan_reported?(identity),
      refresh_status: refresh_status_label(identity),
      token_refresh_label: token_refresh_label(identity, datetime_preferences),
      refresh_job_state: refresh_job_state(refresh_job),
      quota_refresh_status:
        QuotaProjection.quota_refresh_status(
          Map.get(assignments, identity.id, []),
          datetime_preferences
        ),
      auth_fresh_label:
        Formatting.timestamp_status_label(
          "auth imported",
          identity.auth_fresh_at,
          datetime_preferences
        ),
      auth_verified_label:
        Formatting.timestamp_status_label(
          "auth verified",
          identity.auth_verified_at,
          datetime_preferences
        ),
      access_token_label: access_token_label(identity, datetime_preferences),
      reauth_required?: reauth_required?(identity),
      reauth_reason_code: reauth_reason_code(identity),
      reauth_reason_message: reauth_reason_message(identity),
      saved_resets: SavedResetProjection.snapshot(identity, datetime_preferences),
      saved_reset_policy: SavedResetProjection.policy(identity),
      token_burn: Map.fetch!(token_burns, identity.id),
      assignments: identity_assignments,
      quota_readiness: quota_readiness,
      routing_readiness: routing_readiness,
      quota_limits: QuotaProjection.quota_limit_rows(quota_windows, datetime_preferences),
      identity_observability: identity_observability
    }

    Map.put(
      account,
      :saved_reset_redemption_action,
      SavedResetProjection.redemption_action(account)
    )
  end

  defp identity_assignments(identity, assignments, quota_readiness) do
    assignments
    |> Map.get(identity.id, [])
    |> Enum.map(&identity_assignment(&1, identity, quota_readiness))
  end

  defp identity_assignment(assignment, identity, quota_readiness) do
    assignment
    |> Map.delete(:last_reconciliation)
    |> Map.put(:assignment_label, assignment_display_label(identity, assignment))
    |> QuotaProjection.put_current_quota_priming(quota_readiness)
  end

  defp assignment_display_label(identity, assignment) do
    current_label = account_label(identity)

    stored_label =
      Formatting.present_string(Map.get(assignment, :stored_assignment_label)) ||
        Formatting.present_string(Map.get(assignment, :assignment_label))

    cond do
      is_nil(stored_label) -> current_label
      stale_account_identifier_label?(stored_label, current_label) -> current_label
      true -> stored_label
    end
  end

  defp stale_account_identifier_label?(stored_label, current_label) do
    stored_label != current_label and account_identifier_label?(stored_label)
  end

  defp account_identifier_label?(label) do
    String.match?(label, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) or
      String.starts_with?(label, ["acct_", "acct-"])
  end

  defp safe_workspace_label(value) do
    case Formatting.present_string(value) do
      nil -> nil
      label -> mask_email_like(label)
    end
  end

  defp mask_email_like(value) do
    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      [local, domain] = String.split(value, "@", parts: 2)
      String.slice(local, 0, min(2, String.length(local))) <> "***@" <> domain
    else
      value
    end
  end

  defp workspace_ref(nil), do: "legacy"

  defp workspace_ref(workspace_id) when is_binary(workspace_id) do
    digest =
      :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "ws:" <> digest
  end

  defp workspace_ref(_workspace_id), do: "legacy"

  @spec subject_ref(term()) :: String.t() | nil
  defp subject_ref(value) do
    case Formatting.present_string(value) do
      nil ->
        nil

      subject ->
        digest =
          :crypto.hash(:sha256, subject)
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        "subj:" <> digest
    end
  end

  defp account_label(identity) do
    Formatting.present_string(identity.account_label) ||
      Formatting.present_string(identity.chatgpt_account_id) ||
      "Upstream account"
  end

  defp account_plan_label(%{plan_label: label}) when is_binary(label) and label != "", do: label

  defp account_plan_label(%{plan_family: family}) when is_binary(family) and family != "",
    do: family

  defp account_plan_label(_identity), do: nil

  defp account_plan_reported?(identity), do: is_binary(account_plan_label(identity))

  defp refresh_status_label(identity) do
    identity
    |> current_token_refresh_status()
    |> Map.get("status", "not run")
  end

  defp token_refresh_label(identity, datetime_preferences) do
    identity
    |> current_token_refresh_status()
    |> token_refresh_label_from_metadata(datetime_preferences)
  end

  defp current_token_refresh_status(%{status: identity_status} = identity) do
    metadata = TokenRefresh.token_refresh_status(identity)

    if stale_reauth_required_token_refresh?(metadata, identity_status) do
      %{}
    else
      metadata
    end
  end

  defp stale_reauth_required_token_refresh?(
         %{"status" => "reauth_required"},
         identity_status
       )
       when identity_status != "reauth_required",
       do: true

  defp stale_reauth_required_token_refresh?(_metadata, _identity_status), do: false

  defp token_refresh_label_from_metadata(
         %{"status" => "succeeded"} = metadata,
         datetime_preferences
       ) do
    Formatting.timestamp_status_label(
      "token refresh succeeded",
      Formatting.parse_timestamp(metadata["finished_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "failed"} = metadata,
         _datetime_preferences
       ) do
    token_refresh_failure_label("token refresh failed", metadata)
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "reauth_required"} = metadata,
         _datetime_preferences
       ) do
    token_refresh_failure_label("reauth required", metadata)
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "refreshing"} = metadata,
         datetime_preferences
       ) do
    Formatting.timestamp_status_label(
      "token refresh started",
      Formatting.parse_timestamp(metadata["started_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "imported"} = metadata,
         datetime_preferences
       ) do
    Formatting.timestamp_status_label(
      "token refresh imported",
      Formatting.parse_timestamp(metadata["finished_at"]),
      datetime_preferences
    )
  end

  defp token_refresh_label_from_metadata(%{"status" => status}, _datetime_preferences)
       when is_binary(status),
       do: "token refresh #{String.replace(status, "_", " ")}"

  defp token_refresh_label_from_metadata(_metadata, _datetime_preferences),
    do: "token refresh not run"

  defp token_refresh_failure_label(prefix, %{"reason" => %{} = reason}) do
    message = Formatting.present_string(reason["message"])
    code = Formatting.present_string(reason["code"])

    cond do
      message && code -> "#{token_refresh_message_label(prefix, message)} (#{code})"
      message -> token_refresh_message_label(prefix, message)
      code -> "#{prefix}: #{code}"
      true -> prefix
    end
  end

  defp token_refresh_failure_label(prefix, _metadata), do: prefix

  defp token_refresh_message_label(prefix, message) do
    if String.starts_with?(message, "#{prefix}:") do
      message
    else
      "#{prefix}: #{message}"
    end
  end

  defp access_token_label(%{metadata: %{} = metadata}, datetime_preferences) do
    case Formatting.parse_timestamp(metadata["access_token_expires_at"]) do
      %DateTime{} = expires_at -> access_token_expiry_label(expires_at, datetime_preferences)
      nil -> "access token expiry not reported"
    end
  end

  defp access_token_label(_identity, _datetime_preferences),
    do: "access token expiry not reported"

  defp access_token_expiry_label(%DateTime{} = expires_at, datetime_preferences) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      Formatting.timestamp_status_label("access token expired", expires_at, datetime_preferences)
    else
      Formatting.timestamp_status_label("access token expires", expires_at, datetime_preferences)
    end
  end

  defp reauth_required?(%{status: "reauth_required"}), do: true
  defp reauth_required?(_identity), do: false

  defp reauth_reason_code(identity) do
    identity
    |> token_refresh_reason()
    |> Map.get("code")
  end

  defp reauth_reason_message(identity) do
    identity
    |> token_refresh_reason()
    |> Map.get("message")
  end

  defp token_refresh_reason(identity) do
    identity
    |> current_token_refresh_status()
    |> Map.get("reason", %{})
  end

  defp refresh_job_state(nil), do: nil
  defp refresh_job_state(%{state: state}) when is_binary(state), do: state
  defp refresh_job_state(_job), do: nil

  @spec identity_observability(UpstreamIdentity.t(), [map()], [map()], DateTime.t()) ::
          identity_observability()
  def identity_observability(
        %UpstreamIdentity{} = identity,
        assignments,
        quota_windows,
        %DateTime{} = now
      )
      when is_list(assignments) and is_list(quota_windows) do
    reconciliation = newest_terminal_reconciliation(assignments, now)

    last_successful_refresh_at =
      assignments
      |> Enum.reject(&(map_value(&1, :status) == "deleted"))
      |> newest_non_future_timestamp(:last_successful_refresh_at, now)

    quota_evidence_at = newest_quota_evidence_at(quota_windows, now)

    %{
      reconciliation: reconciliation_projection(reconciliation, now),
      last_successful_quota_refresh_at: last_successful_refresh_at,
      last_successful_quota_refresh_age: relative_age(last_successful_refresh_at, now),
      quota_evidence_at: quota_evidence_at,
      quota_evidence_age: relative_age(quota_evidence_at, now),
      credential_expiry: credential_expiry(identity, now)
    }
  end

  defp newest_terminal_reconciliation(assignments, now) do
    assignments
    |> Enum.reject(&(map_value(&1, :status) == "deleted"))
    |> Enum.flat_map(&terminal_reconciliation_candidate(&1, now))
    |> Enum.max_by(
      fn candidate ->
        {DateTime.to_unix(candidate.finished_at, :microsecond), candidate.assignment_id}
      end,
      fn -> nil end
    )
  end

  defp terminal_reconciliation_candidate(assignment, now) do
    reconciliation =
      case map_value(assignment, :last_reconciliation) do
        %{} = projected -> projected
        _missing -> assignment |> map_value(:metadata) |> nested_map("last_reconciliation")
      end

    with %{} <- reconciliation,
         status when status in @terminal_reconciliation_statuses <-
           map_value(reconciliation, :status),
         %DateTime{} = finished_at <-
           parse_non_future(map_value(reconciliation, :finished_at), now),
         assignment_id when is_binary(assignment_id) <- map_value(assignment, :id) do
      [
        %{
          assignment_id: assignment_id,
          status: status,
          finished_at: finished_at,
          steps: map_value(reconciliation, :steps)
        }
      ]
    else
      _invalid -> []
    end
  end

  defp reconciliation_projection(nil, _now) do
    %{status: nil, code: nil, message: nil, finished_at: nil, attempt_age: nil}
  end

  defp reconciliation_projection(candidate, now) do
    {code, message} = reconciliation_reason(candidate.status, candidate.steps)

    %{
      status: candidate.status,
      code: code,
      message: message,
      finished_at: candidate.finished_at,
      attempt_age: Formatting.relative_time_label(candidate.finished_at, now)
    }
  end

  defp reconciliation_reason("succeeded", _steps), do: {nil, nil}

  defp reconciliation_reason(status, steps) when status in ["partial", "failed"] do
    steps
    |> List.wrap()
    |> Enum.find_value({nil, nil}, fn
      %{} = step ->
        code = map_value(step, :code)

        if map_value(step, :status) == "failed" and
             Map.has_key?(@safe_reconciliation_messages, code) do
          {code, Map.fetch!(@safe_reconciliation_messages, code)}
        end

      _step ->
        nil
    end)
  end

  defp newest_non_future_timestamp(items, field, now) do
    items
    |> Enum.map(&(map_value(&1, field) |> parse_non_future(now)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp newest_quota_evidence_at(windows, now) do
    windows
    |> Enum.flat_map(fn window ->
      [map_value(window, :observed_at), map_value(window, :last_sync_at)]
    end)
    |> Enum.map(&parse_non_future(&1, now))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp credential_expiry(%UpstreamIdentity{} = identity, now) do
    expires_at =
      identity |> Map.get(:metadata, %{}) |> nested_map_value("access_token_expires_at")

    case Formatting.parse_datetime(expires_at) do
      %DateTime{} = timestamp ->
        state = if DateTime.compare(timestamp, now) == :gt, do: "known_future", else: "known_past"

        %{
          state: state,
          expires_at: timestamp,
          age: Formatting.relative_time_label(timestamp, now)
        }

      nil ->
        %{state: "unavailable", expires_at: nil, age: nil}
    end
  end

  defp relative_age(%DateTime{} = timestamp, now),
    do: Formatting.relative_time_label(timestamp, now)

  defp relative_age(nil, _now), do: nil

  defp parse_non_future(value, now) do
    case Formatting.parse_datetime(value) do
      %DateTime{} = timestamp ->
        if DateTime.compare(timestamp, now) == :gt, do: nil, else: timestamp

      nil ->
        nil
    end
  end

  defp map_value(%{} = map, field), do: Map.get(map, field) || Map.get(map, Atom.to_string(field))
  defp map_value(_map, _field), do: nil

  defp nested_map(%{} = map, key) do
    case Map.get(map, key) do
      %{} = nested -> nested
      _value -> nil
    end
  end

  defp nested_map(_map, _key), do: nil
  defp nested_map_value(%{} = map, key), do: Map.get(map, key)
  defp nested_map_value(_map, _key), do: nil

  defp pool_label(nil), do: "Unknown Pool"
  defp pool_label(pool), do: pool.name
end
