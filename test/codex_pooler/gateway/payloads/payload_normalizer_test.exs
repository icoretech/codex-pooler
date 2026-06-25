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

    test "lowers backend Codex non-strict function tool schemas for HTTP and websocket upstream JSON" do
      payload = non_strict_tool_schema_payload()
      model = %Model{upstream_model_id: "provider-model"}

      http_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
      websocket_options = RequestOptions.for_websocket(http_options, payload)

      for request_options <- [http_options, websocket_options] do
        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   payload,
                   model,
                   "/backend-api/codex/responses",
                   request_options
                 )

        upstream = Jason.decode!(encoded)

        assert get_in(upstream, ["tools", Access.at(0), "parameters"]) ==
                 lowered_tool_schema()

        assert get_in(upstream, ["tools", Access.at(1), "function", "parameters"]) ==
                 lowered_tool_schema()

        assert get_in(upstream, ["tools", Access.at(2), "parameters"]) ==
                 non_strict_tool_schema()
      end
    end

    test "removes backend Codex encrypted-only agent messages from websocket upstream JSON" do
      payload = %{
        "model" => "gpt-5.5",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hello"},
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [
              %{"type" => "encrypted_content", "encrypted_content" => "opaque-agent-message"}
            ]
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => nil,
            "encrypted_content" => "preserved-assistant-replay"
          },
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [%{"type" => "output_text", "text" => "clear agent message"}]
          }
        ]
      }

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

      assert upstream["input"] == [
               %{"type" => "message", "role" => "user", "content" => "hello"},
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => nil,
                 "encrypted_content" => "preserved-assistant-replay"
               },
               %{
                 "type" => "agent_message",
                 "author" => "root",
                 "recipient" => "worker",
                 "content" => [%{"type" => "output_text", "text" => "clear agent message"}]
               }
             ]
    end

    test "preserves backend Codex plaintext input_text agent messages while stripping encrypted-only siblings" do
      payload = %{
        "model" => "gpt-5.5",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hello"},
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [
              %{"type" => "encrypted_content", "encrypted_content" => "opaque-agent-message"}
            ]
          },
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [%{"type" => "input_text", "text" => "synthetic agent note"}]
          }
        ]
      }

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

      assert upstream["input"] == [
               %{"type" => "message", "role" => "user", "content" => "hello"},
               %{
                 "type" => "agent_message",
                 "author" => "root",
                 "recipient" => "worker",
                 "content" => [%{"type" => "input_text", "text" => "synthetic agent note"}]
               }
             ]
    end

    test "removes backend Codex mixed encrypted agent messages from websocket upstream JSON" do
      payload = %{
        "model" => "gpt-5.5",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "hello"},
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [
              %{"type" => "input_text", "text" => "Message Type: MESSAGE\nPayload:\n"},
              %{"type" => "encrypted_content", "encrypted_content" => "opaque-agent-message"}
            ]
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => nil,
            "encrypted_content" => "preserved-assistant-replay"
          },
          %{
            "type" => "agent_message",
            "author" => "root",
            "recipient" => "worker",
            "content" => [%{"type" => "input_text", "text" => "clear agent message"}]
          }
        ]
      }

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

      assert Enum.map(upstream["input"], &Map.fetch!(&1, "type")) == [
               "message",
               "message",
               "agent_message"
             ]

      assert get_in(upstream, ["input", Access.at(1), "encrypted_content"]) ==
               "preserved-assistant-replay"

      assert get_in(upstream, ["input", Access.at(2), "content", Access.at(0), "type"]) ==
               "input_text"
    end

    test "preserves malformed agent message content shapes while removing encrypted markers" do
      payload = %{
        "model" => "gpt-5.5",
        "input" => [
          %{"type" => "agent_message", "content" => nil},
          %{"type" => "agent_message", "content" => "not-a-list"},
          %{
            "type" => "agent_message",
            "content" => ["odd-part", %{"type" => "input_text", "text" => "clear note"}]
          },
          %{
            "type" => "agent_message",
            "content" => [%{"encrypted_content" => "opaque-agent-message"}]
          }
        ]
      }

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

      assert Enum.map(upstream["input"], &Map.fetch!(&1, "type")) == [
               "agent_message",
               "agent_message",
               "agent_message"
             ]

      assert Enum.map(upstream["input"], &Map.get(&1, "content")) |> Enum.map(&content_shape/1) ==
               [nil, :binary, :list]
    end

    test "normalizes mixed encrypted agent messages while preserving plaintext-only items" do
      payload = %{
        "input" => [
          %{
            "type" => "agent_message",
            "content" => [
              %{"type" => "input_text", "text" => "plain keeper"},
              %{"type" => "encrypted_content", "encrypted_content" => "opaque-agent-message"}
            ]
          },
          %{
            "type" => "agent_message",
            "content" => [%{"type" => "input_text", "text" => "plain keeper only"}]
          }
        ]
      }

      malformed_payload = %{
        "input" => %{
          "type" => "agent_message",
          "content" => [%{"type" => "encrypted_content", "encrypted_content" => "opaque"}]
        }
      }

      assert {:ok,
              %{
                "input" => [
                  %{
                    "type" => "agent_message",
                    "content" => [%{"type" => "input_text", "text" => "plain keeper only"}]
                  }
                ]
              }} = PayloadNormalizer.normalize(payload)

      assert {:ok, ^malformed_payload} = PayloadNormalizer.normalize(malformed_payload)
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

    test "normalizes max thinking alias to reasoning effort" do
      payload = %{"model" => "gpt-4.1", "input" => "hello", "thinking" => "max"}
      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded} =
               PayloadNormalizer.upstream_payload(
                 payload,
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      assert Jason.decode!(encoded)["reasoning"] == %{"effort" => "max"}
    end

    test "maps client-facing ultra reasoning effort to max for backend Codex HTTP, compact, and websocket JSON" do
      payload = %{"model" => "gpt-4.1", "input" => "hello", "reasoning" => %{"effort" => "ultra"}}
      model = %Model{upstream_model_id: "provider-model"}

      http_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
      compact_options = RequestOptions.build(%{}, "/backend-api/codex/responses/compact", payload)
      websocket_options = RequestOptions.for_websocket(http_options, payload)

      for request_options <- [http_options, compact_options, websocket_options] do
        assert {:ok, encoded} =
                 PayloadNormalizer.upstream_payload(
                   payload,
                   model,
                   request_options.transport.upstream_endpoint,
                   request_options
                 )

        assert Jason.decode!(encoded)["reasoning"] == %{"effort" => "max"}
      end
    end

    test "maps enforced ultra reasoning effort to max only in the backend Codex upstream payload" do
      payload = %{"model" => "gpt-4.1", "input" => "hello", "reasoning" => %{"effort" => "low"}}

      request_options =
        RequestOptions.build(
          %{api_key_policy: %{enforced_reasoning_effort: "ultra"}},
          "/backend-api/codex/responses",
          payload
        )

      model = %Model{upstream_model_id: "provider-model"}

      assert {:ok, encoded} =
               PayloadNormalizer.upstream_payload(
                 payload,
                 model,
                 "/backend-api/codex/responses",
                 request_options
               )

      assert Jason.decode!(encoded)["reasoning"] == %{"effort" => "max"}
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

  defp non_strict_tool_schema_payload do
    %{
      "model" => "gpt-5.5",
      "input" => [%{"role" => "user", "content" => "hello"}],
      "tools" => [
        %{
          "type" => "function",
          "name" => "flat_lookup",
          "strict" => false,
          "parameters" => non_strict_tool_schema()
        },
        %{
          "type" => "function",
          "function" => %{
            "name" => "nested_lookup",
            "strict" => false,
            "parameters" => non_strict_tool_schema()
          }
        },
        %{
          "type" => "function",
          "name" => "strict_lookup",
          "strict" => true,
          "parameters" => non_strict_tool_schema()
        }
      ]
    }
  end

  defp non_strict_tool_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "properties" => %{
        "mode" => %{"const" => "fast", "title" => "drop me"},
        "tags" => %{"items" => %{"const" => "tag"}},
        "nested" => %{
          "properties" => %{"ok" => true},
          "required" => ["ok"]
        },
        "choice" => %{
          "anyOf" => [
            %{"const" => "a"},
            %{"type" => "string", "default" => "drop me"}
          ]
        }
      },
      "required" => ["mode"],
      "additionalProperties" => %{"const" => "extra"},
      "$defs" => %{
        "Ref" => %{
          "properties" => %{"value" => %{"const" => "ref"}},
          "required" => ["value"]
        }
      },
      "definitions" => %{
        "Legacy" => %{"items" => %{"const" => "legacy"}}
      }
    }
  end

  defp lowered_tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"enum" => ["fast"]},
        "tags" => %{"type" => "array", "items" => %{"enum" => ["tag"]}},
        "nested" => %{
          "type" => "object",
          "properties" => %{"ok" => %{}},
          "required" => ["ok"]
        },
        "choice" => %{
          "anyOf" => [
            %{"enum" => ["a"]},
            %{"type" => "string"}
          ]
        }
      },
      "required" => ["mode"],
      "additionalProperties" => %{"enum" => ["extra"]},
      "$defs" => %{
        "Ref" => %{
          "type" => "object",
          "properties" => %{"value" => %{"enum" => ["ref"]}},
          "required" => ["value"]
        }
      },
      "definitions" => %{
        "Legacy" => %{"type" => "array", "items" => %{"enum" => ["legacy"]}}
      }
    }
  end

  defp content_shape(nil), do: nil
  defp content_shape(value) when is_binary(value), do: :binary
  defp content_shape(value) when is_list(value), do: :list
end
