defmodule CodexPooler.Dev.Seeds.DocsScreenshots.Presentation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.Invite
  alias CodexPooler.Accounts.{TOTPSetting, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Postgres.INET
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @seed_key "codex_pooler_dev_seed"

  @operator_names %{
    "dev-owner@example.com" => "Example Owner",
    "dev-admin@example.com" => "Example Admin",
    "dev-operator@example.com" => "Example Reviewer",
    "dev-disabled@example.com" => "Example Contractor",
    "dev-password-reset@example.com" => "Example Newcomer"
  }

  # Provider credit observations by identity position: {balance, unlimited?, credits enabled?}.
  # Baselines come from the 1000-credit account windows the inventory already holds.
  @credit_specs %{
    0 => {840, false, true},
    1 => {310, false, true},
    8 => {620, false, true},
    9 => {480, false, false},
    10 => {0, true, true},
    11 => {95, false, true}
  }

  # Invites arrive in the order active, accepted, revoked, expired.
  @invite_specs [
    {"build-agent@example.com", 40},
    {"release-reviewer@example.com", 1_620},
    {"contractor@example.com", 3_100},
    {"intern@example.com", 6_400}
  ]

  # {days until expiry or nil, minutes since last use, Observatory access}, one entry per API key.
  @key_lifecycles [
    {nil, 4, true},
    {21, 135, true},
    {nil, 7_300, false},
    {nil, 20_100, false},
    {nil, 55, false},
    {nil, 12, false},
    {45, 380, false},
    {nil, 27, false},
    {9, 90, false}
  ]

  @spec apply!(map()) :: map()
  def apply!(result) do
    timestamp = DateTime.utc_now()
    rename_operators!(result, timestamp)
    enable_totp!(result.operators, timestamp)
    clear_unmarked_pool_audit_events!(result.pools)
    identities = result.upstream_identities |> workspace_details!() |> provider_credits!(timestamp)
    api_keys = api_key_lifecycles!(result.api_keys, timestamp)
    invites = invites!(result.invites, timestamp)
    audit_events = audit_events!(result, timestamp)
    seeded_events = describe_seeded_events!(result.audit_events, api_keys, result.operators)

    Map.merge(result, %{
      upstream_identities: identities,
      api_keys: api_keys,
      invites: invites,
      audit_events: seeded_events ++ audit_events
    })
  end

  defp rename_operators!(result, timestamp) do
    result.operators
    |> Enum.concat([result.owner])
    |> Enum.with_index()
    |> Enum.each(fn {user, index} ->
      name = Map.fetch!(@operator_names, user.email)
      joined_at = DateTime.add(timestamp, -(34 - index * 6), :day)
      last_login_at = if user.status == "active", do: DateTime.add(timestamp, -(index * 190 + 25), :minute)
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [display_name: name, created_at: joined_at, last_login_at: last_login_at])
    end)
  end

  # Two reviewers use an authenticator app; the owner never does, so the screenshot sign-in stays password-only.
  # The ciphertext is a placeholder that no sign-in can ever decrypt.
  defp enable_totp!([admin, _password_reset, _disabled, reviewer], timestamp) do
    for user <- [admin, reviewer] do
      Repo.delete_all(from(t in TOTPSetting, where: t.user_id == ^user.id))

      Repo.insert!(%TOTPSetting{
        user_id: user.id,
        secret_ciphertext: <<0, 0, 0, 0>>,
        secret_key_version: "v1",
        recovery_generation: 1,
        status: "active",
        enrolled_at: DateTime.add(timestamp, -20, :day),
        verified_at: DateTime.add(timestamp, -20, :day),
        created_at: DateTime.add(timestamp, -20, :day),
        updated_at: DateTime.add(timestamp, -20, :day)
      })
    end
  end

  # Creating the screenshot API keys through the product recorded one event per key with no
  # target name, and earlier seed runs left theirs behind with the Pool link cleared; the named events below replace them.
  # The documentation scenario owns its database, so this also removes key-creation events whose Pool link is already gone.
  defp clear_unmarked_pool_audit_events!(pools) do
    pool_ids = Enum.map(pools, & &1.id)

    Repo.delete_all(
      from(e in AuditEvent,
        where: fragment("coalesce(? ->> 'dev_seed', '') <> ?", e.details, ^@seed_key),
        where: e.pool_id in ^pool_ids or (is_nil(e.pool_id) and e.action == "api_key.create")
      )
    )
  end

  defp workspace_details!(identities) do
    identities
    |> Enum.with_index(1)
    |> Enum.map(fn {identity, position} ->
      identity
      |> Ecto.Changeset.change(%{workspace_label: workspace_label(position), chatgpt_user_id: "sample-user-#{String.pad_leading(Integer.to_string(position), 2, "0")}"})
      |> Repo.update!()
    end)
  end

  defp workspace_label(position) when position <= 8, do: "Engineering"
  defp workspace_label(_position), do: "Research"

  defp provider_credits!(identities, timestamp) do
    identities
    |> Enum.with_index()
    |> Enum.map(fn {identity, index} -> add_credit_observation(identity, Map.get(@credit_specs, index), timestamp) end)
  end

  defp add_credit_observation(identity, nil, _timestamp), do: identity

  defp add_credit_observation(identity, {balance, unlimited?, enabled?}, timestamp) do
    epoch = identity.metadata |> CredentialFencing.initialize_metadata() |> Map.fetch!("credential_epoch")

    observation = %{
      "version" => 1,
      "balance" => balance,
      "has_credits" => balance > 0 or unlimited?,
      "unlimited" => unlimited?,
      "observed_at" => DateTime.to_iso8601(timestamp),
      "credential_epoch" => epoch
    }

    from(w in AccountQuotaWindow, where: w.upstream_identity_id == ^identity.id and w.quota_key == "account" and w.quota_scope == "account" and w.window_kind == "primary")
    |> Repo.update_all(set: [source: "codex_usage_api", active_limit: 1000])

    identity
    |> Ecto.Changeset.change(%{metadata: Map.put(identity.metadata, "quota_credit_balance", observation), allow_provider_credits: enabled?})
    |> Repo.update!()
  end

  defp api_key_lifecycles!(api_keys, timestamp) do
    api_keys
    |> Enum.zip(@key_lifecycles)
    |> Enum.map(fn {api_key, {expiry_days, used_minutes_ago, observatory?}} ->
      api_key
      |> Ecto.Changeset.change(%{
        expires_at: expiry_days && DateTime.add(timestamp, expiry_days, :day),
        last_used_at: DateTime.add(timestamp, -used_minutes_ago, :minute),
        dashboard_access: observatory?
      })
      |> Repo.update!()
    end)
  end

  defp invites!(invites, timestamp) do
    invites
    |> Enum.zip(@invite_specs)
    |> Enum.map(fn {invite, {email, created_minutes_ago}} ->
      created_at = DateTime.add(timestamp, -created_minutes_ago, :minute)

      invite
      |> Ecto.Changeset.change(%{invited_email: email, created_at: created_at, updated_at: created_at})
      |> Repo.update!()
    end)
    |> Enum.map(&shift_invite_lifecycle!(&1, timestamp))
  end

  defp shift_invite_lifecycle!(%Invite{status: "accepted"} = invite, timestamp), do: update_invite!(invite, accepted_at: DateTime.add(timestamp, -1_480, :minute), email_sent_at: DateTime.add(invite.created_at, 2, :minute))
  defp shift_invite_lifecycle!(%Invite{status: "revoked"} = invite, timestamp), do: update_invite!(invite, revoked_at: DateTime.add(timestamp, -2_900, :minute))
  defp shift_invite_lifecycle!(%Invite{status: "expired"} = invite, timestamp), do: update_invite!(invite, expires_at: DateTime.add(timestamp, -1_000, :minute))
  defp shift_invite_lifecycle!(%Invite{} = invite, timestamp), do: update_invite!(invite, expires_at: DateTime.add(timestamp, 1_380, :minute))

  defp update_invite!(invite, changes), do: invite |> Ecto.Changeset.change(Map.new(changes)) |> Repo.update!()

  defp audit_events!(result, timestamp) do
    owner = result.owner
    [admin | _] = result.operators
    [production, secondary, _standby, automation | _] = result.pools
    [build_key, release_key, paused_key | _] = result.api_keys
    identities = result.upstream_identities
    identity = fn name -> Enum.find(identities, &(&1.account_label == name)) end
    primary = identity.("Example Primary Pro")
    exhausted = identity.("Example Quota Exhausted")
    code_review = identity.("Example Code Review")
    build_agents = identity.("Example Build Agents")

    [
      {35, owner, "auth.login", "session", nil, nil, "success", %{}, "203.0.113.24"},
      {58, owner, "upstream_account.provider_credits_policy_update", "upstream_account", code_review.id, production, "success", %{"label" => code_review.account_label, "allow_provider_credits" => false, "previous_allow_provider_credits" => true}, nil},
      {96, admin, "api_key.update", "api_key", release_key.id, production, "success", api_key_update_details(release_key), nil},
      {140, owner, "pool.model_serving_modes_update", "pool", production.id, production, "success", %{"pool_name" => production.name, "changed_models" => ["gpt-6.2-sol"], "to_mode" => "full"}, nil},
      {205, admin, "upstream_account.refresh_enqueue", "upstream_account", exhausted.id, production, "failure", %{"label" => exhausted.account_label, "reason" => "a token refresh is already queued for this account"}, nil},
      {260, owner, "upstream_account.saved_reset_policy_update", "upstream_account", primary.id, production, "success", %{"label" => primary.account_label, "saved_reset_auto_redeem_enabled" => true, "trigger_mode" => "blocked", "resets_to_keep" => 1}, nil},
      {410, owner, "upstream_account.pause", "upstream_account", identity.("Example Paused Account").id, production, "success", %{"label" => "Example Paused Account"}, nil},
      {640, owner, "api_key.pause", "api_key", paused_key.id, production, "success", %{"label" => paused_key.display_name, "key_prefix" => paused_key.key_prefix}, nil},
      {880, admin, "invite.create", "invite", nil, production, "success", %{"invited_email" => "build-agent@example.com"}, nil},
      {1_310, owner, "pool.status_update", "pool", automation.id, automation, "success", %{"pool_name" => automation.name, "status" => "active", "previous_status" => "disabled"}, nil},
      {1_620, owner, "mcp.token_create", "mcp_token", nil, nil, "success", %{"label" => "Observatory reader"}, nil},
      {2_050, owner, "instance_settings.update", "instance_settings", nil, nil, "success", %{"changed_sections" => ["gateway"], "changed_fields" => ["proactive_credential_refresh"]}, nil},
      {2_700, admin, "upstream_account.rename", "upstream_account", build_agents.id, production, "success", %{"label" => build_agents.account_label, "previous_label" => "Example Build Agent"}, nil},
      {3_300, owner, "api_key.rotate", "api_key", build_key.id, production, "success", %{"label" => build_key.display_name, "key_prefix" => build_key.key_prefix}, nil},
      {3_900, owner, "alert_rule.create", "alert_rule", nil, nil, "success", %{"label" => "Upstream quota exhausted"}, nil},
      {4_800, owner, "pool.routing_update", "pool", secondary.id, secondary, "success", %{"pool_name" => secondary.name, "changed_fields" => ["bridge_ring_size", "http_affinity"]}, nil},
      {6_100, admin, "auth.login", "session", nil, nil, "success", %{}, "198.51.100.17"},
      {7_400, owner, "operator.create", "user", nil, nil, "success", %{"email" => "dev-operator@example.com", "role" => "instance_admin"}, nil}
    ]
    |> replace_events!(timestamp)
  end

  # The three events of the base seed name their targets and give a believable failure.
  defp describe_seeded_events!(events, [api_key | _], [admin | _]) do
    Enum.map(events, fn event ->
      details =
        case event.action do
          "api_key.create" -> Map.put(event.details, "label", api_key.display_name)
          "operator.update" -> event.details |> Map.put("email", admin.email) |> Map.put("reason", "the temporary password does not meet the password policy")
          _other -> event.details
        end

      event |> Ecto.Changeset.change(%{details: details}) |> Repo.update!()
    end)
  end

  defp api_key_update_details(api_key) do
    %{
      "label" => api_key.display_name,
      "key_prefix" => api_key.key_prefix,
      "allowed_model_mode" => "selected",
      "changed_fields" => ["allowed_model_identifiers", "default_policy", "expires_at"]
    }
  end

  # The events carry deterministic correlation ids, so a rerun removes exactly its own earlier rows.
  defp replace_events!(specs, timestamp) do
    correlation_ids = Enum.map(specs, &correlation_id/1)
    Repo.delete_all(from(e in AuditEvent, where: e.correlation_id in ^correlation_ids))
    Enum.map(specs, &insert_event!(&1, timestamp))
  end

  defp correlation_id({minutes_ago, _actor, action, _target_type, _target_id, _pool, _outcome, _details, _ip}) do
    :crypto.hash(:sha256, "codex_pooler_docs_screenshots:audit:#{action}:#{minutes_ago}") |> binary_part(0, 16) |> Ecto.UUID.load!()
  end

  defp insert_event!({minutes_ago, actor, action, target_type, target_id, pool, outcome, details, ip} = spec, timestamp) do
    %AuditEvent{}
    |> Ecto.Changeset.change(%{
      occurred_at: DateTime.add(timestamp, -minutes_ago, :minute),
      actor_type: "user",
      actor_user_id: actor.id,
      pool_id: pool && pool.id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      outcome: outcome,
      correlation_id: correlation_id(spec),
      ip_address: inet(ip),
      details: details
    })
    |> Repo.insert!()
  end

  defp inet(nil), do: nil

  defp inet(address) do
    {:ok, inet} = INET.cast(address)
    inet
  end
end
