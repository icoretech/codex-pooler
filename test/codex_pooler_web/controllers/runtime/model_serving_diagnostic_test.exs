defmodule CodexPoolerWeb.Runtime.ModelServingDiagnosticTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @mode_metadata_keys [
    "model_serving_mode_configured",
    "model_serving_mode",
    "model_serving_mode_source"
  ]

  test "explicit Full upstream rejection is visible as a sanitized diagnostic without downgrade",
       %{conn: conn} do
    untrusted_error_text = "untrusted-upstream-error-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.json_response(
          %{
            "error" => %{
              "code" => "unsupported_value",
              "message" => untrusted_error_text,
              "param" => "parallel_tool_calls",
              "type" => "invalid_request_error"
            }
          },
          400
        )
      )

    setup = gateway_setup(upstream)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: "full",
      created_at: now,
      updated_at: now
    })

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic Full rejection request",
        "parallel_tool_calls" => true
      })

    assert response.status == 400
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["parallel_tool_calls"] == true

    refute Map.has_key?(
             Map.new(captured.headers),
             "x-openai-internal-codex-responses-lite"
           )

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 400
    assert request.retry_count == 0
    assert request.last_error_code == "full_upstream_rejection"

    expected_mode_metadata = %{
      "model_serving_mode_configured" => "full",
      "model_serving_mode" => "full",
      "model_serving_mode_source" => "override"
    }

    assert Map.take(request.request_metadata["routing"], @mode_metadata_keys) ==
             expected_mode_metadata

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.upstream_status_code == 400
    assert attempt.network_error_code == "full_upstream_rejection"
    assert attempt.error_message == "upstream returned 400"
    assert attempt.response_metadata["error_kind"] == "full_upstream_rejection"

    assert Map.take(attempt.response_metadata["routing"], @mode_metadata_keys) ==
             expected_mode_metadata

    assert [%{denial_reason: "full_upstream_rejection", response_status_code: 400} = log] =
             RequestLogs.list(setup.pool.id, limit: 10).items

    refute inspect(request.request_metadata) =~ untrusted_error_text
    refute inspect(attempt.response_metadata) =~ untrusted_error_text
    refute inspect(log) =~ untrusted_error_text
  end
end
