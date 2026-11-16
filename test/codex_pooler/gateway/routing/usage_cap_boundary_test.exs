defmodule CodexPooler.Gateway.Routing.UsageCapBoundaryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn
  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageCap
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.Windows

  setup do
    pool = pool_fixture()
    capped = active_upstream_assignment_fixture(pool)
    sibling = active_upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "sample-model"})
    %{pool: pool, capped: capped, sibling: sibling, model: model, now: DateTime.utc_now() |> DateTime.truncate(:second)}
  end

  test "an account at its cap is removed and its sibling keeps serving", ctx do
    write_usage!(ctx.capped, ctx.now, "82")
    write_usage!(ctx.sibling, ctx.now, "82")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now)

    assert {:ok, %FilterInput{candidates: [{assignment, _identity}]}, capped_state, [%{pool_upstream_assignment_id: capped_id}]} = UsageCap.exclude_capped(input, state, :required)
    assert assignment.id == ctx.sibling.assignment.id
    assert capped_id == ctx.capped.assignment.id
    assert [{capacity_assignment, _identity}] = capped_state.saved_reset_auto_capacity
    assert capacity_assignment.id == ctx.sibling.assignment.id
    assert {:ok, [{assignment, _identity}], _options, route_state} = RouteFiltering.filter_candidates_with_route_state(input, state)
    assert assignment.id == ctx.sibling.assignment.id
    assert %{reason: "usage_capped"} = RouteState.filter_exclusion(route_state, ctx.capped.assignment.id)
  end

  test "a 30-day plan at its cap is removed and an account without long windows is not", ctx do
    now = ctx.now
    reset = DateTime.add(now, 20 * 86_400, :second)

    assert {:ok, [_]} =
             Windows.upsert_quota_windows(ctx.capped.identity, [
               %{quota_key: "account", window_kind: "primary", window_minutes: 43_200, used_percent: Decimal.new("55"), reset_at: reset, source: "codex_usage_api", source_precision: "observed", quota_scope: "account", quota_family: "account", freshness_state: "fresh", observed_at: now, last_sync_at: now}
             ])

    set_cap!(ctx.capped, 50)
    set_cap!(ctx.sibling, 50)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], now)

    assert {:ok, %FilterInput{candidates: [{assignment, _identity}]}, _state, [%{reasons: [reason]}]} = UsageCap.exclude_capped(input, state, :required)
    assert assignment.id == ctx.sibling.assignment.id
    assert reason["window_kind"] == "primary" and reason["window_minutes"] == 43_200
  end

  test "an account below its cap or without a cap is untouched", ctx do
    write_usage!(ctx.capped, ctx.now, "79")
    write_usage!(ctx.sibling, ctx.now, "99")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now)

    assert {:ok, %FilterInput{candidates: candidates}, _state, []} = UsageCap.exclude_capped(input, state, :required)
    assert length(candidates) == 2
  end

  test "every candidate capped answers the usage-limit 429 with the soonest weekly reset", ctx do
    write_usage!(ctx.capped, ctx.now, "90", 3 * 86_400)
    write_usage!(ctx.sibling, ctx.now, "60", 2 * 86_400)
    set_cap!(ctx.capped, 80)
    set_cap!(ctx.sibling, 50)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now)

    assert {:error, %{status: 429, code: "quota_exhausted", usage_limit: %{resets_at: resets_at}, candidate_exclusions: exclusions}} =
             RouteFiltering.filter_candidates_with_route_state(input, state)

    assert resets_at == DateTime.to_unix(ctx.now) + 2 * 86_400

    assert Enum.all?(exclusions, fn %{reasons: [reason]} -> reason["reason_codes"] == ["exhausted", "operator_usage_cap"] end)
  end

  test "a capped account and an exhausted sibling advise the soonest return of either", ctx do
    write_usage!(ctx.capped, ctx.now, "85", 4 * 86_400)
    write_usage!(ctx.sibling, ctx.now, "100", 86_400)
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now)

    assert {:error, %{status: 429, code: "quota_exhausted", usage_limit: %{resets_at: resets_at}}} = RouteFiltering.filter_candidates_with_route_state(input, state)
    assert resets_at == DateTime.to_unix(ctx.now) + 86_400
  end

  test "a bound reset probe keeps its capped candidate", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now)
    {:ok, bound} = ResetProbe.bind(ResetProbe.new(), ctx.capped.assignment.id, ctx.capped.identity.id, ctx.model.upstream_model_id, "responses")

    assert {:ok, %FilterInput{candidates: [_]}, _state, []} = UsageCap.exclude_capped(input, RouteState.put_reset_probe(state, bound), :required)
  end

  test "an anchored tool-result continuation finishes its turn on the capped account", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now, anchored_options(ctx.capped.assignment.id), %{"input" => [tool_output("call_cap_1")]})

    assert {:ok, %FilterInput{candidates: [_]}, _state, []} = UsageCap.exclude_capped(input, state, :required)
  end

  test "the next anchored user turn is refused so the client rebuilds it elsewhere", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)

    user_turn = %{"input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "next"}]}]}
    {input, state} = filter_context(ctx, [ctx.capped], ctx.now, anchored_options(ctx.capped.assignment.id), user_turn)

    assert {:error, %{status: 503, code: "pinned_continuation_unavailable", continuity_denial: %{"pin_reason" => "previous_response_id"}}} =
             UsageCap.exclude_capped(input, state, :required)
  end

  test "native HTTP: a running turn's next request stays on the capped session account, the next turn leaves it", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    write_usage!(ctx.sibling, ctx.now, "20")
    set_cap!(ctx.capped, 80)
    history = [user_message("first"), tool_call("call_a"), tool_output("call_a"), %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "ok"}]}]

    running = %{"input" => history ++ [user_message("second"), tool_call("call_b"), tool_output("call_b")]}
    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now, session_options(ctx.capped.assignment.id), running)
    assert {:ok, %FilterInput{candidates: candidates}, kept_state, []} = UsageCap.exclude_capped(input, state, :required)
    assert Enum.map(candidates, fn {assignment, _identity} -> assignment.id end) == [ctx.capped.assignment.id, ctx.sibling.assignment.id]
    assert RouteState.usage_capped_identity?(kept_state, ctx.capped.identity.id)
    refute Enum.any?(kept_state.saved_reset_auto_capacity, fn {assignment, _identity} -> assignment.id == ctx.capped.assignment.id end)

    next_turn = %{"input" => history ++ [user_message("second")]}
    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now, session_options(ctx.capped.assignment.id), next_turn)
    assert {:ok, %FilterInput{candidates: [{assignment, _identity}]}, _state, [_exclusion]} = UsageCap.exclude_capped(input, state, :required)
    assert assignment.id == ctx.sibling.assignment.id
  end

  test "a running turn keeps only its session's account, never another capped one", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    write_usage!(ctx.sibling, ctx.now, "95")
    set_cap!(ctx.capped, 80)
    set_cap!(ctx.sibling, 80)
    running = %{"input" => [tool_output("call_c")]}

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now, session_options(ctx.capped.assignment.id), running)
    assert {:ok, %FilterInput{candidates: [{assignment, _identity}]}, _state, [%{pool_upstream_assignment_id: excluded_id}]} = UsageCap.exclude_capped(input, state, :required)
    assert {assignment.id, excluded_id} == {ctx.capped.assignment.id, ctx.sibling.assignment.id}

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now, anchored_options(nil), running)
    assert {:error, %{code: "pinned_continuation_unavailable"}} = UsageCap.exclude_capped(input, state, :required)
  end

  test "a request that needs a file on the capped account keeps that account", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)
    options = RequestOptions.for_websocket(%{}, %{})
    options = %{options | routing: %{options.routing | file_affinity_assignment_id: ctx.capped.assignment.id}}

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now, options, %{"input" => [user_message("use the file")]})
    assert {:ok, %FilterInput{candidates: [_]}, _state, []} = UsageCap.exclude_capped(input, state, :required)
  end

  test "an anchored /v1 request keeps its anchored account", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)
    options = anchored_options(ctx.capped.assignment.id)
    options = %{options | openai_compatibility: %OpenAICompatibility{source_endpoint: "/v1/responses", translated_endpoint: "/backend-api/codex/responses"}}

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now, options, %{"input" => [user_message("next")]})
    assert {:ok, %FilterInput{candidates: [_]}, _state, []} = UsageCap.exclude_capped(input, state, :required)
  end

  test "file uploads avoid a capped account while an uncapped one can take them", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    write_usage!(ctx.sibling, ctx.now, "20")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped, ctx.sibling], ctx.now)
    assert {:ok, %FilterInput{candidates: [{assignment, _identity}]}, _state, _exclusions} = UsageCap.exclude_capped(input, state, :optional)
    assert assignment.id == ctx.sibling.assignment.id

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now)
    assert {:ok, %FilterInput{candidates: [_]}, _state, []} = UsageCap.exclude_capped(input, state, :optional)
  end

  test "optional-quota routes still serve when every account is capped", ctx do
    write_usage!(ctx.capped, ctx.now, "95")
    set_cap!(ctx.capped, 80)

    {input, state} = filter_context(ctx, [ctx.capped], ctx.now)

    assert {:ok, [_], _options, _state} = RouteFiltering.filter_candidates_with_route_state(input, state, quota_mode: :optional)
  end

  test "Pool-return advice counts a capped sibling as returning at its weekly reset", ctx do
    write_usage!(ctx.sibling, ctx.now, "90", 2 * 86_400)
    set_cap!(ctx.sibling, 80)
    sibling = {ctx.sibling.assignment, Repo.reload!(ctx.sibling.identity)}
    request_options = RequestOptions.for_websocket(%{}, %{})

    assert {:ok, %{resets_at: resets_at}} = PoolReturn.others(ctx.model, [sibling], Ecto.UUID.generate(), ctx.now, request_options)
    assert resets_at == DateTime.to_unix(ctx.now) + 2 * 86_400
  end

  defp set_cap!(%{identity: identity}, cap) do
    identity |> Repo.reload!() |> Ecto.Changeset.change(usage_cap_percent: cap) |> Repo.update!()
  end

  defp write_usage!(%{identity: identity}, now, weekly_percent, weekly_reset_in \\ 3 * 86_400) do
    headers = %{
      "x-codex-primary-used-percent" => "10",
      "x-codex-primary-window-minutes" => "300",
      "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(now) + 3600),
      "x-codex-secondary-used-percent" => weekly_percent,
      "x-codex-secondary-window-minutes" => "10080",
      "x-codex-secondary-reset-at" => Integer.to_string(DateTime.to_unix(now) + weekly_reset_in)
    }

    assert {:ok, [_, _]} = Windows.upsert_quota_windows_from_codex_headers(identity, headers, now, nil)
  end

  defp anchored_options(session_assignment_id) do
    options = RequestOptions.for_websocket(%{}, %{})
    session = session_assignment_id && %CodexSession{pool_upstream_assignment_id: session_assignment_id}
    %{options | continuity: %{options.continuity | previous_response_id: "resp_usagecapanchor0001", codex_session: session}}
  end

  defp session_options(session_assignment_id) do
    options = RequestOptions.for_websocket(%{}, %{})
    %{options | continuity: %{options.continuity | codex_session: %CodexSession{pool_upstream_assignment_id: session_assignment_id}}}
  end

  defp user_message(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
  defp tool_call(call_id), do: %{"type" => "function_call", "call_id" => call_id, "name" => "shell", "arguments" => "{}"}
  defp tool_output(call_id), do: %{"type" => "function_call_output", "call_id" => call_id, "output" => "done"}

  defp filter_context(ctx, targets, as_of, request_options \\ RequestOptions.for_websocket(%{}, %{}), payload \\ %{"input" => []}) do
    candidates = Enum.map(targets, &{&1.assignment, Repo.reload!(&1.identity)})
    input = FilterInput.new(%{model: ctx.model, endpoint: "/backend-api/codex/responses", payload: payload, request_options: request_options, candidates: candidates})
    state = RouteState.new(%{visible_model: ctx.model, candidates: candidates, quota_snapshots: Windows.load_routing_quota_snapshots(Enum.map(targets, & &1.identity.id), as_of)})
    {input, state}
  end
end
