defmodule CodexPooler.Gateway.Runtime.Streaming.ModelDeclarationObserverTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Runtime.Streaming.{ModelDeclarationObserver, StreamUsageObserver}

  test "all collectors retain first, terminal and sticky conflict independently of usage" do
    for {models, first, terminal, conflicting, conflict} <- [
          {["model-a", "model-a"], "model-a", "model-a", nil, false},
          {["model-a", "model-b"], "model-a", "model-b", "model-b", true},
          {["model-b", "model-a"], "model-b", "model-a", "model-a", true},
          {["model-a", "model-b", "model-b", "model-c", "model-a"], "model-a", "model-a", "model-b", true},
          {["MODEL-A", "model-a"], "MODEL-A", "model-a", nil, false},
          {[nil, "model-a"], "model-a", "model-a", nil, false},
          {[nil, nil], nil, nil, nil, nil},
          {["model-a", nil], "model-a", nil, nil, false}
        ] do
      events = events(models)
      wire = Enum.map_join(events, &sse/1)
      expected = %{"version" => 1, "coverage" => "full", "terminal_status" => "completed", "terminal_model" => terminal, "first_conflicting_model" => conflicting, "conflict" => conflict}

      for result <- [ResponseUsage.from_sse(wire), ResponseUsage.from_websocket_body(Enum.map_join(events, "\n\n", &CodexPooler.JSON.encode!/1))] do
        assert Map.get(result, :served_model) == first
        assert result.model_observation == expected
      end

      for split <- 0..byte_size(wire) do
        <<left::binary-size(^split), right::binary>> = wire
        result = StreamUsageObserver.new() |> StreamUsageObserver.observe(left) |> StreamUsageObserver.observe(right) |> StreamUsageObserver.result()
        assert Map.get(result, :served_model) == first
        assert result.model_observation == expected
      end
    end
  end

  test "interruption, no declaration and terminal without a model remain distinct" do
    for collector <- [&ResponseUsage.from_sse/1, &incremental/1] do
      interrupted = collector.(sse(event("response.created", "model-a")))
      assert interrupted.served_model == "model-a"
      assert interrupted.model_observation["terminal_status"] == nil
      assert interrupted.model_observation["terminal_model"] == nil
      assert interrupted.model_observation["conflict"] == false

      no_model = collector.(sse(event("response.completed", nil)))
      refute Map.has_key?(no_model, :served_model)
      assert no_model.model_observation["terminal_status"] == "completed"
      assert no_model.model_observation["conflict"] == nil
    end
  end

  test "nested tool fields, unrelated response identities, duplicate terminals and late events cannot create a conflict" do
    original = event("response.created", "model-a")
    other_response = put_in(event("response.in_progress", "model-b"), ["response", "id"], "resp_other")
    tool = %{"type" => "response.output_item.done", "model" => "model-b", "item" => %{"model" => "model-c"}}
    terminal = event("response.completed", "model-a")
    late = event("response.completed", "model-c")
    wire = Enum.map_join([original, tool, other_response, terminal, late], &sse/1)

    for result <- [ResponseUsage.from_sse(wire), incremental(wire)] do
      assert result.served_model == "model-a"
      assert result.model_observation == %{"version" => 1, "coverage" => "partial", "terminal_status" => "completed", "terminal_model" => "model-a", "first_conflicting_model" => nil, "conflict" => false}
    end
  end

  test "response model precedence does not depend on JSON field order or byte boundaries" do
    wire = "data: {\"model\":\"root-model\",\"response\":{\"model\":\"model-a\",\"id\":\"resp_sample\"},\"type\":\"response.completed\"}\n\n"

    for split <- 0..byte_size(wire) do
      <<left::binary-size(^split), right::binary>> = wire
      result = StreamUsageObserver.new() |> StreamUsageObserver.observe(left) |> StreamUsageObserver.observe(right) |> StreamUsageObserver.result()
      assert result.served_model == "model-a"
      assert result.model_observation["conflict"] == false
    end

    assert ResponseUsage.from_sse(wire).served_model == "model-a"
  end

  test "bounded identifiers are consistent; values beyond parser capacity disclose partial coverage" do
    for model <- [String.duplicate("a", 81), "model with spaces", "model-é"] do
      wire = sse(event("response.completed", model))
      expected = ResponseUsage.bounded_served_model(model)
      assert incremental(wire).served_model == expected
      assert ResponseUsage.from_sse(wire).served_model == expected
    end

    for model <- [nil, "", "   ", 42, %{"model" => "nested"}] do
      result = incremental(sse(event("response.completed", model)))
      refute Map.has_key?(result, :served_model)
      assert result.model_observation["conflict"] == nil
    end

    result = incremental(sse(event("response.completed", String.duplicate("a", 20_000))))
    refute Map.has_key?(result, :served_model)
    assert result.model_observation["coverage"] == "partial"
    assert result.model_observation["terminal_status"] == "completed"
  end

  test "failed, incomplete and cancelled terminals seal evidence and reset starts a new response" do
    for type <- ~w(response.failed response.incomplete response.cancelled) do
      wire = sse(event("response.created", "model-a")) <> sse(event(type, "model-b"))
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), wire)
      observation = StreamUsageObserver.result(state).model_observation
      assert observation["conflict"] == true
      assert observation["terminal_status"] == String.replace_prefix(type, "response.", "")
      assert observation["terminal_model"] == "model-b"

      next = state |> StreamUsageObserver.reset() |> StreamUsageObserver.observe(sse(event("response.completed", "model-c"))) |> StreamUsageObserver.result()
      assert next.served_model == "model-c"
      assert next.model_observation["conflict"] == false
      assert next.model_observation["first_conflicting_model"] == nil
    end
  end

  test "JSON completion observes the response envelope even without usage and ignores nested output" do
    result = ResponseUsage.from_decoded(%{"model" => "model-a", "output" => [%{"model" => "model-b", "usage" => %{}}]})
    assert result.served_model == "model-a"
    assert result.model_observation["terminal_status"] == "json"
    assert result.model_observation["conflict"] == false
    assert ModelDeclarationObserver.evidence(ModelDeclarationObserver.json(nil))["coverage"] == "partial"
  end

  test "record validity, chunk event names, root fallback and identity normalization agree across byte splits" do
    wires = [
      "data: {\"model\":\"model-a\"}\nevent: response.completed\n\n",
      "data: {\"model\":\"tool-model\"}\nevent: response.output_item.done\n\n",
      "event: chunk\ndata: #{CodexPooler.JSON.encode!(event("response.completed", "model-a"))}\n\n",
      "event: chunk\ndata: {\"type\":\"response.output_item.done\",\"model\":\"tool-model\"}\n\n",
      "data: #{CodexPooler.JSON.encode!(event("response.completed", "model-a"))}garbage\n\n",
      "data: {\"type\":\"response.completed\",\"model\":\"root-model\",\"response\":{}}\n\n",
      sse(put_in(event("response.created", "model-a"), ["response", "id"], " resp_sample ")) <> sse(event("response.completed", "model-b"))
    ]

    for wire <- wires do
      expected = ResponseUsage.from_sse(wire)

      for split <- 0..byte_size(wire) do
        <<left::binary-size(^split), right::binary>> = wire
        result = StreamUsageObserver.new() |> StreamUsageObserver.observe(left) |> StreamUsageObserver.observe(right) |> StreamUsageObserver.result()
        assert result.model_observation == expected.model_observation
        assert Map.get(result, :served_model) == Map.get(expected, :served_model)
      end
    end
  end

  defp incremental(wire), do: StreamUsageObserver.new() |> StreamUsageObserver.observe(wire) |> StreamUsageObserver.result()

  defp events(models) do
    models
    |> Enum.with_index()
    |> Enum.map(fn {model, index} -> event(if(index == length(models) - 1, do: "response.completed", else: "response.in_progress"), model) end)
  end

  defp event(type, model), do: %{"type" => type, "response" => %{"id" => "resp_sample", "model" => model}}
  defp sse(event), do: "event: #{event["type"]}\ndata: #{CodexPooler.JSON.encode!(event)}\n\n"
end
