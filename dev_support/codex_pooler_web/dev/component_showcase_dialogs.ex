defmodule CodexPoolerWeb.Dev.ComponentShowcaseDialogs do
  @moduledoc """
  Every admin dialog, one URL each, rendered from synthetic fixtures.

  Dialog chrome is shared - the shell, the footer, the touch-target floor - so a
  change to any of it lands on all of them at once, and the only way that was
  ever checked was by opening dialogs in the real app one at a time. Two of
  these cannot be reached that way at all: the API key and MCP token secrets
  exist for exactly one render after a create, so photographing them in the app
  means creating real credentials.

  Not covered here, and deliberately: `rename_account_dialog/1`,
  `delete_account_dialog/1` and `saved_reset_policy_dialog/1` on the upstreams
  index are `defp`, and the two alert delete dialogs are written inline in
  `AlertsLive.render/1`. The cockpit twins of the first two are public and are
  included, so the shared chrome is still covered; making the rest addressable
  is a production change and is not worth making for a dev surface without
  asking first.
  """

  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User

  alias CodexPoolerWeb.Admin.{
    ApiKeyPageComponents,
    InviteCreationDialog,
    InvitesPageComponents,
    OperatorComponents,
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
    {"invite-revoke", "Invite · revoke"},
    {"api-key-secret", "API key · secret"},
    {"api-key-delete", "API key · delete"},
    {"operator-create", "Operator · create"},
    {"operator-create-receipt", "Operator · password receipt"},
    {"operator-edit", "Operator · edit"},
    {"operator-password", "Operator · reset password"},
    {"auth-json", "Upstream · import auth.json"},
    {"cockpit-rename", "Upstream · rename"},
    {"cockpit-delete", "Upstream · delete"},
    {"cockpit-relink", "Upstream · OAuth relink"}
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

  defp synthetic_api_key, do: "cp_live_9f2a" <> String.duplicate("x7Qk3mZ1", 5)

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
