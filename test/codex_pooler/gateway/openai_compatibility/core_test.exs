defmodule CodexPooler.Gateway.OpenAICompatibilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{
    Audio,
    Chat,
    Files,
    Images,
    Matrix,
    Responses,
    Validation
  }

  alias CodexPooler.Gateway.Payloads.RequestOptions

  test "supported field matrix covers endpoint families" do
    assert "model" in Matrix.supported_fields(:responses)
    assert "messages" in Matrix.supported_fields(:chat)
    assert "purpose" in Matrix.supported_fields(:files)
    assert "file" in Matrix.supported_fields(:audio)
    assert "input_fidelity" in Matrix.supported_fields(:images)
  end

  @tag :responses_coercion
  test "accepted Responses fields coerce to gateway payload and request options" do
    payload = %{
      "model" => "gpt-fixture-text",
      "instructions" => "Use concise synthetic output",
      "input" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "lookup_fixture",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ],
      "tool_choice" => "auto",
      "reasoning" => %{"effort" => "minimal"},
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"ok" => %{"type" => "boolean"}},
            "required" => ["ok"]
          }
        }
      },
      "stream" => true
    }

    assert {:ok, result} =
             Responses.coerce(payload,
               request_id: "req_fixture",
               collect_openai_response_stream: true
             )

    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-fixture-text"
    assert result.payload["tools"] == payload["tools"]
    assert result.payload["stream"] == true
    assert result.payload["store"] == false

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic input"}]
             }
           ] =
             result.payload["input"]

    assert %RequestOptions{} = result.request_options
    assert RequestOptions.route_class(result.request_options) == "proxy_stream"
    assert result.request_options.routing.requested_model == nil
    refute inspect(result.request_options.request_metadata) =~ "synthetic input"
  end

  @tag :responses_coercion
  test "string Responses input coerces to a backend-compatible input_text message" do
    assert {:ok, result} =
             Responses.coerce(
               %{
                 "model" => "gpt-fixture-text",
                 "input" => "synthetic direct string input"
               },
               collect_openai_response_stream: true
             )

    assert result.payload["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "synthetic direct string input"}]
             }
           ]
  end

  @tag :responses_coercion
  test "Chat payloads coerce through a Responses-compatible intermediate" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [
        %{"role" => "system", "content" => "Synthetic system"},
        %{"role" => "user", "content" => "Synthetic user"}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "fixture_schema",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"answer" => %{"type" => "string"}},
            "required" => ["answer"]
          }
        }
      },
      "tool_choice" => "none"
    }

    assert {:ok, result} = Chat.coerce(payload, collect_openai_response_stream: true)
    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-fixture-text"
    assert result.payload["stream"] == true
    assert result.payload["store"] == false

    assert [
             %{
               "type" => "message",
               "role" => "system",
               "content" => [%{"type" => "input_text", "text" => "Synthetic system"}]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "Synthetic user"}]
             }
           ] = result.payload["input"]

    assert get_in(result.payload, ["text", "format", "type"]) == "json_schema"
    assert get_in(result.payload, ["text", "format", "strict"]) == true
  end

  @tag :responses_coercion
  test "Images generation validates parameters and builds an image_generation Responses payload" do
    payload = %{
      "model" => "gpt-image-1",
      "prompt" => "synthetic image request",
      "size" => "1024x1024",
      "quality" => "high",
      "background" => "transparent",
      "input_fidelity" => "high",
      "n" => 1
    }

    assert {:ok, result} = Images.coerce_generation(payload)
    assert result.endpoint == "/backend-api/codex/responses"
    assert result.payload["model"] == "gpt-image-1"
    assert result.payload["stream"] == true
    assert [%{"type" => "image_generation", "quality" => "high"}] = result.payload["tools"]
    assert result.payload["tool_choice"] == %{"type" => "image_generation"}
  end

  @tag :responses_validation
  test "OpenAI shell validation uses validation-only adapter contracts" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic direct string input"
    }

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic"}]
    }

    image_payload = %{
      "model" => "gpt-image-1",
      "prompt" => "synthetic image request"
    }

    assert {:ok, ^response_payload} = Responses.validate(response_payload)
    assert {:ok, ^chat_payload} = Chat.validate(chat_payload)
    assert {:ok, ^image_payload} = Images.validate_generation(image_payload)

    assert :ok = Validation.validate_shell(:responses, response_payload)
    assert :ok = Validation.validate_shell(:chat, chat_payload)
    assert :ok = Validation.validate_shell(:image_generations, image_payload)

    assert {:error, %{code: "invalid_request", param: "tools"}} =
             Validation.validate_shell(:responses, %{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [%{"type" => "function", "function" => %{}}]
             })
  end

  @tag :responses_validation
  test "public compatibility validators return structured errors for non-map payloads" do
    expected_reason = %{
      status: 400,
      code: "invalid_request",
      message: "request body must be an object",
      param: nil
    }

    assert {:error, ^expected_reason} = Validation.normalize_payload("not an object")
    assert {:error, ^expected_reason} = Responses.validate(["not", "an", "object"])
    assert {:error, ^expected_reason} = Responses.coerce(:not_an_object)
    assert {:error, ^expected_reason} = Chat.validate(nil)
    assert {:error, ^expected_reason} = Chat.coerce(nil)
    assert {:error, ^expected_reason} = Images.validate_generation(42)
    assert {:error, ^expected_reason} = Images.coerce_generation(42)
    assert {:error, ^expected_reason} = Images.validate_edit(false)
    assert {:error, ^expected_reason} = Images.coerce_edit(false)
    assert {:error, ^expected_reason} = Files.validate_create("file payload")
    assert {:error, ^expected_reason} = Audio.validate_transcription("audio payload")
    assert {:error, ^expected_reason} = Validation.validate_shell(:responses, "not an object")
  end

  @tag :unsupported_fields
  test "logprobs returns deterministic unsupported parameter errors" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "logprobs" => true
             })

    assert reason == %{
             status: 400,
             code: "unsupported_parameter",
             message: "Unsupported parameter: logprobs",
             param: "logprobs"
           }
  end

  @tag :unsupported_fields
  test "untranslatable tool and legacy Chat function shapes are rejected" do
    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [%{"type" => "function", "function" => %{}}]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "functions"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [%{"role" => "user", "content" => "synthetic"}],
               "functions" => [%{"name" => "legacy_fixture"}]
             })
  end

  @tag :unsupported_fields
  test "malformed nested compatibility payloads are rejected before coercion" do
    assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [%{"type" => "synthetic_unknown", "payload" => %{}}]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "messages"}} =
             Chat.coerce(%{
               "model" => "gpt-fixture-text",
               "messages" => [
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "text", "payload" => "missing text"}]
                 }
               ]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "tools"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 %{"type" => "function", "function" => %{"name" => "missing_parameters"}}
               ]
             })
  end

  @tag :unsupported_fields
  test "invalid image parameters return deterministic reason maps" do
    assert {:error, reason} =
             Images.coerce_generation(%{
               "model" => "gpt-image-1",
               "prompt" => "synthetic image request",
               "size" => "2048x2048"
             })

    assert reason == %{
             status: 400,
             code: "invalid_request",
             message: "size is not supported",
             param: "size"
           }

    assert {:error, %{code: "invalid_model", param: "model"}} =
             Images.coerce_generation(%{
               "model" => "unknown-image-model",
               "prompt" => "synthetic image request"
             })
  end

  test "Responses tool-result input normalization returns explicit results without raising" do
    assert {:ok, %{payload: payload}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [
                 %{"call_id" => "call_fixture", "result" => %{"status" => "ok"}}
               ]
             })

    assert [%{"call_id" => "call_fixture", "result" => %{"status" => "ok"}}] =
             payload["input"]
  end

  test "Responses item_reference continuations require previous response tool-result context" do
    payload = %{
      "model" => "gpt-fixture-text",
      "previous_response_id" => "resp_fixture_previous",
      "input" => [
        %{"type" => "item_reference", "id" => "msg_existing_fixture"},
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture",
          "output" => "{\"ok\":true}"
        }
      ]
    }

    assert {:ok, %{payload: coerced}} = Responses.coerce(payload)
    assert coerced["previous_response_id"] == "resp_fixture_previous"

    assert [
             %{"type" => "item_reference", "id" => "msg_existing_fixture"},
             %{"type" => "function_call_output", "call_id" => "call_fixture"}
           ] = coerced["input"]

    malformed_references = [
      %{"type" => "item_reference"},
      %{"type" => "item_reference", "id" => ""},
      %{"type" => "item_reference", "id" => "msg_existing_fixture", "output" => "bad"}
    ]

    Enum.each(malformed_references, fn item ->
      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               Responses.coerce(%{"model" => "gpt-fixture-text", "input" => [item]})
    end)

    assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [%{"type" => "item_reference", "id" => "msg_existing_fixture"}]
             })

    assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "previous_response_id" => "resp_fixture_previous",
               "input" => [
                 %{"type" => "item_reference", "id" => "msg_existing_fixture"},
                 %{"role" => "user", "content" => "synthetic ordinary continuation"}
               ]
             })
  end

  @tag :unsupported_fields
  test "invalid file purpose and multipart metadata return deterministic reason maps" do
    assert {:error, reason} =
             Files.validate_create(%{"purpose" => "fine_tuning", "file" => upload_metadata()})

    assert reason == %{
             status: 400,
             code: "invalid_request",
             message: "file purpose is not supported",
             param: "purpose"
           }

    assert {:error, %{status: 400, code: "invalid_request", param: "file"}} =
             Files.validate_create(%{
               "purpose" => "user_data",
               "file" => %{"filename" => "fixture.txt"}
             })
  end

  @tag :unsupported_fields
  test "invalid audio model and missing file metadata are rejected" do
    assert {:error, %{code: "invalid_model", param: "model"}} =
             Audio.validate_transcription(%{"model" => "whisper-1", "file" => upload_metadata()})

    assert {:error, %{code: "invalid_request", param: "file"}} =
             Audio.validate_transcription(%{"model" => "gpt-4o-transcribe"})
  end

  @tag :unsupported_fields
  test "existing strict schema and input image guards are reused" do
    assert {:error, %{code: "invalid_json_schema", param: "text.format.schema.required"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "text" => %{
                 "format" => %{
                   "type" => "json_schema",
                   "strict" => true,
                   "schema" => %{
                     "type" => "object",
                     "additionalProperties" => false,
                     "properties" => %{"ok" => %{"type" => "boolean"}},
                     "required" => []
                   }
                 }
               }
             })

    assert {:error, %{code: "unsupported_input_image_format", param: "input"}} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "input_image", "image_url" => "sediment://file_fixture"}
                   ]
                 }
               ]
             })
  end

  @tag :responses_coercion
  test "strict function parameters accept explicit schemas in Responses and Chat" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        function_tool("lookup_fixture", %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"ok" => %{"type" => "boolean"}},
          "required" => ["ok"]
        })
      ]
    }

    assert {:ok, response_result} = Responses.coerce(response_payload)
    assert response_result.payload["tools"] == response_payload["tools"]

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        function_tool("lookup_nullable_fixture", %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"ok" => %{"type" => ["string", "null"]}},
          "required" => ["ok"]
        })
      ]
    }

    assert {:ok, chat_result} = Chat.coerce(chat_payload)
    assert chat_result.payload["tools"] == chat_payload["tools"]
  end

  @tag :responses_coercion
  test "Responses accepts flat function tools emitted by released OpenAI SDK" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup_fixture",
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
    }

    assert {:ok, result} = Responses.coerce(payload)
    assert result.payload["tools"] == payload["tools"]
  end

  @tag :responses_coercion
  test "strict function parameters reject missing additionalProperties at the top level" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 function_tool("lookup_missing_additional_properties", %{
                   "type" => "object",
                   "properties" => %{"ok" => %{"type" => "boolean"}},
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_missing_additional_properties': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.0.function.parameters"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject additionalProperties true at the top level" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 function_tool("lookup_additional_properties_true", %{
                   "type" => "object",
                   "additionalProperties" => true,
                   "properties" => %{"ok" => %{"type" => "boolean"}},
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_additional_properties_true': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.0.function.parameters"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject required omissions and coverage gaps" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 function_tool("lookup_omitted_required", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{"ok" => %{"type" => "boolean"}}
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_omitted_required': strict json_schema object schemas must list every property in required (missing ok)",
             param: "tools.0.function.parameters.required"
           }

    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 function_tool("lookup_missing_required_property", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{
                     "ok" => %{"type" => "boolean"},
                     "extra" => %{"type" => "string"}
                   },
                   "required" => ["ok"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_missing_required_property': strict json_schema object schemas must list every property in required (missing extra)",
             param: "tools.0.function.parameters.required"
           }
  end

  @tag :responses_coercion
  test "strict function parameters reject nested object violations and preserve the failing tool index" do
    assert {:error, reason} =
             Responses.coerce(%{
               "model" => "gpt-fixture-text",
               "input" => "synthetic input",
               "tools" => [
                 %{"type" => "web_search_preview"},
                 function_tool("lookup_nested_object", %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{
                     "settings" => %{
                       "type" => "object",
                       "properties" => %{"ok" => %{"type" => "boolean"}},
                       "required" => ["ok"]
                     }
                   },
                   "required" => ["settings"]
                 })
               ]
             })

    assert reason == %{
             status: 400,
             code: "invalid_function_parameters",
             message:
               "Invalid schema for function 'lookup_nested_object': strict json_schema object schemas must set additionalProperties to false",
             param: "tools.1.function.parameters.properties.settings"
           }
  end

  @tag :responses_coercion
  test "strict function parameters accept local $defs and definitions refs in Responses" do
    payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [function_tool("lookup_local_refs", local_ref_function_parameters())]
    }

    assert {:ok, result} = Responses.coerce(payload)
    assert result.payload["tools"] == payload["tools"]
  end

  @tag :responses_coercion
  test "strict function parameters accept local $defs and definitions refs in Chat" do
    payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [function_tool("lookup_local_refs", local_ref_function_parameters())]
    }

    assert {:ok, result} = Chat.coerce(payload)
    assert result.payload["tools"] == payload["tools"]
  end

  @tag :responses_coercion
  test "strict function parameters reject invalid local refs with sanitized errors in Responses and Chat" do
    invalid_payloads = [
      {
        "unresolved",
        invalid_local_ref_function_parameters("#/$defs/missing", "profile", %{}),
        "tools.0.function.parameters.properties.profile.$ref"
      },
      {
        "malformed",
        invalid_local_ref_function_parameters("#/%24defs/%zz", "profile", %{}),
        "tools.0.function.parameters.properties.profile.$ref"
      },
      {
        "double_hash",
        invalid_local_ref_function_parameters("##/$defs/profile", "profile", %{}),
        "tools.0.function.parameters.properties.profile.$ref"
      },
      {
        "remote",
        invalid_local_ref_function_parameters(
          "https://example.com/schema.json#/$defs/profile",
          "profile",
          %{}
        ),
        "tools.0.function.parameters.properties.profile.$ref"
      },
      {
        "circular",
        invalid_local_ref_function_parameters(
          "#/$defs/node",
          "node",
          %{"next" => %{"$ref" => "#/$defs/node"}}
        ),
        "tools.0.function.parameters.properties.profile.properties.next.$ref"
      },
      {
        "non_map_target",
        invalid_local_ref_function_parameters(
          "#/$defs/profile",
          "profile",
          "not a schema object"
        ),
        "tools.0.function.parameters.properties.profile.$ref"
      }
    ]

    Enum.each(invalid_payloads, fn {_name, parameters, expected_param} ->
      response_payload = %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic input",
        "tools" => [function_tool("lookup_invalid_local_ref", parameters)]
      }

      chat_payload = %{
        "model" => "gpt-fixture-text",
        "messages" => [%{"role" => "user", "content" => "synthetic input"}],
        "tools" => [function_tool("lookup_invalid_local_ref", parameters)]
      }

      assert {:error,
              %{
                status: 400,
                code: "invalid_function_parameters",
                param: ^expected_param
              }} =
               Responses.coerce(response_payload)

      assert {:error,
              %{
                status: 400,
                code: "invalid_function_parameters",
                param: ^expected_param
              }} =
               Chat.coerce(chat_payload)
    end)
  end

  @tag :responses_coercion
  test "strict false and omitted strict function parameters preserve accepted behavior" do
    response_payload = %{
      "model" => "gpt-fixture-text",
      "input" => "synthetic input",
      "tools" => [
        function_tool(
          "lookup_false",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          false
        ),
        function_tool(
          "lookup_omitted",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          nil
        )
      ]
    }

    assert {:ok, response_result} = Responses.coerce(response_payload)
    assert response_result.payload["tools"] == response_payload["tools"]

    chat_payload = %{
      "model" => "gpt-fixture-text",
      "messages" => [%{"role" => "user", "content" => "synthetic input"}],
      "tools" => [
        function_tool(
          "lookup_chat_false",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          false
        ),
        function_tool(
          "lookup_chat_omitted",
          %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}}
          },
          nil
        )
      ]
    }

    assert {:ok, chat_result} = Chat.coerce(chat_payload)
    assert chat_result.payload["tools"] == chat_payload["tools"]
  end

  defp function_tool(name, parameters, strict \\ true) do
    function = %{"name" => name, "parameters" => parameters}

    function =
      case strict do
        nil -> function
        value -> Map.put(function, "strict", value)
      end

    %{"type" => "function", "function" => function}
  end

  defp local_ref_function_parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "from_defs" => %{"$ref" => "#/$defs/profile"},
        "from_definitions" => %{"$ref" => "#/definitions/settings"}
      },
      "required" => ["from_defs", "from_definitions"],
      "$defs" => %{
        "profile" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"summary" => %{"type" => "string"}},
          "required" => ["summary"]
        }
      },
      "definitions" => %{
        "settings" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"enabled" => %{"type" => "boolean"}},
          "required" => ["enabled"]
        }
      }
    }
  end

  defp invalid_local_ref_function_parameters(ref, definition_name, definition_properties)
       when is_map(definition_properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"profile" => %{"$ref" => ref}},
      "required" => ["profile"],
      "$defs" => %{
        definition_name => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => definition_properties,
          "required" => Map.keys(definition_properties)
        }
      }
    }
  end

  defp invalid_local_ref_function_parameters(ref, definition_name, definition_schema) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"profile" => %{"$ref" => ref}},
      "required" => ["profile"],
      "$defs" => %{definition_name => definition_schema}
    }
  end

  defp upload_metadata do
    %{"filename" => "fixture.txt", "content_type" => "text/plain", "bytes" => 12}
  end
end
