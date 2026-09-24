defmodule CodexPoolerWeb.Runtime.BackendCodexInputImageFileAffinityTest do
  # A Responses `input_image` may reference an image by `file_id` (the released
  # Codex app-server forwards a host-supplied `fileId` as `input_image.file_id`,
  # and tool outputs carry the same shape). A file the Pool bridged lives in one
  # upstream account, so the request has to reach the assignment that holds it,
  # exactly as an `input_file` reference does; an id the Pool never bridged is
  # forwarded unpinned (findings#258 row 258-11). The websocket arms of the same
  # rule live in `backend_codex_websocket_file_conflict_test.exs`.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @vision_metadata %{"input_modalities" => ["text", "image"]}

  for path <- ["/backend-api/codex/responses", "/v1/responses"],
      scenario <- [:pending, :candidate_mismatch] do
    @tag file_path: path, file_scenario: scenario
    test "#{path} refuses a #{scenario} input_image file_id before reservation or dispatch", %{
      conn: conn,
      file_path: path,
      file_scenario: scenario
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_should_not_run"}))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      other = gateway_upstream(setup.pool, upstream, "synthetic-other-token", compact?: false)
      prime_routing_quota!(other.identity)

      {assignment, identity, status, finalize_status} =
        case scenario do
          :pending -> {setup.assignment, setup.identity, "pending_upload", "pending"}
          :candidate_mismatch -> {other.assignment, other.identity, "uploaded", "succeeded"}
        end

      file =
        response_affinity_file_fixture(setup, assignment, identity,
          file_id: "file-image-#{scenario}-#{System.unique_integer([:positive])}",
          filename: "sample.png",
          status: status,
          finalize_status: finalize_status
        )

      setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment])}

      conn = conn |> auth(setup) |> post(path, image_payload(setup, file.file_id))

      expected = if scenario == :pending, do: "file_not_ready", else: "file_assignment_conflict"

      assert %{"error" => %{"code" => ^expected, "param" => "file_id"}} = json_response(conn, 409)
      assert FakeUpstream.count(upstream) == 0

      assert [denied] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert denied.status == "rejected"
      assert denied.last_error_code == expected
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied.id), :count) == 0
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^denied.id), :count) == 0
    end
  end

  for path <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag file_path: path
    test "#{path} routes a bridged input_image file_id to the assignment holding the file", %{
      conn: conn,
      file_path: path
    } do
      held_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_held", "object" => "response"}))
      other_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_other", "object" => "response"}))
      setup = gateway_setup(other_upstream, model_metadata: @vision_metadata)
      held = gateway_upstream(setup.pool, held_upstream, "synthetic-held-token", compact?: false)
      prime_routing_quota!(held.identity)

      file =
        response_affinity_file_fixture(setup, held.assignment, held.identity,
          file_id: "file-image-held-#{System.unique_integer([:positive])}",
          filename: "sample.png",
          status: "uploaded",
          finalize_status: "succeeded"
        )

      setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, held.assignment])}
      use_routing_strategy!(setup.pool, "bridge_ring", 2)

      # The ring would pick the assignment without the file; only the file
      # affinity can move the request to the one holding it.
      ring_seed = seed_preferring_assignment([setup.assignment.id, held.assignment.id], setup.assignment.id)

      conn =
        conn
        |> put_req_header("x-request-id", ring_seed)
        |> auth(setup)
        |> post(path, image_payload(setup, file.file_id))

      assert %{"id" => "resp_image_held"} = json_response(conn, 200)
      assert FakeUpstream.count(other_upstream) == 0
      assert [captured] = FakeUpstream.requests(held_upstream)
      assert [%{"content" => [%{"type" => "input_text"}, image]}] = captured.json["input"]
      assert image["type"] == "input_image"
      assert image["file_id"] == file.file_id
    end

    @tag file_path: path
    test "#{path} forwards an input_image file_id the Pool never bridged without pinning it", %{
      conn: conn,
      file_path: path
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_unbridged", "object" => "response"}))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      file_id = "file-image-unbridged-#{System.unique_integer([:positive])}"

      conn = conn |> auth(setup) |> post(path, image_payload(setup, file_id))

      assert %{"id" => "resp_image_unbridged"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert [%{"content" => [%{"type" => "input_text"}, image]}] = captured.json["input"]
      assert image["file_id"] == file_id
    end
  end

  for path <- ["/backend-api/codex/responses", "/v1/responses"], mode <- ["full", "lite"] do
    @tag file_path: path, serving_mode: mode
    test "#{path} keeps a message and a tool-output input_image file_id on a #{mode} model", %{
      conn: conn,
      file_path: path,
      serving_mode: mode
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_#{mode}", "object" => "response"}))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
      message_file_id = "file-image-message-#{System.unique_integer([:positive])}"
      tool_file_id = "file-image-tool-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> auth(setup)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_image", "file_id" => message_file_id, "detail" => "high"}]
            },
            %{"type" => "function_call", "call_id" => "call_image", "name" => "view_image", "arguments" => "{}"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_image",
              "output" => [%{"type" => "input_image", "file_id" => tool_file_id, "detail" => "high"}]
            }
          ]
        })

      assert %{"id" => "resp_image_" <> _} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)

      images =
        for item <- captured.json["input"],
            part <- List.wrap(item["content"]) ++ List.wrap(if(is_list(item["output"]), do: item["output"])),
            is_map(part) and part["type"] == "input_image",
            do: part

      # Lite removes the `detail` compatibility hint, as the released client does
      # for a Responses Lite model; Full forwards it from a message and from a
      # tool output alike, which the provider reads there (findings#206 row
      # 206-476). The file reference itself is never rewritten.
      expected_detail = if mode == "lite", do: nil, else: "high"

      assert [
               %{"file_id" => ^message_file_id} = message_image,
               %{"file_id" => ^tool_file_id} = tool_image
             ] = images

      assert message_image["detail"] == expected_detail
      assert tool_image["detail"] == expected_detail
      refute Map.has_key?(message_image, "image_url")
      refute Map.has_key?(tool_image, "image_url")
    end
  end

  # The provider validates `detail` on every input image, a tool-output one
  # included (400 `invalid_value` on `input[2].output[1].detail`, probed
  # 2026-09-24), so `/v1` refuses a value outside its enum before reservation
  # or dispatch, with the same code and field path, on either serving mode
  # (findings#206 row 206-476).
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "/v1/responses refuses a tool-output input_image detail outside the provider enum on a #{mode} model", %{
      conn: conn,
      serving_mode: mode
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_image_should_not_run"}))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic image question"}]},
            %{"type" => "function_call", "call_id" => "call_image", "name" => "view_image", "arguments" => "{}"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_image",
              "output" => [%{"type" => "input_text", "text" => "loaded"}, %{"type" => "input_image", "file_id" => "file-image-bogus", "detail" => "bogus"}]
            }
          ]
        })

      assert %{"error" => %{"type" => "invalid_request_error", "code" => "invalid_value", "param" => "input[2].output[1].detail", "message" => message}} = json_response(conn, 400)
      assert message =~ "low, high, auto, original"
      refute message =~ "bogus"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end
  end

  defp image_payload(setup, file_id) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "synthetic image question"},
            %{"type" => "input_image", "file_id" => file_id, "detail" => "high"}
          ]
        }
      ]
    }
  end
end
