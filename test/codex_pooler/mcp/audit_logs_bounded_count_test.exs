defmodule CodexPooler.MCP.AuditLogsBoundedCountTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Audit
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.MCP.Tools.LogMetadata

  # The list tool and the admin page counted every matching audit event for
  # their `total`, and `audit_events` has no retention, so an unfiltered listing
  # read the whole audit history on every call (findings#206 row 206-414). Both
  # now count at most 10,000 events past the offset, like the request-log tool,
  # and the tool says with `totalExact` whether `total` is exact or a lower bound.
  @count_window 10_000

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(Audit.AuditEvent)
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()
    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    user = user |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    settings = InstanceSettings.ensure_singleton!()
    assert {:ok, _updated} = InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})
    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)
    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Bounded audit count MCP"})
    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, pool: pool_fixture(%{slug: "mcp-audit-bounded", name: "MCP audit bounded"})}
  end

  test "an exact total below the window says so", %{auth: auth, pool: pool} do
    insert_events!(pool.id, 3)

    structured = list!(auth, %{"pool_id" => pool.id, "limit" => 2})

    assert %{"total" => 3, "totalExact" => true, "limit" => 2, "offset" => 0, "nextOffset" => 2} = Map.delete(structured, "items")
  end

  test "more events than the window are reported as a lower bound, and exactly once the window reaches past them", %{auth: auth, pool: pool} do
    insert_events!(pool.id, @count_window + 2)

    {:ok, result} = ToolDispatch.call("codex_pooler_list_audit_logs", %{"pool_id" => pool.id, "limit" => 5}, %{auth: auth})
    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    structured = result["structuredContent"]

    assert %{"total" => @count_window, "totalExact" => false, "offset" => 0, "nextOffset" => 5} = structured
    assert length(structured["items"]) == 5
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "total more than #{@count_window};"

    near_end = list!(auth, %{"pool_id" => pool.id, "limit" => 5, "offset" => @count_window - 1})
    assert %{"total" => 10_002, "totalExact" => true, "nextOffset" => nil} = near_end
  end

  test "every count the list tool issues stops at the window past its offset", %{auth: auth, pool: pool} do
    insert_events!(pool.id, 1)
    insert_events!(nil, 1)

    for arguments <- [%{"offset" => 7}, %{"pool_id" => pool.id, "offset" => 7}] do
      counts = capture_count_queries(fn -> list!(auth, arguments) end)
      assert counts != []

      for {sql, params} <- counts do
        assert sql =~ ~r/LIMIT \$\d+/, "unbounded audit-event count: #{sql}"
        assert (7 + @count_window + 1) in params
      end
    end
  end

  test "the output schema requires totalExact" do
    tool = Enum.find(LogMetadata.tools(), &(&1.name == "codex_pooler_list_audit_logs"))
    assert "totalExact" in tool.output_schema["required"]
    assert tool.output_schema["properties"]["totalExact"] == %{"type" => "boolean"}
  end

  test "a reader that passes no count limit keeps the exact total", %{pool: pool} do
    insert_events!(pool.id, 4)

    assert %{total: 4, total_exact?: true} = Audit.list_events(pool, limit: 1)
    assert %{total: 3, total_exact?: false} = Audit.list_events(pool, limit: 1, count_limit: 3)
    assert %{total: 4, total_exact?: true} = Audit.list_events(pool, limit: 1, count_limit: 4)
  end

  defp list!(auth, arguments) do
    assert {:ok, %{"isError" => false, "structuredContent" => structured}} = ToolDispatch.call("codex_pooler_list_audit_logs", arguments, %{auth: auth})
    structured
  end

  # One insert writes `count` system events, so the window can be crossed
  # without recording ten thousand events one by one.
  defp insert_events!(pool_id, count) do
    Repo.query!(
      """
      INSERT INTO audit_events (id, occurred_at, actor_type, pool_id, action, target_type, outcome, details)
      SELECT gen_random_uuid(), now() - make_interval(secs => g), 'system', $1::uuid, 'pool.update', 'pool', 'success', '{}'::jsonb
        FROM generate_series(1, $2::integer) g
      """,
      [pool_id && Ecto.UUID.dump!(pool_id), count]
    )
  end

  defp capture_count_queries(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid and metadata.query =~ "count(" and metadata.query =~ ~s("audit_events"),
            do: send(pid, {:count_query, metadata.query, metadata.params})
        end,
        test_pid
      )

    fun.()
    :telemetry.detach(handler_id)
    collect_count_queries([])
  end

  defp collect_count_queries(acc) do
    receive do
      {:count_query, sql, params} -> collect_count_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
