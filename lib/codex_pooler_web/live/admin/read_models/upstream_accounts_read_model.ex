defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Admin.{
    UpstreamCircuitReadiness,
    UpstreamQuotaReadiness,
    UpstreamRoutingReadiness
  }

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.AssignmentModelSummaries
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefresh, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.OAuth, as: UpstreamOAuth
  alias CodexPooler.Upstreams.ProviderCreditsPolicy
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.{
    Filter,
    Formatting,
    QuotaProjection,
    SavedResetOperationProjection,
    SavedResetProjection,
    TokenBurnProjection
  }

  alias CodexPoolerWeb.Admin.UpstreamNaming
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
          required(:model_freshness) => assignment_model_freshness(),
          required(:circuit_readiness) => UpstreamCircuitReadiness.summary(),
          optional(:routing_readiness) => UpstreamRoutingReadiness.t(),
          required(:recent_traffic) => TokenBurnProjection.pool_traffic()
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
  @type usage_poll_pause :: %{
          required(:paused_until) => DateTime.t(),
          required(:paused_until_label) => String.t(),
          required(:remaining_label) => String.t(),
          required(:status_code) => pos_integer() | nil,
          required(:origin_label) => String.t(),
          required(:origin_count) => pos_integer()
        }
  @type token_burn :: TokenBurnProjection.token_burn()
  @type saved_reset_snapshot :: SavedResetProjection.snapshot()
  @type action :: SavedResetProjection.action()
  @type saved_reset_refresh_cursor :: %{
          identity_id: Ecto.UUID.t(),
          credential_epoch: non_neg_integer() | nil,
          lifecycle_generation: non_neg_integer() | nil,
          request_generation: String.t()
        }
  @type account_snapshot :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:label) => String.t(),
          required(:can_delete?) => boolean(),
          required(:deletion_state) => :in_progress | :failed | nil,
          required(:workspace_ref) => String.t(),
          required(:workspace_label) => String.t() | nil,
          required(:subject_ref) => String.t() | nil,
          required(:plan_label) => String.t(),
          required(:plan_reported?) => boolean(),
          required(:refresh_status) => String.t(),
          required(:token_refresh_label) => String.t(),
          required(:token_refresh_value_label) => String.t(),
          required(:refresh_job_state) => String.t() | nil,
          required(:quota_refresh_status) => String.t(),
          required(:auth_fresh_label) => String.t(),
          required(:auth_verified_label) => String.t(),
          required(:access_token_label) => String.t(),
          required(:auth_verified_value_label) => String.t(),
          required(:secret_status) => :present | :missing | :expired | :refresh_due | :reauth_required,
          required(:reauth_required?) => boolean(),
          required(:reauth_reason_code) => String.t() | nil,
          required(:reauth_reason_message) => String.t() | nil,
          required(:saved_resets) => saved_reset_snapshot(),
          required(:saved_reset_policy) => SavedResets.auto_policy_projection(),
          required(:saved_reset_redemption_action) => action(),
          required(:saved_reset_confirmation) => QuotaProjection.saved_reset_confirmation() | nil,
          required(:saved_reset_operation) => SavedResetOperationProjection.t(),
          required(:saved_reset_refresh_cursor) => saved_reset_refresh_cursor(),
          required(:token_burn) => token_burn(),
          required(:assignments) => [assignment_snapshot()],
          required(:quota_readiness) => quota_readiness(),
          required(:routing_readiness) => routing_readiness(),
          required(:provider_credits_policy) => %{allow_provider_credits: boolean()},
          required(:provider_credits_summary) => QuotaProjection.provider_credits_summary(),
          required(:can_manage_provider_credits?) => boolean(),
          required(:quota_limits) => [quota_limit_row()],
          required(:identity_observability) => identity_observability(),
          required(:usage_poll_pause) => usage_poll_pause() | nil
        }

  @terminal_reconciliation_statuses ~w(succeeded partial failed)
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
    # Trusted atom options narrow scoped identities before per-account work.
    # String-keyed browser filters never establish ownership or monitoring targets.
    {identity_id, filters} = Map.pop(filters, :identity_id)
    {identity_ids, filters} = Map.pop(filters, :identity_ids, :all)

    pools = intersect_visible_pools(scope, pools)
    pool_lookup = Map.new(pools, &{&1.id, &1})
    assignments = active_assignment_snapshots(pools, pool_lookup)
    model_inventory = assignment_model_inventory(assignments)
    assignments = attach_assignment_model_inventory(assignments, model_inventory)

    identities =
      scope
      |> Upstreams.list_visible_upstream_identities(
        pool_ids: Enum.map(pools, & &1.id),
        include_deleted: true,
        include_unassigned: Map.get(filters, "pool_id") in [nil, ""]
      )
      |> narrow_to_identity(identity_id)
      |> narrow_to_identities(identity_ids)

    assignments = narrow_assignments_to_identities(assignments, identities)
    circuit_observed_at = DateTime.utc_now()
    circuit_settings = OperationalSettings.current()

    circuit_readiness_by_assignment_id =
      assignments
      |> served_models_by_assignment_id()
      |> UpstreamCircuitReadiness.by_assignment_id(circuit_settings, circuit_observed_at)

    assignments =
      attach_assignment_circuit_readiness(assignments, circuit_readiness_by_assignment_id)

    token_burns = TokenBurnProjection.summaries(identities)
    identity_ids = Enum.map(identities, & &1.id)
    deletion_permissions = Upstreams.account_deletion_permissions(scope, identity_ids)
    deletion_states = Upstreams.account_deletion_states(identity_ids)
    credit_policy_permissions = ProviderCreditsPolicy.management_permissions(scope, identity_ids)
    request_summaries = Jobs.saved_reset_request_summaries(scope, identity_ids, pool_ids: Enum.map(pools, & &1.id))

    snapshot_at = DateTime.utc_now()

    quota_snapshots =
      identities
      |> Enum.map(& &1.id)
      |> RoutingQuotaSnapshot.load_by_identity_ids(snapshot_at)

    identities
    |> Enum.map(fn identity ->
      deletion_state = Map.get(deletion_states, identity.id)

      identity
      |> account_snapshot(assignments, token_burns, datetime_preferences, Map.fetch!(quota_snapshots, identity.id), Map.get(request_summaries, identity.id))
      |> Map.put(:can_manage_provider_credits?, Map.get(credit_policy_permissions, identity.id, false))
      |> Map.put(:deletion_state, deletion_state)
      |> Map.put(:can_delete?, Map.get(deletion_permissions, identity.id, false) and deletion_state != :in_progress)
    end)
    |> Filter.apply(filters)
  end

  defp narrow_to_identity(identities, nil), do: identities

  defp narrow_to_identity(identities, identity_id) when is_binary(identity_id),
    do: Enum.filter(identities, &(&1.id == identity_id))

  defp narrow_to_identity(_identities, _identity_id), do: []

  defp narrow_to_identities(identities, :all), do: identities

  defp narrow_to_identities(identities, identity_ids) when is_list(identity_ids) do
    targets = trusted_identity_ids(identity_ids, [])
    Enum.filter(identities, &(&1.id in targets))
  end

  defp narrow_to_identities(_identities, _identity_ids), do: []

  defp trusted_identity_ids([], acc), do: acc

  defp trusted_identity_ids([id | rest], acc) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> trusted_identity_ids(rest, [id | acc])
      :error -> trusted_identity_ids(rest, acc)
    end
  end

  defp trusted_identity_ids(_improper_tail, _acc), do: []

  defp narrow_assignments_to_identities(assignments, identities) do
    Map.take(assignments, Enum.map(identities, & &1.id))
  end

  defp served_models_by_assignment_id(assignments) do
    Map.new(
      for {_identity_id, identity_assignments} <- assignments,
          assignment <- identity_assignments do
        {assignment.id, Enum.map(assignment.models, & &1.exposed_model_id)}
      end
    )
  end

  defp attach_assignment_circuit_readiness(assignments, circuit_readiness_by_assignment_id) do
    Map.new(assignments, fn {identity_id, identity_assignments} ->
      snapshots =
        Enum.map(identity_assignments, fn assignment ->
          circuit_readiness =
            Map.get(
              circuit_readiness_by_assignment_id,
              assignment.id,
              UpstreamCircuitReadiness.clear()
            )

          Map.put(assignment, :circuit_readiness, circuit_readiness)
        end)

      {identity_id, snapshots}
    end)
  end

  defp intersect_visible_pools(scope, pools) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> MapSet.new(& &1.id)
    Enum.filter(pools, &MapSet.member?(visible_pool_ids, &1.id))
  end

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
    pool_order = pools |> Enum.with_index() |> Map.new(fn {pool, index} -> {pool.id, index} end)

    pools
    |> Enum.map(& &1.id)
    |> UpstreamAssignments.list_pool_assignments_for_pool_ids()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.sort_by(&{Map.fetch!(pool_order, &1.pool_id), &1.created_at, &1.id})
    |> Enum.map(&assignment_snapshot(&1, pool_lookup))
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp assignment_snapshot(%PoolUpstreamAssignment{} = assignment, pool_lookup) do
    pool = Map.get(pool_lookup, assignment.pool_id)

    %{
      id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      pool_id: assignment.pool_id,
      assignment_label: assignment.assignment_label || gettext("Pool assignment"),
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

  defp account_snapshot(
         identity,
         assignments,
         token_burns,
         datetime_preferences,
         quota_snapshot,
         request_summary
       ) do
    snapshot_at = quota_snapshot.as_of
    raw_quota_windows = RoutingQuotaSnapshot.time_visible_raw_windows(quota_snapshot)
    quota_windows = RoutingQuotaSnapshot.effective_windows(quota_snapshot)
    quota_readiness = QuotaProjection.readiness(quota_snapshot, snapshot_at)
    token_burn = Map.fetch!(token_burns, identity.id)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    identity_assignments =
      identity_assignments(identity, assignments, quota_readiness, token_burn)
      |> Enum.map(fn assignment ->
        readiness =
          identity
          |> UpstreamRoutingReadiness.from_inputs(assignment, quota_readiness)
          |> UpstreamRoutingReadiness.with_model_availability(quota_snapshot, [assignment])
          |> Formatting.localize_routing_readiness()

        Map.put(assignment, :routing_readiness, readiness)
      end)

    identity_observability =
      identity_observability(
        identity,
        Map.get(assignments, identity.id, []),
        quota_windows,
        snapshot_at
      )

    circuit_readiness =
      identity_assignments
      |> Enum.filter(&UpstreamRoutingReadiness.assignment_routing_ready?/1)
      |> Enum.map(& &1.circuit_readiness)
      |> UpstreamCircuitReadiness.aggregate()

    routing_readiness =
      identity
      |> UpstreamRoutingReadiness.from_inputs(identity_assignments, quota_readiness)
      |> UpstreamRoutingReadiness.with_model_availability(quota_snapshot, identity_assignments)
      |> UpstreamRoutingReadiness.with_circuit_visibility(circuit_readiness)
      |> Formatting.localize_routing_readiness()

    refresh_job = identity |> Jobs.list_recent_token_refresh_jobs(limit: 1) |> List.first()

    account = %{
      identity: identity,
      label: UpstreamNaming.account_name(identity),
      workspace_ref: workspace_ref(identity.workspace_id),
      workspace_label: safe_workspace_label(identity.workspace_label),
      subject_ref: subject_ref(identity.chatgpt_user_id),
      plan_label: account_plan_label(identity),
      plan_reported?: account_plan_reported?(identity),
      refresh_status: refresh_status_label(identity),
      token_refresh_label: token_refresh_label(identity, datetime_preferences),
      token_refresh_value_label: token_refresh_value_label(identity, datetime_preferences),
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
      auth_verified_value_label: Formatting.timestamp_value_label(identity.auth_verified_at, datetime_preferences),
      access_token_label: access_token_label(identity_observability.credential_expiry, datetime_preferences),
      secret_status: Secrets.secret_status(identity),
      reauth_required?: reauth_required?(identity),
      reauth_reason_code: reauth_reason_code(identity),
      reauth_reason_message: reauth_reason_message(identity),
      saved_resets: SavedResetProjection.snapshot(identity, datetime_preferences),
      saved_reset_policy: SavedResetProjection.policy(identity),
      saved_reset_confirmation:
        QuotaProjection.saved_reset_confirmation(
          redemption || %{},
          raw_quota_windows,
          quota_windows,
          snapshot_at
        ),
      token_burn: token_burn,
      assignments: identity_assignments,
      quota_readiness: quota_readiness,
      routing_readiness: routing_readiness,
      provider_credits_policy: %{allow_provider_credits: quota_snapshot.allow_provider_credits},
      provider_credits_summary: QuotaProjection.provider_credits_summary(quota_snapshot),
      quota_limits:
        QuotaProjection.quota_limit_rows(
          quota_windows,
          datetime_preferences,
          snapshot_at,
          raw_quota_windows,
          redemption
        ),
      identity_observability: identity_observability,
      usage_poll_pause: usage_poll_pause(identity, snapshot_at, datetime_preferences)
    }

    operation =
      SavedResetOperationProjection.project(%{
        snapshot_at: snapshot_at,
        datetime_preferences: datetime_preferences,
        redemption: redemption,
        request_summary: request_summary,
        confirmation: account.saved_reset_confirmation,
        serving_readiness: account.routing_readiness,
        usage_poll_pause: account.usage_poll_pause,
        last_checked_at: snapshot_at
      })

    account =
      account
      |> Map.put(:saved_reset_operation, operation)
      |> Map.put(:saved_reset_refresh_cursor, saved_reset_refresh_cursor(identity, redemption, request_summary))

    Map.put(
      account,
      :saved_reset_redemption_action,
      SavedResetProjection.redemption_action(account)
    )
  end

  # Private LiveView invalidation state; never pass this cursor to components or DOM.
  @spec saved_reset_refresh_cursor(UpstreamIdentity.t(), term(), SavedResetOperationProjection.request_summary() | nil) :: saved_reset_refresh_cursor()
  defp saved_reset_refresh_cursor(identity, redemption, request_summary) do
    metadata = identity.metadata || %{}

    %{
      identity_id: identity.id,
      credential_epoch: cursor_counter(metadata["credential_epoch"]),
      lifecycle_generation: cursor_counter(redemption_generation(redemption)),
      request_generation: :crypto.hash(:sha256, :erlang.term_to_binary(request_summary)) |> Base.encode16(case: :lower)
    }
  end

  # The projection reads a malformed redemption value as an unknown outcome; the cursor reads it as no generation.
  defp redemption_generation(%{"generation" => generation}), do: generation
  defp redemption_generation(_redemption), do: nil

  defp cursor_counter(value) when is_integer(value) and value >= 0, do: value
  defp cursor_counter(_value), do: nil

  @doc """
  Whether a targeted saved-reset status read may replace the account a LiveView shows. `incoming` must
  name the same account and hold every counter at or above `current`, the cursor the read started from:
  a counter `current` does not know accepts any value, and a missing counter never replaces a known one.
  Token refresh advances the credential epoch, so a later epoch is newer data, never a stale read.
  """
  @spec newer_saved_reset_refresh_cursor?(saved_reset_refresh_cursor() | term(), saved_reset_refresh_cursor() | term()) :: boolean()
  def newer_saved_reset_refresh_cursor?(%{identity_id: identity_id} = incoming, %{identity_id: identity_id} = current) do
    Enum.all?([:credential_epoch, :lifecycle_generation], fn field ->
      known = Map.get(current, field)
      read = Map.get(incoming, field)
      is_nil(known) or (is_integer(read) and read >= known)
    end)
  end

  def newer_saved_reset_refresh_cursor?(_incoming, _current), do: false

  defp identity_assignments(identity, assignments, quota_readiness, token_burn) do
    assignments
    |> Map.get(identity.id, [])
    |> Enum.map(&identity_assignment(&1, identity, quota_readiness, token_burn))
  end

  defp identity_assignment(assignment, identity, quota_readiness, token_burn) do
    assignment
    |> Map.delete(:last_reconciliation)
    |> Map.put(:assignment_label, assignment_display_label(identity, assignment))
    |> Map.put(:recent_traffic, assignment_recent_traffic(token_burn, assignment.pool_id))
    |> QuotaProjection.put_current_quota_priming(quota_readiness)
  end

  defp assignment_recent_traffic(token_burn, pool_id) do
    Map.get(token_burn.recent_pools, pool_id, %{
      tokens: 0,
      request_count: 0,
      known_request_count: 0,
      unknown_request_count: 0
    })
  end

  # A lane label only earns its place when an operator plausibly chose it, and
  # the schema cannot say whether one did: `assignment_label` is defaulted to
  # `account_label` at creation and never re-synced. These two heuristics are
  # how the page approximates the answer — drop a stored label that still looks
  # like the account identifier it was seeded from, and otherwise trust it.
  # A rename to a name that is not identifier-shaped defeats both.
  defp assignment_display_label(identity, assignment) do
    current_label = UpstreamNaming.account_name(identity)

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
    token_refresh_failure_label(:failed, metadata)
  end

  defp token_refresh_label_from_metadata(
         %{"status" => "reauth_required"} = metadata,
         _datetime_preferences
       ) do
    token_refresh_failure_label(:reauth_required, metadata)
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
       do: gettext("token refresh %{status}", status: String.replace(status, "_", " "))

  defp token_refresh_label_from_metadata(_metadata, _datetime_preferences),
    do: gettext("token refresh not run")

  defp token_refresh_failure_label(status, %{"reason" => %{} = reason}) do
    token_refresh_failure_label(status, token_refresh_reason_message(reason), Formatting.present_string(reason["code"]))
  end

  defp token_refresh_failure_label(:failed, _metadata), do: gettext("token refresh failed")
  defp token_refresh_failure_label(:reauth_required, _metadata), do: gettext("reauth required")

  defp token_refresh_failure_label(:failed, message, code) when is_binary(message) and is_binary(code), do: gettext("token refresh failed: %{message} (%{code})", message: message, code: code)
  defp token_refresh_failure_label(:failed, message, nil) when is_binary(message), do: gettext("token refresh failed: %{message}", message: message)
  defp token_refresh_failure_label(:failed, nil, code) when is_binary(code), do: gettext("token refresh failed: %{code}", code: code)
  defp token_refresh_failure_label(:reauth_required, message, code) when is_binary(message) and is_binary(code), do: gettext("reauth required: %{message} (%{code})", message: message, code: code)
  defp token_refresh_failure_label(:reauth_required, message, nil) when is_binary(message), do: gettext("reauth required: %{message}", message: message)
  defp token_refresh_failure_label(:reauth_required, nil, code) when is_binary(code), do: gettext("reauth required: %{code}", code: code)
  defp token_refresh_failure_label(status, _message, _code), do: token_refresh_failure_label(status, nil)

  defp token_refresh_value_label(identity, preferences) do
    metadata = current_token_refresh_status(identity)

    case metadata["status"] do
      "succeeded" -> gettext("succeeded %{time}", time: Formatting.timestamp_value_label(Formatting.parse_timestamp(metadata["finished_at"]), preferences))
      "refreshing" -> gettext("started %{time}", time: Formatting.timestamp_value_label(Formatting.parse_timestamp(metadata["started_at"]), preferences))
      "imported" -> gettext("imported %{time}", time: Formatting.timestamp_value_label(Formatting.parse_timestamp(metadata["finished_at"]), preferences))
      "failed" -> token_refresh_value_failure(metadata)
      "reauth_required" -> token_refresh_failure_label(:reauth_required, metadata)
      status when is_binary(status) -> status
      _missing -> gettext("not run")
    end
  end

  defp token_refresh_value_failure(%{"reason" => %{} = reason}) do
    case {token_refresh_reason_message(reason), Formatting.present_string(reason["code"])} do
      {message, code} when is_binary(message) and is_binary(code) -> gettext("failed: %{message} (%{code})", message: message, code: code)
      {message, nil} when is_binary(message) -> gettext("failed: %{message}", message: message)
      {nil, code} when is_binary(code) -> gettext("failed: %{code}", code: code)
      _missing -> gettext("failed")
    end
  end

  defp token_refresh_value_failure(_metadata), do: gettext("failed")

  defp token_refresh_reason_message(reason) do
    reason["message"] |> Formatting.present_string() |> token_refresh_reason_label()
  end

  defp token_refresh_reason_label("refresh token is missing"), do: gettext("refresh token is missing")
  defp token_refresh_reason_label("refresh token was revoked"), do: gettext("refresh token was revoked")
  defp token_refresh_reason_label("upstream returned an invalid refresh response"), do: gettext("upstream returned an invalid refresh response")
  defp token_refresh_reason_label("provider usage authentication was rejected"), do: gettext("provider usage authentication was rejected")
  defp token_refresh_reason_label("upstream OAuth refresh failed"), do: gettext("upstream OAuth refresh failed")
  defp token_refresh_reason_label("token refresh failed: " <> detail), do: detail
  defp token_refresh_reason_label("reauth required: " <> detail), do: detail
  defp token_refresh_reason_label(message), do: message

  defp access_token_label(
         %{state: "known_future", expires_at: %DateTime{} = expires_at},
         preferences
       ),
       do: Formatting.timestamp_status_label("access token expires", expires_at, preferences)

  defp access_token_label(
         %{state: "known_past", expires_at: %DateTime{} = expires_at},
         preferences
       ),
       do: Formatting.timestamp_status_label("access token expired", expires_at, preferences)

  defp access_token_label(_credential_expiry, _preferences), do: gettext("access token expiry unavailable")

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
    |> token_refresh_reason_message()
  end

  defp token_refresh_reason(identity) do
    identity
    |> current_token_refresh_status()
    |> Map.get("reason", %{})
  end

  # The longest running pause is the one that decides when this account's usage
  # is read again, so it is the one shown; the others are only counted. The
  # stored origin is a digest, so the operator sees what the provider said and
  # how, never where.
  defp usage_poll_pause(%UpstreamIdentity{} = identity, now, datetime_preferences) do
    case Upstreams.usage_poll_pauses(identity, now) do
      [] ->
        nil

      [longest | _others] = pauses ->
        %{
          paused_until: longest.not_before,
          paused_until_label: DateTimeDisplay.format_datetime(longest.not_before, datetime_preferences),
          remaining_label: Formatting.relative_time_label(longest.not_before, now),
          status_code: longest.status_code,
          origin_label: usage_poll_pause_origin_label(longest.status_code, longest.source),
          origin_count: length(pauses)
        }
    end
  end

  defp usage_poll_pause_origin_label(status_code, "retry_after") when is_integer(status_code),
    do: gettext("HTTP %{status_code} with Retry-After", status_code: status_code)

  defp usage_poll_pause_origin_label(status_code, _source) when is_integer(status_code),
    do: gettext("HTTP %{status_code} with a provider instruction", status_code: status_code)

  defp usage_poll_pause_origin_label(_status_code, "retry_after"), do: gettext("a throttling response with Retry-After")
  defp usage_poll_pause_origin_label(_status_code, _source), do: gettext("a throttling response with a provider instruction")

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
    |> Enum.find_value({nil, nil}, &reconciliation_step_reason/1)
  end

  defp reconciliation_step_reason(%{} = step) do
    with "failed" <- map_value(step, :status),
         code = map_value(step, :code),
         message when is_binary(message) <- reconciliation_message(code) do
      {code, message}
    else
      _not_failed_or_unreported -> nil
    end
  end

  defp reconciliation_step_reason(_step), do: nil

  defp reconciliation_message("catalog_refreshed"), do: gettext("catalog refreshed")
  defp reconciliation_message("catalog_sync_failed"), do: gettext("catalog sync failed")
  defp reconciliation_message("catalog_sync_in_progress"), do: gettext("catalog sync in progress")
  defp reconciliation_message("catalog_sync_partial"), do: gettext("catalog sync partially completed")
  defp reconciliation_message("catalog_sync_skipped"), do: gettext("catalog sync skipped")
  defp reconciliation_message("health_preserved"), do: gettext("assignment health preserved")
  defp reconciliation_message("health_refreshed"), do: gettext("assignment health refreshed")
  defp reconciliation_message("health_skipped"), do: gettext("assignment health skipped")
  defp reconciliation_message("quota_refreshed"), do: gettext("quota refreshed")
  defp reconciliation_message("quota_refresh_auth_unavailable"), do: gettext("quota refresh authentication unavailable")
  defp reconciliation_message("quota_refresh_failed"), do: gettext("quota refresh failed")
  defp reconciliation_message("quota_refresh_superseded"), do: gettext("quota refresh superseded")
  defp reconciliation_message("quota_refresh_unavailable"), do: gettext("quota refresh unavailable")
  defp reconciliation_message("quota_reused_fresh"), do: gettext("fresh quota evidence reused")
  defp reconciliation_message("workspace_identity_mismatch"), do: gettext("workspace identity mismatch")
  defp reconciliation_message(_code), do: nil

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
    identity.metadata
    |> TokenRefreshMetadata.project_access_token_expiry()
    |> AccessTokenExpiry.evaluate(now)
    |> credential_expiry_projection(now)
  end

  defp credential_expiry_projection(%{state: :known, deadline: %DateTime{} = deadline}, now) do
    %{
      state: "known_future",
      expires_at: deadline,
      age: Formatting.relative_time_label(deadline, now)
    }
  end

  defp credential_expiry_projection(%{state: :expired, deadline: %DateTime{} = deadline}, now) do
    %{
      state: "known_past",
      expires_at: deadline,
      age: Formatting.relative_time_label(deadline, now)
    }
  end

  defp credential_expiry_projection(_evaluation, _now),
    do: %{state: "unavailable", expires_at: nil, age: nil}

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

  defp pool_label(nil), do: gettext("Unknown Pool")
  defp pool_label(pool), do: pool.name
end
