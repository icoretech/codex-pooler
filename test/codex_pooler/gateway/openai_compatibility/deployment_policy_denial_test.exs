defmodule CodexPooler.Gateway.OpenAICompatibility.DeploymentPolicyDenialTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{DeploymentPolicyDenial, PublicResponse, Responses}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @diagnostic %{"error" => "middleware_denied", "reason_code" => "request_credential_denied", "layer" => "l7"}
  @private "synthetic-private-policy-detail"
  @public %{
    "code" => "model_request_policy_denied",
    "type" => "invalid_request_error",
    "message" => "The deployment rejected this model request. Ask the administrator to check the model access policy and request settings."
  }

  test "HTTP classification is opt-in and consumes one complete top-level diagnostic" do
    body = CodexPooler.JSON.encode!(Map.put(@diagnostic, "detail", @private))
    assert {:ok, %{"error" => @public}} = PublicResponse.normalize_raw_body(403, body, &Function.identity/1, deployment_policy_denial?: true)
    assert {:ok, %{"error" => generic}} = PublicResponse.normalize_raw_body(403, body, &Function.identity/1)
    assert generic == generic_error("upstream_status")

    for malformed <- [body <> "garbage", body <> body, String.trim_trailing(body, "}"), "[" <> body <> "]", CodexPooler.JSON.encode!(%{"error" => @diagnostic}), ~s({"error":"middleware_denied",})] do
      assert {:ok, %{"error" => error}} = PublicResponse.normalize_raw_body(403, malformed, &Function.identity/1, deployment_policy_denial?: true)
      assert error["message"] == "upstream request failed"
      refute error["code"] == @public["code"]
    end
  end

  test "HTTP and decoded diagnostic size limits are inclusive and include ignored extras" do
    base = CodexPooler.JSON.encode!(Map.put(@diagnostic, "detail", ""))
    padding = String.duplicate("x", 8_192 - byte_size(base))
    diagnostic = Map.put(@diagnostic, "detail", padding)
    body = CodexPooler.JSON.encode!(diagnostic)
    assert byte_size(body) == 8_192
    assert DeploymentPolicyDenial.matches?(403, body)
    assert DeploymentPolicyDenial.matches?(403, diagnostic)
    refute DeploymentPolicyDenial.matches?(403, body <> " ")
    refute DeploymentPolicyDenial.matches?(403, Map.put(diagnostic, "detail", padding <> "x"))
    assert {:ok, %{"error" => @public}} = PublicResponse.normalize_raw_body(403, body, &Function.identity/1, deployment_policy_denial?: true)
    assert {:ok, %{"error" => error}} = PublicResponse.normalize_raw_body(403, body <> " ", &Function.identity/1, deployment_policy_denial?: true)
    assert error == generic_error("upstream_status")
  end

  test "only all three exact diagnostic values and an integer 403 qualify" do
    negatives = for key <- Map.keys(@diagnostic), value <- [nil, 403, [], %{}, String.upcase(@diagnostic[key]), @diagnostic[key] <> " "], do: Map.put(@diagnostic, key, value)
    negatives = negatives ++ Enum.map(Map.keys(@diagnostic), &Map.delete(@diagnostic, &1)) ++ [%{"code" => "model_request_policy_denied", "message" => @private}, %{"message" => CodexPooler.JSON.encode!(@diagnostic)}, %{"error" => "invalid_api_key"}]

    for diagnostic <- negatives do
      refute DeploymentPolicyDenial.matches?(403, diagnostic)
      assert %{"type" => "error", "status" => 403, "error" => error} = PublicResponse.provider_rejection_websocket_event(403, diagnostic)
      assert error == generic_error("upstream_status")
    end

    for status <- [nil, 200, 400, 401, 404, 429, 500, "403"] do
      refute DeploymentPolicyDenial.matches?(status, @diagnostic)
      body = CodexPooler.JSON.encode!(@diagnostic)

      if is_integer(status) and status >= 400 do
        assert {:ok, %{"error" => error}} = PublicResponse.normalize_raw_body(status, body, &Function.identity/1, deployment_policy_denial?: true)
        refute error["code"] == @public["code"]
        assert error["message"] == "upstream request failed"
      end
    end
  end

  test "wrapped websocket denial is fixed and latches the terminal without exposing provider fields" do
    diagnostic = Map.put(@diagnostic, "detail", @private)
    frame = %{"type" => "error", "status" => 403, "error" => diagnostic, "headers" => %{"x-private" => @private}}
    owner_wire = frame |> CodexPooler.JSON.encode!() |> StreamProtocol.normalize_public_openai_responses_json_message()
    assert {:push, wire, state} = StreamProtocol.normalize_public_openai_responses_websocket_data(owner_wire, StreamProtocol.public_openai_responses_websocket_state())
    assert %{"type" => "error", "status" => 403, "error" => @public} = CodexPooler.JSON.decode!(wire)
    refute wire =~ @private
    refute wire =~ "headers"
    assert {:drop, ^state} = StreamProtocol.normalize_public_openai_responses_websocket_data(owner_wire, state)
  end

  test "SSE final projection and owner-forwarded websocket keep generic accounting classification" do
    event = terminal(403, Map.put(@diagnostic, "detail", @private))
    source = "event: response.failed\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
    {wire, state} = StreamProtocol.normalize_public_openai_responses_sse_data(source, StreamProtocol.public_openai_responses_stream_state())
    assert state.terminal_kind == :failed
    assert state.terminal_failure.code == "upstream_error"
    refute wire =~ @private
    refute wire =~ "reason_code"
    [_, terminal] = sse_events(wire)
    assert terminal["error"] == @public
    assert terminal["response"]["error"] == @public
    owner = event |> CodexPooler.JSON.encode!() |> StreamProtocol.normalize_public_openai_responses_json_message()
    assert {:push, public_wire, _state} = StreamProtocol.normalize_public_openai_responses_websocket_data(owner, StreamProtocol.public_openai_responses_websocket_state())
    normalized = CodexPooler.JSON.decode!(public_wire)
    assert normalized["error"] == @public
    assert normalized["response"]["error"] == @public
  end

  test "label-only and status aliases project once while terminal accounting stays generic" do
    for type <- ["response.failed", "error"], status_key <- ["status", "status_code"], position <- [:top, :nested], json_type? <- [true, false] do
      diagnostic = Map.merge(@diagnostic, %{"detail" => @private})
      event = if position == :top, do: %{"error" => diagnostic}, else: %{"response" => %{"status" => "failed", "error" => diagnostic}}
      event = Map.put(event, status_key, 403)
      event = if json_type?, do: Map.put(event, "type", type), else: event
      source = "event: #{type}\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
      {wire, state} = StreamProtocol.normalize_public_openai_responses_sse_data(source, StreamProtocol.public_openai_responses_stream_state())
      assert state.terminal_failure.code == "upstream_error"
      terminal = wire |> sse_events() |> List.last()
      assert terminal["error"] == @public or get_in(terminal, ["response", "error"]) == @public
      assert is_integer(terminal["sequence_number"])
      refute wire =~ @private
    end
  end

  test "nested-only and retry-code wrapped websocket denials preserve assigned sequence" do
    for event <- [
          %{"type" => "error", "status_code" => 403, "response" => %{"error" => @diagnostic}},
          %{"type" => "error", "status" => 403, "error" => Map.put(@diagnostic, "code", "websocket_connection_limit_reached")}
        ] do
      assert {:push, wire, state} = StreamProtocol.normalize_public_openai_responses_websocket_data(CodexPooler.JSON.encode!(event), StreamProtocol.public_openai_responses_websocket_state())
      assert %{"type" => "error", "status" => 403, "error" => @public, "sequence_number" => 0} = CodexPooler.JSON.decode!(wire)
      assert state.terminal_latched?
    end
  end

  test "frame diagnostics must be decoded objects and an explicit malformed status wins over its alias" do
    for type <- ["response.failed", "error"] do
      event = terminal(403, CodexPooler.JSON.encode!(@diagnostic)) |> Map.put("type", type)
      refute DeploymentPolicyDenial.frame?(event)
      source = "event: #{type}\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
      {wire, _state} = StreamProtocol.normalize_public_openai_responses_sse_data(source, StreamProtocol.public_openai_responses_stream_state())
      refute wire =~ @public["message"]
    end

    for status <- [nil, false, 400, "403"] do
      event = terminal(403, @diagnostic) |> Map.put("status", status) |> Map.put("status_code", 403)
      refute DeploymentPolicyDenial.frame?(event)
      source = "event: response.failed\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
      assert {:error, reason} = Responses.response_from_sse(source)
      refute Map.has_key?(reason, :public_deployment_policy_denial?)
    end
  end

  test "missing or contradictory terminal statuses cannot promote diagnostic-looking errors" do
    for status <- [nil, 400, 401, 500, "403"] do
      diagnostic = Map.put(@diagnostic, "status", 403)
      event = terminal(status, diagnostic)
      {wire, _state} = StreamProtocol.normalize_public_openai_responses_sse_data("event: response.failed\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n", StreamProtocol.public_openai_responses_stream_state())
      [_, terminal] = sse_events(wire)
      assert terminal["error"] == generic_error("upstream_error")
      assert terminal["response"]["error"] == generic_error("upstream_error")
    end
  end

  test "collected SSE keeps settlement reason and carries only a trusted public projection marker" do
    event = terminal(403, Map.put(@diagnostic, "detail", @private))
    source = "event: response.failed\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
    assert {:error, reason} = Responses.response_from_sse(source)
    assert reason == %{status: 502, code: "upstream_error", message: "upstream request failed", param: nil, public_deployment_policy_denial?: true}
    refute inspect(reason) =~ @private
    refute inspect(reason) =~ "reason_code"
  end

  test "a provider-authored fixed public error is not classification evidence" do
    for status <- [nil, 403, "403"] do
      event = terminal(status, @public)
      source = "event: response.failed\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
      assert {:error, reason} = Responses.response_from_sse(source)
      refute Map.has_key?(reason, :public_deployment_policy_denial?)
      assert reason.status == 502
      assert reason.message == "upstream request failed"
      {wire, _state} = StreamProtocol.normalize_public_openai_responses_sse_data(source, StreamProtocol.public_openai_responses_stream_state())
      [_, terminal] = sse_events(wire)
      assert terminal["error"]["message"] == "upstream request failed"
      assert terminal["response"]["error"]["type"] == "server_error"
    end

    assert PublicResponse.provider_rejection_websocket_event(403, @public)["error"] == generic_error("upstream_status")
  end

  test "colliding public codes do not preserve provider prose or fields" do
    for error <- [Map.put(@public, "message", @private), Map.put(@public, "detail", @private), Map.delete(@public, "type"), %{"code" => @public["code"]}] do
      assert PublicResponse.normalize_error(error, status: 403, deployment_policy_denial?: true)["message"] == "upstream request failed"
    end

    matrix = CodexPooler.CompatibilityMatrix.fixture!(:v1_supported_surface).public_error_redaction.deployment_policy_denial
    assert Map.new(matrix.public_error, fn {key, value} -> {to_string(key), value} end) == @public
    assert matrix.diagnostic == @diagnostic
  end

  defp terminal(status, diagnostic) do
    event = %{"type" => "response.failed", "error" => diagnostic, "response" => %{"id" => "resp_synthetic_denial", "status" => "failed", "error" => diagnostic}}
    if is_nil(status), do: event, else: Map.put(event, "status", status)
  end

  defp generic_error(code), do: %{"code" => code, "type" => "server_error", "message" => "upstream request failed"}

  defp sse_events(wire) do
    for block <- String.split(wire, "\n\n", trim: true), "data: " <> data <- String.split(block, "\n"), do: CodexPooler.JSON.decode!(data)
  end
end
