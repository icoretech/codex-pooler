defmodule CodexPooler.Upstreams.SavedResetRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResetRedemption

  setup do
    on_exit(fn -> :ok end)
  end

  describe "redeem/2" do
    test "redeems ChatGPT style credit with list and consume calls" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "credit_1", "status" => "available"}],
                  "available_count" => 1
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {404, %{}},
             "/backend-api/codex/usage" => {404, %{}},
             "/wham/usage" => {404, %{}},
             "/backend-api/wham/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      requests = FakeUpstream.requests(fake)

      assert Enum.map(requests, &{&1.method, &1.path}) == [
               {"GET", "/backend-api/wham/rate-limit-reset-credits"},
               {"POST", "/backend-api/wham/rate-limit-reset-credits/consume"},
               {"GET", "/api/codex/usage"},
               {"GET", "/backend-api/codex/usage"},
               {"GET", "/wham/usage"},
               {"GET", "/backend-api/wham/usage"}
             ]

      consume =
        Enum.find(requests, &(&1.path == "/backend-api/wham/rate-limit-reset-credits/consume"))

      assert %{"credit_id" => "credit_1", "redeem_request_id" => redeem_request_id} = consume.json
      assert is_binary(redeem_request_id)

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
      metadata_json = Jason.encode!(persisted.metadata)
      refute metadata_json =~ "credit_1"
      refute metadata_json =~ redeem_request_id
    end

    test "redeems Codex style credit without credit id" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{assignment: assignment} = assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      requests = FakeUpstream.requests(fake)

      assert [
               %{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume", json: body}
               | _
             ] = requests

      assert %{"redeem_request_id" => redeem_request_id} = body
      assert is_binary(redeem_request_id)
      refute Map.has_key?(body, "credit_id")
    end

    test "does not consume when no ChatGPT credit is usable and preserves expiration metadata" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "used_credit", "status" => "redeemed"}],
                  "available_count" => 0
                }}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets: saved_resets_with_expirations()
        )

      assert {:ok, %{status: :noop, applied?: false, code: "no_credit"}} =
               SavedResetRedemption.redeem(assignment)

      assert [%{method: "GET", path: "/backend-api/wham/rate-limit-reset-credits"}] =
               FakeUpstream.requests(fake)

      saved_resets = Repo.reload!(identity).metadata["saved_resets"]

      assert saved_resets["available_count"] == 0
      assert saved_resets["available_expires_at"] == ["2026-07-18T00:40:11.968726Z"]

      assert saved_resets["available_expirations"] == [
               %{
                 "expires_at" => "2026-07-18T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-21T09:00:00Z"
               }
             ]

      assert saved_resets["next_expires_at"] == "2026-07-18T00:40:11.968726Z"
      assert saved_resets["expires_observed_at"] == "2026-06-22T10:00:00Z"
      assert saved_resets["expires_refresh_attempted_at"] == "2026-06-22T10:00:00Z"

      metadata_json = Jason.encode!(Repo.reload!(identity).metadata)

      refute metadata_json =~ "used_credit"
      refute metadata_json =~ "redeem_request_id"
      refute metadata_json =~ "provider-credit"
      refute metadata_json =~ "Provider Title"
      refute metadata_json =~ "Provider description"
      refute metadata_json =~ "granted_at"
      refute metadata_json =~ "raw_payload"
    end

    test "fresh in-progress redemption blocks another attempt" do
      {:ok, fake} = FakeUpstream.start_link({:json, 200, %{}})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          redemption: %{
            "status" => "redeeming",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 1,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(now),
            "finished_at" => nil,
            "result" => nil
          }
        )

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert [] = FakeUpstream.requests(fake)
    end

    test "stale admin in-progress redemption is recovered by manual attempt" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      stale_started_at =
        DateTime.utc_now()
        |> DateTime.add(-5, :minute)
        |> DateTime.truncate(:microsecond)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: %{
            "status" => "redeeming",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 1,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(stale_started_at),
            "finished_at" => nil,
            "result" => nil
          }
        )

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      assert [consume_request, usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "succeeded"
      assert get_in(persisted.metadata, ["saved_reset_redemption", "generation"]) == 3
      assert get_in(persisted.metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
    end
  end

  defp assignment_with_fake(fake, usage_path, path_style, opts \\ []) do
    saved_resets =
      Keyword.get(opts, :saved_resets, %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => path_style,
        "observed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "usage_path" => usage_path,
        "reason" => nil
      })

    metadata = %{
      "usage_base_url" => FakeUpstream.url(fake),
      "saved_resets" => saved_resets
    }

    metadata =
      case Keyword.get(opts, :redemption) do
        nil -> metadata
        redemption -> Map.put(metadata, "saved_reset_redemption", redemption)
      end

    active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})
  end

  defp saved_resets_with_expirations do
    %{
      "status" => "reported",
      "available_count" => 1,
      "source" => "codex_usage_api",
      "path_style" => "chatgpt_api",
      "observed_at" => "2026-06-22T10:00:00Z",
      "usage_path" => "/backend-api/wham/usage",
      "available_expires_at" => ["2026-07-18T00:40:11.968726Z"],
      "available_expirations" => [
        %{
          "expires_at" => "2026-07-18T00:40:11.968726Z",
          "first_seen_at" => "2026-06-21T09:00:00Z"
        },
        %{
          "expires_at" => "not-a-date",
          "first_seen_at" => "2026-06-20T09:00:00Z"
        }
      ],
      "next_expires_at" => "2026-07-18T00:40:11.968726Z",
      "expires_observed_at" => "2026-06-22T10:00:00Z",
      "expires_refresh_attempted_at" => "2026-06-22T10:00:00Z",
      "credit_id" => "provider-credit",
      "title" => "Provider Title",
      "description" => "Provider description",
      "granted_at" => "2026-06-20T00:00:00Z",
      "raw_payload" => %{"unsafe" => true},
      "reason" => nil
    }
  end

  defp usage_payload(available_count) do
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end
end
