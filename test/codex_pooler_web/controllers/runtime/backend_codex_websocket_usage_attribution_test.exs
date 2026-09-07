defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketUsageAttributionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo

  @detection_timeout 5_000
  @marker "synthetic-attribution-marker"
  @usage %{
    "input_tokens" => 123,
    "input_tokens_details" => %{"cached_tokens" => 17},
    "output_tokens" => 45,
    "output_tokens_details" => %{"reasoning_tokens" => 6},
    "total_tokens" => 168
  }

  for envelope <- [:response, :root] do
    test "native #{envelope} terminal preserves aggregate usage beyond retained body" do
      terminal = terminal_frame(unquote(envelope), @usage)
      {setup, upstream, result, frames} = execute_frames([terminal])
      assert :ok = result
      assert Enum.map(frames, &digest/1) == [digest(terminal)]
      assert length(FakeUpstream.requests(upstream)) == 1
      assert_settlement(setup, "usage_known")
    end
  end

  test "terminal usage overrides earlier progress" do
    progress =
      CodexPooler.JSON.encode!(%{
        "type" => "response.in_progress",
        "response" => %{"usage" => @usage}
      })

    terminal = terminal_frame(:response, nil)
    {setup, upstream, result, _frames} = execute_frames([progress, terminal])
    assert :ok = result
    assert length(FakeUpstream.requests(upstream)) == 1
    assert_settlement(setup, "usage_unknown")
  end

  for usage <- [
        nil,
        [],
        %{"input_tokens" => -1, "output_tokens" => 4},
        %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 9}
      ] do
    test "malformed terminal usage stays unknown: #{inspect(usage)}" do
      {setup, _upstream, result, _frames} =
        execute_frames([terminal_frame(:response, unquote(Macro.escape(usage)))])

      assert :ok = result
      assert_settlement(setup, "usage_unknown")
    end
  end

  test "unrelated nested usage cannot become terminal aggregate usage" do
    response = %{
      "id" => "resp_synthetic_nested_usage",
      "status" => "completed",
      "output" => [%{"usage" => @usage}]
    }

    terminal = CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => response})
    {setup, _upstream, result, _frames} = execute_frames([terminal])
    assert :ok = result
    assert_settlement(setup, "usage_unknown")
  end

  for terminal_type <- ["response.failed", "response.incomplete"] do
    test "#{terminal_type} preserves measured aggregates despite attribution" do
      terminal = terminal_frame(:response, @usage, unquote(terminal_type))
      {setup, upstream, _result, _frames} = execute_frames([terminal])
      assert length(FakeUpstream.requests(upstream)) == 1
      assert_settlement(setup, "usage_known")
    end
  end

  defp terminal_frame(envelope, usage, type \\ "response.completed") do
    # Put attribution after the usage marker so suffix retention cannot see it.
    usage_json = CodexPooler.JSON.encode!(usage)
    attribution = CodexPooler.JSON.encode!(String.duplicate(@marker, 5_000))

    usage_json =
      if is_map(usage),
        do: String.trim_trailing(usage_json, "}") <> ",\"attribution\":" <> attribution <> "}",
        else: usage_json

    response =
      ~s({"id":"resp_synthetic_usage_123456","status":) <>
        CodexPooler.JSON.encode!(String.replace_prefix(type, "response.", "")) <>
        ",\"usage\":" <> usage_json <> "}"

    case envelope do
      :response ->
        "{\"type\":" <> CodexPooler.JSON.encode!(type) <> ",\"response\":" <> response <> "}"

      :root ->
        response
    end
  end

  defp execute_frames(frames) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames(frames))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    observer = self()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true
      })

    opts =
      RequestOptions.for_websocket(%{request_id: Ecto.UUID.generate(), codex_session: session})

    result =
      Gateway.execute_websocket_response(auth, payload, opts, fn frame ->
        if CodexPooler.JSON.decode!(frame)["type"] != "codex.response.metadata",
          do: send(observer, {:usage_frame, frame})
      end)

    delivered =
      Enum.map(frames, fn _ ->
        assert_receive {:usage_frame, frame}, @detection_timeout
        frame
      end)

    refute_received {:usage_frame, _}
    {setup, upstream, result, delivered}
  end

  defp assert_settlement(setup, status) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert [settlement] =
             Repo.all(
               from(e in LedgerEntry,
                 where: e.request_id == ^request.id and e.entry_kind == "settlement"
               )
             )

    assert request.usage_status == status
    assert attempt.usage_status == status
    assert settlement.usage_status == status
    assert request.transport == "websocket"

    if status == "usage_known" do
      assert Map.take(settlement, [
               :input_tokens,
               :cached_input_tokens,
               :output_tokens,
               :reasoning_tokens,
               :total_tokens
             ]) ==
               %{
                 input_tokens: 123,
                 cached_input_tokens: 17,
                 output_tokens: 45,
                 reasoning_tokens: 6,
                 total_tokens: 168
               }
    end

    metadata = inspect({request.request_metadata, attempt.response_metadata, settlement.details})
    refute metadata =~ @marker
    refute metadata =~ setup.raw_key
  end

  defp digest(frame), do: :crypto.hash(:sha256, frame)
end
