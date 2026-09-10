defmodule CodexPooler.Gateway.Runtime.ModelTransitionContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures, only: [model_fixture: 2, active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  test "a same-model tool continuation keeps its explicit response anchor", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_http_turn(tool_response(), valid: true, forbidden: ["previous_response_id"]),
          strict_http_turn(success(),
            valid: true,
            equals: %{
              "previous_response_id" => "resp_example_transition_anchor",
              "input.0.type" => "function_call_output"
            }
          )
        ])
      )

    setup = gateway_setup(upstream)
    {anchor, call_id} = complete_first_model!(conn, setup)

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> post(@endpoint_path, continuation(setup.model, anchor, call_id))

    assert %{"id" => "resp_example_transition_complete"} = json_response(response, 200)
    assert anchor != "resp_example_transition_complete"
    assert [_first, second] = FakeUpstream.requests(upstream)
    assert second.json["previous_response_id"] == anchor
    assert [%{"type" => "function_call_output", "call_id" => ^call_id}] = second.json["input"]
    assert Repo.aggregate(Request, :count) == 2
    assert Repo.aggregate(Attempt, :count) == 2
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "a target-model error with an explicit prior-model anchor stays terminal", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_http_turn(tool_response(), valid: true, forbidden: ["previous_response_id"]),
          strict_http_turn(model_error(),
            valid: true,
            equals: %{
              "previous_response_id" => "resp_example_transition_anchor",
              "input.0.type" => "function_call_output"
            }
          )
        ])
      )

    setup = gateway_setup(upstream)
    target = target_model(setup)
    {anchor, call_id} = complete_first_model!(conn, setup)

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> post(@endpoint_path, continuation(target, anchor, call_id))

    assert %{"error" => %{"code" => "model_not_found"}} = json_response(response, 404)
    assert [first, second] = FakeUpstream.requests(upstream)
    refute first.json["model"] == second.json["model"]
    assert second.json["previous_response_id"] == anchor
    assert FakeUpstream.count(upstream) == 2
    assert [failed] = Repo.all(from r in Request, where: r.status == "failed")
    assert failed.requested_model == target.exposed_model_id
    assert failed.retry_count == 0
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^failed.id), :count) == 1
    assert failed.usage_status == "usage_unknown"

    assert Enum.sort(
             Repo.all(
               from l in LedgerEntry, where: l.request_id == ^failed.id, select: l.entry_kind
             )
           ) == ["release", "reservation", "settlement"]

    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "an allowed first model does not authorize the anchored target model", %{conn: conn} do
    upstream = start_upstream(tool_response())
    setup = gateway_setup(upstream)
    target = target_model(setup)
    {anchor, call_id} = complete_first_model!(conn, setup)

    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: [setup.model.exposed_model_id])
    |> Repo.update!()

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> post(@endpoint_path, continuation(target, anchor, call_id))

    assert %{"error" => %{"code" => "model_not_allowed"}} = json_response(response, 403)
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.status == "succeeded"), :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    denied = Repo.one!(from r in Request, where: r.requested_model == ^target.exposed_model_id)
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^denied.id), :count) == 0
  end

  test "an anchor from another API key cannot establish assignment ownership", %{conn: conn} do
    upstream = start_upstream(tool_response())
    setup = gateway_setup(upstream)
    {anchor, _call_id} = complete_first_model!(conn, setup)
    other_key = active_api_key_fixture(setup.pool)
    {:ok, owner_auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, other_auth} = Access.authenticate_authorization_header(other_key.authorization)
    now = DateTime.utc_now()

    assert SessionContinuity.previous_response_assignment_id(owner_auth, anchor, now) ==
             setup.assignment.id

    assert SessionContinuity.previous_response_assignment_id(other_auth, anchor, now) == nil
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(Request, :count) == 1
  end

  defp complete_first_model!(conn, setup) do
    assert %{
             "id" => anchor,
             "status" => "completed",
             "output" => [
               %{"type" => "function_call", "call_id" => call_id, "status" => "completed"}
             ]
           } =
             conn
             |> auth(setup)
             |> put_req_header("session_id", Ecto.UUID.generate())
             |> post(@endpoint_path, %{
               "model" => setup.model.exposed_model_id,
               "input" => [
                 %{"type" => "message", "role" => "user", "content" => "synthetic first turn"}
               ]
             })
             |> json_response(200)

    {anchor, call_id}
  end

  defp target_model(setup) do
    source =
      setup.model.metadata["source_assignment_models"][setup.assignment.id]
      |> Map.put("slug", "gpt-example-target")

    model_fixture(setup.pool, %{
      exposed_model_id: "gpt-example-target",
      upstream_model_id: "provider-gpt-example-target",
      metadata: %{
        "source_assignment_ids" => [setup.assignment.id],
        "source_assignment_models" => %{setup.assignment.id => source}
      }
    })
  end

  defp continuation(model, anchor, call_id) do
    %{
      "model" => model.exposed_model_id,
      "previous_response_id" => anchor,
      "input" => [
        %{"type" => "function_call_output", "call_id" => call_id, "output" => "synthetic"}
      ]
    }
  end

  defp strict_http_turn(respond, json_expectations) do
    FakeUpstream.expect_request(
      method: "POST",
      path: @endpoint_path,
      json: json_expectations,
      respond: respond
    )
  end

  defp tool_response do
    FakeUpstream.json_response(%{
      "id" => "resp_example_transition_anchor",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "id" => "fc_example_transition",
          "call_id" => "call_example_transition",
          "name" => "example_tool",
          "arguments" => "{}",
          "status" => "completed"
        }
      ],
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
    })
  end

  defp success do
    FakeUpstream.json_response(%{
      "id" => "resp_example_transition_complete",
      "status" => "completed",
      "output" => [],
      "object" => "response",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
    })
  end

  defp model_error do
    FakeUpstream.json_response(
      %{
        "error" => %{
          "code" => "model_not_found",
          "type" => "invalid_request_error",
          "param" => "model"
        }
      },
      404
    )
  end
end
