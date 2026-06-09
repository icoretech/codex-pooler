defmodule CodexPooler.Gateway.Payloads.PayloadNormalizerTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions

  describe "upstream_payload/4" do
    test "removes backend Codex encrypted tool schema markers from HTTP upstream JSON" do
      payload = encrypted_tool_schema_payload()
      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded} =
               PayloadNormalizer.upstream_payload(
                 payload,
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      upstream = Jason.decode!(encoded)

      assert get_in(upstream, ["tools", Access.at(0), "parameters", "properties", "message"]) ==
               %{
                 "description" => "Initial plain-text task for the new agent.",
                 "type" => "string"
               }

      assert get_in(upstream, [
               "tools",
               Access.at(1),
               "function",
               "parameters",
               "properties",
               "message"
             ]) ==
               %{
                 "description" => "Message text to queue on the target agent.",
                 "type" => "string"
               }
    end

    test "removes backend Codex encrypted tool schema markers from websocket upstream JSON" do
      payload = encrypted_tool_schema_payload()

      request_options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.for_websocket(payload)

      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded} =
               PayloadNormalizer.upstream_payload(
                 payload,
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      upstream = Jason.decode!(encoded)
      assert upstream["type"] == "response.create"

      refute Map.has_key?(
               get_in(upstream, ["tools", Access.at(0), "parameters", "properties", "message"]),
               "encrypted"
             )

      refute Map.has_key?(
               get_in(upstream, [
                 "tools",
                 Access.at(1),
                 "function",
                 "parameters",
                 "properties",
                 "message"
               ]),
               "encrypted"
             )
    end

    test "omits absent, auto, and default service tiers while preserving concrete tiers upstream" do
      model = %Model{upstream_model_id: "provider-model"}

      for payload <- [
            %{"model" => "gpt-4.1", "input" => "hello"},
            %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "auto"},
            %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}
          ] do
        request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   payload,
                   model,
                   "/backend-api/codex/responses",
                   request_options
                 )

        refute Map.has_key?(Jason.decode!(encoded), "service_tier")
      end

      for tier <- ["priority", "flex", "scale", "latency_preview"] do
        payload = %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => tier}
        request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   payload,
                   model,
                   "/backend-api/codex/responses",
                   request_options
                 )

        assert Jason.decode!(encoded)["service_tier"] == tier
      end
    end

    test "carries gateway debug metadata on request options instead of process state" do
      previous_env = Application.get_env(:codex_pooler, OperationalSettings)

      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{gateway_debug?: true}
      )

      on_exit(fn ->
        if previous_env,
          do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
          else: Application.delete_env(:codex_pooler, OperationalSettings)
      end)

      request_options =
        RequestOptions.build(
          %{request_id: "payload-debug-explicit"},
          "/backend-api/codex/responses",
          %{"model" => "gpt-4.1", "input" => "hello"}
        )

      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded, updated_options} =
               PayloadNormalizer.prepare_upstream_payload(
                 %{"model" => "gpt-4.1", "input" => "hello"},
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      assert Jason.decode!(encoded)["model"] == "provider-model"

      assert %{
               "request_id" => "payload-debug-explicit",
               "transport" => "http_json"
             } = updated_options.runtime.gateway_debug_payload

      refute Process.get({:codex_gateway_debug_payload, "payload-debug-explicit"})
    end

    test "returns a gateway error when a transcription upload path is unreadable" do
      request_options =
        RequestOptions.build(
          %{
            media_upload: %{
              path: Path.join(System.tmp_dir!(), "codex-pooler-missing-upload"),
              redacted_filename: "upload",
              content_type: "audio/wav",
              size: 12
            }
          },
          "/backend-api/transcribe",
          %{"model" => "gpt-4o-transcribe"}
        )

      model = %Model{upstream_model_id: "provider-transcribe"}

      assert PayloadNormalizer.upstream_payload(
               %{"model" => "gpt-4o-transcribe"},
               model,
               "/backend-api/transcribe",
               request_options
             ) ==
               {:error,
                %{
                  status: 400,
                  code: "invalid_request",
                  message: "file upload is not readable",
                  param: "file"
                }}
    end

    test "omits enforced auto and default service tiers from upstream JSON" do
      model = %Model{upstream_model_id: "provider-model"}

      for tier <- ["auto", "default"] do
        request_options =
          RequestOptions.build(
            %{api_key_policy: %{enforced_service_tier: tier}},
            "/backend-api/codex/responses",
            %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"}
          )

        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "priority"},
                   model,
                   "/backend-api/codex/responses",
                   request_options
                 )

        refute Map.has_key?(Jason.decode!(encoded), "service_tier")
      end
    end

    test "omits requested auto and default service tiers from upstream JSON" do
      model = %Model{upstream_model_id: "provider-model"}

      for tier <- ["auto", "default"] do
        request_options =
          RequestOptions.build(
            %{},
            "/backend-api/codex/responses",
            %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => tier}
          )

        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => tier},
                   model,
                   "/backend-api/codex/responses",
                   request_options
                 )

        refute Map.has_key?(Jason.decode!(encoded), "service_tier")
      end
    end

    test "preserves explicit enforced service tiers upstream" do
      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_service_tier: "priority"}},
          "/backend-api/codex/responses",
          %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"}
        )

      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded} =
               PayloadNormalizer.upstream_payload(
                 %{"model" => "gpt-4.1", "input" => "hello", "service_tier" => "default"},
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      assert Jason.decode!(encoded)["service_tier"] == "priority"
    end
  end

  defp encrypted_tool_schema_payload do
    %{
      "model" => "gpt-5.5",
      "input" => [%{"role" => "user", "content" => "hello"}],
      "tools" => [
        %{
          "type" => "function",
          "name" => "spawn_agent",
          "strict" => false,
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "message" => %{
                "type" => "string",
                "description" => "Initial plain-text task for the new agent.",
                "encrypted" => true
              },
              "task_name" => %{"type" => "string"}
            },
            "required" => ["task_name", "message"],
            "additionalProperties" => false
          }
        },
        %{
          "type" => "function",
          "function" => %{
            "name" => "send_message",
            "strict" => false,
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{
                  "type" => "string",
                  "description" => "Message text to queue on the target agent.",
                  "encrypted" => true
                },
                "target" => %{"type" => "string"}
              },
              "required" => ["target", "message"],
              "additionalProperties" => false
            }
          }
        }
      ]
    }
  end
end
