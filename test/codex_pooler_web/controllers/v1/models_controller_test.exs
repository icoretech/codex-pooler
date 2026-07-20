defmodule CodexPoolerWeb.V1.ModelsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      gateway_setup: 2,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  test "GET /v1/models returns an OpenAI-compatible list without upstream dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    conn = conn |> auth(setup) |> get("/v1/models")

    assert %{"object" => "list", "data" => [model]} = json_response(conn, 200)
    assert model["id"] == setup.model.exposed_model_id
    assert model["object"] == "model"
    assert model["owned_by"] == "codex-pooler"
    assert model["permission"] == []
    assert model["display_name"] == setup.model.display_name
    assert model["supports_streaming"] == true
    assert model["supports_tools"] == true
    assert model["supports_reasoning"] == true
    assert model["input_modalities"] == ["text"]
    assert is_integer(model["created"])
    refute Map.has_key?(model, "metadata")
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/v1/models"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "models"
    assert request.request_metadata["model_source"]["upstream_identity_id"] == setup.identity.id
  end

  test "GET /v1/models keeps its schema unchanged for reasoning-restricted API keys", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "supported_reasoning_levels" => ~w(low medium high),
          "default_reasoning_level" => "high"
        }
      )

    setup.api_key
    |> Ecto.Changeset.change(enforced_reasoning_effort: "medium")
    |> Repo.update!()

    conn = conn |> auth(setup) |> get("/v1/models")

    assert %{"object" => "list", "data" => [model]} = json_response(conn, 200)
    assert model["id"] == setup.model.exposed_model_id
    refute Map.has_key?(model, "supported_reasoning_levels")
    refute Map.has_key?(model, "default_reasoning_level")
  end

  @tag :model_serving_modes
  test "GET /v1/models is unchanged while the Pool model mode switches", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    baseline = conn |> auth(setup) |> get("/v1/models")

    assert %{"object" => "list", "data" => [%{"id" => exposed_model_id} = baseline_model]} =
             json_response(baseline, 200)

    for mode <- ["full", "lite"] do
      put_models_model_serving_mode!(setup, mode)
      response = conn |> recycle() |> auth(setup) |> get("/v1/models")

      assert %{"object" => "list", "data" => [model]} = json_response(response, 200)
      assert model == baseline_model
      assert model["id"] == exposed_model_id
      refute Map.has_key?(model, "use_responses_lite")
      refute model["id"] =~ "-lite"
      refute model["id"] =~ "-full"
    end

    assert FakeUpstream.count(upstream) == 0
  end

  test "GET /v1/models only exposes policy-authorized visible models", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    %{assignment: allowed_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Allowed visible upstream"
      })

    allowed_visible =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-visible-allowed",
        upstream_model_id: "provider-gpt-visible-allowed",
        display_name: "Visible Allowed",
        metadata: %{"source_assignment_ids" => [allowed_assignment.id]}
      })

    %{assignment: hidden_assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Policy hidden upstream"
      })

    _hidden_by_policy =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-policy-hidden",
        upstream_model_id: "provider-gpt-policy-hidden",
        display_name: "Policy Hidden",
        metadata: %{"source_assignment_ids" => [hidden_assignment.id]}
      })

    %{assignment: unroutable_assignment} =
      upstream_assignment_fixture(setup.pool, %{
        account_label: "Unroutable upstream",
        health_status: "errored"
      })

    _unroutable =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-unroutable",
        upstream_model_id: "provider-gpt-unroutable",
        display_name: "Unroutable",
        metadata: %{"source_assignment_ids" => [unroutable_assignment.id]}
      })

    _suppressed =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-suppressed",
        upstream_model_id: "provider-gpt-suppressed",
        display_name: "Suppressed",
        status: "suppressed",
        metadata: %{"source_assignment_ids" => [setup.assignment.id]}
      })

    setup.api_key
    |> Ecto.Changeset.change(%{
      allowed_model_identifiers: [
        setup.model.exposed_model_id,
        allowed_visible.exposed_model_id,
        "gpt-unroutable",
        "gpt-suppressed"
      ]
    })
    |> Repo.update!()

    conn = conn |> auth(setup) |> get("/v1/models")

    assert %{"object" => "list", "data" => data} = json_response(conn, 200)

    assert Enum.map(data, & &1["id"]) == [
             setup.model.exposed_model_id,
             allowed_visible.exposed_model_id
           ]

    refute Enum.any?(data, &(&1["id"] == "gpt-policy-hidden"))
    refute Enum.any?(data, &(&1["id"] == "gpt-unroutable"))
    refute Enum.any?(data, &(&1["id"] == "gpt-suppressed"))
    assert FakeUpstream.count(upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/v1/models"
    assert request.request_metadata["operation"] == "models"
  end

  test "GET /v1/models exposes SDK-readable context length without backend metadata", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "context_window" => 272_000,
            "max_context_window" => 272_000,
            "auto_compact_token_limit" => nil,
            "comp_hash" => "comp-fixture-hash"
          }
        }
      )

    conn = conn |> auth(setup) |> get("/v1/models")

    assert %{"object" => "list", "data" => [model]} = json_response(conn, 200)
    assert model["id"] == setup.model.exposed_model_id
    assert model["object"] == "model"
    assert model["owned_by"] == "codex-pooler"
    assert model["permission"] == []
    assert model["display_name"] == setup.model.display_name
    assert model["supports_streaming"] == true
    assert model["supports_tools"] == true
    assert model["supports_reasoning"] == true
    assert model["input_modalities"] == ["text"]
    assert is_integer(model["created"])
    assert model["context_length"] == 258_400

    refute Map.has_key?(model, "upstream_model_id")
    refute Map.has_key?(model, "source_assignment_ids")
    refute Map.has_key?(model, "status")
    refute Map.has_key?(model, "supported_in_api")
    refute Map.has_key?(model, "pricing")
    refute Map.has_key?(model, "quotas")
    refute Map.has_key?(model, "account_label")
    refute Map.has_key?(model, "routing_state")
    refute Map.has_key?(model, "secret")
    refute Map.has_key?(model, "input_context_window")
    refute Map.has_key?(model, "metadata")
    refute Map.has_key?(model, "max_context_window")
    refute Map.has_key?(model, "auto_compact_token_limit")
    refute Map.has_key?(model, "comp_hash")
  end

  test "GET /v1/models agrees with the backend Codex effective context projection", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))

    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "upstream_model" => %{
            "context_window" => 272_000,
            "max_context_window" => 272_000,
            "effective_context_window_percent" => 95,
            "auto_compact_token_limit" => nil
          }
        }
      )

    backend_conn = conn |> auth(setup) |> get("/backend-api/codex/models")
    public_conn = conn |> recycle() |> auth(setup) |> get("/v1/models")

    assert %{"models" => [backend_model]} = json_response(backend_conn, 200)
    assert %{"object" => "list", "data" => [public_model]} = json_response(public_conn, 200)

    assert backend_model["context_window"] == 258_400
    assert backend_model["max_context_window"] == 272_000
    assert backend_model["auto_compact_token_limit"] == 232_560
    assert backend_model["effective_context_window_percent"] == 95
    assert public_model["context_length"] == backend_model["context_window"]
    assert public_model["context_length"] == 258_400
    assert FakeUpstream.count(upstream) == 0
  end

  defp put_models_model_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.get_by(ModelServingOverride,
           pool_id: setup.pool.id,
           exposed_model_id: setup.model.exposed_model_id
         ) do
      nil ->
        Repo.insert!(%ModelServingOverride{
          pool_id: setup.pool.id,
          exposed_model_id: setup.model.exposed_model_id,
          mode: mode,
          created_at: timestamp,
          updated_at: timestamp
        })

      override ->
        override
        |> Ecto.Changeset.change(mode: mode, updated_at: timestamp)
        |> Repo.update!()
    end
  end
end
