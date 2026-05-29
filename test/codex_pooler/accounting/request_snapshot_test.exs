defmodule CodexPooler.Accounting.RequestSnapshotTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  describe "gateway accounting request snapshots" do
    test "request snapshot keeps original upstream account fields after identity mutation" do
      setup =
        accounting_setup(%{
          account_label: "Operator account",
          account_email: "operator@example.com",
          plan_label: "Pro",
          plan_family: "paid"
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "auto",
                   "reasoning" => %{"effort" => "medium"}
                 },
                 %{correlation_id: "corr-snapshot-historical"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, _result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
                 %{response_status_code: 200, attempt_metadata: %{"service_tier" => "priority"}}
               )

      setup.identity
      |> Ecto.Changeset.change(%{
        account_label: "changed@example.com",
        account_email: "changed@example.com",
        plan_label: "Team",
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

      persisted = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)

      assert persisted.upstream_account_label == "Operator account"
      assert persisted.upstream_account_email == "operator@example.com"
      assert persisted.upstream_account_plan_label == "Pro"
      assert persisted.upstream_account_plan_family == "paid"
    end

    test "request snapshot keeps attempt-time identity when identity mutates before finalization" do
      setup =
        accounting_setup(%{
          account_label: "Operator account",
          account_email: "operator@example.com",
          plan_label: "Pro",
          plan_family: "paid"
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-snapshot-attempt-time"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      setup.identity
      |> Ecto.Changeset.change(%{
        account_label: "changed@example.com",
        account_email: "changed@example.com",
        plan_label: "Team",
        plan_family: "enterprise",
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

      assert {:ok, _result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
                 %{response_status_code: 200}
               )

      persisted = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert persisted.upstream_account_label == "Operator account"
      assert persisted.upstream_account_email == "operator@example.com"
      assert persisted.upstream_account_plan_label == "Pro"
      assert persisted.upstream_account_plan_family == "paid"
    end

    test "non-email upstream account labels do not populate upstream_account_email" do
      setup =
        accounting_setup(%{
          account_label: "Codex account",
          plan_label: "Team",
          plan_family: "paid"
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-snapshot-non-email"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, _result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 1, output_tokens: 1, total_tokens: 2},
                 %{response_status_code: 200}
               )

      persisted = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)

      assert persisted.upstream_account_label == "Codex account"
      assert is_nil(persisted.upstream_account_email)
      assert persisted.upstream_account_plan_label == "Team"
      assert persisted.upstream_account_plan_family == "paid"
    end

    test "denied requests keep upstream snapshot fields nil" do
      setup = accounting_setup()

      assert {:ok, %{request: denied}} =
               Accounting.record_denied_request(setup.auth, setup.model, %{
                 correlation_id: "corr-denied-snapshot-nil",
                 endpoint: "/backend-api/codex/responses",
                 transport: "http_json",
                 request_metadata: %{"policy_denial" => %{"code" => "model_not_allowed"}}
               })

      persisted = Repo.get!(CodexPooler.Accounting.Request, denied.id)
      assert is_nil(persisted.upstream_account_email)
      assert is_nil(persisted.upstream_account_plan_label)
      assert is_nil(persisted.upstream_account_plan_family)

      assert %{items: [log], total: 1} = Accounting.list_request_logs(setup.pool)
      assert log.id == denied.id
      assert log.status == "rejected"
    end

    test "request snapshot stores model settings with effective tier preferring actual tier" do
      setup =
        accounting_setup(%{
          account_label: "Operator account",
          account_email: "operator@example.com",
          plan_label: "Pro"
        })

      raw_secret = "sk-cxp-123456789abc-SECRET-token"
      raw_prompt = "keep this prompt out of snapshots"

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "auto",
                   "reasoning" => %{"effort" => "high"},
                   "input" => raw_prompt
                 },
                 %{
                   correlation_id: "corr-model-settings-snapshot",
                   request_metadata: %{
                     "authorization" => "Bearer " <> raw_secret,
                     "body" => %{"input" => raw_prompt}
                   }
                 }
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, _result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3},
                 %{response_status_code: 200, attempt_metadata: %{"service_tier" => "priority"}}
               )

      persisted = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert persisted.reasoning_effort == "high"
      assert persisted.requested_service_tier == "auto"
      assert persisted.actual_service_tier == "priority"
      assert persisted.service_tier == "priority"

      refute inspect(persisted) =~ raw_secret
      refute inspect(persisted) =~ raw_prompt
    end
  end
end
