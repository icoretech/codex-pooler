defmodule CodexPooler.Metrics.AccountPrometheusTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Metrics.AccountPrometheus

  test "fixed gauge declarations, exact escaping and unique deterministic sample keys" do
    samples = [{:account_info, [account_id: "synthetic\\quote\"\nline", provider: "unknown"], 1}]
    body = AccountPrometheus.render({:ok, projection(samples)}, 0.25)
    assert body =~ ~S(account_id="synthetic\\quote\"\nline")
    assert Enum.count(String.split(body, "\n"), &String.starts_with?(&1, "# TYPE ")) == 36

    assert Enum.all?(
             String.split(body, "\n") |> Enum.filter(&String.starts_with?(&1, "# TYPE ")),
             &String.ends_with?(&1, " gauge")
           )

    assert body == AccountPrometheus.render({:ok, projection(Enum.reverse(samples))}, 0.25)

    assert_raise RuntimeError, "duplicate account metric identity", fn ->
      AccountPrometheus.render({:ok, projection(samples ++ samples)}, 0.25)
    end
  end

  test "read failure emits only real health values without fabricated counts or snapshot time" do
    body = AccountPrometheus.render({:error, "private-error"}, 0.5)
    lines = String.split(body, "\n") |> Enum.filter(&String.starts_with?(&1, "codex_pooler_"))
    assert length(lines) == 3
    assert "codex_pooler_account_metrics_collection_success 0" in lines
    assert "codex_pooler_account_metrics_collection_duration_seconds 0.5" in lines
    refute body =~ "private-error"
  end

  defp projection(samples),
    do: %{
      complete: true,
      as_of: ~U[2026-09-07 06:00:00Z],
      accounts: 1,
      memberships: 0,
      groups: 0,
      observations: 0,
      samples: samples
    }
end
