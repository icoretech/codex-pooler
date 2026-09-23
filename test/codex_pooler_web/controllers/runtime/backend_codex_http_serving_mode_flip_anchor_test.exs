defmodule CodexPoolerWeb.Runtime.BackendCodexHttpServingModeFlipAnchorTest do
  # A native HTTP tool-output continuation keeps `previous_response_id`, but it
  # is not tied to an upstream connection that could remember the Full/Lite
  # dialect of the context it continues. Lite sends its tool manifest and
  # instructions message only on a request that opens a context (findings#232
  # row 232-184), so after the Pool flips the model from Full to Lite the first
  # anchored continuation would reach the provider with no tools and no base
  # instructions. The dialect is recorded on the alias of the response when it
  # completes, and an anchored Lite request whose anchor was served under Full
  # carries the prefix (row 232-270).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3, set_model_serving_mode!: 4]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Repo

  @tools [%{"type" => "function", "name" => "sample_lookup", "parameters" => %{"type" => "object", "properties" => %{}, "required" => []}}]
  @tool_output %{"type" => "function_call_output", "call_id" => "call_http_flip_sample", "output" => "sample output"}

  for {anchor_mode, continuation_mode} <- [{"full", "lite"}, {"lite", "lite"}, {"lite", "full"}, {"full", "full"}] do
    @tag :serving_mode_flip_anchor
    test "native HTTP tool-output continuation anchored on a #{anchor_mode} response and served #{continuation_mode}", %{conn: conn} do
      anchor_mode = unquote(anchor_mode)
      continuation_mode = unquote(continuation_mode)
      anchor_id = "resp_http_flip_anchor_#{anchor_mode}_#{continuation_mode}"
      continuation_id = "resp_http_flip_continuation_#{anchor_mode}_#{continuation_mode}"

      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              json: [valid: true, forbidden: ["previous_response_id"]],
              respond: completed_sse(anchor_id)
            ),
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"previous_response_id" => anchor_id}],
              respond: completed_sse(continuation_id)
            )
          ])
        )

      setup = gateway_setup(upstream)
      scope = model_serving_scope()
      revision = set_model_serving_mode!(scope, setup, anchor_mode)
      session = "http-flip-#{System.unique_integer([:positive])}"

      first = post_turn(conn, setup, session, %{"input" => native_text_input("anchor")})
      assert response(first, 200) =~ anchor_id

      if continuation_mode != anchor_mode, do: set_model_serving_mode!(scope, setup, continuation_mode, revision)

      second = post_turn(conn, setup, session, %{"previous_response_id" => anchor_id, "input" => [@tool_output]})
      assert response(second, 200) =~ continuation_id

      assert [_anchor_request, continuation_request] = FakeUpstream.requests(upstream)
      upstream_json = continuation_request.json
      assert upstream_json["previous_response_id"] == anchor_id

      case {anchor_mode, continuation_mode} do
        {"full", "lite"} ->
          # The context holds no manifest and no instructions message: the
          # anchored request opens them.
          assert [
                   %{"type" => "additional_tools", "role" => "developer", "tools" => [%{"name" => "sample_lookup"}]},
                   %{"type" => "message", "role" => "developer"},
                   @tool_output
                 ] = upstream_json["input"]

          refute Map.has_key?(upstream_json, "tools")
          refute Map.has_key?(upstream_json, "instructions")

        {"lite", "lite"} ->
          # The context already holds the prefix (row 232-184).
          assert upstream_json["input"] == [@tool_output]
          refute Map.has_key?(upstream_json, "tools")
          refute Map.has_key?(upstream_json, "instructions")

        {_anchor_mode, "full"} ->
          # Full carries tools and instructions at top level whatever the
          # context holds.
          assert upstream_json["input"] == [@tool_output]
          assert [%{"name" => "sample_lookup"}] = upstream_json["tools"]
          assert upstream_json["instructions"] == "synthetic base instructions"
      end

      requests = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
      assert Enum.map(requests, & &1.status) == ["succeeded", "succeeded"]
      assert Enum.map(requests, & &1.request_metadata["routing"]["model_serving_mode"]) == [anchor_mode, continuation_mode]
      refute inspect(Enum.map(requests, & &1.request_metadata)) =~ anchor_id

      # Each response's alias records the dialect it was served in, and the
      # anchor keeps its own after the continuation re-registered it.
      assert alias_serving_mode(setup, anchor_id) == anchor_mode
      assert alias_serving_mode(setup, continuation_id) == continuation_mode
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  defp post_turn(conn, setup, session, attrs) do
    body =
      Map.merge(
        %{"model" => setup.model.exposed_model_id, "instructions" => "synthetic base instructions", "tools" => @tools, "stream" => true},
        attrs
      )

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("session-id", session)
    |> post("/backend-api/codex/responses", body)
  end

  defp completed_sse(response_id) do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "output" => [],
           "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
         }
       }}
    ])
  end

  defp alias_serving_mode(setup, response_id) do
    alias_hash = :crypto.hash(:sha256, response_id)

    Repo.one!(
      from(alias_record in BridgeSessionAlias,
        where:
          alias_record.pool_id == ^setup.pool.id and alias_record.alias_kind == "previous_response_id" and
            alias_record.alias_hash == ^alias_hash,
        select: alias_record.metadata
      )
    )
    |> Map.get("serving_mode")
  end
end
