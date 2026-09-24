defmodule CodexPoolerWeb.Admin.ApiKeysLiveEditRoundTripTest do
  @moduledoc """
  The API key edit form saves what the operator changed and keeps everything
  else the key stores: an empty operator note stays empty instead of taking
  the "No notes" placeholder as its value (findings#206 row 206-503), and the
  labels and every per-model limit set a key stores survive an edit of an
  unrelated field (row 206-504). The form edits one model override; the
  others are kept as stored and listed read-only.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Audit.AuditEvent
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
      assert latest_update_audit(api_key.id).details["changed_fields"] == ["display_name"]
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

  describe "stored labels and per-model limit sets" do
    test "an edit of an unrelated field keeps every label and every model override", %{conn: conn, scope: scope} do
      pool = pool!(scope, "round-trip")
      api_key = labelled_key!(scope, pool)
      before = stored_snapshot(api_key.id)
      assert length(before.model_bindings) == 3

      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
      view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      view |> element("#api-key-tab-limits") |> render_click()

      assert has_element?(view, "#api_key_model_policy_model_identifier[value='gpt-alpha']")
      assert has_element?(view, "#api-key-retained-model-limits", "gpt-beta")
      assert has_element?(view, "#api-key-retained-model-limits", "gpt-gamma")
      refute has_element?(view, "#api-key-retained-model-limits", "gpt-alpha")

      # Only the fields the form renders come from the client; the carried
      # labels and model overrides cannot be replaced through the submission.
      view
      |> element("#api-key-form")
      |> render_submit(%{"api_key" => %{"display_name" => "Renamed labelled key", "stored_metadata" => %{"labels" => []}, "retained_model_policies" => ""}})

      assert Repo.get!(APIKey, api_key.id).display_name == "Renamed labelled key"
      assert stored_snapshot(api_key.id) == before
      assert latest_update_audit(api_key.id).details["changed_fields"] == ["display_name"]
    end

    test "an edit of the shown model override changes only that override", %{conn: conn, scope: scope} do
      pool = pool!(scope, "round-trip-edit")
      api_key = labelled_key!(scope, pool)
      before = stored_snapshot(api_key.id)

      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
      view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      view |> element("#api-key-form") |> render_submit(%{"api_key" => %{"model_max_requests_per_minute" => "7"}})

      expected =
        Enum.map(before.model_bindings, fn
          %{model_identifier: "gpt-alpha"} = binding -> %{binding | max_requests_per_minute: 7}
          binding -> binding
        end)

      assert stored_snapshot(api_key.id) == %{before | model_bindings: expected}

      view |> element("#edit-api-key-#{api_key.id}") |> render_click()

      view
      |> element("#api-key-form")
      |> render_submit(%{"api_key" => %{"model_policy_model_identifier" => "", "model_max_requests_per_minute" => ""}})

      assert stored_snapshot(api_key.id).model_bindings == Enum.reject(expected, &(&1.model_identifier == "gpt-alpha"))
      assert stored_snapshot(api_key.id).metadata == before.metadata
    end

    test "the shown override cannot take a model another override already limits", %{conn: conn, scope: scope} do
      pool = pool!(scope, "round-trip-duplicate")
      api_key = labelled_key!(scope, pool)
      before = stored_snapshot(api_key.id)

      {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
      view |> element("#edit-api-key-#{api_key.id}") |> render_click()
      view |> element("#api-key-form") |> render_submit(%{"api_key" => %{"model_policy_model_identifier" => "GPT-Beta"}})

      assert has_element?(view, "#api-key-review-errors", "gpt-beta already has its own model override")
      assert stored_snapshot(api_key.id) == before
    end
  end

  defp labelled_key!(scope, pool) do
    assert {:ok, %{api_key: api_key}} =
             Access.create_api_key(scope, pool, %{
               display_name: "Labelled key",
               metadata: %{"labels" => ["team-a", "batch-7"], "operator_notes" => "kept note"},
               default_policy: %{max_requests_per_minute: 30},
               model_policies: [
                 %{model_identifier: "gpt-gamma", max_tokens_per_week: 1_000},
                 %{model_identifier: "gpt-alpha", max_requests_per_minute: 5},
                 %{model_identifier: "gpt-beta", max_tokens_per_day: 100}
               ]
             })

    api_key
  end

  defp stored_snapshot(api_key_id) do
    api_key = Repo.get!(APIKey, api_key_id)
    bindings = Repo.all(from binding in APIKeyPolicyBinding, where: binding.api_key_id == ^api_key_id)

    %{
      metadata: api_key.metadata,
      default_bindings: bindings |> Enum.filter(&(&1.binding_scope == "default")) |> Enum.map(&binding_values/1),
      model_bindings: bindings |> Enum.filter(&(&1.binding_scope == "model")) |> Enum.map(&binding_values/1) |> Enum.sort_by(& &1.model_identifier)
    }
  end

  defp binding_values(binding) do
    Map.take(binding, [
      :model_identifier,
      :status,
      :max_requests_per_minute,
      :max_tokens_per_day,
      :max_tokens_per_week,
      :max_input_tokens_per_request,
      :max_output_tokens_per_request
    ])
  end

  defp latest_update_audit(api_key_id) do
    Repo.one(
      from event in AuditEvent,
        where: event.target_id == ^api_key_id and event.action == "api_key.update",
        order_by: [desc: event.occurred_at],
        limit: 1
    )
  end

  defp pool!(scope, prefix) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "#{prefix}-#{System.unique_integer([:positive])}", name: "Round trip #{prefix}"})
    pool
  end
end
