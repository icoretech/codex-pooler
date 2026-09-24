defmodule CodexPooler.Access.APIKeyPartialPolicyUpdateTest do
  @moduledoc """
  A policy update changes only the policy fields its caller submits
  (findings#206 row 206-497). An omitted field keeps the stored value; a
  submitted value, `nil` included, replaces it. The allow list
  (`model_mode`/`allowed_model_identifiers`) and the reasoning pair
  (`enforced_reasoning_effort`/`maximum_reasoning_effort`) each change as one
  unit, `default_policy` and `model_policies` each replace their bindings, and
  the merged result is validated as a whole. The operator form submits every
  field, so its edits keep their meaning; the Pool wizard submits only the
  target Pool, so a move can no longer write back a policy it read before its
  lock.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget_ms 15_000

  @restricted_policy %{
    model_mode: "selected_models",
    allowed_model_identifiers: ["gpt-alpha", "gpt-beta"],
    enforced_model_identifier: "gpt-alpha",
    maximum_reasoning_effort: "high",
    enforced_service_tier: "flex",
    default_policy: %{max_requests_per_minute: 30, max_tokens_per_day: 5_000},
    model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_week: 9_000}],
    # The operator form submits this metadata shape on every edit (a key with
    # no note would get the form's "No notes" placeholder saved as its note).
    metadata: %{"labels" => [], "operator_notes" => "Partial policy fixture"}
  }

  describe "a partial caller" do
    test "keeps every policy field it omits" do
      {scope, pool} = owner_scope_and_pool()
      other_pool = pool!(scope, "partial-target")
      expires_at = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

      for {label, attrs, changed} <- [
            {"pause", %{status: "paused"}, ["status"]},
            {"rename", %{display_name: "Renamed key"}, ["display_name"]},
            {"active cap", %{max_active_requests: 3}, ["max_active_requests"]},
            {"string-keyed dashboard", %{"dashboard_access" => false}, []},
            {"expiry", %{expires_at: expires_at}, ["expires_at"]},
            {"move", %{pool_id: other_pool.id}, ["pool_id"]}
          ] do
        api_key = restricted_key!(scope, pool, label)
        before = policy_snapshot(api_key.id)

        assert {:ok, _result} = Access.update_api_key_with_policy(scope, api_key, attrs), label
        assert {label, policy_snapshot(api_key.id)} == {label, before}

        audit = latest_update_audit(api_key.id)
        assert {label, audit.details["changed_fields"]} == {label, changed}
        assert audit.details["submitted_fields"] == attrs |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(), label
      end
    end

    test "changes one policy group and keeps the others, with nil as the explicit clear" do
      {scope, pool} = owner_scope_and_pool()

      for {label, attrs, expected_change, changed} <- [
            {"all models", %{model_mode: "all_models"}, %{allowed_model_identifiers: nil}, ["allowed_model_identifiers"]},
            {"narrowed models", %{model_mode: "selected_models", allowed_model_identifiers: ["GPT-Alpha"]}, %{allowed_model_identifiers: ["gpt-alpha"]}, ["allowed_model_identifiers"]},
            {"no enforced model", %{enforced_model_identifier: nil}, %{enforced_model_identifier: nil}, ["enforced_model_identifier"]},
            {"unrestricted reasoning", %{enforced_reasoning_effort: nil, maximum_reasoning_effort: nil}, %{maximum_reasoning_effort: nil}, ["maximum_reasoning_effort"]},
            {"exact reasoning replaces the ceiling", %{enforced_reasoning_effort: "low"}, %{enforced_reasoning_effort: "low", maximum_reasoning_effort: nil}, ["enforced_reasoning_effort", "maximum_reasoning_effort"]},
            {"no service tier", %{enforced_service_tier: nil}, %{enforced_service_tier: nil}, ["enforced_service_tier"]},
            {"no default limits", %{default_policy: %{}}, %{default_binding: default_binding(%{})}, ["default_policy"]},
            {"no model bindings", %{model_policies: []}, %{model_bindings: []}, ["model_policies"]}
          ] do
        api_key = restricted_key!(scope, pool, label)
        before = policy_snapshot(api_key.id)

        assert {:ok, _result} = Access.update_api_key_with_policy(scope, api_key, attrs), label
        assert {label, policy_snapshot(api_key.id)} == {label, Map.merge(before, expected_change)}
        assert {label, latest_update_audit(api_key.id).details["changed_fields"]} == {label, changed}
      end
    end

    test "validates the merged policy, so narrowing past the stored enforced model is refused" do
      {scope, pool} = owner_scope_and_pool()
      api_key = restricted_key!(scope, pool, "narrow past enforced")
      before = policy_snapshot(api_key.id)

      assert {:error, %{code: :invalid_policy, message: message}} =
               Access.update_api_key_with_policy(scope, api_key, %{
                 model_mode: "selected_models",
                 allowed_model_identifiers: ["gpt-beta"]
               })

      assert message =~ "enforced model"

      assert {:error, %{code: :invalid_policy, message: both_message}} =
               Access.update_api_key_with_policy(scope, api_key, %{enforced_reasoning_effort: "low", maximum_reasoning_effort: "high"})

      assert both_message =~ "cannot both"
      assert policy_snapshot(api_key.id) == before
      refute latest_update_audit(api_key.id)
    end
  end

  describe "the operator form" do
    test "submits the whole policy, so an unchanged submission changes nothing and its edits keep their meaning" do
      {scope, pool} = owner_scope_and_pool()

      for {label, overrides, expected_change, changed} <- [
            {"unchanged", %{}, %{}, []},
            {"all models", %{"model_mode" => "all_models"}, %{allowed_model_identifiers: nil}, ["allowed_model_identifiers"]},
            {"unrestricted reasoning", %{"reasoning_policy_mode" => "unrestricted"}, %{maximum_reasoning_effort: nil}, ["maximum_reasoning_effort"]},
            {"no enforced model", %{"enforced_model_identifier" => ""}, %{enforced_model_identifier: nil}, ["enforced_model_identifier"]},
            {"no default limits", %{"default_max_requests_per_minute" => "", "default_max_tokens_per_day" => ""}, %{default_binding: default_binding(%{})}, ["default_policy"]}
          ] do
        api_key = restricted_key!(scope, pool, label)
        before = policy_snapshot(api_key.id)

        assert {:ok, %{api_key: api_key, policy_bindings: bindings}} = Access.get_api_key_with_policy(scope, api_key.id)

        form_attrs =
          api_key
          |> ApiKeyPolicyForm.params_for(bindings)
          |> Map.merge(overrides)
          |> ApiKeyPolicyForm.attrs()

        assert {:ok, _result} = Access.update_api_key_with_policy(scope, api_key.id, form_attrs), label
        assert {label, policy_snapshot(api_key.id)} == {label, Map.merge(before, expected_change)}

        audit = latest_update_audit(api_key.id)
        assert {label, audit.details["changed_fields"]} == {label, changed}
        assert "default_policy" in audit.details["submitted_fields"], label
        assert "model_mode" in audit.details["submitted_fields"], label
      end
    end
  end

  # `Access.update_api_key/3` edits the key row and never its bindings. A
  # policy field it receives goes through the same merge and validation as
  # the policy path, so the allow list is lowercased and cannot drop the
  # stored enforced model (findings#206 row 206-505), and binding limits are
  # refused rather than silently ignored.
  describe "the key-row update path" do
    test "normalizes a submitted allow list and keeps the policy fields it omits" do
      {scope, pool} = owner_scope_and_pool()
      api_key = restricted_key!(scope, pool, "key row allow list")
      before = policy_snapshot(api_key.id)

      assert {:ok, updated} =
               Access.update_api_key(scope, api_key, %{allowed_model_identifiers: [" GPT-Alpha ", "GPT-Gamma", "gpt-alpha"]})

      assert updated.allowed_model_identifiers == ["gpt-alpha", "gpt-gamma"]
      assert policy_snapshot(api_key.id) == %{before | allowed_model_identifiers: ["gpt-alpha", "gpt-gamma"]}
      assert latest_update_audit(api_key.id).details["changed_fields"] == ["allowed_model_identifiers"]

      assert {:ok, widened} = Access.update_api_key(scope, api_key, %{model_mode: "all_models", enforced_model_identifier: " GPT-Beta "})
      assert widened.allowed_model_identifiers == nil
      assert widened.enforced_model_identifier == "gpt-beta"
      assert policy_snapshot(api_key.id).model_bindings == before.model_bindings
    end

    test "refuses binding limits instead of ignoring them" do
      {scope, pool} = owner_scope_and_pool()
      api_key = restricted_key!(scope, pool, "key row bindings")
      before = policy_snapshot(api_key.id)

      for attrs <- [
            %{default_policy: %{max_tokens_per_day: 1}},
            %{"model_policies" => [%{"model_identifier" => "gpt-alpha", "max_requests_per_minute" => 1}]},
            %{status: "paused", model_policies: []}
          ] do
        assert {:error, %{code: :unsupported_field, message: message}} = Access.update_api_key(scope, api_key, attrs)
        assert message =~ "update_api_key_with_policy"
      end

      assert policy_snapshot(api_key.id) == before
      assert Repo.get!(APIKey, api_key.id).status == "active"
      refute latest_update_audit(api_key.id)
    end

    test "refuses an allow list that drops the stored enforced model" do
      {scope, pool} = owner_scope_and_pool()
      api_key = restricted_key!(scope, pool, "key row narrow")
      before = policy_snapshot(api_key.id)

      assert {:error, %{code: :invalid_policy, message: message}} =
               Access.update_api_key(scope, api_key, %{status: "paused", allowed_model_identifiers: ["gpt-beta"]})

      assert message =~ "enforced model"
      assert policy_snapshot(api_key.id) == before
      assert Repo.get!(APIKey, api_key.id).status == "active"
      refute latest_update_audit(api_key.id)
    end
  end

  describe "the Pool wizard" do
    test "moves a key without rewriting its policy and audits only the Pool change" do
      {scope, pool} = owner_scope_and_pool()
      target_pool = pool!(scope, "wizard-target")
      api_key = restricted_key!(scope, pool, "wizard move")
      before = policy_snapshot(api_key.id)

      assert :ok = Access.assign_api_keys_to_pool(scope, target_pool, [api_key.id])

      assert Repo.get!(APIKey, api_key.id).pool_id == target_pool.id
      assert policy_snapshot(api_key.id) == before

      audit = latest_update_audit(api_key.id)
      assert audit.details["changed_fields"] == ["pool_id"]
      assert audit.details["submitted_fields"] == ["pool_id"]
    end

    test "does not write back a policy it read before a concurrent narrowing committed" do
      %{user: owner} = committed_bootstrap_owner_fixture!()
      scope = Scope.for_user(owner, ["instance_owner"])

      {source_pool, target_pool, api_key} =
        run_unboxed(fn ->
          source_pool = pool!(scope, "race-source")
          target_pool = pool!(scope, "race-target")
          {:ok, %{api_key: api_key}} = Access.create_api_key(scope, source_pool, %{display_name: "Race key"})
          {source_pool, target_pool, api_key}
        end)

      parent = self()
      editor_ref = make_ref()
      wizard_ref = make_ref()

      # The operator's narrowing holds the key's writer lock, uncommitted,
      # while the wizard reads the key and then waits for that lock.
      editor =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              {:ok, _result} =
                Access.update_api_key_with_policy(scope, api_key.id, %{
                  model_mode: "selected_models",
                  allowed_model_identifiers: ["gpt-alpha"]
                })

              send(parent, {:narrowed_uncommitted, editor_ref, backend_pid!()})

              receive do
                {:commit, ^editor_ref} -> :committed
              after
                @detection_budget_ms -> Repo.rollback(:not_released)
              end
            end)
          end)
        end)

      assert_receive {:narrowed_uncommitted, ^editor_ref, editor_backend}, @detection_budget_ms

      wizard =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:wizard_started, wizard_ref, backend_pid!()})
            Access.assign_api_keys_to_pool(scope, target_pool, [api_key.id])
          end)
        end)

      assert_receive {:wizard_started, ^wizard_ref, wizard_backend}, @detection_budget_ms
      assert await_waiting_on!(wizard_backend, editor_backend) == "api_keys"

      send(editor.pid, {:commit, editor_ref})
      assert {:ok, :committed} = Task.await(editor, @detection_budget_ms)
      assert :ok = Task.await(wizard, @detection_budget_ms)

      committed = run_unboxed(fn -> Repo.get!(APIKey, api_key.id) end)
      assert committed.pool_id == target_pool.id
      refute committed.pool_id == source_pool.id
      assert committed.allowed_model_identifiers == ["gpt-alpha"]
    end
  end

  defp restricted_key!(scope, pool, label) do
    assert {:ok, %{api_key: api_key}} =
             Access.create_api_key(scope, pool, Map.put(@restricted_policy, :display_name, "Partial #{label}"))

    api_key
  end

  defp policy_snapshot(api_key_id) do
    api_key = Repo.get!(APIKey, api_key_id)

    bindings =
      Repo.all(from binding in APIKeyPolicyBinding, where: binding.api_key_id == ^api_key_id)

    %{
      allowed_model_identifiers: api_key.allowed_model_identifiers && Enum.sort(api_key.allowed_model_identifiers),
      enforced_model_identifier: api_key.enforced_model_identifier,
      enforced_reasoning_effort: api_key.enforced_reasoning_effort,
      maximum_reasoning_effort: api_key.maximum_reasoning_effort,
      enforced_service_tier: api_key.enforced_service_tier,
      default_binding: bindings |> Enum.filter(&(&1.binding_scope == "default")) |> Enum.map(&binding_values/1),
      model_bindings: bindings |> Enum.filter(&(&1.binding_scope == "model")) |> Enum.map(&binding_values/1) |> Enum.sort()
    }
  end

  defp binding_values(%APIKeyPolicyBinding{} = binding) do
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

  defp default_binding(limits) do
    [
      Map.merge(
        %{
          model_identifier: nil,
          status: "active",
          max_requests_per_minute: nil,
          max_tokens_per_day: nil,
          max_tokens_per_week: nil,
          max_input_tokens_per_request: nil,
          max_output_tokens_per_request: nil
        },
        limits
      )
    ]
  end

  defp latest_update_audit(api_key_id) do
    Repo.one(
      from event in AuditEvent,
        where: event.target_id == ^api_key_id and event.action == "api_key.update",
        order_by: [desc: event.occurred_at],
        limit: 1
    )
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    {scope, pool!(scope, "partial-policy")}
  end

  defp pool!(scope, prefix) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "#{prefix}-#{System.unique_integer([:positive])}", name: "Partial policy #{prefix}"})
    pool
  end

  defp await_waiting_on!(waiter, blocker) do
    await_waiting_on!(waiter, blocker, System.monotonic_time(:millisecond) + @detection_budget_ms)
  end

  # `query` is read from the sampling transaction's snapshot while the wait is
  # live, so a sample naming no relation is taken again (test/AGENTS.md).
  defp await_waiting_on!(waiter, blocker, deadline) do
    rows =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          """
          SELECT query FROM pg_stat_activity
          WHERE pid = $1 AND wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids(pid))
          """,
          [waiter, blocker]
        ).rows
      end)

    relation =
      case rows do
        [[query]] -> with [_match, relation] <- Regex.run(~r/FROM "(\w+)"/, query), do: relation
        [] -> nil
      end

    cond do
      is_binary(relation) -> relation
      System.monotonic_time(:millisecond) >= deadline -> flunk("backend #{waiter} was not observed waiting on backend #{blocker}")
      true -> await_waiting_on!(waiter, blocker, deadline)
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp run_unboxed(fun), do: CodexPooler.UnboxedFixture.run_unboxed(fun)
end
