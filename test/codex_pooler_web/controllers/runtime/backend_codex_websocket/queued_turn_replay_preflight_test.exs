defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.QueuedTurnReplayPreflightTest do
  # A released-client turn sent while the socket still tracks the previous
  # turn's response task is queued (a tool continuation, or the first turn
  # right after a prewarm). With owner forwarding on, its dequeue asks the
  # owner's replay preflight only whether it may attach the replay binding:
  # any other answer, a refusal included, hands the frame to the ordinary
  # checks every turn meets with forwarding off (findings#232 row 232-181,
  # `record_model_denial: false`). That is why a queued later turn left no
  # `runtime_replay_preflight` line and, before `220eb3490`, served a model the
  # key had just been narrowed away from (findings#206 row 206-496, measured
  # with a bounded call trace). The preflight's refusal is not a separate
  # protection: every refusal it can raise is raised again by the ordinary
  # checks, from durable state. These arms pin that for the queued turn and
  # for the direct turn after it, on a three-turn socket. A key edit is written
  # here with its epoch advanced and no event, as the operator edit stores it
  # and a node that missed the event sees it.
  #
  # One node, native websocket `/backend-api/codex/responses`, owner forwarding
  # on and off, the Pool's serving mode forced to Full and to Lite, FakeUpstream,
  # the released client's turn frame and upgrade headers, synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @installation_id "00000000-0000-4000-8000-00000000c118"
  @context_window_id "00000000-0000-4000-8000-00000000c119"
  @turn_endpoint "/backend-api/codex/responses"
  @detection_timeout_ms 5_000
  @policy_close {:close, 1008, "api key is no longer active"}

  # The key edit is stored with its runtime epoch advanced (what the operator
  # edit writes since `220eb3490`) and without its event, so only the durable
  # fences can refuse the turn: this socket never hears of the edit.
  @changes [:narrow_models, :retire_model, :disable_pool]

  # `:before_send`: the change lands after turn 1's terminal, while its task is
  # still tracked, and turn 2 then arrives. `:while_queued`: turn 2 is already
  # queued when the change lands, so only the dequeue and the ordinary checks
  # after it can refuse it. Forwarding off has no queue for this frame.
  for change <- @changes,
      forwarding <- [:forwarded, :direct],
      mode <- ["full", "lite"],
      timing <- [:before_send, :while_queued],
      forwarding == :forwarded or timing == :before_send do
    @tag change: change, forwarding: forwarding, serving_mode: mode, timing: timing
    test "websocket #{forwarding} #{mode}: a later released-client turn is refused after #{change} (#{timing})", ctx do
      measured = run_three_turns(ctx.change, ctx.forwarding, ctx.serving_mode, ctx.timing)

      assert measured == expected(ctx.change, ctx.forwarding, ctx.timing),
             "measured #{inspect(measured)}"
    end
  end

  # turn 1 served; turn 2 (held behind turn 1's task) and turn 3 (direct)
  # refused by what the change durably says, the provider sees turn 1 only.
  defp expected(:narrow_models, _forwarding, _timing),
    do: %{turns: [{:served, "response.completed"}, {:closed, @policy_close}], upstream_requests: 1, rows: ["succeeded"]}

  defp expected(:disable_pool, _forwarding, _timing),
    do: %{turns: [{:served, "response.completed"}, {:closed, @policy_close}], upstream_requests: 1, rows: ["succeeded"]}

  defp expected(:retire_model, _forwarding, _timing),
    do: %{
      turns: [{:served, "response.completed"}, {:refused, "invalid_model"}, {:refused, "invalid_model"}],
      upstream_requests: 1,
      rows: ["succeeded", "rejected", "rejected"]
    }

  defp run_three_turns(change, forwarding, mode, timing) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()

    upstream =
      start_upstream(
        # provenance: observed released Codex 0.156.1 turn frame and upgrade headers (as replay_preflight_policy_denial_record_test.exs); only turn 1 reaches the provider, reply frames synthetic
        FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_p118_queued_1"))])
      )

    setup = gateway_setup(upstream, compact?: true)
    put_serving_mode!(setup, mode)
    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = connect!(port, setup, thread_id)
    hold = hold_turn_task_after_settlement!()

    turns =
      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, thread_id, 1))
        {conn, websocket, first} = receive_outcome!(conn, websocket, ref)
        assert_receive {^hold, :held, task, callers}, @detection_timeout_ms
        :telemetry.detach({__MODULE__, :turn_settlement_hold, hold})

        if timing == :before_send, do: apply_change!(change, setup)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, thread_id, 2))
        if timing == :while_queued, do: await_queued!(callers) && apply_change!(change, setup)
        send(task, {hold, :release})
        {conn, websocket, second} = receive_outcome!(conn, websocket, ref)

        case second do
          {:closed, _frame} ->
            [first, second]

          _answered ->
            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, thread_id, 3))
            {_conn, _websocket, third} = receive_outcome!(conn, websocket, ref)
            [first, second, third]
        end
      after
        Mint.HTTP.close(conn)
      end

    measured = %{turns: turns, upstream_requests: FakeUpstream.count(upstream), rows: setup.pool.id |> await_settled!(length(turns) - closed_count(turns)) |> Enum.map(& &1.status)}
    CodexPooler.TestDiagnostics.puts(fn -> "queued turn #{change} #{forwarding} #{mode} #{timing}: #{inspect(measured)}" end)
    measured
  end

  defp closed_count(turns), do: Enum.count(turns, &match?({:closed, _}, &1))

  defp apply_change!(:narrow_models, setup) do
    {1, _} =
      Repo.update_all(from(key in APIKey, where: key.id == ^setup.api_key.id),
        set: [allowed_model_identifiers: ["another-model-fixture"]],
        inc: [runtime_revocation_epoch: 1]
      )

    :ok
  end

  defp apply_change!(:retire_model, setup) do
    setup.model |> Ecto.Changeset.change(status: "retired") |> Repo.update!()
    :ok
  end

  defp apply_change!(:disable_pool, setup) do
    setup.pool |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
    :ok
  end

  # Holds the first response task that settles a websocket turn from here on
  # right after its settlement, outside any transaction, so its socket still
  # tracks it when the next frame arrives (as `backend_codex_websocket_pre_turn_compaction_cut_test.exs`).
  defp hold_turn_task_after_settlement! do
    hold = make_ref()
    handler_id = {__MODULE__, :turn_settlement_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    config = %{hold: hold, test: self(), claimed: :atomics.new(1, [])}
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :gateway, :stream, :outcome], &__MODULE__.hold_settled_turn_task/4, config)
    hold
  end

  @doc false
  def hold_settled_turn_task(_event, _measurements, %{outcome: "succeeded", downstream_transport: "websocket"}, %{hold: hold, test: test, claimed: claimed}) do
    if not Repo.in_transaction?() and :atomics.add_get(claimed, 1, 1) == 1 do
      send(test, {hold, :held, self(), Process.get(:"$callers", [])})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
  end

  def hold_settled_turn_task(_event, _measurements, _metadata, _config), do: :ok

  defp await_queued!(callers) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> Enum.any?(callers, &queued_turn?/1) end)
    |> Enum.reduce_while(nil, fn
      true, _acc -> {:halt, :ok}
      false, _acc -> if System.monotonic_time(:millisecond) >= deadline, do: flunk("turn 2 was never queued behind turn 1's task"), else: Process.sleep(5) && {:cont, nil}
    end)
  end

  defp queued_turn?(pid) do
    pid |> :sys.get_state(1_000) |> queued_frames(6) |> Enum.any?(&match?(%{endpoint: @turn_endpoint}, &1))
  catch
    :exit, _not_a_socket -> false
  end

  defp queued_frames(%{queued_response_payloads: queue}, _depth), do: :queue.to_list(queue)
  defp queued_frames(_term, 0), do: []
  defp queued_frames(%_{} = struct, depth), do: struct |> Map.from_struct() |> queued_frames(depth)
  defp queued_frames(map, depth) when is_map(map), do: Enum.flat_map(Map.values(map), &queued_frames(&1, depth - 1))
  defp queued_frames(tuple, depth) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&queued_frames(&1, depth - 1))
  defp queued_frames(_term, _depth), do: []

  # A turn's outcome: its terminal text frame, or the close frame that ends
  # the socket instead.
  defp receive_outcome!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            receive_outcome!(conn, websocket, ref)

          {:ok, conn, responses} ->
            {websocket, frames} =
              Enum.reduce(responses, {websocket, []}, fn
                {:data, ^ref, data}, {websocket, frames} ->
                  {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
                  {websocket, frames ++ decoded}

                _response, acc ->
                  acc
              end)

            case Enum.find_value(frames, &outcome/1) do
              nil -> receive_outcome!(conn, websocket, ref)
              outcome -> {conn, websocket, outcome}
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket frame receive failed: #{inspect(reason)}")
        end
    after
      @detection_timeout_ms -> flunk("timed out waiting for a turn outcome")
    end
  end

  defp outcome({:close, _code, _reason} = close), do: {:closed, close}

  defp outcome({:text, text}) do
    case CodexPooler.JSON.decode!(text) do
      %{"type" => "error", "error" => %{"code" => code}} -> {:refused, code}
      %{"type" => type} when type in ["response.completed", "response.failed"] -> {:served, type}
      _progress -> nil
    end
  end

  defp outcome(_frame), do: nil

  defp connect!(port, setup, thread_id) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  # The released client's turn frame: its turn metadata makes it
  # replay-eligible, so with forwarding on the owner's replay preflight is asked.
  defp frame(setup, thread_id, n) do
    turn_id = "#{thread_id}-turn-#{n}"
    window_id = "#{thread_id}:0"
    model = setup.model.exposed_model_id

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic queued turn #{n}"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => thread_id,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => window_id,
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "agent_name" => "/root",
            "context_window_id" => @context_window_id,
            "installation_id" => @installation_id,
            "request_kind" => "turn",
            "root_turn_id" => turn_id,
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => turn_id,
            "window_id" => window_id,
            "window_number" => 0,
            "model" => model,
            "reasoning_effort" => "low"
          })
      }
    })
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    :ok
  end

  # The socket writes a terminal before its row settles; poll the rows within
  # the detection budget.
  defp await_settled!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at])) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        length(rows) >= count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) and no_live_attempt?(rows) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp no_live_attempt?(rows) do
    ids = Enum.map(rows, & &1.id)
    not Repo.exists?(from(attempt in Attempt, where: attempt.request_id in ^ids and attempt.status in ["queued", "in_progress"]))
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
