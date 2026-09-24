defmodule CodexPoolerWeb.Admin.ApiKeysLiveEditRoundTripTest do
  @moduledoc """
  The API key edit form saves what the operator changed and keeps everything
  else the key stores: an empty operator note stays empty instead of taking
  the "No notes" placeholder as its value (findings#206 row 206-503).
  """

  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  describe "operator notes" do
    test "an edit of a key without a note leaves the note empty", %{conn: conn, scope: scope} do
      pool = pool!(scope, "notes-empty")
      assert {:ok, %{api_key: api_key}} = Access.create_api_key(scope, pool, %{display_name: "No note key"})
      assert Repo.get!(APIKey, api_key.id).metadata["operator_notes"] == nil

      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
      view |> element("#edit-api-key-#{api_key.id}") |> render_click()

      assert has_element?(view, "#api_key_operator_notes[placeholder='Operator-only notes; no secrets']")
      refute has_element?(view, "#api_key_operator_notes", "No notes")

      view |> element("#api-key-form") |> render_submit(%{"api_key" => %{"display_name" => "Renamed no note key"}})

      edited = Repo.get!(APIKey, api_key.id)
      assert edited.display_name == "Renamed no note key"
      assert edited.metadata["operator_notes"] == nil
      refute has_element?(view, "#api-key-row-#{api_key.id}-notes-content")
    end

    test "an edit keeps a stored note and saves a cleared one as empty", %{conn: conn, scope: scope} do
      pool = pool!(scope, "notes-kept")

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Noted key", metadata: %{"operator_notes" => "rollout batch two"}})

      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
      view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      assert has_element?(view, "#api_key_operator_notes", "rollout batch two")

      view |> element("#api-key-form") |> render_submit(%{"api_key" => %{"display_name" => "Renamed noted key"}})
      assert Repo.get!(APIKey, api_key.id).metadata["operator_notes"] == "rollout batch two"

      view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      view |> element("#api-key-form") |> render_submit(%{"api_key" => %{"operator_notes" => ""}})
      assert Repo.get!(APIKey, api_key.id).metadata["operator_notes"] == nil
    end
  end

  defp pool!(scope, prefix) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "#{prefix}-#{System.unique_integer([:positive])}", name: "Round trip #{prefix}"})
    pool
  end
end
