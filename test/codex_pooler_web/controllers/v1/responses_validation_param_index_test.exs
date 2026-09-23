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

  # The non-streaming native answer used to relay the provider body verbatim:
  # the provider's `input[2].id` (a position the client never sent) and its
  # message quoting the rejected value. It now answers the same Pooler-authored
  # error as the streaming answer (findings#254 row 254-54).
  test "native /backend-api/codex/responses Lite: the non-streaming answer names the client's position", %{conn: conn} do
    {upstream, setup} = rejecting_setup("input[2].id", "lite")

    response =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => client_input()})

    assert json_response(response, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => "input[1].id",
               "message" => "upstream rejected parameter input[1].id (invalid_value)"
             }
           }

    refute response.resp_body =~ @rejected_id
    assert_provider_names_the_item!(upstream, 2, ".id")
    assert attempt_rejection_param!(setup) == "input[2].id"
  end

  # A Chat Completions client sent `messages`, which the adapter rebuilds into
  # Responses input items (not one item per message), so no `input[N]` path
  # names anything the client sent: the relayed param names the client field
  # that carried the refused item (findings#254 row 254-54).
  for mode <- ["lite", "full"] do
    @tag mode: mode
    test "/v1/chat/completions #{mode}: a refused input item is relayed as the client's messages field", %{conn: conn, mode: mode} do
      {_upstream, setup} = rejecting_setup("input[2].content", mode)

      response =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "first"}, %{"role" => "assistant", "content" => "earlier answer"}, %{"role" => "user", "content" => "second"}]})

      assert json_response(response, 400)["error"] == %{
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => "messages",
               "message" => "upstream rejected parameter messages (invalid_value)"
             }

      assert attempt_rejection_param!(setup) == "input[2].content"
    end
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
