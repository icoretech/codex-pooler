defmodule CodexPoolerWeb.Runtime.AnchoredOwnerDrainSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.InstanceSettings
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000

  @spec fixture(keyword()) :: {map(), FakeUpstream.t(), map(), reference()}
  def fixture(opts \\ []) do
    cache = InstanceSettings.snapshot_cache_for_test()
    on_exit(fn -> InstanceSettings.restore_cache_for_test(cache) end)
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)

      if previous == nil,
        do: Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled),
        else: Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         Keyword.get(opts, :completed_responses, [completed_tool_response()]) ++
           [
             FakeUpstream.delayed_terminal_sse_stream(
               [%{"type" => "response.output_text.delta", "delta" => "synthetic"}],
               %{
                 "type" => "response.completed",
                 "response" => %{"id" => "resp_synthetic_continuation", "status" => "completed"}
               },
               notify: self(),
               release_ref: release_ref
             )
           ]}
      )

    setup = gateway_setup(upstream)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(setup.pool)
        Repo.delete!(setup.identity)
        Repo.delete!(setup.pricing)
      end)
    end)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: Ecto.UUID.generate()}
      })

    on_exit(fn ->
      if Process.alive?(state.websocket_owner_pid),
        do: WebsocketOwnerSession.drain_owner(state.websocket_owner_pid)
    end)

    {setup, upstream, state, release_ref}
  end

  defp completed_tool_response do
    item = %{
      "type" => "function_call",
      "id" => "fc_synthetic",
      "call_id" => "call_synthetic",
      "name" => "synthetic_tool",
      "arguments" => "{}",
      "status" => "completed"
    }

    FakeUpstream.sse_stream([
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_synthetic_anchor_completed",
          "object" => "response",
          "status" => "completed",
          "output" => [item]
        }
      }
    ])
  end

  @spec receive_completed_tool(map()) :: {String.t(), String.t(), map()}
  def receive_completed_tool(state) do
    {item_event, state} = receive_until(state, {:event, "response.output_item.done"})
    {completed, state} = receive_until(state, {:event, "response.completed"})
    assert %{"item" => %{"type" => "function_call", "call_id" => call_id} = item} = item_event
    assert completed["response"]["output"] == [item]
    assert item["name"] == "synthetic_tool"
    assert CodexPooler.JSON.decode!(item["arguments"]) == %{}
    {completed["response"]["id"], call_id, receive_until(state, :complete)}
  end

  @spec metadata() :: map()
  def metadata do
    %{
      "session_id" => Ecto.UUID.generate(),
      "thread_id" => Ecto.UUID.generate(),
      "turn_id" => Ecto.UUID.generate(),
      "request_kind" => "turn"
    }
  end

  @spec payload(map(), map()) :: map()
  def payload(setup, metadata) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "tools" => [
        %{
          "type" => "function",
          "name" => "synthetic_tool",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => false
          }
        }
      ],
      "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)},
      "stream" => true,
      "generate" => true
    }
  end

  @spec receive_until(map(), :complete | String.t() | {:error | :event, String.t()}) ::
          map() | {map(), map()}
  def receive_until(state, expected) do
    if expected == :complete and MapSet.size(state.tasks) == 0,
      do: state,
      else: receive_next(state, expected)
  end

  defp receive_next(state, expected) do
    owner_monitor = Map.get(state, :websocket_owner_monitor)
    task_monitors = Map.get(state, :task_monitors, %{})

    receive do
      {:DOWN, ref, :process, pid, _reason} = message
      when ref == owner_monitor or
             (is_map_key(task_monitors, pid) and :erlang.map_get(pid, task_monitors) == ref) ->
        handle_lifecycle_message(message, state, expected)

      message
      when elem(message, 0) in [
             :websocket_owner_cleanup_witness,
             :websocket_owner_frame,
             :websocket_owner_output_commit_probe,
             :websocket_response_activity,
             :codex_response_done,
             :websocket_response_delivery_complete,
             :direct_request_cleanup,
             :codex_response_chunk
           ] ->
        handle_lifecycle_message(message, state, expected)
    after
      @budget -> flunk("missing bounded owner lifecycle event #{inspect(expected)}")
    end
  end

  defp handle_lifecycle_message(message, state, expected) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} ->
        receive_until(state, expected)

      {:push, {:text, frame}, state} ->
        event = CodexPooler.JSON.decode!(frame)
        code = get_in(event, ["error", "code"])

        if event["type"] == expected or expected == {:event, event["type"]} or
             (not is_nil(code) and expected == {:error, code}),
           do: event_result(event, state, expected),
           else: receive_until(state, expected)
    end
  end

  defp event_result(event, state, {:event, _type}), do: {event, state}
  defp event_result(_event, state, _expected), do: state
end
