defmodule CodexPoolerWeb.V1.ChatRejectionDiagnosticsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest, only: [render_component: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer.Attempts

  @provider_param "input[1].call_id"
  @provider_message "synthetic-provider-message-private"
  @prompt "synthetic-client-input-private"
  @call_id String.duplicate("c", 64)

  setup %{conn: conn} do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{gateway_debug?: true})
      |> Keyword.put(:use_instance_settings?, false)
    )

    # The fake returns a structured provider refusal independently of the
    # Chat identifier normalizer. This exercises diagnostic propagation and
    # rendering, while the separate call-id tests own the length boundary.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: {:json_error, 400, %{"error" => %{"type" => "invalid_request_error", "code" => "string_above_max_length", "param" => @provider_param, "message" => @provider_message}}}
          )
        ])
      )

    setup = gateway_setup(upstream)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: "full",
      created_at: timestamp,
      updated_at: timestamp
    })

    response =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "messages" => [
          %{"role" => "user", "content" => @prompt},
          %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => @call_id, "type" => "function", "function" => %{"name" => "fixture", "arguments" => "{}"}}]},
          %{"role" => "tool", "tool_call_id" => @call_id, "content" => "synthetic-result"}
        ],
        "stream" => true
      })

    assert json_response(response, 400)["error"] == %{
             "type" => "invalid_request_error",
             "code" => "string_above_max_length",
             "param" => "messages",
             "message" => "upstream rejected parameter messages (string_above_max_length)"
           }

    assert :ok = FakeUpstream.verify!(upstream)
    assert [captured] = FakeUpstream.requests(upstream)
    assert Enum.at(captured.json["input"], 1)["type"] == "function_call"
    assert Enum.at(captured.json["input"], 1)["call_id"] == @call_id
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    assert %{items: [log]} = Accounting.list_request_logs(setup.pool, surface: :admin)
    assert [debug_attempt] = log.debug.attempts

    refute inspect({request, attempt, log}) =~ @provider_message
    refute inspect({request, attempt, log}) =~ @prompt

    %{request: request, attempt: attempt, debug_attempt: debug_attempt, log: log}
  end

  test "Full Chat HTTP SSE rejection preserves the provider field in stored and projected metadata", %{request: request, attempt: attempt, debug_attempt: debug_attempt} do
    assert request.transport == "http_sse"
    assert request.last_error_code == "upstream_status"
    assert attempt.upstream_status_code == 400
    assert attempt.response_metadata["routing"]["model_serving_mode"] == "full"
    assert is_map(attempt.response_metadata["gateway_debug"])
    assert attempt.response_metadata["rejection_error_code"] == "string_above_max_length"
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
    assert attempt.response_metadata["rejection_error_param"] == @provider_param
    assert debug_attempt.rejection_error_code == "string_above_max_length"
    assert debug_attempt.rejection_error_param == @provider_param
    refute Map.has_key?(debug_attempt, :transport_failure)
  end

  test "Full Chat HTTP SSE rejection shows the original provider field in the attempt drawer", %{debug_attempt: debug_attempt, log: log} do
    rows = Attempts.attempt_rows(debug_attempt)

    assert Enum.any?(rows, &(&1.value == @provider_param)), "attempt drawer omitted the persisted provider rejection parameter"
    assert Enum.any?(rows, &(&1.value == "string_above_max_length")), "attempt drawer omitted the persisted provider rejection code"
    assert Enum.any?(rows, &(&1.value == "invalid_request_error")), "attempt drawer omitted the persisted provider rejection type"

    html = render_component(&RequestLogDetailDrawer.request_log_detail_drawer/1, selected_request_log: log, datetime_preferences: %{datetime_format: "default", timezone: "Etc/UTC"})

    for {suffix, value} <- [{"code", "string_above_max_length"}, {"type", "invalid_request_error"}, {"param", @provider_param}] do
      assert html |> LazyHTML.from_document() |> LazyHTML.query("#request-log-detail-attempt-1-rejection-error-#{suffix} dd") |> LazyHTML.text() |> String.trim() == value
    end

    refute html =~ @provider_message
    refute html =~ @prompt
    assert html =~ "No compact transport failure metadata recorded."
  end
end
