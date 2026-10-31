defmodule CodexPoolerWeb.Admin.UpstreamDeletionFeedbackTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Summary
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Dev.ComponentShowcaseData

  test "pending deletion makes card contents inert while announcing status outside the busy subtree" do
    account = account(:in_progress)
    document = card(account)

    assert present?(document, "article[data-deletion-state='in_progress']")
    assert present?(document, "[data-role='upstream-account-card-content'][inert][aria-busy='true']")
    assert present?(document, "[inert] #upstream-account-#{account.identity.id}-mail")
    assert present?(document, "[inert] #upstream-account-actions-menu-#{account.identity.id}")
    assert present?(document, "[data-role='upstream-deletion-notice'][role='status'][aria-live='polite'][aria-atomic='true']")
    refute present?(document, "[inert] [data-role='upstream-deletion-notice']")
    refute present?(document, "[aria-busy='true'] [data-role='upstream-deletion-notice']")
    assert present?(document, "[data-role='upstream-deletion-notice'] .admin-loading-icon")
    assert LazyHTML.query(document, "[data-role='upstream-deletion-notice']") |> LazyHTML.text() =~ account.label
  end

  test "paused pending cards preserve disabled content and explicitly pause the live indicator" do
    document = account(:in_progress, true) |> card()

    assert present?(document, "[data-role='upstream-account-card-content'][inert]")
    assert present?(document, "[data-role='upstream-deletion-notice'][data-updates-paused='true']")
    assert present?(document, "[data-role='upstream-deletion-paused']")
    refute present?(document, "[data-role='upstream-deletion-notice'] .admin-loading-icon")
  end

  test "failed and historical deleted accounts stay inspectable with an accessible retry" do
    for deletion_state <- [:failed, :none] do
      account = account(deletion_state)
      document = card(account)

      assert present?(document, "article[data-deletion-state='#{deletion_state}']")
      refute present?(document, "[data-role='upstream-account-card-content'][inert]")
      assert present?(document, "[data-role='upstream-account-card-content'][aria-busy='false']")
      refute present?(document, "[data-role='upstream-deletion-notice']")
      assert present?(document, "#delete-upstream-account-#{account.identity.id}:not([disabled])")
      refute present?(document, "[inert] #delete-upstream-account-#{account.identity.id}")
    end
  end

  test "cockpit pending feedback follows the durable state and pause projection" do
    for paused <- [false, true] do
      document = cockpit(:in_progress, paused)

      assert present?(document, "#upstream-cockpit-header[data-deletion-state='in_progress']")
      assert present?(document, "#upstream-cockpit-deletion-notice[role='status'][aria-live='polite']")
      assert present?(document, "#upstream-cockpit-deletion-notice[data-updates-paused='#{paused}']")
      assert present?(document, "[data-role='upstream-deletion-paused']") == paused
      assert present?(document, "#upstream-cockpit-deletion-notice .admin-loading-icon") == !paused
      refute present?(document, "[inert]")
    end
  end

  test "cockpit has no busy notice for failed or historical deleted accounts" do
    for deletion_state <- [:failed, :none] do
      document = cockpit(deletion_state, false)
      refute present?(document, "[data-role='upstream-deletion-notice']")
      assert present?(document, "#upstream-cockpit-header[data-deletion-state='#{deletion_state}']")
    end
  end

  defp account(deletion_state, paused \\ false) do
    account = ComponentShowcaseData.account_card()

    account
    |> Map.merge(%{deletion_state: deletion_state, deletion_updates_paused?: paused, can_delete?: deletion_state != :in_progress})
    |> put_in([:identity, Access.key(:status)], "deleted")
  end

  defp card(account) do
    render_component(&AccountCard.account_card/1, account: account, account_index: 0)
    |> LazyHTML.from_fragment()
  end

  defp cockpit(deletion_state, paused) do
    cockpit = %{
      deletion_state: deletion_state,
      deletion_updates_paused?: paused,
      identity: %{account_email: nil, label: "Sample account", onboarding_method: "import"},
      header: %{title: "Sample account", status: "deleted", status_label: "Deleted", plan_reported?: false, safe_account_id_label: "unavailable", safe_account_id_value: "unavailable", subject_ref: nil}
    }

    render_component(&Summary.credential_card/1, cockpit: cockpit)
    |> LazyHTML.from_fragment()
  end

  defp present?(document, selector), do: Enum.any?(LazyHTML.query(document, selector))
end
