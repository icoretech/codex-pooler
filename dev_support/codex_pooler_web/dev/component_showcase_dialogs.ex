defmodule CodexPoolerWeb.Dev.ComponentShowcaseDialogs do
  @moduledoc """
  Every admin dialog, one URL each, rendered from synthetic fixtures.

  Dialog chrome is shared - the shell, the footer, the touch-target floor - so a
  change to any of it lands on all of them at once, and the only way that was
  ever checked was by opening dialogs in the real app one at a time. Two of
  these cannot be reached that way at all: the API key and MCP token secrets
  exist for exactly one render after a create, so photographing them in the app
  means creating real credentials.

  One dialog is still missing: `saved_reset_policy_dialog/1` on the upstreams
  index. It renders a projection the read model builds - saved-reset banks,
  redemption availability and its reason - and a hand-written fixture for that
  shape would drift from the real one without anything failing, which is the
  opposite of what this gallery is for.
  """

  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.DateTimeDisplay

  alias CodexPoolerWeb.Admin.{
    AlertsPageComponents,
    ApiKeyPageComponents,
    InviteCreationDialog,
    InvitesPageComponents,
    OperatorComponents,
    PoolListComponents,
    SettingsPageComponents,
    UpstreamCockpitComponents,
    UpstreamPageComponents
  }

  @pool_option_list [
    {"Design review Pool", "dev-showcase-pool"},
    {"Overflow Pool", "dev-showcase-2"}
  ]

  # Ordered the way an operator meets them: create, then the one-time secret it
  # hands back, then the destructive twin.
  @dialogs [
    {"pool-invite", "Pool · invite"},
    {"pool-delete", "Pool · delete"},
    {"invite-revoke", "Invite · revoke"},
    {"api-key-secret", "API key · secret"},
    {"api-key-delete", "API key · delete"},
    {"mcp-token", "MCP · token"},
    {"mcp-delete", "MCP · delete"},
    {"operator-create", "Operator · create"},
    {"operator-create-receipt", "Operator · password receipt"},
    {"operator-edit", "Operator · edit"},
    {"operator-password", "Operator · reset password"},
    {"auth-json", "Upstream · import auth.json"},
    {"cockpit-rename", "Upstream · rename"},
    {"cockpit-delete", "Upstream · delete"},
    {"cockpit-relink", "Upstream · OAuth relink"},
    {"upstream-rename", "Upstream · rename (index)"},
    {"upstream-delete", "Upstream · delete (index)"},
    {"saved-reset", "Upstream · saved resets"},
    {"alert-rule-delete", "Alert rule · delete"},
    {"alert-channel-delete", "Alert channel · delete"}
  ]

  @spec dialogs() :: [{String.t(), String.t()}]
  def dialogs, do: @dialogs

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@dialogs, &elem(&1, 0))

  @spec default_id() :: String.t()
  def default_id, do: "pool-invite"

  attr :dialog, :string, required: true
  attr :upload, :map, required: true

  def dialog_fixture(assigns) do
    ~H"""
    <InviteCreationDialog.pool_invite_dialog
      :if={@dialog == "pool-invite"}
      creating_invite
      invite_form={
        fixture_form(%{
          "invited_email" => "",
          "pool_id" => "dev-showcase-pool",
          "send_email" => "true"
        })
      }
      invite_form_valid?={false}
      last_invite={nil}
      mailer_configured?={true}
      pool_options={pool_options()}
    />

    <InvitesPageComponents.invite_revoke_dialog :if={@dialog == "invite-revoke"} invite={invite()} />

    <ApiKeyPageComponents.created_secret_dialog
      :if={@dialog == "api-key-secret"}
      created_secret={%{key_prefix: "cp_live_9f2a", raw_key: synthetic_api_key()}}
    />

    <ApiKeyPageComponents.delete_api_key_dialog
      :if={@dialog == "api-key-delete"}
      api_key={api_key()}
      form={fixture_form(%{"id" => "dev-showcase-key", "confirmation_prefix" => ""})}
      form_version={1}
    />

    <OperatorComponents.Dialogs.operator_create_dialog
      :if={@dialog in ["operator-create", "operator-create-receipt"]}
      creating_operator
      create_form={fixture_form(%{"display_name" => "", "email" => ""})}
      temporary_password_receipt={if(@dialog == "operator-create-receipt", do: password_receipt())}
      pool_options={operator_pool_options()}
    />

    <OperatorComponents.Dialogs.operator_edit_dialog
      :if={@dialog == "operator-edit"}
      editing_operator={operator()}
      edit_form={
        fixture_form(%{
          "id" => "dev-showcase-operator",
          "display_name" => "Dana Reviewer",
          "email" => "dana@example.com",
          "password_change_required" => "false"
        })
      }
      pool_options={operator_pool_options()}
    />

    <OperatorComponents.Dialogs.operator_password_dialog
      :if={@dialog == "operator-password"}
      resetting_operator={operator()}
      reset_operation={:reset_password}
      reset_form={
        fixture_form(%{
          "id" => "dev-showcase-operator",
          "operation" => "reset_password",
          "password" => "",
          "password_mode" => "generated",
          "password_change_required" => "true",
          "send_email" => "true"
        })
      }
    />

    <UpstreamPageComponents.AuthJsonDialog.auth_json_import_dialog
      :if={@dialog == "auth-json"}
      auth_json_form={fixture_form(%{"pool_id" => "dev-showcase-pool"})}
      importing_auth_json
      pool_options={pool_options()}
      upload={@upload}
      upload_limit_label="Up to 512 KB"
    />

    <UpstreamCockpitComponents.Dialogs.rename_account_dialog
      :if={@dialog == "cockpit-rename"}
      account={%{label: "design-review-account"}}
      form={fixture_form(%{"account_label" => "design-review-account"})}
    />

    <UpstreamCockpitComponents.Dialogs.delete_account_dialog
      :if={@dialog == "cockpit-delete"}
      account={%{label: "design-review-account"}}
      form={fixture_form(%{"id" => "dev-showcase-identity", "confirmation_label" => ""})}
    />

    <PoolListComponents.pool_delete_dialog
      :if={@dialog == "pool-delete"}
      deleting_pool={pool()}
      delete_form={fixture_form(%{"id" => "dev-showcase-pool", "confirmation_slug" => ""})}
      delete_form_version={1}
    />

    <SettingsPageComponents.MCP.mcp_created_token_dialog
      :if={@dialog == "mcp-token"}
      created_secret={%{key: %{key_prefix: "mcp_4c81"}, raw_token: synthetic_mcp_token()}}
    />

    <SettingsPageComponents.MCP.mcp_delete_dialog
      :if={@dialog == "mcp-delete"}
      key={%{key_prefix: "mcp_4c81", label: "Read-only metadata"}}
      form={fixture_form(%{"id" => "dev-showcase-mcp"})}
    />

    <UpstreamPageComponents.rename_account_dialog
      :if={@dialog == "upstream-rename"}
      account={%{label: "design-review-account"}}
      form={fixture_form(%{"account_label" => "design-review-account"})}
    />

    <UpstreamPageComponents.delete_account_dialog
      :if={@dialog == "upstream-delete"}
      account={%{label: "design-review-account"}}
      form={fixture_form(%{"id" => "dev-showcase-identity", "confirmation_label" => ""})}
    />

    <UpstreamPageComponents.saved_reset_policy_dialog
      :if={@dialog == "saved-reset"}
      account={saved_reset_account()}
      form={
        fixture_form(%{
          "auto_redeem_enabled" => "true",
          "auto_redeem_min_blocked_minutes" => "60",
          "auto_redeem_keep_credits" => "0",
          "auto_redeem_trigger_mode" => "blocked",
          "auto_redeem_quota_threshold_percent" => "95"
        })
      }
      datetime_preferences={CodexPoolerWeb.DateTimeDisplay.preferences_for_user(nil)}
    />

    <AlertsPageComponents.Dialogs.rule_delete_dialog
      :if={@dialog == "alert-rule-delete"}
      rule={%{display_name: "Weekly quota exhausted"}}
      form={fixture_form(%{"id" => "dev-showcase-rule"})}
    />

    <AlertsPageComponents.Dialogs.channel_delete_dialog
      :if={@dialog == "alert-channel-delete"}
      channel={%{display_name: "Ops mailbox"}}
      form={fixture_form(%{"id" => "dev-showcase-channel"})}
    />

    <UpstreamCockpitComponents.Dialogs.oauth_relink_dialog
      :if={@dialog == "cockpit-relink"}
      account_label="design-review-account"
      oauth_relinking
      oauth_relink_form={fixture_form(%{"callback_url" => ""})}
      datetime_preferences={CodexPoolerWeb.DateTimeDisplay.preferences_for_user(nil)}
    />
    """
  end

  # Synthetic throughout. These read like credentials because the dialogs that
  # show them are the ones that exist to show credentials, and a placeholder
  # that does not wrap or break the same way would hide the layout bug this
  # gallery is for.
  # Two different `pool_options` contracts live in the admin: the select-backed
  # dialogs take `{label, value}` tuples, the operator role fields iterate maps
  # and read `pool.id` / `pool.name`. Same attribute name, different shape.
  defp pool_options, do: @pool_option_list

  defp operator_pool_options,
    do: Enum.map(@pool_option_list, fn {name, id} -> %{id: id, name: name} end)

  # Built by running a synthetic identity through the real projection rather
  # than by hand-writing the map. The saved-reset bank is the richest shape any
  # of these dialogs reads, and a literal would drift from it silently - which
  # is the failure this gallery exists to prevent, not to reproduce.
  defp saved_reset_account do
    identity = %UpstreamIdentity{
      id: "dev-showcase-identity",
      account_label: "design-review-account",
      saved_reset_first_seen_ledger: %{"version" => 1, "entries" => []}
    }

    account = %{
      identity: identity,
      label: "design-review-account",
      saved_resets:
        SavedResetProjection.snapshot(identity, DateTimeDisplay.preferences_for_user(nil))
    }

    Map.put(
      account,
      :saved_reset_redemption_action,
      SavedResetProjection.redemption_action(account)
    )
  end

  defp synthetic_api_key, do: "cp_live_9f2a" <> String.duplicate("x7Qk3mZ1", 5)
  defp synthetic_mcp_token, do: "mcp_4c81" <> String.duplicate("b2Rt8vLp", 4)

  defp pool,
    do: %{
      id: "dev-showcase-pool",
      name: "Design review Pool",
      slug: "design-review",
      status: "archived"
    }

  defp invite,
    do: %{id: "dev-showcase-invite", invited_email: "dana@example.com", status: "pending"}

  defp api_key,
    do: %{
      id: "dev-showcase-key",
      display_name: "Review harness",
      key_prefix: "cp_live_9f2a",
      status: "active"
    }

  defp operator,
    do: %User{
      id: "dev-showcase-operator",
      email: "dana@example.com",
      display_name: "Dana Reviewer"
    }

  defp password_receipt,
    do: %{
      operator_email: "dana@example.com",
      temporary_password: "corral-vault-8821",
      email_error?: false
    }

  defp fixture_form(params), do: to_form(params, as: :showcase_dialog)
end
