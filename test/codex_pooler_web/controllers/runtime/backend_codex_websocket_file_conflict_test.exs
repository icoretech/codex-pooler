defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketFileConflictTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  # `input_image` arms: a bridged image `file_id` is held by one upstream account
  # like an `input_file` (findings#258 row 258-11).
  for path <- ["/backend-api/codex/responses", "/v1/responses"],
      scenario <- [:pending, :mixed_assignments, :candidate_mismatch, :session_pin],
      part_type <- ["input_file", "input_image"] do
    @tag file_path: path, file_scenario: scenario, part_type: part_type
    test "#{path} rejects #{scenario} #{part_type} files on the wire without dispatch or reservation", %{
      file_path: path,
      file_scenario: scenario,
      part_type: part_type
    } do
      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence(
            List.duplicate(
              FakeUpstream.expect_request(
                method: "WEBSOCKET",
                respond:
                  FakeUpstream.websocket_text_frames([
                    CodexPooler.JSON.encode!(%{
                      "type" => "response.completed",
                      "response" => %{
                        "id" => "resp_file_control",
                        "status" => "completed",
                        "output" => [],
                        "usage" => %{
                          "input_tokens" => 1,
                          "output_tokens" => 1,
                          "total_tokens" => 2
                        }
                      }
                    })
                  ])
              ),
              if(scenario == :session_pin, do: 2, else: 1)
            )
          )
        )

      setup = gateway_setup(upstream, model_metadata: %{"input_modalities" => ["text", "image"]})
      other = gateway_upstream(setup.pool, upstream, "synthetic-other-token", compact?: false)
      prime_routing_quota!(other.identity)

      ready =
        response_affinity_file_fixture(setup, setup.assignment, setup.identity,
          file_id: "file-ready-#{System.unique_integer([:positive])}",
          status: "uploaded",
          finalize_status: "succeeded"
        )

      rejected =
        response_affinity_file_fixture(setup, other.assignment, other.identity,
          file_id: "file-rejected-#{System.unique_integer([:positive])}",
          status: if(scenario == :pending, do: "pending_upload", else: "uploaded"),
          finalize_status: if(scenario == :pending, do: "pending", else: "succeeded")
        )

      model = put_model_source_assignments!(setup.model, [setup.assignment])
      setup = %{setup | model: model}

      port = start_public_endpoint!()

      headers =
        if path == "/v1/responses",
          do: [{"openai-beta", "responses_websockets=2026-02-06"}],
          else: []

      turn_state = "files-#{System.unique_integer([:positive])}"

      {conn, websocket, ref, _headers} =
        public_websocket_connect_with_request_headers!(
          port,
          setup,
          turn_state,
          path,
          headers
        )

      on_exit(fn -> Mint.HTTP.close(conn) end)

      {conn, websocket, ref} =
        if scenario == :session_pin do
          {conn, websocket} =
            public_websocket_send_text!(conn, websocket, ref, payload(setup, part_type, [ready.file_id]))

          {conn, _websocket} = receive_completed(conn, websocket, ref)

          await_pinned!(
            setup.pool.id,
            setup.assignment.id,
            System.monotonic_time(:millisecond) + 15_000
          )

          assert {:ok, _} = Mint.HTTP.close(conn)

          {conn, websocket, ref, _headers} =
            public_websocket_connect_with_request_headers!(port, setup, turn_state, path, headers)

          on_exit(fn -> Mint.HTTP.close(conn) end)
          {conn, websocket, ref}
        else
          {conn, websocket, ref}
        end

      prior_sends = length(FakeUpstream.requests(upstream))

      ids =
        if scenario == :mixed_assignments,
          do: [ready.file_id, rejected.file_id],
          else: [rejected.file_id]

      {{conn, websocket, frame}, logs} =
        with_log(fn ->
          {conn, websocket} =
            public_websocket_send_text!(conn, websocket, ref, payload(setup, part_type, ids))

          public_websocket_receive_text!(conn, websocket, ref)
        end)

      error = CodexPooler.JSON.decode!(frame)
      expected = if scenario == :pending, do: "file_not_ready", else: "file_assignment_conflict"
      assert logs =~ "reason_code=#{expected}"

      assert %{
               "type" => "error",
               "status" => 409,
               "error" => %{
                 "code" => ^expected,
                 "type" => "invalid_request_error",
                 "param" => "file_id"
               }
             } = error

      refute Map.has_key?(error["error"], "recovery_kind")
      assert length(FakeUpstream.requests(upstream)) == prior_sends

      assert [denied] =
               Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "rejected"))

      assert denied.response_status_code == 409
      assert denied.last_error_code == expected
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^denied.id), :count) ==
               0

      {conn, websocket} =
        public_websocket_send_text!(conn, websocket, ref, payload(setup, part_type, [ready.file_id]))

      {conn, _websocket} = receive_completed(conn, websocket, ref)
      assert length(FakeUpstream.requests(upstream)) == prior_sends + 1
      assert FakeUpstream.http_request_count(upstream) == 0
      assert :ok = FakeUpstream.verify!(upstream)
      assert {:ok, _} = Mint.HTTP.close(conn)
    end
  end

  defp await_pinned!(pool_id, assignment_id, deadline) do
    if Repo.exists?(
         from(s in CodexSession,
           where: s.pool_id == ^pool_id and s.pool_upstream_assignment_id == ^assignment_id
         )
       ) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "successful file request did not publish its session assignment"

      receive do
      after
        10 -> await_pinned!(pool_id, assignment_id, deadline)
      end
    end
  end

  defp payload(setup, part_type, ids) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => Enum.map(ids, &%{"type" => part_type, "file_id" => &1})
        }
      ]
    })
  end

  defp receive_completed(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "response.completed"} -> {conn, websocket}
      %{"type" => "error"} = error -> flunk("file control failed: #{error["error"]["code"]}")
      _event -> receive_completed(conn, websocket, ref)
    end
  end
end
