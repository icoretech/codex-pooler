defmodule CodexPoolerWeb.Admin.JobFilterFormTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.JobFilterForm

  @assignment_id "11111111-1111-4111-8111-111111111111"
  @identity_id "22222222-2222-4222-8222-222222222222"
  @pool_id "33333333-3333-4333-8333-333333333333"
  @api_key_id "44444444-4444-4444-8444-444444444444"

  test "normalizes valid URL params and serializes a deterministic round trip" do
    params = %{
      "state" => " retryable ",
      "worker" => " CodexPooler.Jobs.TokenRefreshWorker ",
      "queue" => " jobs ",
      "attention" => "active_failure",
      "target_kind" => "upstream_identity",
      "target_id" => " #{@identity_id} ",
      "page" => "3",
      "show_completed" => "true",
      "job_id" => "42"
    }

    assert {filters, form_values, []} = JobFilterForm.parse_filters(params)

    assert filters == %{
             state: "retryable",
             worker: "CodexPooler.Jobs.TokenRefreshWorker",
             queue: "jobs",
             attention: "active_failure",
             target_kind: "upstream_identity",
             target_id: @identity_id,
             page: 3,
             show_completed: true,
             job_id: 42
           }

    assert form_values == %{
             "state" => "retryable",
             "worker" => "CodexPooler.Jobs.TokenRefreshWorker",
             "queue" => "jobs",
             "attention" => "active_failure",
             "target_kind" => "upstream_identity",
             "target_id" => @identity_id,
             "page" => "3",
             "show_completed" => "true",
             "job_id" => "42"
           }

    assert JobFilterForm.query_params(form_values) == %{
             "attention" => "active_failure",
             "job_id" => "42",
             "page" => "3",
             "queue" => "jobs",
             "show_completed" => "true",
             "state" => "retryable",
             "target_id" => @identity_id,
             "target_kind" => "upstream_identity",
             "worker" => "CodexPooler.Jobs.TokenRefreshWorker"
           }
  end

  test "defaults to hiding completed jobs and omits default params" do
    assert {filters, form_values, []} = JobFilterForm.parse_filters(%{})

    assert filters.page == 1
    refute filters.show_completed
    assert filters.state == nil
    assert form_values["page"] == "1"
    assert form_values["show_completed"] == "false"
    assert JobFilterForm.query_params(form_values) == %{}
  end

  test "warns for invalid state and page while preserving safe defaults" do
    assert {filters, form_values, errors} =
             JobFilterForm.parse_filters(%{"state" => "unknown", "page" => "0"})

    assert filters.state == nil
    assert filters.page == 1
    assert form_values["state"] == "unknown"
    assert form_values["page"] == "1"
    assert %{field: :state, message: "State filter is not supported"} in errors
    assert %{field: :page, message: "Page must be a positive integer"} in errors
    assert JobFilterForm.form_errors(errors)[:state] == {"State filter is not supported", []}
  end

  test "keeps completed rows hidden unless show_completed is explicitly enabled" do
    assert {filters, _form_values, errors} =
             JobFilterForm.parse_filters(%{"state" => "completed"})

    assert filters.state == nil
    refute filters.show_completed
    assert %{field: :state, message: "Completed jobs require show_completed=true"} in errors

    assert {filters, _form_values, []} =
             JobFilterForm.parse_filters(%{"state" => "completed", "show_completed" => "true"})

    assert filters.state == "completed"
    assert filters.show_completed
  end

  test "validates target kind enum and target id semantics" do
    assert JobFilterForm.target_kind_options() |> Enum.map(& &1.value) == [
             "assignment",
             "upstream_identity",
             "pool",
             "api_key",
             "rollup_date",
             "system"
           ]

    for {kind, id} <- [
          {"assignment", @assignment_id},
          {"upstream_identity", @identity_id},
          {"pool", @pool_id},
          {"api_key", @api_key_id}
        ] do
      assert {filters, form_values, []} =
               JobFilterForm.parse_filters(%{"target_kind" => kind, "target_id" => id})

      assert filters.target_kind == kind
      assert filters.target_id == id
      assert form_values["target_id"] == id
    end

    assert {filters, form_values, []} =
             JobFilterForm.parse_filters(%{
               "target_kind" => "rollup_date",
               "target_id" => "2026-06-02"
             })

    assert filters.target_kind == "rollup_date"
    assert filters.target_id == "2026-06-02"
    assert form_values["target_id"] == "2026-06-02"

    assert {filters, form_values, []} =
             JobFilterForm.parse_filters(%{"target_kind" => "system", "target_id" => ""})

    assert filters.target_kind == "system"
    assert filters.target_id == nil
    assert form_values["target_id"] == ""
  end

  test "warns for invalid target combinations without applying unsafe target filters" do
    invalid_cases = [
      {%{"target_id" => @pool_id}, :target_kind,
       "Target kind is required when target id is present"},
      {%{"target_kind" => "tenant", "target_id" => @pool_id}, :target_kind,
       "Target kind filter is not supported"},
      {%{"target_kind" => "pool", "target_id" => "not-a-uuid"}, :target_id,
       "Target id must be a valid UUID for the selected target kind"},
      {%{"target_kind" => "rollup_date", "target_id" => "2026-99-99"}, :target_id,
       "Target id must be a valid ISO date for rollup_date"},
      {%{"target_kind" => "system", "target_id" => @pool_id}, :target_id,
       "Target id must be blank for system jobs"}
    ]

    for {params, field, message} <- invalid_cases do
      assert {filters, _form_values, errors} = JobFilterForm.parse_filters(params)

      assert filters.target_kind == nil
      assert filters.target_id == nil
      assert %{field: field, message: message} in errors
    end
  end

  test "normalizes selected drawer job id and provides open close query helpers" do
    base_params = %{"state" => "retryable", "page" => "2", "job_id" => "7"}

    assert {filters, form_values, []} = JobFilterForm.parse_filters(base_params)
    assert filters.job_id == 7
    assert form_values["job_id"] == "7"

    assert JobFilterForm.open_job_query_params(base_params, 12) == %{
             "job_id" => "12",
             "page" => "2",
             "state" => "retryable"
           }

    assert JobFilterForm.close_job_query_params(base_params) == %{
             "page" => "2",
             "state" => "retryable"
           }
  end

  test "selected option helpers fall back to the any option" do
    assert %{label: "Retryable", value: "retryable"} =
             JobFilterForm.selected_state_option("retryable")

    assert %{label: "Any state", value: ""} = JobFilterForm.selected_state_option("invalid")

    assert %{label: "Retry pressure", value: "retry_pressure"} =
             JobFilterForm.selected_attention_option("retry_pressure")

    assert %{label: "Any attention", value: ""} = JobFilterForm.selected_attention_option(nil)

    worker_options =
      JobFilterForm.worker_options(["CodexPooler.Jobs.TokenRefreshWorker"], "Other.Worker")

    assert Enum.map(worker_options, & &1.value) == [
             "",
             "CodexPooler.Jobs.TokenRefreshWorker",
             "Other.Worker"
           ]

    assert %{label: "Other.Worker", value: "Other.Worker"} =
             JobFilterForm.selected_worker_option(worker_options, "Other.Worker")
  end

  test "attention options use HealthPolicy canonical states" do
    values = JobFilterForm.attention_options() |> Enum.map(& &1.value)

    assert values == [
             "",
             "active_failure",
             "retry_pressure",
             "stuck_executing",
             "backlog_pressure",
             "cancelled",
             "healthy_context",
             "executing",
             "available",
             "scheduled",
             "suspended",
             "unknown_state"
           ]

    for value <- ["active_failure", "retry_pressure", "stuck_executing", "backlog_pressure"] do
      assert {filters, form_values, []} = JobFilterForm.parse_filters(%{"attention" => value})
      assert filters.attention == value
      assert form_values["attention"] == value
      assert JobFilterForm.query_params(form_values) == %{"attention" => value}
    end
  end

  test "non-actionable attention options are accepted as documented HealthPolicy context states" do
    for value <- [
          "cancelled",
          "healthy_context",
          "executing",
          "available",
          "scheduled",
          "suspended",
          "unknown_state"
        ] do
      assert {filters, _form_values, []} = JobFilterForm.parse_filters(%{"attention" => value})
      assert filters.attention == value
    end
  end

  test "old ad hoc attention aliases are warning-only and not serialized" do
    for value <- ["needs_attention", "stuck", "overdue", "terminal_failure"] do
      assert {filters, form_values, errors} = JobFilterForm.parse_filters(%{"attention" => value})
      assert filters.attention == nil
      assert form_values["attention"] == value
      assert %{field: :attention, message: "Attention filter is not supported"} in errors
      assert JobFilterForm.query_params(%{"attention" => value}) == %{}
    end
  end
end
