defmodule CodexPoolerWeb.V1.PolicyDenialErrorTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Repo
  alias CodexPoolerWeb.PublicGatewayResult

  # A Pooler-authored policy decision used to reach `/v1` as
  # `403 server_error "upstream request failed"`, blaming the upstream for a
  # denial the upstream never saw, while `/backend-api/codex/*` rendered the
  # real code and message (findings#221). Upstream-originated 401/403/429
  # stay redacted; `upstream_validation_rejection_test.exs` pins that side.
  # Control through the public renderer itself: an upstream-shaped 401/403
  # gateway error carrying provider wording, and even one of the five codes,
  # is redacted unless it carries the Pooler's own marker (findings#221).
  test "the public renderer redacts unmarked gateway errors and renders marked policy denials",
       %{conn: conn} do
    for {status, code} <- [
          {403, "account_deactivated"},
          {403, "model_not_allowed"},
          {401, "api_key_disabled"}
        ] do
      response =
        conn
        |> Phoenix.ConnTest.recycle()
        |> PublicGatewayResult.send(
          {:error, %{status: status, code: code, message: "synthetic provider wording", param: nil}},
          &Function.identity/1
        )

      assert %{"error" => error} = json_response(response, status)
      assert error["type"] == "server_error"
      assert error["message"] == "upstream request failed"
      refute response.resp_body =~ "synthetic provider wording"
    end

    marked =
      conn
      |> Phoenix.ConnTest.recycle()
      |> PublicGatewayResult.send(
        {:error,
         Denials.policy_error(
           403,
           "model_not_allowed",
           "api key is not allowed to use this model"
         )},
        &Function.identity/1
      )

    assert json_response(marked, 403) == %{
             "error" => %{
               "code" => "model_not_allowed",
               "type" => "invalid_request_error",
               "message" => "api key is not allowed to use this model",
               "param" => nil
             }
           }
  end

  for {endpoint, payload_fun} <- [
        {"/v1/responses",
         quote(
           do: fn model, stream? ->
             %{"model" => model, "input" => "synthetic policy denial", "stream" => stream?}
           end
         )},
        {"/v1/chat/completions",
         quote(
           do: fn model, stream? ->
             %{
               "model" => model,
               "messages" => [%{"role" => "user", "content" => "synthetic policy denial"}],
               "stream" => stream?
             }
           end
         )}
      ],
      stream? <- [false, true] do
    test "#{endpoint} stream=#{stream?} renders a model policy denial with its own code and message",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)

      setup.api_key
      |> Ecto.Changeset.change(allowed_model_identifiers: ["unrelated-model"])
      |> Repo.update!()

      payload = unquote(payload_fun).(setup.model.exposed_model_id, unquote(stream?))
      response = conn |> auth(setup) |> post(unquote(endpoint), payload)

      # `400`, like the Codex backend's refusal of a model the account cannot
      # serve; neither OpenAI SDK retries it (findings#206 row 206-438).
      assert json_response(response, 400) == %{
               "error" => %{
                 "code" => "model_not_allowed",
                 "type" => "invalid_request_error",
                 "message" => "api key is not allowed to use this model",
                 "param" => "model"
               }
             }

      refute response.resp_body =~ "upstream request failed"
      refute response.resp_body =~ "server_error"
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(from(a in Attempt), :count) == 0
      assert Repo.aggregate(from(l in LedgerEntry), :count) == 0

      # The denial is still accounted as a denied request, not as dispatch.
      assert [%Request{status: "rejected"}] =
               Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    end
  end
end
