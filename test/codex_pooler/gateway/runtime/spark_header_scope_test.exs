defmodule CodexPooler.Gateway.Runtime.SparkHeaderScopeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @endpoint_path "/backend-api/codex/responses"
  @spark "gpt-5.3-codex-spark"

  test "generic Spark response headers cannot mint account windows or overwrite ordinary weekly" do
    usage = spark_usage()

    {upstream, setup} =
      reconciled_setup(usage, exposed_model_id: @spark, upstream_model_id: @spark)

    before = account_windows(setup)
    assert length(before) == 1
    [meter] = usage["additional_rate_limits"]
    {:path_json, responses} = routes(usage)
    headers = generic_headers(meter["rate_limit"])

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       Map.put(
         responses,
         @endpoint_path,
         FakeUpstream.json_response_with_headers(
           %{"id" => "resp_scope", "object" => "response", "output" => []},
           headers
         )
       )}
    )

    {auth, payload, options} = request_context(setup)
    assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint_path, payload, options)
    assert account_windows(setup) == before
    assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint_path, payload, options)
    assert generation_count(upstream) == 2
    assert account_windows(setup) == before
    windows = Windows.list_quota_windows(setup.identity)
    spark = Enum.filter(windows, &(&1.quota_key == "codex_spark"))
    assert Enum.any?(spark, &(&1.source == "codex_response_headers"))
  end

  test "ordinary model generic headers retain their account scope" do
    usage = usage_payload(:weekly_primary)
    {upstream, setup} = reconciled_setup(usage)
    {:path_json, responses} = routes(usage)

    headers =
      generic_headers(%{
        "primary_window" => window(18_000),
        "secondary_window" => window(604_800)
      })

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       Map.put(
         responses,
         @endpoint_path,
         FakeUpstream.json_response_with_headers(
           %{"id" => "resp_scope", "object" => "response", "output" => []},
           headers
         )
       )}
    )

    assert dispatch(Phoenix.ConnTest.build_conn(), setup).status == 200
    assert Enum.any?(account_windows(setup), &(elem(&1, 0) == "primary"))
  end

  for observer <- [:record_websocket_upgrade_headers, :record_websocket_frame_headers] do
    test "#{observer} scopes generic Spark headers without changing account windows" do
      {_upstream, setup} =
        reconciled_setup(spark_usage(), exposed_model_id: @spark, upstream_model_id: @spark)

      before = account_windows(setup)

      headers =
        generic_headers(%{
          "primary_window" => window(18_000),
          "secondary_window" => window(604_800)
        })
        |> Map.new()

      assert :ok =
               apply(CodexPooler.Gateway.Runtime.RateLimitObserver, unquote(observer), [
                 setup.identity,
                 headers,
                 @spark
               ])

      assert account_windows(setup) == before
    end
  end

  defp account_windows(setup) do
    setup.identity
    |> Windows.list_quota_windows()
    |> Enum.filter(&(&1.quota_key == "account"))
    |> Enum.map(&{&1.window_kind, &1.reset_at, &1.used_percent, &1.source})
    |> Enum.sort()
  end

  defp generic_headers(limits) do
    Enum.flat_map([{"primary", 300}, {"secondary", 10_080}], fn {kind, minutes} ->
      prefix = "x-codex-#{kind}"

      [
        {"#{prefix}-used-percent", "1"},
        {"#{prefix}-window-minutes", to_string(minutes)},
        {"#{prefix}-reset-at", to_string(limits["#{kind}_window"]["reset_at"])}
      ]
    end)
  end

  defp spark_usage do
    denied_payload(:denied)
    |> Map.put("rate_limit_reached_type", %{"type" => "rate_limit_reached"})
    |> Map.put("spend_control", %{"reached" => false})
    |> Map.put("additional_rate_limits", [
      %{
        "limit_name" => "GPT-5.3-Codex-Spark",
        "metered_feature" => "codex_bengalfox",
        "rate_limit" => %{
          "allowed" => true,
          "limit_reached" => false,
          "primary_window" => Map.put(window(18_000), "used_percent", 0),
          "secondary_window" => Map.put(window(604_800), "used_percent", 0)
        }
      }
    ])
  end

  defp reconciled_setup(usage, opts \\ []) do
    upstream = start_upstream(routes(usage))
    setup = gateway_setup(upstream, Keyword.put(opts, :quota?, false))

    identity =
      setup.identity
      |> Ecto.Changeset.change(
        metadata: Map.put(setup.identity.metadata, "usage_base_url", FakeUpstream.url(upstream))
      )
      |> Repo.update!()

    assert {:ok, identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, setup.assignment)

    assert Enum.any?(FakeUpstream.requests(upstream), &String.ends_with?(&1.path, "/usage"))
    {upstream, %{setup | identity: identity}}
  end

  defp request_context(setup) do
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    assert {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    options = RequestOptions.build(%{api_key_policy: policy}, @endpoint_path, payload)
    {auth, payload, options}
  end

  defp dispatch(conn, setup) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> post(@endpoint_path, %{"model" => setup.model.exposed_model_id, "input" => []})
  end

  defp generation_count(upstream) do
    Enum.count(FakeUpstream.requests(upstream), &(&1.method == "POST"))
  end

  defp routes(usage) do
    {:path_json,
     %{
       "/api/codex/usage" => {200, usage},
       "/backend-api/codex/usage" => {200, usage},
       "/wham/usage" => {200, usage},
       "/backend-api/wham/usage" => {200, usage},
       @endpoint_path =>
         {200, %{"id" => "resp_permission_fixture", "object" => "response", "output" => []}}
     }}
  end

  defp usage_payload(shape) do
    rate_limit = %{
      "allowed" => true,
      "limit_reached" => false,
      "primary_window" => window(if(shape == :weekly_primary, do: 604_800, else: 18_000)),
      "secondary_window" => if(shape == :weekly_primary, do: nil, else: window(604_800))
    }

    %{
      "plan_type" => "plus",
      "rate_limit" => rate_limit,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }
  end

  defp denied_payload(:denied) do
    usage_payload(:weekly_primary)
    |> put_in(["rate_limit", "allowed"], false)
    |> put_in(["rate_limit", "limit_reached"], true)
  end

  defp window(seconds) do
    %{
      "used_percent" => 100,
      "limit_window_seconds" => seconds,
      "reset_after_seconds" => seconds,
      "reset_at" => DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_unix()
    }
  end
end
