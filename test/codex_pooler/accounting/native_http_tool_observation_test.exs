defmodule CodexPooler.Accounting.NativeHttpToolObservationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.NativeHttpToolObservation, as: Observation

  for {kind, prefix, field} <- [
        {"custom_tool_call", "response.custom_tool_call_input", "input"},
        {"function_call", "response.function_call_arguments", "arguments"}
      ] do
    test "#{kind} remains incomplete through input.done but never through item.done" do
      kind = unquote(kind)
      prefix = unquote(prefix)
      started = started(kind)
      delta = %{"type" => prefix <> ".delta", "item_id" => "item_synthetic", "output_index" => 0, "delta" => "synthetic"}
      state = Observation.observe(started, delta["type"], delta)
      assert Observation.eligible_metadata?(Observation.metadata(state, true))
      done = %{"type" => prefix <> ".done", "item_id" => "item_synthetic", "output_index" => 0, unquote(field) => "synthetic"}
      state = Observation.observe(state, done["type"], done)
      assert Observation.eligible_metadata?(Observation.metadata(state, true))
      refute Observation.eligible_metadata?(Observation.metadata(state, false))

      completed = %{"type" => "response.output_item.done", "item" => %{"type" => kind}}
      state = Observation.observe(state, completed["type"], completed)
      refute Observation.eligible_metadata?(Observation.metadata(state, true))
    end
  end

  test "malformed, unknown, terminal, mismatched and duplicate events permanently poison authority" do
    for event <- [
          %{},
          %{"type" => "response.unknown"},
          %{"type" => "response.completed"},
          %{"type" => "error"},
          %{"type" => "response.output_item.done"},
          added("custom_tool_call"),
          %{"type" => "response.custom_tool_call_input.delta", "item_id" => "other", "output_index" => 0, "delta" => "synthetic"},
          %{"type" => "response.custom_tool_call_input.delta", "item_id" => "item_synthetic", "output_index" => 1, "delta" => "synthetic"}
        ] do
      state = Observation.observe(started("custom_tool_call"), event["type"], event)
      refute Observation.eligible_metadata?(Observation.metadata(state, true))
      state = Observation.observe(state, "response.output_item.added", added("custom_tool_call"))
      refute Observation.eligible_metadata?(Observation.metadata(state, true))
    end

    for kind <- ["computer_call", "web_search_call", "unknown"] do
      refute Observation.eligible_metadata?(Observation.metadata(started(kind), true))
    end

    refute Observation.eligible_metadata?(Observation.metadata(Observation.new(), true))
    refute Observation.eligible_metadata?(%{})
    refute Observation.eligible_metadata?(nil)
    refute inspect(Observation.metadata(started("custom_tool_call"), true)) =~ "item_synthetic"
  end

  defp started(kind), do: Observation.observe(Observation.new(), "response.output_item.added", added(kind))

  defp added(kind),
    do: %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => "item_synthetic", "type" => kind, "call_id" => "call_synthetic", "name" => "sample_tool", "status" => "in_progress"}}
end
