defmodule CodexPoolerWeb.Runtime.CodexUsageMeteredIdentityTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence}
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe

  import CodexPooler.PoolerFixtures

  test "meter identity survives probe, reconciliation, persistence, and public usage", %{
    conn: conn
  } do
    configure_upstream_secret_key!()

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    payload = metered_usage_payload(observed_at)

    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, payload}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()
    api_key = active_api_key_fixture(pool)
    account_id = "metered-identity-#{System.unique_integer([:positive])}"

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        metadata: %{
          "base_url" => FakeUpstream.url(upstream),
          "usage_path" => "/api/codex/usage"
        }
      })

    seed_legacy_and_stale_siblings!(identity, observed_at)

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    probe_additional = Enum.reject(probe.windows, &(&1.quota_key == "account"))
    covered_additional = Enum.reject(probe.covered_descriptors, &(elem(&1, 4) == "account"))

    assert length(probe_additional) == 2
    assert MapSet.size(MapSet.new(probe_additional, &AdditionalMeterIdentity.token/1)) == 2
    assert MapSet.size(MapSet.new(covered_additional)) == 2

    assert {:ok, %{status: :succeeded}} =
             Upstreams.reconcile_pool_account(pool, assignment)

    raw_additional =
      identity
      |> QuotaWindows.list_evidence()
      |> Enum.reject(&(&1.quota_key == "account"))

    raw_usage_rows = Enum.filter(raw_additional, &(&1.source == "codex_usage_api"))
    assert length(raw_usage_rows) == 2

    assert MapSet.new(raw_usage_rows, &AdditionalMeterIdentity.token/1) ==
             MapSet.new(["meter_alpha", "meter_beta"])

    assert Enum.any?(raw_additional, fn window ->
             window.source == "local_reconciliation" and
               is_nil(AdditionalMeterIdentity.token(window))
           end)

    assert Enum.any?(raw_additional, fn window ->
             window.source == "codex_response_headers" and
               AdditionalMeterIdentity.token(window) == "meter_alpha"
           end)

    effective_at = DateTime.utc_now()

    effective_additional =
      identity
      |> QuotaWindows.list_quota_windows(effective_at)
      |> Enum.reject(&(&1.quota_key == "account"))

    assert length(effective_additional) == 2

    assert MapSet.new(effective_additional, &AdditionalMeterIdentity.token/1) ==
             MapSet.new(["meter_alpha", "meter_beta"])

    conn =
      conn
      |> put_req_header("authorization", api_key.authorization)
      |> get("/api/codex/usage")

    response = json_response(conn, 200)
    public_additional = response["additional_rate_limits"]

    assert length(public_additional) == 2

    assert Enum.map(public_additional, & &1["quota_key"]) ==
             List.duplicate("shared_weekly_limit", 2)

    assert Enum.map(public_additional, & &1["metered_feature"]) == [
             "meter_alpha",
             "meter_beta"
           ]

    assert Enum.map(
             public_additional,
             &get_in(&1, ["rate_limit", "secondary_window", "used_percent"])
           ) == [83, 71]

    maybe_write_evidence!(%{
      "http_status" => conn.status,
      "parser_probe_count" => length(probe_additional),
      "descriptor_count" => MapSet.size(MapSet.new(covered_additional)),
      "raw_usage_row_count" => length(raw_usage_rows),
      "effective_meter_group_count" => length(effective_additional),
      "public_entry_count" => length(public_additional),
      "legacy_generic_present" => true,
      "stale_sibling_folded" => true,
      "public_entries" =>
        Enum.map(public_additional, fn entry ->
          %{
            "quota_key" => entry["quota_key"],
            "metered_feature" => entry["metered_feature"],
            "used_percent" => get_in(entry, ["rate_limit", "secondary_window", "used_percent"])
          }
        end),
      "sanitized" => true
    })
  end

  defp metered_usage_payload(observed_at) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => observed_at |> DateTime.add(18_000, :second) |> DateTime.to_unix()
        }
      },
      "additional_rate_limits" => [
        additional_limit("meter_alpha", 31, observed_at),
        additional_limit("meter_alpha", 83, observed_at),
        additional_limit("meter_beta", 71, observed_at)
      ]
    }
  end

  defp additional_limit(meter, used_percent, observed_at) do
    %{
      "limit_name" => "Shared weekly limit",
      "metered_feature" => meter,
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => used_percent,
          "limit_window_seconds" => 604_800,
          "reset_at" => observed_at |> DateTime.add(604_800, :second) |> DateTime.to_unix()
        }
      }
    }
  end

  defp seed_legacy_and_stale_siblings!(identity, observed_at) do
    base = %{
      quota_key: "shared_weekly_limit",
      window_kind: "secondary",
      window_minutes: 10_080,
      display_label: "Shared weekly limit",
      limit_name: "Shared weekly limit",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "Shared weekly limit",
      reset_at: DateTime.add(observed_at, 604_800, :second),
      freshness_state: "fresh"
    }

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               Map.merge(base, %{
                 used_percent: Decimal.new("99"),
                 source: "local_reconciliation",
                 source_precision: "inferred",
                 observed_at: observed_at
               }),
               Map.merge(base, %{
                 used_percent: Decimal.new("100"),
                 metered_feature: "meter_alpha",
                 raw_limit_id: "meter_alpha",
                 raw_limit_name: "Shared weekly limit",
                 raw_metered_feature: "meter_alpha",
                 source: "codex_response_headers",
                 source_precision: "observed",
                 observed_at:
                   DateTime.add(observed_at, -Evidence.freshness_ttl_seconds() - 1, :second)
               })
             ])
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "metered-identity-test-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end

  defp maybe_write_evidence!(evidence) do
    case System.get_env("CODEX_POOLER_METERED_IDENTITY_EVIDENCE_PATH") do
      path when is_binary(path) and path != "" ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, Jason.encode!(evidence, pretty: true))

      _other ->
        :ok
    end
  end
end
