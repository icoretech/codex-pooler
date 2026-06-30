defmodule CodexPooler.Upstreams.SavedResetRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

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

    test "gateway auto does not consume when persisted policy was disabled after candidate selection" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_identity!(stale_identity, %{saved_reset_auto_redeem_enabled: false})

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted count was reduced to keep credits" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity =
        enable_saved_reset_auto_redeem!(identity, %{saved_reset_auto_redeem_keep_credits: 1})

      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_saved_resets!(stale_identity, %{"available_count" => 1})

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted saved-reset count is unreported" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_saved_resets!(stale_identity, %{"status" => "unreported", "available_count" => nil})

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_saved_reset_unavailable"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(stale_identity)
      refute get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "redeeming"
    end

    test "gateway auto does not consume when persisted weekly quota no longer matches trigger" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      upsert_weekly_pressure_quota!(stale_identity, Decimal.new("20"))

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto rejects mismatched context without marking redemption" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)

      context =
        assignment
        |> gateway_auto_context(stale_identity, :blocked_weekly_exhaustion)
        |> Map.merge(%{
          upstream_identity_id: Ecto.UUID.generate(),
          candidate_identity_ids: [Ecto.UUID.generate()]
        })

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_context_mismatch"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(stale_identity)
      refute get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "redeeming"
    end

    test "gateway auto does not consume when persisted identity has fresh in-progress redemption" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_redemption!(stale_identity, redemption_metadata("gateway_auto", DateTime.utc_now()))

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted identity has stale gateway auto metadata" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)
      started_at = DateTime.utc_now() |> DateTime.add(-5, :minute)

      update_redemption!(stale_identity, redemption_metadata("gateway_auto", started_at))

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted identity lost expiring eligibility" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          saved_resets:
            saved_resets_with_expirations()
            |> Map.merge(expiring_saved_reset_attrs())
            |> Map.put("path_style", "codex_api")
            |> Map.put("usage_path", "/api/codex/usage")
        )

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_pressure_quota!(stale_identity, Decimal.new("25"))
      context = gateway_auto_context(assignment, stale_identity, :expiring_reset)

      update_saved_resets!(stale_identity, %{
        "available_expires_at" => [],
        "available_expirations" => [],
        "next_expires_at" => nil
      })

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto rejects malformed context without provider request" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: %{trigger: :blocked_weekly_exhaustion}
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto rejects non-keyword list malformed context without provider request" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_context_invalid"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: [:bad]
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(identity)
      refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
    end

    test "gateway auto returns an error without provider request when persisted assignment is inactive" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      update_assignment!(assignment, %{status: PoolUpstreamAssignment.paused_status()})

      assert {:error, %{code: :pool_assignment_not_found}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end
  end

  describe "AutoEligibility.validate_locked_gateway_auto/4" do
    test "gateway auto noops when the locked identity is disabled or deleted" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for status <- [UpstreamIdentity.disabled_status(), UpstreamIdentity.deleted_status()] do
        locked_identity = %{identity | status: status}

        assert {:noop, "gateway_auto_identity_unavailable"} =
                 AutoEligibility.validate_locked_gateway_auto(
                   locked_identity,
                   assignment,
                   context,
                   timestamp
                 )
      end

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto noops when the current assignment is inactive or reassigned" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      inactive_assignment = %{assignment | status: PoolUpstreamAssignment.paused_status()}

      assert {:noop, "gateway_auto_assignment_unavailable"} =
               AutoEligibility.validate_locked_gateway_auto(
                 identity,
                 inactive_assignment,
                 context,
                 timestamp
               )

      reassigned_assignment = %{assignment | upstream_identity_id: Ecto.UUID.generate()}

      assert {:noop, "gateway_auto_context_mismatch"} =
               AutoEligibility.validate_locked_gateway_auto(
                 identity,
                 reassigned_assignment,
                 context,
                 timestamp
               )

      assert [] = FakeUpstream.requests(fake)
    end
  end

  defp codex_reset_fake(available_count) do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" => {200, usage_payload(available_count)}
       }}
    )
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

  defp expiring_saved_reset_attrs do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = timestamp |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
    observed_at = DateTime.to_iso8601(timestamp)

    %{
      "available_expires_at" => [expires_at],
      "available_expirations" => [%{"expires_at" => expires_at, "first_seen_at" => observed_at}],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at
    }
  end

  defp gateway_auto_context(assignment, identity, trigger) do
    %{
      trigger: trigger,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      candidate_assignment_ids: [assignment.id],
      candidate_identity_ids: [identity.id],
      route_class: "proxy_http"
    }
  end

  defp enable_saved_reset_auto_redeem!(%UpstreamIdentity{} = identity, attrs \\ %{}) do
    update_identity!(
      identity,
      Map.merge(
        %{
          saved_reset_auto_redeem_enabled: true,
          saved_reset_auto_redeem_min_blocked_minutes: 60,
          saved_reset_auto_redeem_keep_credits: 0,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        },
        attrs
      )
    )
  end

  defp update_identity!(%UpstreamIdentity{} = identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update!()
  end

  defp update_saved_resets!(%UpstreamIdentity{} = identity, attrs) do
    persisted = Repo.reload!(identity)
    metadata = persisted.metadata || %{}
    saved_resets = Map.merge(metadata["saved_resets"] || %{}, attrs)

    update_identity!(persisted, %{metadata: Map.put(metadata, "saved_resets", saved_resets)})
  end

  defp update_redemption!(%UpstreamIdentity{} = identity, redemption) do
    persisted = Repo.reload!(identity)
    metadata = persisted.metadata || %{}

    update_identity!(persisted, %{
      metadata: Map.put(metadata, "saved_reset_redemption", redemption)
    })
  end

  defp update_assignment!(%PoolUpstreamAssignment{} = assignment, attrs) do
    assignment
    |> Repo.reload!()
    |> PoolUpstreamAssignment.changeset(
      Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    )
    |> Repo.update!()
  end

  defp redemption_metadata(trigger_kind, started_at) do
    %{
      "status" => "redeeming",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => trigger_kind,
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil
    }
  end

  defp upsert_weekly_exhausted_quota!(identity) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [weekly_quota_attrs(Decimal.new("100"))])
  end

  defp upsert_weekly_pressure_quota!(identity, used_percent) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [weekly_quota_attrs(used_percent)])
  end

  defp weekly_quota_attrs(used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: used_percent,
      reset_at: DateTime.add(now, 2, :hour),
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
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
