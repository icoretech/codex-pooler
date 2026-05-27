defmodule CodexPoolerWeb.V1.ResponsesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  defp with_public_metadata_headers(conn) do
    conn
    |> put_req_header("x-codex-turn-metadata", "turn-metadata-redacted")
    |> put_req_header("x-codex-window-id", "window-redacted")
    |> put_req_header("x-codex-parent-thread-id", "thread-redacted")
    |> put_req_header("x-openai-subagent", "subagent-redacted")
    |> put_req_header("x-codex-extra", "extra-redacted")
    |> put_req_header("x-openai-extra", "extra-redacted")
    |> put_req_header("cookie", "public-client-cookie")
    |> put_req_header("idempotency-key", "public-client-idempotency")
  end

  test "POST /v1/responses non-streaming dispatches through the gateway", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_stream",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response"
      })

    assert %{"id" => "resp_v1_non_stream", "object" => "response"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/responses"

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/codex/responses"

    refute inspect(request.request_metadata) =~ "synthetic v1 response"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /v1/responses does not forward public metadata headers upstream", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_public_headers",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "public response"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> with_public_metadata_headers()
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response with public metadata headers"
      })

    assert %{"id" => "resp_v1_public_headers", "object" => "response"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    captured_headers = Map.new(captured.headers)

    assert captured.path == "/backend-api/codex/responses"
    refute Map.has_key?(captured_headers, "x-codex-turn-metadata")
    refute Map.has_key?(captured_headers, "x-codex-window-id")
    refute Map.has_key?(captured_headers, "x-codex-parent-thread-id")
    refute Map.has_key?(captured_headers, "x-openai-subagent")
    refute Map.has_key?(captured_headers, "x-codex-extra")
    refute Map.has_key?(captured_headers, "x-openai-extra")
    refute Map.has_key?(captured_headers, "cookie")
    refute Map.has_key?(captured_headers, "idempotency-key")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
  end

  test "POST /v1/responses normalizes upstream JSON errors", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic upstream validation"
             },
             "response" => %{"id" => "resp_v1_failed", "status" => "failed"}
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic rejected response"
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request_error"
    assert error["message"] == "synthetic upstream validation"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert [_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits public Responses SSE and filters codex events", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", %{"type" => "codex.rate_limits", "limits" => []}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible text"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream",
               "status" => "completed",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "visible text"
    assert conn.resp_body =~ "event: response.completed\n"
    refute conn.resp_body =~ "codex.rate_limits"
    refute conn.resp_body =~ "event: codex."

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
  end

  test "POST /v1/responses streaming synthesizes missing delta from terminal output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_terminal_only",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "terminal text"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic terminal stream request",
        "stream" => true
      })

    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "terminal text"
    assert conn.resp_body =~ "event: response.completed\n"
  end

  @tag :startup_error
  test "POST /v1/responses streaming startup error returns OpenAI-shaped error", %{conn: conn} do
    upstream =
      start_upstream(
        {:json_error, 400,
         %{
           "error" => %{
             "code" => "invalid_request_error",
             "message" => "synthetic startup rejection"
           }
         }}
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic startup error request",
        "stream" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "upstream_status"
    assert error["message"] == "upstream returned 400"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
  end

  test "POST /v1/responses rejects unsupported logprobs before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic invalid request",
        "logprobs" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "unsupported_parameter"
    assert error["param"] == "logprobs"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses forwards supported SDK-shaped image and file parts safely", %{
    conn: conn
  } do
    image_bytes = "inline image fixture"
    pdf_bytes = "inline pdf fixture"
    image_data_url = "data:image/png;base64," <> Base.encode64(image_bytes)
    file_data_url = "data:application/pdf;base64," <> Base.encode64(pdf_bytes)

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_media_supported",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic multimodal response"},
              %{"type" => "input_image", "image_url" => image_data_url},
              %{"type" => "input_image", "image_url" => "https://example.com/sample.png"},
              %{
                "type" => "input_file",
                "filename" => "sample.pdf",
                "file_data" => file_data_url
              }
            ]
          }
        ]
      })

    assert %{"id" => "resp_v1_media_supported"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert [%{"content" => content}] = captured.json["input"]

    assert Enum.map(content, & &1["type"]) == [
             "input_text",
             "input_image",
             "input_image",
             "input_file"
           ]

    assert Enum.at(content, 1)["image_url"] =~ "data:image/png;base64,"
    assert Enum.at(content, 2)["image_url"] == "https://example.com/sample.png"
    assert Enum.at(content, 3)["filename"] == "sample.pdf"
    assert Enum.at(content, 3)["file_data"] =~ "data:application/pdf;base64,"

    [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    metadata = inspect(request.request_metadata)
    refute metadata =~ "synthetic multimodal response"
    refute metadata =~ image_bytes
    refute metadata =~ pdf_bytes
    refute metadata =~ Base.encode64(image_bytes)
    refute metadata =~ Base.encode64(pdf_bytes)
    refute metadata =~ "https://example.com/sample.png"
  end

  test "POST /v1/responses rejects unsupported media references before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    invalid_parts = [
      {%{"type" => "input_image", "file_id" => "file_image_fixture"},
       "unsupported_input_image_format"},
      {%{"type" => "input_image", "image_url" => "file:///tmp/private.png"},
       "unsupported_input_image_format"},
      {%{
         "type" => "input_file",
         "filename" => "sample.html",
         "file_data" => "data:text/html;base64," <> Base.encode64("html fixture")
       }, "unsupported_input_file_format"}
    ]

    Enum.each(invalid_parts, fn {part, expected_code} ->
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [%{"role" => "user", "content" => [part]}]
        })

      assert %{"error" => %{"code" => ^expected_code, "param" => "input"}} =
               json_response(response, 400)
    end)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses/compact returns deterministic unsupported error without dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> auth(setup)
      |> with_public_metadata_headers()
      |> post("/v1/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic compact request"
      })

    assert %{"error" => error} = json_response(conn, 404)
    assert error["code"] == "unsupported_endpoint"
    assert error["message"] == "Unsupported OpenAI /v1 endpoint"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
