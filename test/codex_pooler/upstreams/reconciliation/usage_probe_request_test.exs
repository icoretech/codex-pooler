defmodule CodexPooler.Upstreams.Reconciliation.UsageProbeRequestTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.UpstreamConnPoolTelemetry
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe

  @account_id "acct_usage_header_contract"

  test "usage GETs match current Codex and omit an explicit JSON Accept header" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 1,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600,
          "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 3_600, :second))
        }
      }
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {404, %{}},
           "/backend-api/codex/usage" => {200, payload}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment, access_token: access_token} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/codex/usage"}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    requests = FakeUpstream.requests(fake)

    assert Enum.map(requests, & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/codex/usage"
           ]

    Enum.each(requests, fn request ->
      headers = Map.new(request.headers)

      assert headers["authorization"] == "Bearer #{access_token}"
      assert headers["chatgpt-account-id"] == @account_id
      refute Map.has_key?(headers, "accept")
    end)
  end

  test "usage and reset-credit GETs carry the upstream connection idle bound from settings" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false},
      "rate_limit_reset_credits" => %{"available_count" => 1}
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/codex/usage" => {200, payload},
           "/backend-api/wham/rate-limit-reset-credits" => {200, %{"items" => []}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    UpstreamConnPoolTelemetry.put_idle_bound!(0)
    UpstreamConnPoolTelemetry.attach!(FakeUpstream.url(fake))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, %UsageProbe.Result{}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    paths = fake |> FakeUpstream.requests() |> Enum.map(& &1.path)
    assert "/backend-api/wham/rate-limit-reset-credits" in paths
    assert length(paths) >= 2

    assert UpstreamConnPoolTelemetry.drain_events() ==
             List.duplicate(:conn_max_idle_time_exceeded, length(paths) - 1)
  end
end
