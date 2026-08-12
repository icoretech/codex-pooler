defmodule CodexPooler.Gateway.Facade.ConcurrencyTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.FacadeAssertions

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, CodexSession}
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "simultaneous identical facade values stay isolated by Pool and API key" do
    parent = self()
    first_ref = make_ref()
    second_ref = make_ref()

    first_upstream =
      start_upstream(
        barrier_success_stream("first Pool answer",
          notify: parent,
          release_ref: first_ref
        )
      )

    second_upstream =
      start_upstream(
        barrier_success_stream("second Pool answer",
          notify: parent,
          release_ref: second_ref
        )
      )

    first = facade_gateway_setup(first_upstream)
    second = facade_gateway_setup(second_upstream)
    install_one_request_limit!(first.api_key)
    install_one_request_limit!(second.api_key)

    raw_cache = "facade-raw-cache-key-sentinel"
    raw_session = "identical-raw-ollama-session"

    tasks = [
      start_request_task(parent, :first, first, raw_cache, raw_session),
      start_request_task(parent, :second, second, raw_cache, raw_session)
    ]

    releases =
      for expected_ref <- [first_ref, second_ref], into: %{} do
        assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^expected_ref}, 5_000
        {expected_ref, upstream_pid}
      end

    Enum.each(releases, fn {release_ref, upstream_pid} ->
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end)

    results = Task.await_many(tasks, 10_000) |> Map.new()

    assert %{first: first_response, second: second_response} = results
    first_body = json_response(first_response, 200)
    second_body = json_response(second_response, 200)

    assert response_text(first_body) == "first Pool answer"
    assert response_text(second_body) == "second Pool answer"
    assert first_body["model"] == "gemma3"
    assert second_body["model"] == "gemma3"
    assert_cloaked_json(first_body)
    assert_cloaked_json(second_body)
    assert_cloaked_headers(first_response)
    assert_cloaked_headers(second_response)

    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(second_upstream) == 1
    assert [first_capture] = FakeUpstream.requests(first_upstream)
    assert [second_capture] = FakeUpstream.requests(second_upstream)
    assert_fixed_target(first_capture)
    assert_fixed_target(second_capture)

    first_cache = first_capture.json["prompt_cache_key"]
    second_cache = second_capture.json["prompt_cache_key"]
    assert first_cache =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/
    assert second_cache =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/
    refute first_cache == second_cache

    capture_text = inspect({first_capture, second_capture})
    refute capture_text =~ raw_cache
    refute capture_text =~ raw_session

    assert_accounting_isolated(first, second)
    assert_affinity_isolated(first, second, raw_cache, raw_session)

    # Both keys have an independent one-request-per-minute policy. If either
    # counter were shared across Pools or keys, one of the simultaneous calls
    # above would have been rejected before reaching its own upstream.
    assert Enum.sort(policy_reservation_counts([first.api_key.id, second.api_key.id])) == [1, 1]
  end

  defp start_request_task(parent, label, setup, raw_cache, raw_session) do
    Task.async(fn ->
      Sandbox.allow(Repo, parent, self())

      response =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> put_req_header("x-ollama-session-id", raw_session)
        |> post("/v1/responses", %{
          "input" => "identical public request",
          "max_output_tokens" => 32,
          "prompt_cache_key" => raw_cache
        })

      {label, response}
    end)
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: "gpt-5.6-sol",
      upstream_model_id: "gpt-5.6-sol",
      pricing_ref: "gpt-5.6-sol",
      display_name: "Facade fixed target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max",
        "input_modalities" => ["text", "image"]
      }
    )
  end

  defp install_one_request_limit!(api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.get_by(APIKeyPolicyBinding,
           api_key_id: api_key.id,
           binding_scope: "default",
           status: "active"
         ) do
      nil ->
        %APIKeyPolicyBinding{
          api_key_id: api_key.id,
          binding_scope: "default",
          status: "active",
          max_requests_per_minute: 1,
          created_at: now,
          updated_at: now
        }
        |> Repo.insert!()

      binding ->
        binding
        |> Ecto.Changeset.change(max_requests_per_minute: 1, updated_at: now)
        |> Repo.update!()
    end
  end

  defp barrier_success_stream(text, opts) do
    FakeUpstream.barrier_sse_stream(
      [
        {"response.completed",
         %{
           "type" => "response.completed",
           "provider" => "facade-provider-private-sentinel",
           "request_id" => "facade-provider-request-id-sentinel",
           "response" => %{
             "id" => "resp_facade_concurrency",
             "model" => "facade-provider-private-sentinel",
             "status" => "completed",
             "output" => [
               %{
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => text}]
               }
             ],
             "usage" => %{
               "input_tokens" => 4,
               "output_tokens" => 2,
               "total_tokens" => 6
             }
           }
         }}
      ],
      barrier_after: 0,
      notify: Keyword.fetch!(opts, :notify),
      release_ref: Keyword.fetch!(opts, :release_ref)
    )
  end

  defp assert_fixed_target(capture) do
    assert capture.path == "/backend-api/codex/responses"
    assert capture.json["model"] == "gpt-5.6-sol"
    assert get_in(capture.json, ["reasoning", "effort"]) == "max"
    assert capture.json["instructions"] =~ "Your external model identity is gemma3"
  end

  defp assert_accounting_isolated(first, second) do
    requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id in ^[first.pool.id, second.pool.id],
          order_by: [asc: r.pool_id]
        )
      )

    assert length(requests) == 2

    assert MapSet.new(Enum.map(requests, &{&1.pool_id, &1.api_key_id})) ==
             MapSet.new([
               {first.pool.id, first.api_key.id},
               {second.pool.id, second.api_key.id}
             ])

    assert Enum.all?(requests, fn request ->
             request.status == "succeeded" and request.requested_model == "gemma3" and
               request.reasoning_effort == "max"
           end)

    attempts =
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: r.id == a.request_id,
          where: r.pool_id in ^[first.pool.id, second.pool.id]
        )
      )

    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.status == "succeeded"))
    assert Enum.all?(attempts, &(&1.upstream_model_id == "gpt-5.6-sol"))

    assert MapSet.new(Enum.map(attempts, & &1.pool_upstream_assignment_id)) ==
             MapSet.new([first.assignment.id, second.assignment.id])
  end

  defp assert_affinity_isolated(first, second, raw_cache, raw_session) do
    sessions =
      Repo.all(
        from(s in CodexSession,
          where: s.pool_id in ^[first.pool.id, second.pool.id],
          order_by: [asc: s.pool_id]
        )
      )

    assert length(sessions) == 2
    assert Enum.all?(sessions, &(&1.session_key =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/))
    assert Enum.uniq(Enum.map(sessions, & &1.session_key)) |> length() == 2

    assert MapSet.new(Enum.map(sessions, &{&1.pool_id, &1.api_key_id})) ==
             MapSet.new([
               {first.pool.id, first.api_key.id},
               {second.pool.id, second.api_key.id}
             ])

    affinities =
      Repo.all(
        from(a in BridgeAffinity,
          where: a.pool_id in ^[first.pool.id, second.pool.id]
        )
      )

    assert length(affinities) == 2
    assert Enum.all?(affinities, &(&1.affinity_kind == "codex_session"))
    assert Enum.uniq(Enum.map(affinities, & &1.affinity_key_hash)) |> length() == 2

    persisted = inspect({sessions, affinities, Repo.all(Request)})
    refute persisted =~ raw_cache
    refute persisted =~ raw_session
  end

  defp policy_reservation_counts(api_key_ids) do
    Repo.all(
      from(e in CodexPooler.Accounting.LedgerEntry,
        where:
          e.api_key_id in ^api_key_ids and e.entry_kind == "reservation" and
            e.amount_status == "recorded",
        group_by: e.api_key_id,
        select: count(e.id)
      )
    )
  end

  defp response_text(body) do
    get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"])
  end
end
