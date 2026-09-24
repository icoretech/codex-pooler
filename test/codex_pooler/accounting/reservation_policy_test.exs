defmodule CodexPooler.Accounting.ReservationPolicyTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.ReservationPolicy
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "explicit enforcement clock excludes future terminal and pending usage and includes its boundary" do
    fixture = CodexPooler.AccountingTestSupport.accounting_setup()
    as_of = ~U[2026-01-15 12:00:00.000000Z]
    later = DateTime.add(as_of, 1, :second)
    estimate = %{input_tokens: 0, output_tokens: 1, total_tokens: 1}

    # The settlement ends a finished request; the reservation holds a live one,
    # because only a live request's reservation is pending (findings#206 row
    # 206-461): a finished request's reservation that nothing released is not.
    live = %{status: "in_progress", usage_status: "usage_pending", completed_at: nil, response_status_code: nil}

    for {kind, request_attrs} <- [{"settlement", %{}}, {"reservation", live}] do
      request = request_fixture(fixture.auth, Map.put(request_attrs, :model_id, fixture.model.id))

      ledger_entry_fixture(request, %{
        entry_kind: kind,
        usage_status: "usage_known",
        total_tokens: 10,
        occurred_at: later
      })
    end

    for field <- [:max_tokens_per_day, :max_tokens_per_week] do
      policy = struct(APIKeyPolicyBinding, [{field, 20}])

      assert :ok =
               ReservationPolicy.enforce_reservation_limits(
                 fixture.api_key,
                 policy,
                 estimate,
                 as_of
               )

      assert {:error, %{code: :api_key_policy_limit_exceeded}} =
               ReservationPolicy.enforce_reservation_limits(
                 fixture.api_key,
                 policy,
                 estimate,
                 later
               )
    end

    policy = %APIKeyPolicyBinding{max_requests_per_minute: 1}

    assert :ok =
             ReservationPolicy.enforce_reservation_limits(
               fixture.api_key,
               policy,
               estimate,
               as_of
             )

    assert {:error, %{code: :api_key_policy_limit_exceeded}} =
             ReservationPolicy.enforce_reservation_limits(
               fixture.api_key,
               policy,
               estimate,
               later
             )
  end

  test "candidate policies are reloaded and scoped to the authenticated key and model" do
    %{api_key: key} = active_api_key_fixture(pool_fixture())
    %{api_key: other_key} = active_api_key_fixture(pool_fixture())
    default = Repo.get_by!(APIKeyPolicyBinding, api_key_id: key.id, binding_scope: "default")
    candidate = insert_policy(key, "sample-model")

    foreign =
      Repo.get_by!(APIKeyPolicyBinding, api_key_id: other_key.id, binding_scope: "default")

    assert ReservationPolicy.policy_for_update(key, " SAMPLE-MODEL ", candidate).id ==
             candidate.id

    assert ReservationPolicy.policy_for_update(key, "different-model", candidate).id == default.id
    assert ReservationPolicy.policy_for_update(key, "sample-model", foreign).id == candidate.id

    candidate |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
    assert ReservationPolicy.policy_for_update(key, "sample-model", candidate).id == default.id
    assert ReservationPolicy.policy_for_update(key, nil, default).id == default.id

    default |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
    assert is_nil(ReservationPolicy.policy_for_update(key, nil, default))
  end

  test "effective model preserves explicit aliases before exposed and requested model fallback" do
    model = %Model{exposed_model_id: "exposed-model"}

    assert ReservationPolicy.effective_model(model, "requested", %{effective_model: "alias"}) ==
             "alias"

    assert ReservationPolicy.effective_model(model, "requested", %{"effective_model" => "alias"}) ==
             "alias"

    assert ReservationPolicy.effective_model(model, "requested", %{}) == "exposed-model"
    assert ReservationPolicy.effective_model(%Model{}, "requested", %{}) == "requested"
  end

  test "request limits accept the exact boundary and reject input before output" do
    policy = %APIKeyPolicyBinding{
      max_input_tokens_per_request: 10,
      max_output_tokens_per_request: 5
    }

    estimate = %{input_tokens: Decimal.new(10), output_tokens: Decimal.new(5), total_tokens: 15}
    now = DateTime.utc_now()

    assert :ok =
             ReservationPolicy.enforce_reservation_limits(
               %{id: Ecto.UUID.generate()},
               policy,
               estimate,
               now
             )

    assert {:error, input_error} =
             ReservationPolicy.enforce_reservation_limits(
               nil,
               policy,
               %{estimate | input_tokens: 11, output_tokens: 6},
               now
             )

    assert input_error.code == :api_key_policy_limit_exceeded
    assert input_error.message =~ "max_input_tokens_per_request"

    assert {:error, output_error} =
             ReservationPolicy.enforce_reservation_limits(
               nil,
               policy,
               %{estimate | output_tokens: 6},
               now
             )

    assert output_error.message =~ "max_output_tokens_per_request"
    assert :ok = ReservationPolicy.enforce_reservation_limits(nil, nil, estimate, now)
  end

  # A token window the request fits once it moves is a window refusal (429,
  # with the daily window's reset as its hint); a token window whose max is
  # below the request's own estimate never admits that request, whatever the
  # window holds, so it is a per-request refusal like the estimate caps, with
  # no hint (findings#206 row 206-448).
  test "a token window below the request's own estimate is a per-request refusal, an exhausted one a window refusal" do
    fixture = CodexPooler.AccountingTestSupport.accounting_setup()
    as_of = ~U[2026-01-15 12:00:00.000000Z]
    earlier = DateTime.add(as_of, -1, :second)
    request = request_fixture(fixture.auth, %{model_id: fixture.model.id})
    ledger_entry_fixture(request, %{entry_kind: "settlement", usage_status: "usage_known", total_tokens: 10, occurred_at: earlier})

    fits_alone = %{input_tokens: 0, output_tokens: 11, total_tokens: 11}
    above_max = %{input_tokens: 0, output_tokens: 21, total_tokens: 21}

    measured =
      for field <- [:max_tokens_per_day, :max_tokens_per_week], {label, estimate} <- [fits_alone: fits_alone, above_max: above_max], into: %{} do
        policy = struct(APIKeyPolicyBinding, [{field, 20}])
        {:error, error} = ReservationPolicy.enforce_reservation_limits(fixture.api_key, policy, estimate, as_of)
        {{field, label}, {error.code, Map.get(error, :limit_scope), Map.get(error, :retry_after_seconds)}}
      end

    assert measured == %{
             {:max_tokens_per_day, :fits_alone} => {:api_key_policy_limit_exceeded, :window, 12 * 3_600},
             {:max_tokens_per_day, :above_max} => {:api_key_policy_limit_exceeded, :request, nil},
             {:max_tokens_per_week, :fits_alone} => {:api_key_policy_limit_exceeded, :window, nil},
             {:max_tokens_per_week, :above_max} => {:api_key_policy_limit_exceeded, :request, nil}
           }

    {:error, error} = ReservationPolicy.enforce_reservation_limits(fixture.api_key, %APIKeyPolicyBinding{max_tokens_per_day: 20}, above_max, as_of)
    assert error.message =~ "max_tokens_per_day"
    assert error.message =~ "request estimate 21 exceeds max 20"

    # An exhausted daily window does not promise a reset the weekly max
    # below the estimate would refuse again.
    both = %APIKeyPolicyBinding{max_tokens_per_day: 20, max_tokens_per_week: 15}
    {:error, error} = ReservationPolicy.enforce_reservation_limits(fixture.api_key, both, %{input_tokens: 0, output_tokens: 16, total_tokens: 16}, as_of)
    assert {error.limit_scope, Map.get(error, :retry_after_seconds)} == {:request, nil}
    assert error.message =~ "max_tokens_per_week"
  end

  test "absent and nil active caps skip database reads for trusted minimal key contexts" do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:repo] == Repo,
            do: send(test_pid, {handler_id, :query})
        end,
        nil
      )

    estimate = %{input_tokens: 10, output_tokens: 5, total_tokens: 15}

    for key <- [
          nil,
          %{id: Ecto.UUID.generate()},
          %{id: Ecto.UUID.generate(), max_active_requests: nil}
        ] do
      assert :ok =
               ReservationPolicy.enforce_reservation_limits(
                 key,
                 nil,
                 estimate,
                 DateTime.utc_now()
               )
    end

    # The synchronous caller is the telemetry emitter; completion fences all reads.
    refute_received {^handler_id, :query}
  end

  defp insert_policy(key, model) do
    now = DateTime.utc_now()

    Repo.insert!(%APIKeyPolicyBinding{
      api_key_id: key.id,
      binding_scope: "model",
      model_identifier: model,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end
end
