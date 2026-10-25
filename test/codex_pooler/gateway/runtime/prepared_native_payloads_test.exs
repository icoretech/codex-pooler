defmodule CodexPooler.Gateway.Runtime.PreparedNativePayloadsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.{PayloadNormalizer, RequestOptions}
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedNativePayloads
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias CodexPooler.{Access, Accounting, FakeUpstream, Repo}
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
  alias CodexPooler.Gateway.Runtime.Dispatch.{CandidateDispatch, Context, RouteState}
  alias CodexPooler.Gateway.Transports.{ProviderCreditsAdmission, UpstreamDispatch}

  @endpoint "/backend-api/codex/responses"

  test "equivalent candidates share exact bytes and selected metadata preserves current runtime options" do
    {payload, model, options, candidates} = fixture()
    assert {:ok, prepared} = prepare(payload, model, options, candidates)
    assert map_size(prepared.variants) == 2
    assert map_size(prepared.assignment_variants) == 3
    [first, equivalent, different] = Enum.map(candidates, fn {assignment, _} -> assignment.id end)
    assert prepared.assignment_variants[first] == prepared.assignment_variants[equivalent]
    refute prepared.assignment_variants[first] == prepared.assignment_variants[different]

    for {assignment, _identity} <- candidates do
      current = options |> selected_options(model, assignment.id) |> RequestOptions.put_runtime_context(api_key_runtime_epoch: 93, replay_generation: 7)
      witness = %CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness{session_id: Ecto.UUID.generate(), lease_token: Ecto.UUID.generate()}
      current = %{current | runtime: %{current.runtime | session_owner_witness: witness}, routing: %{current.routing | routing_attempt_metadata: %{"retry" => 2}, routing_circuit_state: %CodexPooler.Gateway.Persistence.RoutingCircuitState{id: Ecto.UUID.generate()}}, transport: %{current.transport | websocket_owner: %{current.transport.websocket_owner | downstream_epoch: 31}}}
      assert {:ok, expected_bytes, expected_options} = PayloadNormalizer.prepare_upstream_payload(payload, model, @endpoint, current, assignment_id: assignment.id)
      assert {:ok, actual_bytes, actual_options} = fetch(prepared, payload, model, current, assignment.id)
      assert actual_bytes == expected_bytes
      assert actual_options == expected_options
      assert actual_options.runtime.api_key_runtime_epoch == 93
      assert actual_options.runtime.replay_generation == 7
      refute Map.has_key?(actual_options.extra, :prepared_native_payloads)
      refute Map.has_key?(Map.from_struct(actual_options.runtime), :prepared_native_payloads)
    end

    refute inspect(prepared) =~ "synthetic-private-content"
    Enum.each(Map.values(prepared.variants), fn variant -> refute inspect(variant) =~ "synthetic-private-content" end)
  end

  for capability <- [:summary, :effort] do
    test "candidate #{capability} alone changes the exact prepared variant" do
      {payload, model, options, candidates} = fixture()
      [{first, _}, _equivalent, {different, _}] = candidates
      sources = model.metadata["source_assignment_models"]
      metadata = sources[first.id]
      metadata = if unquote(capability) == :summary, do: Map.put(metadata, "supports_reasoning_summary_parameter", false), else: Map.put(metadata, "supported_reasoning_levels", ~w(low xhigh))
      model = %{model | metadata: Map.put(model.metadata, "source_assignment_models", Map.put(sources, different.id, metadata))}
      assert {:ok, prepared} = prepare(payload, model, options, candidates)
      assert map_size(prepared.variants) == 2
      first_variant = prepared.variants[prepared.assignment_variants[first.id]]
      different_variant = prepared.variants[prepared.assignment_variants[different.id]]
      refute first_variant.encoded == different_variant.encoded

      for {assignment, _} <- candidates do
        current = selected_options(options, model, assignment.id)
        assert {:ok, expected, expected_options} = PayloadNormalizer.prepare_upstream_payload(payload, model, @endpoint, current, assignment_id: assignment.id)
        assert {:ok, ^expected, ^expected_options} = fetch(prepared, payload, model, current, assignment.id)
      end
    end
  end

  test "assignment Lite projection applies only without the frozen Full serving snapshot" do
    {payload, model, full_options, [{assignment, _} = candidate | _]} = fixture()
    metadata = Map.put(model.metadata["source_assignment_models"][assignment.id], "use_responses_lite", true)
    model = %{model | metadata: %{"source_assignment_models" => %{assignment.id => metadata}}}
    unresolved = %{} |> RequestOptions.build(@endpoint, payload) |> RequestOptions.for_websocket(payload)

    for options <- [full_options, unresolved] do
      current = selected_options(options, model, assignment.id)
      assert RequestOptions.use_responses_lite?(current) == is_nil(RequestOptions.model_serving_mode_snapshot(options))
      assert {:ok, prepared} = prepare(payload, model, options, [candidate])
      assert {:ok, expected, expected_options} = PayloadNormalizer.prepare_upstream_payload(payload, model, @endpoint, current, assignment_id: assignment.id)
      assert {:ok, ^expected, ^expected_options} = fetch(prepared, payload, model, current, assignment.id)
    end
  end

  @tag :binding_guard
  test "changed model, input, serving snapshot, capability or absent assignment fails closed" do
    {payload, model, options, [{assignment, _} | _] = candidates} = fixture()
    assert {:ok, prepared} = prepare(payload, model, options, candidates)
    current = selected_options(options, model, assignment.id)
    changed_mode = %{current | routing: %{current.routing | model_serving_mode: "lite"}}
    changed_summary = RequestOptions.put_routing(current, supports_reasoning_summary_parameter?: false)

    for {body, bound_model, bound_options, id} <- [
          {payload, %{model | upstream_model_id: "other-model"}, current, assignment.id},
          {Map.put(payload, "instructions", "changed"), model, current, assignment.id},
          {payload, model, changed_mode, assignment.id},
          {payload, model, changed_summary, assignment.id},
          {payload, model, current, Ecto.UUID.generate()}
        ] do
      assert {:error, :prepared_native_payload_binding_mismatch} = fetch(prepared, body, bound_model, bound_options, id)
    end
  end

  test "limit uses exact normalized UTF-8 escaped JSON and response.create envelope bytes inclusively" do
    {payload, model, options, candidates} = fixture()
    payload = Map.put(payload, "instructions", "é\n\"\\")
    assert {:ok, prepared} = prepare(payload, model, options, Enum.take(candidates, 1))
    [%{encoded: encoded}] = Map.values(prepared.variants)
    assert CodexPooler.JSON.decode!(encoded)["type"] == "response.create"
    assert {:ok, _} = prepare(payload, model, options, Enum.take(candidates, 1), byte_size(encoded))
    assert {:oversized, size} = prepare(payload, model, options, Enum.take(candidates, 1), byte_size(encoded) - 1)
    assert size == byte_size(encoded)
  end

  for offset <- [-1, 0, 1] do
    test "actual 16 MiB boundary offset #{offset} is measured after complete normalization" do
      {payload, model, options, candidates} = fixture()
      candidates = Enum.take(candidates, 1)
      payload = Map.put(payload, "instructions", "é\n\"\\")
      assert {:ok, prepared} = prepare(payload, model, options, candidates)
      [%{encoded: base}] = Map.values(prepared.variants)
      bytes = 16_777_216 + unquote(offset)
      payload = Map.update!(payload, "instructions", &(&1 <> String.duplicate("x", bytes - byte_size(base))))

      if unquote(offset) > 0 do
        assert {:oversized, ^bytes} = prepare(payload, model, options, candidates)
      else
        assert {:ok, prepared} = prepare(payload, model, options, candidates)
        [%{encoded: encoded}] = Map.values(prepared.variants)
        assert byte_size(encoded) == bytes
      end
    end
  end

  test "discarded raw metadata can exceed the bound while final bytes fit" do
    {payload, model, options, candidates} = fixture()
    payload = Map.put(payload, "metadata", %{"discarded" => String.duplicate("x", 1_024)})
    assert byte_size(CodexPooler.JSON.encode!(payload)) > 1_024
    assert {:ok, _} = prepare(payload, model, options, candidates, 1_024)
  end

  test "small raw input can exceed the bound after native envelope expansion" do
    {_, model, _, candidates} = fixture()
    payload = %{"input" => []}
    options = options(payload)
    limit = byte_size(CodexPooler.JSON.encode!(payload))
    assert {:oversized, size} = prepare(payload, model, options, candidates, limit)
    assert size > limit
  end

  test "preparation encodes once per capability and debug projection runs only for selected dispatch" do
    {payload, model, options, candidates} = fixture()
    previous = Application.fetch_env(:codex_pooler, OperationalSettings)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, OperationalSettings, value)
        :error -> Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)

    Application.put_env(:codex_pooler, OperationalSettings, settings: %OperationalSettings{gateway_debug?: true})
    traced = [{PayloadNormalizer, :prepare_json_payload, 5}, {DebugPayloadSummary, :record, 5}]
    on_exit(fn -> Enum.each(traced, &:erlang.trace_pattern(&1, false, [:call_count])) end)

    Enum.each(traced, fn {module, _, _} = function ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(function, true, [:call_count])
    end)

    assert {:ok, prepared} = prepare(payload, model, options, candidates)
    assert {:call_count, 2} = :erlang.trace_info({PayloadNormalizer, :prepare_json_payload, 5}, :call_count)
    assert {:call_count, 0} = :erlang.trace_info({DebugPayloadSummary, :record, 5}, :call_count)
    [{assignment, _} | _] = candidates
    current = selected_options(options, model, assignment.id)
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    Logger.configure(level: :info)
    {{:ok, encoded, derived}, log} = with_log([level: :info], fn -> fetch(prepared, payload, model, current, assignment.id) end)
    assert encoded == prepared.variants[prepared.assignment_variants[assignment.id]].encoded
    assert is_map(derived.runtime.gateway_debug_payload)
    assert log =~ "gateway_debug payload"
    assert {:call_count, 2} = :erlang.trace_info({PayloadNormalizer, :prepare_json_payload, 5}, :call_count)
    assert {:call_count, 1} = :erlang.trace_info({DebugPayloadSummary, :record, 5}, :call_count)
  end

  @tag :large_http_normalization
  test "large ordinary HTTP debug normalization reuses maps and matches cached debug metadata" do
    previous = Application.fetch_env(:codex_pooler, OperationalSettings)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, OperationalSettings, value)
        :error -> Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)

    Application.put_env(:codex_pooler, OperationalSettings, settings: %OperationalSettings{gateway_debug?: true})
    payload = %{"model" => "sample-model", "input" => [%{"role" => "user", "content" => [%{"type" => "input_image", "image_url" => "data:image/png;base64," <> String.duplicate("A", 28 * 1024 * 1024)}]}]}
    model = %Model{upstream_model_id: "provider-model"}
    options = RequestOptions.build(%{request_id: "synthetic-large-http", model_serving_mode_configured: "full", model_serving_mode: "full", model_serving_mode_source: "override"}, @endpoint, payload)
    traced = [{CodexPooler.JSON, :decode!, 1}, {PayloadNormalizer, :normalize_reasoning_aliases, 1}]
    on_exit(fn -> Enum.each(traced, &:erlang.trace_pattern(&1, false, [:call_count])) end)

    Enum.each(traced, fn {module, _, _} = function ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(function, true, [:call_count])
    end)

    {elapsed_us, {:ok, encoded, derived}} = :timer.tc(fn -> PayloadNormalizer.prepare_upstream_payload(payload, model, @endpoint, options) end)
    {:call_count, decode_calls} = :erlang.trace_info({CodexPooler.JSON, :decode!, 1}, :call_count)
    {:call_count, alias_calls} = :erlang.trace_info({PayloadNormalizer, :normalize_reasoning_aliases, 1}, :call_count)
    summary_hash = :crypto.hash(:sha256, CodexPooler.JSON.encode!(derived.runtime.gateway_debug_payload)) |> Base.encode16(case: :lower)
    bytes_hash = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    CodexPooler.TestDiagnostics.puts("large_http_normalization elapsed_us=#{elapsed_us} encoded_bytes=#{byte_size(encoded)} decode_calls=#{decode_calls} alias_calls=#{alias_calls} encoded_sha256=#{bytes_hash} summary_sha256=#{summary_hash}")
    assert decode_calls == 0
    assert alias_calls == 1
    assert {:ok, prepared} = PayloadNormalizer.prepare_json_payload(payload, model, @endpoint, options, [])
    cached_options = PayloadNormalizer.apply_prepared_json(prepared, payload, model, @endpoint, options)
    assert prepared.encoded == encoded
    assert cached_options == derived
  end

  test "candidate dispatch sends the previously prepared bytes through the real websocket sender" do
    {context, upstream, prepared} = dispatch_fixture()
    [%{encoded: expected}] = Map.values(prepared.variants)

    assert {:ok, _response} =
             CandidateDispatch.dispatch(context, fn selected ->
               assert selected.upstream_payload == expected
               assert selected.context.prepared_native_payloads == prepared
               assert selected.context.request_options.runtime.api_key_runtime_epoch == 93

               UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
                 url: selected.url,
                 token: selected.token,
                 upstream_payload: selected.upstream_payload,
                 identity: selected.context.identity,
                 provider_credits_context: ProviderCreditsAdmission.from_selected(selected.context),
                 accounting_request: selected.context.reserved.request,
                 accounting_attempt: selected.context.attempt,
                 writer: fn _frame -> :ok end,
                 assignment_advertised?: true,
                 request_options: selected.context.request_options
               })
             end)

    [received] = FakeUpstream.requests(upstream)
    assert received.method == "WEBSOCKET"
    assert received.body == expected
  end

  @tag :binding_guard
  test "candidate binding mismatch refuses before decryption and sender with neutral route cleanup" do
    {context, upstream, _prepared} = dispatch_fixture()
    context = %{context | payload: Map.put(context.payload, "instructions", "changed")}

    operations = %{
      decrypt_active_secret: fn _, _ -> flunk("binding mismatch reached secret decryption") end,
      upstream_url: fn _, _, _ -> flunk("binding mismatch reached URL resolution") end
    }

    assert {:error, %{status: 500, code: "server_error"}} = CandidateDispatch.dispatch_with_operations(context, fn _ -> flunk("binding mismatch sent upstream") end, operations)
    assert FakeUpstream.count(upstream) == 0
    request = Repo.reload!(context.reserved.request)
    assert request.status == "failed"
    assert request.last_error_code == "server_error"
    assert [%{status: "failed", retryable: false}] = Repo.all(Accounting.Attempt)
  end

  defp dispatch_fixture do
    terminal = CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_prepared", "status" => "completed", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => [%{"role" => "user", "content" => "synthetic"}]}
    options = options(payload) |> RequestOptions.put_runtime_context(api_key_runtime_epoch: 93)
    candidates = [{setup.assignment, setup.identity}]
    assert {:ok, prepared} = prepare(payload, setup.model, options, candidates)
    assert {:ok, reserved} = Accounting.reserve(auth, setup.model, payload, %{endpoint: @endpoint, transport: "websocket", correlation_id: Ecto.UUID.generate()})

    assert {:ok, context} =
             Context.new(%{
               auth: auth,
               endpoint: @endpoint,
               payload: payload,
               model: setup.model,
               reserved: reserved,
               candidates: candidates,
               request_options: options,
               prepared_native_payloads: prepared,
               route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
             })

    {context, upstream, prepared}
  end

  defp prepare(payload, model, options, candidates, limit \\ 16_777_216),
    do: PreparedNativePayloads.prepare(payload, model, @endpoint, options, candidates, limit)

  defp fetch(prepared, payload, model, options, assignment_id),
    do: PreparedNativePayloads.fetch(prepared, payload, model, @endpoint, options, assignment_id)

  defp selected_options(options, model, assignment_id),
    do: RequestOptions.put_routing(options, Dispatch.payload_selection_updates(model, assignment_id, options))

  defp fixture do
    candidates = for _ <- 1..3, do: {%PoolUpstreamAssignment{id: Ecto.UUID.generate()}, %UpstreamIdentity{}}
    [first, equivalent, different] = Enum.map(candidates, fn {assignment, _} -> assignment.id end)
    standard = %{"supported_reasoning_levels" => ~w(low high), "supports_reasoning_summary_parameter" => true}
    other = %{"supported_reasoning_levels" => ~w(low xhigh), "supports_reasoning_summary_parameter" => false}
    model = %Model{upstream_model_id: "provider-model", metadata: %{"source_assignment_models" => %{first => standard, equivalent => Map.put(standard, "supported_reasoning_levels", ~w(high low)), different => other}}}
    payload = %{"model" => "sample-model", "input" => [%{"role" => "user", "content" => "synthetic-private-content"}], "reasoning" => %{"effort" => "ultra", "summary" => "auto"}}
    {payload, model, options(payload), candidates}
  end

  defp options(payload) do
    %{model_serving_mode_configured: "full", model_serving_mode: "full", model_serving_mode_source: "override"}
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.for_websocket(payload)
  end
end
