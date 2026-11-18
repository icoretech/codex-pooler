defmodule CodexPoolerWeb.V1.ResponsesImageGenerationCallTest do
  # A Full-served model that ran the hosted `image_generation` tool returns an `image_generation_call` output item with
  # the image as base64 in `result`, and an SDK or gateway client sends `response.output` back as the history of its
  # next stateless request. The item used to be a `400 invalid_request` on `input`. The provider reads it in the Full
  # and in the Lite request shape (direct probe, 2026-11-18) without tokenizing the image, so `/v1/responses` forwards
  # the exact shape it emits, streaming or not, drops only the id the public stream invents for an item the upstream
  # sent without one (the provider wants an id that begins with `ig`), and reserves one image allowance, not the bytes.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @prompt "synthetic private revised prompt"
  @result Base.encode64(:binary.copy(<<137, 80, 78, 71, 13, 10, 26, 10>>, 50_000))
  @call %{
    "id" => "ig_synthetic_0001",
    "type" => "image_generation_call",
    "status" => "completed",
    "action" => "generate",
    "background" => "opaque",
    "output_format" => "png",
    "quality" => "low",
    "size" => "1024x1024",
    "revised_prompt" => @prompt,
    "result" => @result
  }

  for mode <- ["auto", "lite", "full"], stream? <- [true, false] do
    test "#{mode} serving, stream #{stream?}: a replayed image_generation_call reaches the upstream untouched" do
      upstream = start_upstream(FakeUpstream.sse_stream([completed("resp_image_generation_call_forward", [message("msg_after_image", "synthetic closing text")])]))
      setup = serving_setup(upstream, unquote(mode))

      conn = post_responses(setup, %{"model" => setup.model.exposed_model_id, "store" => false, "stream" => unquote(stream?), "input" => history(@call)})

      assert conn.status == 200
      assert conn.resp_body =~ "resp_image_generation_call_forward"
      assert [captured] = FakeUpstream.requests(upstream)
      assert Enum.filter(captured.json["input"], &(&1["type"] == "image_generation_call")) == [@call]
      assert Enum.map(captured.json["input"], & &1["type"]) -- ["additional_tools"] == ["message", "image_generation_call", "message", "message"]
      assert [%{status: "succeeded"}] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    end
  end

  test "an image generated through /v1 replays from the public output, and an id-less item replays without the fallback id" do
    generated = Map.delete(@call, "id")

    upstream = start_upstream(FakeUpstream.sse_stream([completed("resp_image_generation_call_first", [generated, message(nil, "synthetic answer")])]))
    setup = gateway_setup(upstream)

    first = post_responses(setup, %{"model" => setup.model.exposed_model_id, "input" => "synthetic first turn", "tools" => [%{"type" => "image_generation"}], "stream" => true})
    assert first.status == 200
    assert [%{"type" => "image_generation_call", "id" => "image_generation_call_0"} = public_item | _rest] = completed_output!(first.resp_body)

    replay_upstream = start_upstream(FakeUpstream.sse_stream([completed("resp_image_generation_call_replay", [message("msg_after_replay", "synthetic closing text")])]))
    replay_setup = gateway_setup(replay_upstream)

    replay = post_responses(replay_setup, %{"model" => replay_setup.model.exposed_model_id, "store" => false, "stream" => true, "input" => [user("synthetic first turn"), public_item, user("synthetic follow-up")]})

    assert replay.status == 200
    assert [captured] = FakeUpstream.requests(replay_upstream)
    assert [_user, replayed, _follow_up] = captured.json["input"]
    assert replayed == generated
  end

  test "the image is reserved as one image allowance, not its bytes, and neither the image nor the revised prompt is persisted" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed("resp_image_generation_call_privacy", [message("msg_after_privacy", "synthetic closing text")])]))
    setup = gateway_setup(upstream)

    conn = post_responses(setup, %{"model" => setup.model.exposed_model_id, "store" => false, "stream" => true, "input" => history(@call)})

    assert conn.status == 200
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.request_metadata["reservation"]["input_tokens"] < 2_000
    assert request.request_metadata["reservation"]["image_estimate"]["image_count"] == 1
    assert byte_size(@result) > 500_000

    persisted = inspect({request, Repo.all(Attempt)}, limit: :infinity, printable_limit: :infinity)
    refute persisted =~ @prompt
    refute persisted =~ binary_part(@result, 0, 64)
  end

  for {label, item} <- [
        {"an unknown item key", Map.put(@call, "zz_probe_unknown_key", true)},
        {"no result (the provider would look it up as a stored item)", Map.delete(@call, "result")},
        {"a blank status (the provider would look it up as a stored item)", Map.put(@call, "status", "")},
        {"a non-string quality", Map.put(@call, "quality", 1)}
      ] do
    test "an image_generation_call with #{label} is refused before any upstream work" do
      upstream = start_upstream(FakeUpstream.sse_stream([completed("resp_image_generation_call_never", [message("msg_never", "synthetic never sent")])]))
      setup = gateway_setup(upstream)

      conn = post_responses(setup, %{"model" => setup.model.exposed_model_id, "store" => false, "stream" => true, "input" => history(unquote(Macro.escape(item)))})

      assert %{"error" => %{"type" => "invalid_request_error", "code" => "invalid_request", "param" => "input", "message" => "input item shape is not translatable"}} = json_response(conn, 400)
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end
  end

  defp serving_setup(upstream, mode) do
    setup = gateway_setup(upstream)
    if mode != "auto", do: set_model_serving_mode!(model_serving_scope(), setup, mode)
    setup
  end

  defp post_responses(setup, payload), do: build_conn() |> auth(setup) |> post("/v1/responses", payload)

  defp history(item), do: [user("synthetic task"), item, message(nil, "synthetic answer"), user("synthetic follow-up")]

  defp user(text), do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp message(id, text) do
    item = %{"type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]}
    if id, do: Map.put(item, "id", id), else: item
  end

  defp completed(response_id, output) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => response_id,
         "object" => "response",
         "created_at" => 1_790_000_000,
         "model" => "provider-gpt-test-model",
         "status" => "completed",
         "output" => output,
         "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
       }
     }}
  end

  defp completed_output!(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      fields = block |> String.split("\n") |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))

      case fields do
        %{"event" => "response.completed", "data" => data} -> CodexPooler.JSON.decode!(data)["response"]["output"]
        _other -> nil
      end
    end) || flunk("no response.completed event in the public stream")
  end
end
