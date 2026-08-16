defmodule CodexPooler.Gateway.Payloads.StrictSchemaRepairTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.StrictSchema

  describe "generic strict schema characterization" do
    test "generic validation retains the native non-empty type vocabulary behavior" do
      payload = %{
        "tools" => [
          strict_flat_function_tool("flat_fixture", %{"type" => "future-flat-token"}),
          strict_nested_function_tool("nested_fixture", %{"type" => "future-native-token"})
        ]
      }

      assert :ok = StrictSchema.validate(payload)
    end

    test "generic validation retains deterministic missing-type errors and ignores non-strict tools" do
      strict_payload = %{
        "tools" => [
          strict_flat_function_tool("strict_fixture", %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "nested" => %{
                "properties" => %{},
                "required" => [],
                "additionalProperties" => false
              }
            },
            "required" => ["nested"]
          })
        ]
      }

      assert {:error,
              %{
                code: "invalid_function_parameters",
                param: "tools.0.parameters.properties.nested.type"
              }} = StrictSchema.validate(strict_payload)

      assert :ok =
               StrictSchema.validate(%{
                 "tools" => [
                   %{
                     "type" => "function",
                     "name" => "non_strict_fixture",
                     "parameters" => %{"properties" => %{}},
                     "strict" => false
                   }
                 ]
               })
    end
  end

  describe "validate_public_type_vocabulary/1" do
    test "accepts every public primitive and preserves unique union order" do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "array" => %{"type" => "array", "items" => %{"type" => "string"}},
          "boolean" => %{"type" => "boolean"},
          "integer" => %{"type" => "integer"},
          "null" => %{"type" => "null"},
          "number" => %{"type" => "number"},
          "object" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{},
            "required" => []
          },
          "string" => %{"type" => "string"},
          "union" => %{"type" => ["string", "null", "integer"]}
        },
        "required" => ~w(array boolean integer null number object string union)
      }

      payload = %{"tools" => [strict_flat_function_tool("vocabulary_fixture", schema)]}
      snapshot = payload

      assert :ok = StrictSchema.validate_public_type_vocabulary(payload)
      assert payload == snapshot

      assert get_in(payload, ["tools", Access.at(0), "parameters", "properties", "union", "type"]) ==
               ["string", "null", "integer"]
    end

    test "allows an absent type for the later repair and generic validation stages" do
      payload = %{
        "tools" => [
          strict_flat_function_tool("missing_type_fixture", %{
            "properties" => %{},
            "required" => [],
            "additionalProperties" => false
          })
        ]
      }

      assert :ok = StrictSchema.validate_public_type_vocabulary(payload)
    end

    test "rejects invalid explicit scalar and list type forms" do
      invalid_types = [
        nil,
        "",
        "future-type",
        true,
        [],
        ["string", "string"],
        ["string", "future-type"],
        ["string", nil]
      ]

      Enum.each(invalid_types, fn invalid_type ->
        payload = %{
          "tools" => [
            strict_flat_function_tool("invalid_type_fixture", %{"type" => invalid_type})
          ]
        }

        assert {:error,
                %{
                  code: "invalid_function_parameters",
                  param: "tools.0.parameters.type"
                }} = StrictSchema.validate_public_type_vocabulary(payload)
      end)
    end

    test "rejects bogus types at every supported schema graph location" do
      cases = [
        {"root", %{"type" => "future-type"}, "tools.0.parameters.type"},
        {"properties", strict_object_schema(%{"value" => %{"type" => "future-type"}}),
         "tools.0.parameters.properties.value.type"},
        {"$defs", %{"type" => "string", "$defs" => %{"value" => %{"type" => "future-type"}}},
         "tools.0.parameters.$defs.value.type"},
        {"definitions",
         %{
           "type" => "string",
           "definitions" => %{"value" => %{"type" => "future-type"}}
         }, "tools.0.parameters.definitions.value.type"},
        {"map items", %{"type" => "array", "items" => %{"type" => "future-type"}},
         "tools.0.parameters.items.type"},
        {"tuple items",
         %{
           "type" => "array",
           "items" => [%{"type" => "string"}, %{"type" => "future-type"}]
         }, "tools.0.parameters.items.1.type"},
        {"anyOf", %{"type" => "string", "anyOf" => [%{"type" => "future-type"}]},
         "tools.0.parameters.anyOf.0.type"},
        {"oneOf", %{"type" => "string", "oneOf" => [%{"type" => "future-type"}]},
         "tools.0.parameters.oneOf.0.type"},
        {"allOf", %{"type" => "string", "allOf" => [%{"type" => "future-type"}]},
         "tools.0.parameters.allOf.0.type"},
        {"resolved local ref",
         strict_object_schema(
           %{"value" => %{"$ref" => "#/$defs/value"}},
           %{"$defs" => %{"value" => %{"type" => "future-type"}}}
         ), "tools.0.parameters.properties.value.type"}
      ]

      Enum.each(cases, fn {_label, schema, expected_param} ->
        payload = %{"tools" => [strict_flat_function_tool("graph_fixture", schema)]}

        assert {:error, %{code: "invalid_function_parameters", param: ^expected_param}} =
                 StrictSchema.validate_public_type_vocabulary(payload)
      end)
    end

    test "checks each node type before descendants and traverses named maps in sorted order" do
      root_precedence = %{
        "type" => "future-root",
        "properties" => %{"child" => %{"type" => "future-child"}}
      }

      sorted_precedence = %{
        "type" => "string",
        "properties" => %{
          "zeta" => %{"type" => "future-zeta"},
          "alpha" => %{"type" => "future-alpha"}
        }
      }

      assert {:error, %{param: "tools.0.parameters.type"}} =
               StrictSchema.validate_public_type_vocabulary(%{
                 "tools" => [strict_flat_function_tool("root_order_fixture", root_precedence)]
               })

      assert {:error, %{param: "tools.0.parameters.properties.alpha.type"}} =
               StrictSchema.validate_public_type_vocabulary(%{
                 "tools" => [strict_flat_function_tool("sorted_order_fixture", sorted_precedence)]
               })
    end

    test "validates unused root definition tables beside a root local ref" do
      schema = %{
        "$ref" => "#/$defs/root",
        "$defs" => %{
          "root" => %{"type" => "string"},
          "unused" => %{"type" => "future-type"}
        }
      }

      assert {:error, %{param: "tools.0.parameters.$defs.unused.type"}} =
               StrictSchema.validate_public_type_vocabulary(%{
                 "tools" => [strict_flat_function_tool("root_ref_fixture", schema)]
               })
    end

    test "ignores schema-looking values under annotations and unknown keywords" do
      schema = %{
        "type" => "string",
        "default" => %{"type" => "future-default"},
        "examples" => [%{"type" => "future-example"}],
        "description" => "synthetic schema",
        "enum" => [%{"type" => "future-enum"}],
        "const" => %{"type" => "future-const"},
        "metadata" => %{"type" => "future-metadata"},
        "unknown" => %{"type" => "future-unknown"}
      }

      assert :ok =
               StrictSchema.validate_public_type_vocabulary(%{
                 "tools" => [strict_flat_function_tool("annotation_fixture", schema)]
               })
    end

    test "covers flat, nested, namespace, and structured-output strict targets" do
      cases = [
        {%{"tools" => [strict_flat_function_tool("flat_fixture", %{"type" => "future"})]},
         "tools.0.parameters.type", "invalid_function_parameters"},
        {%{"tools" => [strict_nested_function_tool("nested_fixture", %{"type" => "future"})]},
         "tools.0.function.parameters.type", "invalid_function_parameters"},
        {%{
           "tools" => [
             %{
               "type" => "namespace",
               "name" => "namespace_fixture",
               "description" => "Synthetic namespace",
               "tools" => [strict_flat_function_tool("child_fixture", %{"type" => "future"})]
             }
           ]
         }, "tools.0.tools.0.parameters.type", "invalid_function_parameters"},
        {%{"text" => %{"format" => strict_text_format(%{"type" => "future"})}},
         "text.format.schema.type", "invalid_json_schema"},
        {%{
           "response_format" => %{
             "type" => "json_schema",
             "json_schema" => strict_json_schema(%{"type" => "future"})
           }
         }, "response_format.json_schema.schema.type", "invalid_json_schema"}
      ]

      Enum.each(cases, fn {payload, expected_param, expected_code} ->
        assert {:error, %{code: ^expected_code, param: ^expected_param}} =
                 StrictSchema.validate_public_type_vocabulary(payload)
      end)

      assert :ok =
               StrictSchema.validate_public_type_vocabulary(%{
                 "tools" => [
                   %{
                     "type" => "function",
                     "name" => "non_strict_fixture",
                     "parameters" => %{"type" => "future"},
                     "strict" => false
                   }
                 ]
               })
    end
  end

  describe "validate_public_root_contract/1" do
    test "rejects every non-concrete object root through every strict target layout" do
      invalid_roots = [
        {"omitted type",
         %{"properties" => %{}, "required" => [], "additionalProperties" => false}},
        {"primitive", %{"type" => "string"}},
        {"array", %{"type" => "array", "items" => %{"type" => "string"}}},
        {"singleton object type array", %{"type" => ["object"]}},
        {"nullable object type array", %{"type" => ["object", "null"]}},
        {"root local ref",
         %{
           "$ref" => "#/$defs/root",
           "$defs" => %{"root" => strict_object_schema(%{})}
         }},
        {"object with root local ref",
         strict_object_schema(%{}, %{
           "$ref" => "#/$defs/root",
           "$defs" => %{"root" => strict_object_schema(%{})}
         })},
        {"root anyOf",
         %{
           "anyOf" => [strict_object_schema(%{}), strict_object_schema(%{})]
         }},
        {"object with root anyOf",
         strict_object_schema(%{}, %{
           "anyOf" => [strict_object_schema(%{}), strict_object_schema(%{})]
         })}
      ]

      Enum.each(invalid_roots, fn {_root_label, schema} ->
        Enum.each(strict_target_payloads(schema), fn {_target_label, payload, code, param} ->
          assert {:error, %{status: 400, code: ^code, param: ^param}} =
                   StrictSchema.validate_public_root_contract(payload)
        end)
      end)
    end

    test "accepts concrete object roots with supported nested schema families in every layout" do
      valid_roots = [
        {"$defs",
         strict_object_schema(
           %{"value" => %{"$ref" => "#/$defs/value"}},
           %{"$defs" => %{"value" => %{"type" => "string"}}}
         )},
        {"definitions",
         strict_object_schema(
           %{"enabled" => %{"$ref" => "#/definitions/enabled"}},
           %{"definitions" => %{"enabled" => %{"type" => "boolean"}}}
         )},
        {"nested local refs",
         strict_object_schema(
           %{"node" => %{"$ref" => "#/$defs/node"}},
           %{
             "$defs" => %{
               "node" => strict_object_schema(%{"leaf" => %{"$ref" => "#/$defs/leaf"}}),
               "leaf" => %{"type" => "integer"}
             }
           }
         )},
        {"nested arrays primitives and nullable unions",
         strict_object_schema(%{
           "entries" => %{
             "type" => "array",
             "items" =>
               strict_object_schema(%{
                 "label" => %{"type" => "string"},
                 "score" => %{"type" => ["number", "null"]}
               })
           },
           "active" => %{"type" => "boolean"}
         })},
        {"nested combinators",
         strict_object_schema(%{
           "choice" => %{
             "type" => "string",
             "anyOf" => [%{"type" => "string"}],
             "oneOf" => [%{"type" => "string"}],
             "allOf" => [%{"type" => "string"}]
           }
         })}
      ]

      Enum.each(valid_roots, fn {_root_label, schema} ->
        Enum.each(strict_target_payloads(schema), fn {_target_label, payload, _code, _param} ->
          assert :ok = StrictSchema.validate_public_type_vocabulary(payload)
          assert :ok = StrictSchema.validate_public_root_contract(payload)
          assert :ok = StrictSchema.validate(payload)
        end)
      end)
    end

    test "accepts productive recursive local refs in every strict target layout" do
      schema =
        strict_object_schema(
          %{"node" => %{"$ref" => "#/$defs/node"}},
          %{
            "$defs" => %{
              "node" => strict_object_schema(%{"next" => %{"$ref" => "#/$defs/node"}})
            }
          }
        )

      Enum.each(strict_target_payloads(schema), fn {_target_label, payload, _code, _param} ->
        assert :ok = StrictSchema.validate_public_type_vocabulary(payload)
        assert :ok = StrictSchema.validate_public_root_contract(payload)
        assert :ok = StrictSchema.validate_public(payload)
      end)
    end

    test "generic validation retains productive recursive-ref rejection" do
      schema =
        strict_object_schema(
          %{"node" => %{"$ref" => "#/$defs/node"}},
          %{
            "$defs" => %{
              "node" => strict_object_schema(%{"next" => %{"$ref" => "#/$defs/node"}})
            }
          }
        )

      assert {:error,
              %{
                code: "invalid_function_parameters",
                param: "tools.0.parameters.properties.node.properties.next.$ref"
              }} =
               StrictSchema.validate(%{
                 "tools" => [strict_flat_function_tool("generic_recursive_fixture", schema)]
               })
    end

    test "does not apply the public root contract to non-strict or generic schemas" do
      array_schema = %{"type" => "array", "items" => %{"type" => "string"}}

      root_ref_schema = %{
        "$ref" => "#/$defs/root",
        "$defs" => %{"root" => strict_object_schema(%{})}
      }

      assert :ok =
               StrictSchema.validate_public_root_contract(%{
                 "tools" => [
                   %{
                     "type" => "function",
                     "name" => "non_strict_fixture",
                     "parameters" => array_schema,
                     "strict" => false
                   }
                 ]
               })

      assert :ok =
               StrictSchema.validate(%{
                 "tools" => [strict_flat_function_tool("generic_array_fixture", array_schema)]
               })

      assert :ok =
               StrictSchema.validate(%{
                 "tools" => [strict_flat_function_tool("generic_ref_fixture", root_ref_schema)]
               })
    end
  end

  describe "repair_direct_responses_function_tools/1" do
    test "returns a new map with nested object and array types repaired bottom-up" do
      parameters =
        strict_object_schema(%{
          "config" => %{
            "additionalProperties" => false,
            "properties" => %{
              "entries" => %{
                "items" => %{
                  "additionalProperties" => false,
                  "properties" => %{"value" => %{"type" => "string"}},
                  "required" => ["value"]
                }
              }
            },
            "required" => ["entries"]
          }
        })

      payload = %{"tools" => [strict_flat_function_tool("repair_fixture", parameters)]}
      snapshot = payload

      assert {:ok, repaired} = StrictSchema.repair_direct_responses_function_tools(payload)
      assert payload == snapshot
      refute repaired == payload

      repaired_config =
        get_in(repaired, ["tools", Access.at(0), "parameters", "properties", "config"])

      assert repaired_config["type"] == "object"
      assert get_in(repaired_config, ["properties", "entries", "type"]) == "array"

      assert get_in(repaired_config, ["properties", "entries", "items", "type"]) ==
               "object"

      assert :ok = StrictSchema.validate(repaired)
    end

    test "repairs candidates whose strict children resolve through root local definitions" do
      parameters =
        strict_object_schema(
          %{
            "candidate" => %{
              "additionalProperties" => false,
              "properties" => %{"value" => %{"$ref" => "#/$defs/value"}},
              "required" => ["value"]
            }
          },
          %{"$defs" => %{"value" => %{"type" => "string"}}}
        )

      payload = %{"tools" => [strict_flat_function_tool("local_ref_repair_fixture", parameters)]}

      assert {:ok, repaired} = StrictSchema.repair_direct_responses_function_tools(payload)

      assert get_in(repaired, [
               "tools",
               Access.at(0),
               "parameters",
               "properties",
               "candidate",
               "type"
             ]) == "object"

      assert :ok = StrictSchema.validate(repaired)
    end

    test "repairs strict namespace child functions but not the parameters root" do
      parameters =
        strict_object_schema(%{
          "nested" => %{
            "additionalProperties" => false,
            "properties" => %{},
            "required" => []
          }
        })

      payload = %{
        "tools" => [
          %{
            "type" => "namespace",
            "name" => "namespace_fixture",
            "description" => "Synthetic namespace",
            "tools" => [strict_flat_function_tool("namespace_repair_fixture", parameters)]
          }
        ]
      }

      assert {:ok, repaired} = StrictSchema.repair_direct_responses_function_tools(payload)

      assert get_in(repaired, [
               "tools",
               Access.at(0),
               "tools",
               Access.at(0),
               "parameters",
               "properties",
               "nested",
               "type"
             ]) == "object"

      rootless_payload = %{
        "tools" => [
          strict_flat_function_tool("root_guard_fixture", %{
            "additionalProperties" => false,
            "properties" => %{},
            "required" => []
          })
        ]
      }

      assert {:error, %{param: "tools.0.parameters.type"}} =
               StrictSchema.repair_direct_responses_function_tools(rootless_payload)

      refute get_in(rootless_payload, ["tools", Access.at(0), "parameters"])
             |> Map.has_key?("type")
    end

    test "leaves every explicit type form unchanged and delegates rejection by policy" do
      cases = [
        {"bogus", "future-type", :public_error},
        {"blank", "", :generic_error},
        {"null", nil, :generic_error},
        {"duplicate union", ["object", "object"], :public_error},
        {"invalid union", ["object", nil], :generic_error},
        {"valid unique union", ["object", "null"], :ok}
      ]

      Enum.each(cases, fn {_label, type, expected} ->
        candidate =
          strict_object_evidence()
          |> Map.put("type", type)

        payload = guard_payload(candidate)
        snapshot = payload
        result = StrictSchema.repair_direct_responses_function_tools(payload)

        assert payload == snapshot

        case expected do
          :ok ->
            assert {:ok, ^payload} = result
            assert :ok = StrictSchema.validate_public_type_vocabulary(payload)

          :public_error ->
            assert {:ok, ^payload} = result

            assert {:error, %{param: "tools.0.parameters.properties.candidate.type"}} =
                     StrictSchema.validate_public_type_vocabulary(payload)

          :generic_error ->
            assert {:error, %{param: "tools.0.parameters.properties.candidate.type"}} = result
        end
      end)
    end

    test "keeps ref and definition subtrees opaque" do
      ref_payload = %{
        "tools" => [
          strict_flat_function_tool(
            "ref_guard_fixture",
            strict_object_schema(
              %{"candidate" => %{"$ref" => "#/$defs/candidate"}},
              %{"$defs" => %{"candidate" => strict_object_evidence()}}
            )
          )
        ]
      }

      ref_snapshot = ref_payload

      assert {:error, %{param: "tools.0.parameters.properties.candidate.type"}} =
               StrictSchema.repair_direct_responses_function_tools(ref_payload)

      assert ref_payload == ref_snapshot

      Enum.each(["$defs", "definitions"], fn definition_key ->
        definition_payload = %{
          "tools" => [
            strict_flat_function_tool(
              "definition_guard_fixture",
              strict_object_schema(%{}, %{
                definition_key => %{"candidate" => strict_object_evidence()}
              })
            )
          ]
        }

        definition_snapshot = definition_payload
        expected_param = "tools.0.parameters.#{definition_key}.candidate.type"

        assert {:error, %{param: ^expected_param}} =
                 StrictSchema.repair_direct_responses_function_tools(definition_payload)

        assert definition_payload == definition_snapshot
      end)
    end

    test "keeps combinator nodes and all their descendants opaque" do
      Enum.each(~w(anyOf oneOf allOf), fn combinator ->
        candidate = %{
          "type" => "string",
          combinator => [strict_object_evidence()]
        }

        payload = guard_payload(candidate)
        snapshot = payload
        expected_param = "tools.0.parameters.properties.candidate.#{combinator}.0.type"

        assert {:error, %{param: ^expected_param}} =
                 StrictSchema.repair_direct_responses_function_tools(payload)

        assert payload == snapshot
      end)
    end

    test "does not repair ambiguous or structurally incomplete evidence" do
      cases = [
        {"mixed evidence", Map.put(strict_object_evidence(), "items", %{"type" => "string"})},
        {"missing additionalProperties",
         Map.delete(strict_object_evidence(), "additionalProperties")},
        {"additionalProperties true",
         Map.put(strict_object_evidence(), "additionalProperties", true)},
        {"missing required", Map.delete(strict_object_evidence(), "required")},
        {"duplicate required",
         %{
           "properties" => %{"value" => %{"type" => "string"}},
           "required" => ["value", "value"],
           "additionalProperties" => false
         }},
        {"required coverage gap",
         %{
           "properties" => %{
             "value" => %{"type" => "string"},
             "other" => %{"type" => "string"}
           },
           "required" => ["value"],
           "additionalProperties" => false
         }},
        {"tuple items", %{"items" => [%{"type" => "string"}]}},
        {"invalid array child", %{"items" => %{}}}
      ]

      Enum.each(cases, fn {_label, candidate} ->
        payload = guard_payload(candidate)
        snapshot = payload

        assert {:error, %{param: "tools.0.parameters.properties.candidate.type"}} =
                 StrictSchema.repair_direct_responses_function_tools(payload)

        assert payload == snapshot
      end)
    end

    test "never traverses schema-looking annotations or arbitrary map values" do
      candidate = %{
        "type" => "string",
        "default" => strict_object_evidence(),
        "examples" => [strict_object_evidence()],
        "metadata" => %{"schema" => strict_object_evidence()},
        "unknown" => strict_object_evidence()
      }

      payload = guard_payload(candidate)
      snapshot = payload

      assert {:ok, ^payload} = StrictSchema.repair_direct_responses_function_tools(payload)
      assert payload == snapshot
    end

    test "does not repair non-strict, nested native, or structured-output targets" do
      candidate = strict_object_evidence()

      non_strict_payload = %{
        "tools" => [
          %{
            "type" => "function",
            "name" => "non_strict_fixture",
            "parameters" => candidate,
            "strict" => false
          }
        ]
      }

      assert {:ok, ^non_strict_payload} =
               StrictSchema.repair_direct_responses_function_tools(non_strict_payload)

      native_payload = %{
        "tools" => [
          strict_nested_function_tool(
            "native_fixture",
            strict_object_schema(%{"candidate" => candidate})
          )
        ]
      }

      native_snapshot = native_payload

      assert {:error, %{param: "tools.0.function.parameters.properties.candidate.type"}} =
               StrictSchema.repair_direct_responses_function_tools(native_payload)

      assert native_payload == native_snapshot

      structured_payload = %{
        "text" => %{
          "format" => strict_text_format(strict_object_schema(%{"candidate" => candidate}))
        }
      }

      structured_snapshot = structured_payload

      assert {:error, %{param: "text.format.schema.properties.candidate.type"}} =
               StrictSchema.repair_direct_responses_function_tools(structured_payload)

      assert structured_payload == structured_snapshot

      response_format_payload = %{
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => strict_json_schema(strict_object_schema(%{"candidate" => candidate}))
        }
      }

      response_format_snapshot = response_format_payload

      assert {:error, %{param: "response_format.json_schema.schema.properties.candidate.type"}} =
               StrictSchema.repair_direct_responses_function_tools(response_format_payload)

      assert response_format_payload == response_format_snapshot
    end
  end

  defp strict_flat_function_tool(name, parameters) do
    %{
      "type" => "function",
      "name" => name,
      "parameters" => parameters,
      "strict" => true
    }
  end

  defp strict_nested_function_tool(name, parameters) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "parameters" => parameters,
        "strict" => true
      }
    }
  end

  defp strict_object_schema(properties, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => properties,
        "required" => properties |> Map.keys() |> Enum.sort()
      },
      extra
    )
  end

  defp strict_object_evidence do
    %{
      "additionalProperties" => false,
      "properties" => %{"value" => %{"type" => "string"}},
      "required" => ["value"]
    }
  end

  defp guard_payload(candidate) do
    %{
      "tools" => [
        strict_flat_function_tool(
          "guard_fixture",
          strict_object_schema(%{"candidate" => candidate})
        )
      ]
    }
  end

  defp strict_text_format(schema) do
    %{
      "type" => "json_schema",
      "name" => "fixture_schema",
      "strict" => true,
      "schema" => schema
    }
  end

  defp strict_json_schema(schema) do
    %{
      "name" => "fixture_schema",
      "strict" => true,
      "schema" => schema
    }
  end

  defp strict_target_payloads(schema) do
    [
      {"text format", %{"text" => %{"format" => strict_text_format(schema)}},
       "invalid_json_schema", "text.format.schema"},
      {"response format",
       %{
         "response_format" => %{
           "type" => "json_schema",
           "json_schema" => strict_json_schema(schema)
         }
       }, "invalid_json_schema", "response_format.json_schema.schema"},
      {"flat function", %{"tools" => [strict_flat_function_tool("flat_fixture", schema)]},
       "invalid_function_parameters", "tools.0.parameters"},
      {"nested function", %{"tools" => [strict_nested_function_tool("nested_fixture", schema)]},
       "invalid_function_parameters", "tools.0.function.parameters"},
      {"namespace function",
       %{
         "tools" => [
           %{
             "type" => "namespace",
             "name" => "namespace_fixture",
             "description" => "Synthetic namespace",
             "tools" => [strict_flat_function_tool("child_fixture", schema)]
           }
         ]
       }, "invalid_function_parameters", "tools.0.tools.0.parameters"}
    ]
  end
end
