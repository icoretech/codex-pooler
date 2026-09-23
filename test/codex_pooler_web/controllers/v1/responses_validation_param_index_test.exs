defmodule CodexPoolerWeb.V1.ResponsesValidationParamIndexTest do
  # Lite puts the tool manifest (and the instructions message) in front of the
  # client's input, so the provider names an item by its upstream position:
  # iCoreTech rev 23 answered a Lite client `input[2].id` for the item it sent
  # as `input[1]` (findings#254 row 254-61). The relayed param must name the
  # client's own position, or drop the index when no client item sits there;
  # the attempt keeps the provider's path. Each case asserts that the item the
  # provider names really sits at that upstream position, so the fixture's
  # param is the one a provider would send for that request.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @rejected_id "message_x"

  for {label, mode, extra, provider_index, provider_path, client_param} <- [
        {"Lite without instructions", "lite", %{}, 2, ".id", "input[1].id"},
        {"Lite with instructions", "lite", %{"instructions" => "Answer briefly."}, 3, ".id", "input[1].id"},
        {"Lite naming the Pooler's tool manifest", "lite", %{}, 0, ".tools", "input[].tools"},
        {"Full", "full", %{}, 1, ".id", "input[1].id"}
      ] do
    @tag mode: mode, extra: extra, provider_index: provider_index, provider_path: provider_path, client_param: client_param
    test "/v1/responses #{label}: the relayed param names the client's position", %{conn: conn} = context do
      provider_param = "input[#{context.provider_index}]#{context.provider_path}"
      {upstream, setup} = rejecting_setup(provider_param, context.mode)

      response =
        conn
        |> auth(setup)
        |> post("/v1/responses", Map.merge(%{"model" => setup.model.exposed_model_id, "input" => client_input(), "stream" => true}, context.extra))

      assert json_response(response, 400)["error"] == %{
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => context.client_param,
               "message" => "upstream rejected parameter #{context.client_param} (invalid_value)"
             }

      assert_provider_names_the_item!(upstream, context.provider_index, context.provider_path)
      assert attempt_rejection_param!(setup) == provider_param
    end
  end

  test "native /backend-api/codex/responses Lite: the streaming answer names the client's position", %{conn: conn} do
    {upstream, setup} = rejecting_setup("input[2].id", "lite")

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => client_input(), "stream" => true})

    assert json_response(response, 400)["error"]["param"] == "input[1].id"
    assert_provider_names_the_item!(upstream, 2, ".id")
    assert attempt_rejection_param!(setup) == "input[2].id"
  end

  defp rejecting_setup(provider_param, mode) do
    error = %{"type" => "invalid_request_error", "code" => "invalid_value", "message" => "Invalid '#{provider_param}': '#{@rejected_id}'.", "param" => provider_param}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => error}})
        ])
      )

    setup = gateway_setup(upstream)
    put_mode!(setup, mode)
    {upstream, setup}
  end

  defp client_input do
    [
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "first"}]},
      %{"type" => "message", "role" => "assistant", "id" => @rejected_id, "content" => [%{"type" => "output_text", "text" => "earlier answer"}]},
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "second"}]}
    ]
  end

  defp assert_provider_names_the_item!(upstream, index, path) do
    assert :ok = FakeUpstream.verify!(upstream)
    assert [captured] = FakeUpstream.requests(upstream)
    item = Enum.at(captured.json["input"], index)

    case path do
      ".id" -> assert item["id"] == @rejected_id
      ".tools" -> assert item["type"] == "additional_tools"
    end
  end

  defp attempt_rejection_param!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    attempt.response_metadata["rejection_error_param"]
  end

  defp put_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: mode,
      created_at: timestamp,
      updated_at: timestamp
    })
  end
end
