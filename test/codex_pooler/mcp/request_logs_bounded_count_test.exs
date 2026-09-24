defmodule CodexPooler.MCP.RequestLogsBoundedCountTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.MCP.Tools.LogMetadata

  # The list tool counted every matching request log for its `total`: an
  # unfiltered listing read the whole request history on every call, the same
  # read the admin page stopped paying in 206-385 (findings#206 row 206-411).
  # The tool now counts at most 10,000 rows past its offset, like the page, and
  # says with `totalExact` whether `total` is the exact count or a lower bound.
  @count_window 10_000

  setup do
    reset_bootstrap_state_fixture!()
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
    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Bounded count MCP"})
    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{auth: auth, pool: pool, api_key: api_key}
  end

  test "an exact total below the window says so", %{auth: auth, pool: pool, api_key: api_key} do
    for _index <- 1..3, do: request_fixture(%{pool: pool, api_key: api_key})

    structured = list!(auth, %{"pool_id" => pool.id, "limit" => 2})

    assert %{"total" => 3, "totalExact" => true, "limit" => 2, "offset" => 0, "nextOffset" => 2} = Map.delete(structured, "items")
  end

  test "more rows than the window are reported as a lower bound, and exactly once the window reaches past them", %{auth: auth, pool: pool, api_key: api_key} do
    request = request_fixture(%{pool: pool, api_key: api_key})
    copy_request!(request, @count_window + 1)

    {:ok, result} = ToolDispatch.call("codex_pooler_list_request_logs", %{"pool_id" => pool.id, "limit" => 5}, %{auth: auth})
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

  test "every count the list tool issues stops at the window past its offset", %{auth: auth, pool: pool, api_key: api_key} do
    request_fixture(%{pool: pool, api_key: api_key})

    for arguments <- [%{"offset" => 7}, %{"pool_id" => pool.id, "offset" => 7}] do
      counts = capture_count_queries(fn -> list!(auth, arguments) end)
      assert counts != []

      for {sql, params} <- counts do
        assert sql =~ ~r/LIMIT \$\d+/, "unbounded request-log count: #{sql}"
        assert (7 + @count_window + 1) in params
      end
    end
  end

  test "the output schema requires totalExact" do
    tool = Enum.find(LogMetadata.tools(), &(&1.name == "codex_pooler_list_request_logs"))
    assert "totalExact" in tool.output_schema["required"]
    assert tool.output_schema["properties"]["totalExact"] == %{"type" => "boolean"}
  end

  defp list!(auth, arguments) do
    assert {:ok, %{"isError" => false, "structuredContent" => structured}} = ToolDispatch.call("codex_pooler_list_request_logs", arguments, %{auth: auth})
    structured
  end

  # One insert copies the fixture row `count` times with fresh ids, so the
  # window can be crossed without building ten thousand fixtures one by one.
  defp copy_request!(request, count) do
    Repo.query!(
      """
      INSERT INTO requests (id, pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id,
                            request_metadata, admitted_at, completed_at, response_status_code, retry_count)
      SELECT gen_random_uuid(), r.pool_id, r.api_key_id, r.requested_model, r.endpoint, r.transport, r.status, r.usage_status,
             r.correlation_id || '-' || g, r.request_metadata, r.admitted_at, r.completed_at, r.response_status_code, r.retry_count
        FROM requests r, generate_series(1, $2::integer) g
       WHERE r.id = $1
      """,
      [Ecto.UUID.dump!(request.id), count]
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
          if self() == pid and metadata.query =~ "count(" and metadata.query =~ ~s("requests"),
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
