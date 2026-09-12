defmodule CodexPoolerWeb.Runtime.BackendCodexOverloadSteeringTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      first_event_terminal_payload: 2,
      gateway_setup: 1,
      gateway_upstream: 4,
      native_text_input: 1,
      prime_routing_quota!: 1,
      put_model_source_assignments!: 2,
      rendezvous_score: 2,
      start_upstream: 1,
      use_routing_strategy!: 3
    ]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo

  @overload_code "server_is_overloaded"

  # The terminal arrives after visible output, which is the whole point: by
  # contract there is no cross-account retry once bytes have reached the client,
  # so the only thing that can steer away from an overloaded account is the
  # *next* turn's candidate order.
  test "an overload terminal after visible output steers the next turn to another account", %{
    conn: conn
  } do
    overloading = start_upstream({:sse, overloaded_after_visible_output()})
    healthy = start_upstream({:sse, completed_stream()})

    setup = gateway_setup(overloading)
    fallback = gateway_upstream(setup.pool, healthy, "synthetic-fallback-token", compact?: false)
    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup = %{
      setup
      | model: put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
    }

    # Two different correlators that both make rendezvous prefer the overloading
    # account. Without the second one preferring it too, a later turn landing
    # elsewhere would prove nothing but a different seed.
    [first_seed, second_seed] =
      seeds_preferring([setup.assignment.id, fallback.assignment.id], setup.assignment.id, 2)

    turn!(conn, setup, first_seed)

    assert [%BridgeDemotion{} = demotion] = Repo.all(BridgeDemotion)
    assert demotion.reason_code == "provider_overloaded"
    assert demotion.pool_upstream_assignment_id == setup.assignment.id
    assert demotion.status == "active"

    # Health-neutral by contract: an overload says the provider refused the
    # work, not that the account is unhealthy.
    assert Repo.all(RoutingCircuitState) == []

    assert FakeUpstream.count(overloading) == 1
    assert FakeUpstream.count(healthy) == 0

    turn!(build_conn(), setup, second_seed)

    # The demotion, not the seed, is what moved this turn.
    assert FakeUpstream.count(healthy) == 1
    assert FakeUpstream.count(overloading) == 1
  end

  defp turn!(conn, setup, seed) do
    conn
    |> put_req_header("x-request-id", seed)
    |> auth(setup)
    |> post("/backend-api/codex/responses", %{
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "input" => native_text_input("synthetic overload steering request")
    })
  end

  defp seeds_preferring(assignment_ids, desired_assignment_id, count) do
    1..5_000
    |> Stream.map(&"overload-steering-seed-#{&1}")
    |> Stream.filter(fn seed ->
      Enum.max_by(assignment_ids, &rendezvous_score(seed, &1)) == desired_assignment_id
    end)
    |> Enum.take(count)
  end

  defp overloaded_after_visible_output do
    {_event, failed_payload} = first_event_terminal_payload("response.failed", @overload_code)

    [
      sse_block("response.created", %{
        "type" => "response.created",
        "response" => %{"id" => "resp_overload_steering"}
      }),
      sse_block("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "delta" => "visible"
      }),
      sse_block("response.failed", failed_payload)
    ]
  end

  defp completed_stream do
    [
      sse_block("response.created", %{
        "type" => "response.created",
        "response" => %{"id" => "resp_overload_steering_fallback"}
      }),
      sse_block("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "delta" => "visible"
      }),
      sse_block("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_overload_steering_fallback",
          "status" => "completed",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        }
      })
    ]
  end

  defp sse_block(event_type, payload),
    do: "event: #{event_type}\ndata: #{CodexPooler.JSON.encode!(payload)}\n\n"
end
