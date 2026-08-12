defmodule CodexPoolerWeb.Anthropic.MessagesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, prime_routing_quota!: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @version "2023-06-01"

  test "accepts current version and beta syntax, dispatches fixed max work, and forwards neither header",
       %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("x-api-key", setup.raw_key)
      |> put_req_header("anthropic-version", @version)
      |> put_req_header(
        "anthropic-beta",
        "prompt-caching-2024-07-31, interleaved-thinking-2025-05-14"
      )
      |> post("/v1/messages", %{
        "model" => "claude-opus-client-alias",
        "max_tokens" => 96,
        "stream" => false,
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "thinking" => %{"type" => "enabled", "budget_tokens" => 1_024}
      })

    assert response.status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == "gpt-5.6-sol"
    assert captured.json["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert captured.json["max_output_tokens"] == 96
    assert captured.json["stream"] == true
    assert captured.json["store"] == false
    refute Jason.encode!(captured.json) =~ "claude-opus-client-alias"

    captured_headers = Map.new(captured.headers)
    refute Map.has_key?(captured_headers, "anthropic-version")
    refute Map.has_key?(captured_headers, "anthropic-beta")
    refute Map.has_key?(captured_headers, "x-api-key")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.requested_model == "gemma3"
    assert request.reasoning_effort == "max"

    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) ==
             "anthropic"
  end

  test "accepts Bearer, x-api-key, and matching dual Pool credentials", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    credential_sets = [
      [{"authorization", setup.authorization}],
      [{"x-api-key", setup.raw_key}],
      [{"authorization", setup.authorization}, {"x-api-key", setup.raw_key}]
    ]

    for headers <- credential_sets do
      response =
        conn
        |> recycle()
        |> put_req_header("anthropic-version", @version)
        |> put_headers(headers)
        |> post("/v1/messages", minimal_message())

      assert response.status == 200
    end

    assert FakeUpstream.count(upstream) == 3
  end

  test "rejects mismatched dual credentials before validation or dispatch", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)
    other = active_api_key_fixture(setup.pool)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-api-key", other.raw_key)
      |> post("/v1/messages", %{})

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "authentication_error",
               "message" => "Pool API key is required or invalid"
             }
           } = json_response(response, 401)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "requires exactly the supported API version and bounded beta token syntax", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    cases = [
      {:missing_version, []},
      {:wrong_version, [{"anthropic-version", "2024-01-01"}]},
      {:blank_beta,
       [{"anthropic-version", @version}, {"anthropic-beta", "prompt-caching-2024-07-31,"}]},
      {:space_in_beta, [{"anthropic-version", @version}, {"anthropic-beta", "not a beta token"}]},
      {:control_in_beta,
       [{"anthropic-version", @version}, {"anthropic-beta", "beta-token\nother"}]}
    ]

    for {_label, headers} <- cases do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", setup.authorization)
        |> put_headers(headers)
        |> post("/v1/messages", minimal_message())

      assert %{
               "type" => "error",
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => message
               }
             } = json_response(response, 400)

      assert message in [
               "anthropic-version must be 2023-06-01",
               "anthropic-beta must be a comma-separated list of valid beta tokens"
             ]
    end

    duplicate_version =
      conn
      |> recycle()
      |> put_req_header("authorization", setup.authorization)
      |> Map.update!(:req_headers, fn headers ->
        [
          {"anthropic-version", @version},
          {"anthropic-version", @version}
          | Enum.reject(headers, fn {name, _value} -> name == "anthropic-version" end)
        ]
      end)
      |> post("/v1/messages", minimal_message())

    assert json_response(duplicate_version, 400)["error"]["type"] ==
             "invalid_request_error"

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "counts tokens locally and creates no request, attempt, or upstream traffic", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> put_req_header("anthropic-beta", "token-counting-2024-11-01")
      |> post("/v1/messages/count_tokens", %{
        "model" => "claude-sonnet-arbitrary-alias",
        "system" => "Count this system prompt",
        "messages" => [%{"role" => "user", "content" => "Count this message"}],
        "tools" => [
          %{
            "name" => "lookup",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      })

    assert %{"input_tokens" => count} = json_response(response, 200)
    assert is_integer(count) and count > 0
    assert map_size(Jason.decode!(response.resp_body)) == 1
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "returns an Anthropic 400 for unbounded local count input without dispatch", %{conn: conn} do
    upstream = start_upstream(completed_response())
    setup = facade_gateway_setup(upstream)

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("anthropic-version", @version)
      |> post("/v1/messages/count_tokens", %{
        "messages" => [
          %{"role" => "user", "content" => String.duplicate("x", 8_193)}
        ]
      })

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "request cannot be represented by the bounded local token counter"
             }
           } = json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp minimal_message do
    %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "max_tokens" => 32,
      "stream" => false
    }
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp completed_response do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "provider-hidden-response-id",
           "status" => "completed",
           "model" => "provider-hidden-model",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "hello"}]
             }
           ],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    setup =
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

    prime_routing_quota!(setup.identity)
    setup
  end
end
