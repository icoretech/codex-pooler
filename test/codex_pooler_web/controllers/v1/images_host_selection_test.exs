defmodule CodexPoolerWeb.V1.ImagesHostSelectionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures, only: [model_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "native image carrier prefers listed catalog host while preserving wire image model", %{
    conn: conn
  } do
    upstream = start_upstream({:json, 200, %{"created" => 1, "data" => []}})
    setup = gateway_setup(upstream)
    host(setup, "a-review-host", %{"visibility" => "hide", "priority" => 0})
    preferred = host(setup, "z-listed-host", %{"visibility" => "list", "priority" => 20})
    Repo.delete!(setup.model)

    response =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{"model" => "gpt-image-2", "prompt" => "synthetic image"})

    assert response.status == 502
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/images/generations"
    assert captured.json["model"] == "gpt-image-2"
    assert [request] = Repo.all(Request)
    assert request.model_id == preferred.id
    assert [attempt] = Repo.all(Attempt)
    assert attempt.upstream_model_id == preferred.upstream_model_id
  end

  for {label, first, second} <- [
        {"listed before hidden", %{"visibility" => "hide", "priority" => 0},
         %{"visibility" => "list", "priority" => 20}},
        {"listed before unspecified", %{}, %{"visibility" => "list"}},
        {"catalog priority before identifier", %{"visibility" => "list", "priority" => 20},
         %{"visibility" => "list", "priority" => 1}},
        {"integer priority before malformed priority",
         %{"visibility" => "list", "priority" => "0"}, %{"visibility" => "list", "priority" => 1}}
      ] do
    @first first
    @second second
    test "Images host selection prefers #{label}", %{conn: conn} do
      upstream = start_upstream(image_stream())
      setup = gateway_setup(upstream)
      first = host(setup, "a-host", @first)
      preferred = host(setup, "z-host", @second)
      Repo.delete!(setup.model)

      assert_image_host(conn, setup, upstream, preferred)
      refute preferred.id == first.id
    end
  end

  test "hidden hosts remain usable when no listed host exists", %{conn: conn} do
    upstream = start_upstream(image_stream())
    setup = gateway_setup(upstream)
    hidden = host(setup, "hidden-host", %{"visibility" => "hide", "priority" => 1})
    Repo.delete!(setup.model)

    assert_image_host(conn, setup, upstream, hidden)
  end

  test "catalog preference cannot admit a host without tools capability", %{conn: conn} do
    upstream = start_upstream(image_stream())
    setup = gateway_setup(upstream)

    host(setup, "a-ineligible", %{"visibility" => "list", "priority" => 0})
    |> Ecto.Changeset.change(supports_tools: false)
    |> Repo.update!()

    hidden = host(setup, "z-eligible", %{"visibility" => "hide", "priority" => 10})
    Repo.delete!(setup.model)

    assert_image_host(conn, setup, upstream, hidden)
  end

  defp host(setup, identifier, attributes) do
    source =
      setup.model.metadata["source_assignment_models"][setup.assignment.id]
      |> Map.drop(["visibility", "priority"])
      |> Map.merge(attributes)
      |> Map.put("slug", identifier)
      |> Map.put("upstream_model_id", "provider-#{identifier}")

    model_fixture(setup.pool, %{
      exposed_model_id: identifier,
      upstream_model_id: "provider-#{identifier}",
      metadata: %{
        "upstream_model" => source,
        "source_assignment_ids" => [setup.assignment.id],
        "source_assignment_models" => %{setup.assignment.id => source}
      }
    })
  end

  defp assert_image_host(conn, setup, upstream, expected) do
    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: ["gpt-image-1"])
    |> Repo.update!()

    result =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{
        "model" => "gpt-image-1",
        "prompt" => "synthetic image"
      })

    assert %{"data" => [%{"b64_json" => "c3ludGhldGlj"}]} = json_response(result, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["model"] == expected.upstream_model_id
    assert [%{"model" => "gpt-image-1", "type" => "image_generation"}] = captured.json["tools"]
    assert [request] = Repo.all(Request)
    assert request.model_id == expected.id
    assert request.request_metadata["effective_model"] == "gpt-image-1"
    assert [attempt] = Repo.all(Attempt)
    assert attempt.upstream_model_id == expected.upstream_model_id
  end

  defp image_stream do
    payload = %{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "output" => [%{"type" => "image_generation_call", "result" => "c3ludGhldGlj"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      }
    }

    {:sse, ["event: response.completed\ndata: #{CodexPooler.JSON.encode!(payload)}\n\n"]}
  end
end
