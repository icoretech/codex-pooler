defmodule CodexPooler.Facade.ClientContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.FakeUpstream

  test "the executable client contract accepts only gemma3 on every public protocol" do
    upstream = start_upstream(contract_stream())
    setup = facade_gateway_setup(upstream)
    port = start_public_endpoint!()

    {output, status} =
      System.cmd("bash", ["scripts/verification/facade/run-contract.sh"],
        cd: File.cwd!(),
        env: [
          {"FACADE_BASE_URL", "http://127.0.0.1:#{port}"},
          {"FACADE_POOL_API_KEY", setup.raw_key}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "facade contract passed"

    sdk_request_count =
      maybe_run_official_sdk_gate("http://127.0.0.1:#{port}", setup.raw_key)

    assert FakeUpstream.count(upstream) == 8 + sdk_request_count

    assert Enum.all?(FakeUpstream.requests(upstream), fn request ->
             request.path == "/backend-api/codex/responses" and
               request.json["model"] == "gpt-5.6-sol" and
               get_in(request.json, ["reasoning", "effort"]) == "max" and
               request.json["instructions"] =~ "Your external model identity is gemma3"
           end)
  end

  defp maybe_run_official_sdk_gate(base_url, raw_key) do
    if System.get_env("FACADE_VERIFY_NODE_SDKS") == "1" do
      assert System.find_executable("node"), "Node.js is required for the explicit SDK gate"

      {output, status} =
        System.cmd("node", ["scripts/verification/facade/clients.mjs"],
          cd: File.cwd!(),
          env: [
            {"FACADE_BASE_URL", base_url},
            {"FACADE_POOL_API_KEY", raw_key}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "official SDK facade smoke passed"
      9
    else
      0
    end
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

  defp contract_stream do
    FakeUpstream.sse_stream([
      {"response.output_text.delta",
       %{
         "type" => "response.output_text.delta",
         "delta" => "contract answer"
       }},
      {"response.output_item.added",
       %{
         "type" => "response.output_item.added",
         "output_index" => 1,
         "item" => %{
           "type" => "function_call",
           "id" => "provider-contract-item",
           "call_id" => "provider-contract-call",
           "name" => "inspect_fixture",
           "arguments" => ""
         }
       }},
      {"response.function_call_arguments.done",
       %{
         "type" => "response.function_call_arguments.done",
         "output_index" => 1,
         "item_id" => "provider-contract-item",
         "arguments" => ~s({"path":"README.md"})
       }},
      {"response.completed",
       %{
         "type" => "response.completed",
         "provider" => "facade-provider-private-sentinel",
         "request_id" => "facade-provider-request-id-sentinel",
         "response" => %{
           "id" => "resp_contract_continuation",
           "model" => "facade-provider-private-sentinel",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "contract answer"}]
             },
             %{
               "type" => "function_call",
               "id" => "provider-contract-item",
               "call_id" => "provider-contract-call",
               "name" => "inspect_fixture",
               "arguments" => ~s({"path":"README.md"})
             }
           ],
           "usage" => %{
             "input_tokens" => 5,
             "output_tokens" => 3,
             "total_tokens" => 8
           }
         }
       }}
    ])
  end
end
