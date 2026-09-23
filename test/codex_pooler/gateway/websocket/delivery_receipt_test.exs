defmodule CodexPooler.Gateway.Websocket.DeliveryReceiptTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  import CodexPooler.PoolerFixtures,
    only: [
      active_api_key_fixture: 0,
      active_upstream_assignment_fixture: 1,
      request_fixture: 2,
      attempt_fixture: 3
    ]

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Websocket.DeliveryReceipt
  alias CodexPooler.Repo

  @pushed_at ~U[2026-09-10 23:27:46.108000Z]

  test "build keeps the receipt bounded to the fixed vocabulary" do
    receipt =
      DeliveryReceipt.build(%{
        outcome: "delivered",
        terminal_class: "response.completed",
        pushed_at: @pushed_at,
        frames_after_visible: 3
      })

    assert receipt == %{
             "outcome" => "delivered",
             "terminal_class" => "response.completed",
             "pushed_at" => "2026-09-10T23:27:46.108Z",
             "frames_after_visible" => 3,
             "transport" => "websocket"
           }

    assert DeliveryReceipt.build(%{outcome: "aborted"}) == %{
             "outcome" => "aborted",
             "terminal_class" => "none",
             "pushed_at" => nil,
             "frames_after_visible" => 0,
             "transport" => "websocket"
           }

    unknown =
      DeliveryReceipt.build(%{
        outcome: "prompt text leaked",
        terminal_class: "Authorization: Bearer sk-secret",
        frames_after_visible: -4,
        transport: "carrier pigeon"
      })

    assert unknown["outcome"] == "unknown"
    assert unknown["terminal_class"] == "unknown"
    assert unknown["frames_after_visible"] == 0
    assert unknown["transport"] == "websocket"
    refute inspect(unknown) =~ "secret"
    refute inspect(unknown) =~ "prompt"
  end

  # findings#232 row 232-203: the released Codex client resends the identical
  # request after a cut that showed it only these frames, and a different one
  # after a completed item; the receipt ranks what the socket pushed.
  test "frame_class ranks each pushed frame by what the released client does with it" do
    classes =
      for type <- [
            "response.created",
            "response.in_progress",
            "response.queued",
            "response.metadata",
            "codex.response.metadata",
            "response.output_item.added",
            "response.content_part.added",
            "response.reasoning_summary_part.added",
            "response.output_text.delta",
            "response.function_call_arguments.delta",
            "response.reasoning_summary_text.delta",
            "response.output_text.done",
            "response.content_part.done",
            "response.web_search_call.in_progress",
            "response.output_item.done",
            "response.completed",
            "response.failed",
            "response.incomplete",
            "error"
          ],
          into: %{} do
        {type, DeliveryReceipt.frame_class(CodexPooler.JSON.encode!(%{"type" => type}))}
      end

    assert classes == %{
             "response.created" => "lifecycle",
             "response.in_progress" => "lifecycle",
             "response.queued" => "lifecycle",
             "response.metadata" => "lifecycle",
             "codex.response.metadata" => "lifecycle",
             "response.output_item.added" => "item_added",
             "response.content_part.added" => "part_added",
             "response.reasoning_summary_part.added" => "part_added",
             "response.output_text.delta" => "delta",
             "response.function_call_arguments.delta" => "delta",
             "response.reasoning_summary_text.delta" => "delta",
             "response.output_text.done" => "other",
             "response.content_part.done" => "other",
             "response.web_search_call.in_progress" => "other",
             "response.output_item.done" => "item_done",
             "response.completed" => "terminal",
             "response.failed" => "terminal",
             "response.incomplete" => "terminal",
             "error" => "terminal"
           }

    assert DeliveryReceipt.frame_class("{not json") == "other"
    assert DeliveryReceipt.frame_class(CodexPooler.JSON.encode!(%{"delta" => "no type"})) == "other"
    assert DeliveryReceipt.frame_class(:not_binary) == "other"

    sse = "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\"}\n\nevent: response.output_item.done\ndata: {\"type\":\"response.output_item.done\"}\n\n"
    assert DeliveryReceipt.frame_class(sse) == "item_done"

    assert DeliveryReceipt.resendable_frame_classes() == ~w(lifecycle item_added part_added delta)
    assert Enum.all?(DeliveryReceipt.resendable_frame_classes(), &(&1 in DeliveryReceipt.frame_classes()))
  end

  test "higher_frame_class keeps the highest class pushed, and the receipt carries it only when classified" do
    highest = Enum.reduce(~w(lifecycle delta item_added lifecycle), nil, &DeliveryReceipt.higher_frame_class(&2, &1))
    assert highest == "delta"
    assert DeliveryReceipt.higher_frame_class("delta", "other") == "other"
    assert DeliveryReceipt.higher_frame_class("item_done", "delta") == "item_done"
    assert DeliveryReceipt.higher_frame_class("terminal", "item_done") == "terminal"
    assert DeliveryReceipt.higher_frame_class("prompt text", "delta") == "other"

    assert DeliveryReceipt.build(%{outcome: "aborted", highest_frame_class: "delta"})["highest_frame_class"] == "delta"
    assert DeliveryReceipt.build(%{outcome: "aborted", highest_frame_class: nil})["highest_frame_class"] == "none"
    assert DeliveryReceipt.build(%{outcome: "aborted", highest_frame_class: "Bearer sk-secret"})["highest_frame_class"] == "other"
    refute Map.has_key?(DeliveryReceipt.build(%{outcome: "aborted", transport: "http_sse"}), "highest_frame_class")
  end

  test "terminal_class maps provider terminal outcomes onto the fixed vocabulary" do
    completed = ~s({"type":"response.completed","response":{"id":"resp_class_completed"}})
    legacy = ~s({"id":"resp_class_legacy","object":"response"})

    failed =
      ~s({"type":"response.failed","response":{"id":"resp_class_failed","error":{"code":"server_error"}}})

    error = ~s({"type":"error","error":{"code":"server_error","message":"synthetic"}})
    delta = ~s({"type":"response.output_text.delta","delta":"partial"})

    assert DeliveryReceipt.terminal_class(completed) == "response.completed"
    assert DeliveryReceipt.terminal_class(legacy) == "response.completed"
    assert DeliveryReceipt.terminal_class(failed) == "response.failed"
    assert DeliveryReceipt.terminal_class(error) == "error"
    assert DeliveryReceipt.terminal_class(delta) == nil
    assert DeliveryReceipt.terminal_class("not json at all") == nil
  end

  test "persist merges the receipt into the attempt row without dropping other metadata" do
    %{attempt: attempt, request: request} = fixture()

    receipt =
      DeliveryReceipt.build(%{
        outcome: "delivered",
        terminal_class: "response.completed",
        pushed_at: @pushed_at,
        frames_after_visible: 2
      })

    assert :ok = DeliveryReceipt.persist(attempt.id, receipt)

    persisted = Repo.get!(Attempt, attempt.id)

    assert persisted.response_metadata["upstream_websocket_connection"] == %{
             "generation" => 1,
             "reused" => true
           }

    assert persisted.response_metadata["downstream_delivery"] == receipt
    assert persisted.status == attempt.status
    assert persisted.request_id == request.id

    assert {:error, :attempt_not_found} =
             DeliveryReceipt.persist(Ecto.UUID.generate(), receipt)
  end

  test "record logs one sanitized info line and persists the receipt" do
    %{attempt: attempt, request: request} = fixture()

    receipt =
      DeliveryReceipt.build(%{
        outcome: "delivered",
        terminal_class: "response.completed",
        pushed_at: @pushed_at,
        frames_after_visible: 5
      })

    context = %{
      attempt_id: attempt.id,
      request_id: request.id,
      codex_session_id: "session prompt=leak\nAuthorization"
    }

    logs = with_info_log(fn -> assert :ok = DeliveryReceipt.record(context, receipt) end)

    assert logs =~
             "websocket downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=redacted outcome=delivered " <>
               "terminal_class=response.completed frames_after_visible=5"

    refute logs =~ "Authorization"
    assert Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"] == receipt

    missing = Map.put(context, :attempt_id, nil)

    logs = with_info_log(fn -> assert :ok = DeliveryReceipt.record(missing, receipt) end)
    assert logs =~ "websocket downstream terminal pushed request_id=#{request.id}"
  end

  test "record renders the receipt transport as the log prefix" do
    %{attempt: attempt, request: request} = fixture()

    receipt =
      DeliveryReceipt.build(%{
        outcome: "delivered",
        terminal_class: "response.failed",
        pushed_at: @pushed_at,
        frames_after_visible: 2,
        transport: "http_sse"
      })

    assert receipt["transport"] == "http_sse"

    context = %{attempt_id: attempt.id, request_id: request.id, codex_session_id: nil}

    logs = with_info_log(fn -> assert :ok = DeliveryReceipt.record(context, receipt) end)

    assert logs =~
             "http_sse downstream terminal pushed request_id=#{request.id} " <>
               "codex_session_id=none outcome=delivered " <>
               "terminal_class=response.failed frames_after_visible=2"

    refute logs =~ "websocket downstream terminal pushed"
    assert Repo.get!(Attempt, attempt.id).response_metadata["downstream_delivery"] == receipt

    missing = Map.put(context, :attempt_id, Ecto.UUID.generate())
    logs = with_info_log(fn -> assert :ok = DeliveryReceipt.record(missing, receipt) end)
    assert logs =~ "http_sse downstream delivery receipt not persisted"
    assert logs =~ "reason=attempt_not_found"
  end

  test "record survives a missing attempt row with one bounded warning" do
    receipt = DeliveryReceipt.build(%{outcome: "aborted"})

    context = %{
      attempt_id: Ecto.UUID.generate(),
      request_id: Ecto.UUID.generate(),
      codex_session_id: Ecto.UUID.generate()
    }

    logs = with_info_log(fn -> assert :ok = DeliveryReceipt.record(context, receipt) end)
    assert logs =~ "websocket downstream delivery receipt not persisted"
    assert logs =~ "reason=attempt_not_found"
  end

  defp fixture do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = active_upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        transport: "websocket",
        request_metadata: %{"codex_session_id" => Ecto.UUID.generate()}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        transport: "websocket",
        response_metadata: %{
          "upstream_websocket_connection" => %{"generation" => 1, "reused" => true}
        }
      })

    %{request: request, attempt: attempt}
  end

  defp with_info_log(fun) do
    previous_level = Logger.level()
    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end
end
