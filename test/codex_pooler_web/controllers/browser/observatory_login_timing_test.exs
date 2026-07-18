defmodule CodexPoolerWeb.Browser.ObservatoryLoginTimingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.ObservatoryControllerTestHelpers
  import Ecto.Query

  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Access.APIKeys.{Material, TouchDebounce}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @login_path "/observatory/login"
  @invalid_copy "The API key is invalid or unavailable."

  test "every failed login traverses one identical dashboard exchange lookup path" do
    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)
    expired = api_key_fixture(pool_fixture(), %{expires_at: expired_at})
    enable_dashboard_access!(expired.api_key)

    %{api_key: paused_api_key, raw_key: paused_key} = paused_api_key_fixture()
    enable_dashboard_access!(paused_api_key)

    %{api_key: revoked_api_key, raw_key: revoked_key} =
      api_key_fixture(pool_fixture(), %{status: "revoked"})

    enable_dashboard_access!(revoked_api_key)

    %{api_key: no_access_api_key, raw_key: no_access_key} = active_api_key_fixture()
    _ = no_access_api_key

    disabled_pool = pool_fixture()

    %{api_key: disabled_pool_api_key, raw_key: disabled_pool_key} =
      api_key_fixture(disabled_pool)

    enable_dashboard_access!(disabled_pool_api_key)

    disabled_pool
    |> Pool.changeset(%{status: "disabled", disabled_at: DateTime.utc_now()})
    |> Repo.update!()

    %{api_key: query_guard_api_key, raw_key: query_guard_key} = active_api_key_fixture()
    enable_dashboard_access!(query_guard_api_key)

    {_unknown_prefix, unknown_key, _unknown_hash} = Material.generate()

    cases = [
      {:missing, %{}, ""},
      {:malformed, %{"observatory" => %{"api_key" => "malformed-observatory-value"}}, ""},
      {:wrong_shape, %{"api_key" => query_guard_key}, ""},
      {:unknown, %{"observatory" => %{"api_key" => unknown_key}}, ""},
      {:expired, %{"observatory" => %{"api_key" => expired.raw_key}}, ""},
      {:paused, %{"observatory" => %{"api_key" => paused_key}}, ""},
      {:revoked, %{"observatory" => %{"api_key" => revoked_key}}, ""},
      {:no_dashboard_access, %{"observatory" => %{"api_key" => no_access_key}}, ""},
      {:disabled_pool, %{"observatory" => %{"api_key" => disabled_pool_key}}, ""},
      {:query_present, %{"observatory" => %{"api_key" => query_guard_key}}, "?probe=1"}
    ]

    results =
      Enum.map(cases, fn {label, body, query_suffix} ->
        login_conn = get(build_conn(), @login_path)

        {failed, lookups} =
          capture_dashboard_exchange_lookups(fn ->
            post(
              login_conn,
              @login_path <> query_suffix,
              Map.put(body, "_csrf_token", csrf_token_from(login_conn.resp_body))
            )
          end)

        html = failed.resp_body

        %{
          label: label,
          lookups: lookups,
          public_result:
            {failed.status, String.contains?(html, @invalid_copy), flash_error(failed),
             empty_api_key_input?(html)}
        }
      end)

    assert Enum.map(results, &{&1.label, &1.public_result}) ==
             Enum.map(cases, fn {label, _body, _query_suffix} ->
               {label, {422, true, nil, true}}
             end)

    assert Enum.map(results, &{&1.label, &1.lookups}) ==
             Enum.map(cases, fn {label, _body, _query_suffix} ->
               {label, [{"api_keys", :for_update}, {"pools", :for_share}]}
             end)

    assert :ok = TouchDebounce.flush()
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    assert Repo.aggregate(Request, :count, :id) == 0

    assert Repo.aggregate(
             from(api_key in APIKey, where: not is_nil(api_key.last_used_at)),
             :count,
             :id
           ) == 0
  end

  defp capture_dashboard_exchange_lookups(fun) do
    parent = self()
    handler_id = "observatory-login-lookups-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and metadata[:source] in ["api_keys", "pools"] do
            send(parent, {handler_id, metadata[:source], query_lock(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_dashboard_exchange_lookups(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_dashboard_exchange_lookups(handler_id, lookups) do
    receive do
      {^handler_id, source, lock} ->
        drain_dashboard_exchange_lookups(handler_id, [{source, lock} | lookups])
    after
      0 -> Enum.reverse(lookups)
    end
  end

  defp query_lock(query) when is_binary(query) do
    cond do
      String.contains?(query, "FOR UPDATE") -> :for_update
      String.contains?(query, "FOR SHARE") -> :for_share
      true -> :unlocked
    end
  end

  defp query_lock(_query), do: :unknown

  defp empty_api_key_input?(html) do
    case Regex.run(~r/<input[^>]*id="observatory-api-key"[^>]*>/, html) do
      [input] -> not String.contains?(input, "value=")
      _missing -> false
    end
  end
end
