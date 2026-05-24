defmodule CodexPooler.Gateway.OpenAICompatibilityContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport

  setup do
    old_files_config = Application.get_env(:codex_pooler, Files, [])
    old_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 256,
      file_ttl_seconds: 60
    )

    Application.put_env(:codex_pooler, FileBridge,
      finalize_retry_timeout_ms: 1_000,
      finalize_retry_interval_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, Files, old_files_config)
      Application.put_env(:codex_pooler, FileBridge, old_bridge_config)
    end)

    :ok
  end

  @tag :tool_result_previous_response
  test "v1 Responses preserves previous_response_id only for semantic tool-result continuations",
       %{conn: conn} do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.require_json_field(
             "previous_response_id",
             %{
               "id" => "resp_v1_tool_continuation",
               "object" => "response",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             },
             %{"error" => %{"code" => "missing_tool_context"}}
           ),
           FakeUpstream.reject_json_field(
             "previous_response_id",
             %{
               "id" => "resp_v1_ordinary_continuation",
               "object" => "response",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             },
             %{"error" => %{"code" => "invalid_previous_response_id"}}
           )
         ]}
      )

    setup = gateway_setup(upstream)

    tool_conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_tool_origin",
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_v1_tool",
            "name" => "sample_tool",
            "output" => "synthetic tool output"
          }
        ]
      })

    assert %{"id" => "resp_v1_tool_continuation"} = json_response(tool_conn, 200)

    ordinary_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_stale_ordinary",
        "input" => "synthetic ordinary continuation"
      })

    assert %{"id" => "resp_v1_ordinary_continuation"} = json_response(ordinary_conn, 200)

    assert [tool_request, ordinary_request] = FakeUpstream.requests(upstream)
    assert tool_request.json["previous_response_id"] == "resp_v1_tool_origin"

    assert tool_request.json["input"] |> List.first() |> Map.fetch!("type") ==
             "custom_tool_call_output"

    refute Map.has_key?(ordinary_request.json, "previous_response_id")

    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic tool output"
    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic ordinary continuation"
    refute persisted_gateway_metadata(setup.pool.id) =~ "resp_v1_tool_origin"
  end

  @tag :tool_result_previous_response
  test "v1 Responses accepts ai-sdk item references in previous response tool-result continuations",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_v1_ai_sdk_item_reference",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "missing_tool_context"}}
        )
      )

    setup = gateway_setup(upstream)

    response_conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_v1_ai_sdk_previous",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]
          },
          %{"type" => "item_reference", "id" => "msg_existing_123"},
          %{
            "type" => "function_call_output",
            "call_id" => "call_123",
            "output" => "{\"ok\":true}"
          }
        ],
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup",
            "description" => "Lookup synthetic fixture",
            "parameters" => %{
              "$schema" => "http://json-schema.org/draft-07/schema#",
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{"value" => %{"type" => "string"}},
              "required" => ["value"]
            }
          }
        ]
      })

    assert %{"id" => "resp_v1_ai_sdk_item_reference"} = json_response(response_conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == "resp_v1_ai_sdk_previous"

    assert [
             %{"type" => "message", "role" => "user"},
             %{"type" => "item_reference", "id" => "msg_existing_123"},
             %{"type" => "function_call_output", "call_id" => "call_123"}
           ] = captured.json["input"]

    assert [
             %{"type" => "function", "name" => "lookup", "parameters" => %{"type" => "object"}}
           ] = captured.json["tools"]

    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic follow-up"
    refute persisted_gateway_metadata(setup.pool.id) =~ "msg_existing_123"
    refute persisted_gateway_metadata(setup.pool.id) =~ "resp_v1_ai_sdk_previous"
  end

  @tag :input_file_affinity
  test "v1 input_file routes to the uploaded file owner assignment and rejects cross-key or missing refs",
       %{conn: conn} do
    unique = System.unique_integer([:positive])
    file_id = "file_v1_affinity_#{unique}"

    file_upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      file_upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: FakeUpstream.url(file_upstream) <> "/upload/#{file_id}"
      )
    )

    setup = gateway_setup(file_upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("affinity.txt", "text/plain", "synthetic affinity bytes")
      })

    assert %{"id" => ^file_id, "status" => "uploaded"} = json_response(create_conn, 200)

    owner_response_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_file_owner",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    other_response_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_v1_file_other_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = swap_upstream_base_url!(setup, owner_response_upstream)

    other =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_v1_file_other_#{unique}",
        metadata: %{"base_url" => FakeUpstream.url(other_response_upstream)},
        access_token: "v1-file-other-token"
      })

    prime_routing_quota!(other.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, other.assignment])
      )

    owner_before = FakeUpstream.count(owner_response_upstream)
    other_before = FakeUpstream.count(other_response_upstream)

    response_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_file", "file_id" => file_id}]
          }
        ]
      })

    assert %{"id" => "resp_v1_file_owner"} = json_response(response_conn, 200)
    assert FakeUpstream.count(owner_response_upstream) == owner_before + 1
    assert FakeUpstream.count(other_response_upstream) == other_before

    assert [captured] = FakeUpstream.requests(owner_response_upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert captured.json["input"]
           |> List.first()
           |> Map.fetch!("content")
           |> List.first()
           |> Map.fetch!("file_id") == file_id

    refute inspect(captured.json) =~ "fake-upload"
    refute inspect(captured.json) =~ "fake-download"

    second_key = active_api_key_fixture(setup.pool)

    denied_conn =
      build_conn()
      |> auth(second_key)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => file_id}]
      })

    assert %{"error" => %{"code" => "file_not_found", "param" => "file_id"}} =
             json_response(denied_conn, 404)

    missing_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [%{"type" => "input_file", "file_id" => "file_missing_v1_affinity"}]
      })

    assert %{"error" => %{"code" => "file_not_found", "param" => "file_id"}} =
             json_response(missing_conn, 404)

    assert FakeUpstream.count(owner_response_upstream) == owner_before + 1
    assert FakeUpstream.count(other_response_upstream) == other_before

    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic affinity bytes"
    refute persisted_gateway_metadata(setup.pool.id) =~ "fake-upload"
    refute persisted_gateway_metadata(setup.pool.id) =~ "fake-download"
  end

  test "sediment image references stay rejected before dispatch with sanitized metadata", %{
    conn: conn
  } do
    file_id = "file_v1_sediment_#{System.unique_integer([:positive])}"
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: FakeUpstream.url(upstream) <> "/upload/#{file_id}"
      )
    )

    setup = gateway_setup(upstream)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("image-ref.txt", "text/plain", "synthetic sediment bytes")
      })

    assert json_response(create_conn, 200)["id"] == file_id
    create_dispatch_count = FakeUpstream.count(upstream)

    rejected_conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_image", "image_url" => "sediment://#{file_id}"}
            ]
          }
        ]
      })

    assert %{"error" => %{"code" => "unsupported_input_image_format", "param" => "input"}} =
             json_response(rejected_conn, 400)

    assert FakeUpstream.count(upstream) == create_dispatch_count
    refute persisted_gateway_metadata(setup.pool.id) =~ "sediment://"
    refute persisted_gateway_metadata(setup.pool.id) =~ "synthetic sediment bytes"
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-task11-file-#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp persisted_gateway_metadata(pool_id) do
    Repo.all(from request in Request, where: request.pool_id == ^pool_id)
    |> inspect()
  end

  defp swap_upstream_base_url!(setup, upstream) do
    base_url = FakeUpstream.url(upstream)

    identity =
      setup.identity
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    assignment =
      setup.assignment
      |> Ecto.Changeset.change(%{metadata: %{"base_url" => base_url}})
      |> Repo.update!()

    %{setup | identity: identity, assignment: assignment}
  end

  defp prime_routing_quota!(identity) do
    BackendCodexTestSupport.prime_routing_quota!(identity)
  end

  defp put_model_source_assignments!(model, assignments) do
    BackendCodexTestSupport.put_model_source_assignments!(model, assignments)
  end
end
