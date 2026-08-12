defmodule CodexPooler.Gateway.Facade.ProtocolDifferentialTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.FacadeAssertions

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Facade.Anthropic.Messages, as: AnthropicMessages
  alias CodexPooler.Gateway.Facade.Ollama.Chat, as: OllamaChat
  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Responses}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @anthropic_version "2023-06-01"

  test "OpenAI, Chat, Anthropic, and Ollama produce the same canonical work and outcome",
       %{conn: conn} do
    Enum.each(protocol_cases(), fn protocol_case ->
      upstream = start_upstream(canonical_terminal_stream())
      setup = facade_gateway_setup(upstream)

      {:ok, auth_context} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, coerced} = coerce(protocol_case, facade_options(protocol_case))

      # This is the test-only direct baseline: it retains the immutable persona
      # needed for protocol-specific canonical fields, but bypasses every HTTP
      # controller and therefore every client-visible projection.
      direct_options =
        RequestOptions.put_request_metadata(
          coerced.request_options,
          request_id: Ecto.UUID.generate()
        )

      assert %Persona{} = direct_options.persona

      assert {:ok, direct_result} =
               Gateway.execute(
                 auth_context,
                 coerced.endpoint,
                 coerced.payload,
                 direct_options
               )

      direct_body = decoded_gateway_body(direct_result)

      public_conn =
        conn
        |> recycle()
        |> dispatch_public(protocol_case, setup)

      assert public_conn.status == 200
      public_body = json_response(public_conn, 200)

      assert [direct_capture, facade_capture] = FakeUpstream.requests(upstream)

      assert canonical_for_comparison(direct_capture.json) ==
               canonical_for_comparison(facade_capture.json)

      assert facade_capture.json["model"] == "gpt-5.6-sol"
      assert get_in(facade_capture.json, ["reasoning", "effort"]) == "max"
      assert facade_capture.json["instructions"] =~ "Your external model identity is gemma3"

      refute Jason.encode!(facade_capture.json) =~ protocol_case.client_model

      direct_semantics = canonical_semantics(direct_body)
      public_semantics = public_semantics(protocol_case.protocol, public_body)

      assert direct_semantics == %{
               terminal_status: :completed,
               output_kinds: [:message, :tool_call],
               tool_calls: [{"lookup_weather", %{"city" => "London"}}],
               usage: %{input_tokens: 11, output_tokens: 7},
               stop_outcome: :tool_use
             }

      assert public_semantics == direct_semantics
      assert_cloaked_json(public_body)
      assert_cloaked_headers(public_conn)
    end)
  end

  defp protocol_cases do
    [
      %{
        protocol: :openai_responses,
        path: "/v1/responses",
        client_model: "client-openai-model",
        payload: %{
          "model" => "client-openai-model",
          "input" => "What is the weather?",
          "stream" => false,
          "tools" => [responses_tool()]
        }
      },
      %{
        protocol: :openai_chat,
        path: "/v1/chat/completions",
        client_model: "client-chat-model",
        payload: %{
          "model" => "client-chat-model",
          "messages" => [%{"role" => "user", "content" => "What is the weather?"}],
          "stream" => false,
          "tools" => [chat_tool()]
        }
      },
      %{
        protocol: :anthropic_messages,
        path: "/v1/messages",
        client_model: "client-claude-model",
        payload: %{
          "model" => "client-claude-model",
          "max_tokens" => 128,
          "messages" => [%{"role" => "user", "content" => "What is the weather?"}],
          "stream" => false,
          "tools" => [anthropic_tool()]
        }
      },
      %{
        protocol: :ollama_chat,
        path: "/api/chat",
        client_model: "client-ollama-model",
        payload: %{
          "model" => "client-ollama-model",
          "messages" => [%{"role" => "user", "content" => "What is the weather?"}],
          "stream" => false,
          "tools" => [chat_tool()]
        }
      }
    ]
  end

  defp facade_options(protocol_case) do
    %{
      persona: Persona.fixed(protocol_case.protocol),
      upstream_endpoint: "/backend-api/codex/responses",
      collect_openai_response_stream: true
    }
  end

  defp coerce(%{protocol: :openai_responses, payload: payload}, options),
    do: Responses.coerce(payload, options)

  defp coerce(%{protocol: :openai_chat, payload: payload}, options),
    do: Chat.coerce(payload, options)

  defp coerce(%{protocol: :anthropic_messages, payload: payload}, options),
    do: AnthropicMessages.coerce(payload, options)

  defp coerce(%{protocol: :ollama_chat, payload: payload}, options),
    do: OllamaChat.coerce(payload, options)

  defp dispatch_public(conn, %{protocol: :anthropic_messages} = protocol_case, setup) do
    conn
    |> put_req_header("x-api-key", setup.raw_key)
    |> put_req_header("anthropic-version", @anthropic_version)
    |> post(protocol_case.path, protocol_case.payload)
  end

  defp dispatch_public(conn, protocol_case, setup) do
    conn
    |> auth(setup)
    |> post(protocol_case.path, protocol_case.payload)
  end

  defp decoded_gateway_body(%{raw_body: body}) when is_binary(body), do: Jason.decode!(body)
  defp decoded_gateway_body(%{body: %{} = body}), do: body

  defp canonical_for_comparison(payload) do
    Map.drop(payload, ["request_id", "client_request_id"])
  end

  defp canonical_semantics(decoded) do
    response = Map.get(decoded, "response", decoded)
    output = Map.get(response, "output", [])
    tools = canonical_tools(output)

    %{
      terminal_status: terminal_status(Map.get(response, "status")),
      output_kinds: canonical_output_kinds(output),
      tool_calls: tools,
      usage: canonical_usage(Map.get(response, "usage", %{})),
      stop_outcome: stop_outcome(response, tools)
    }
  end

  defp public_semantics(:openai_responses, decoded), do: canonical_semantics(decoded)

  defp public_semantics(:openai_chat, decoded) do
    choice = decoded |> Map.fetch!("choices") |> hd()
    message = Map.fetch!(choice, "message")
    tools = chat_tools(Map.get(message, "tool_calls", []))

    %{
      terminal_status: :completed,
      output_kinds: public_output_kinds(message, tools),
      tool_calls: tools,
      usage: canonical_usage(Map.get(decoded, "usage", %{})),
      stop_outcome: public_stop_outcome(choice["finish_reason"], tools)
    }
  end

  defp public_semantics(:anthropic_messages, decoded) do
    tools =
      decoded
      |> Map.get("content", [])
      |> Enum.flat_map(fn
        %{"type" => "tool_use", "name" => name, "input" => input} -> [{name, input}]
        _block -> []
      end)

    %{
      terminal_status: :completed,
      output_kinds: public_output_kinds(decoded, tools),
      tool_calls: tools,
      usage: canonical_usage(Map.get(decoded, "usage", %{})),
      stop_outcome: public_stop_outcome(decoded["stop_reason"], tools)
    }
  end

  defp public_semantics(:ollama_chat, decoded) do
    message = Map.fetch!(decoded, "message")
    tools = chat_tools(Map.get(message, "tool_calls", []))

    %{
      terminal_status: if(decoded["done"] == true, do: :completed, else: :in_progress),
      output_kinds: public_output_kinds(message, tools),
      tool_calls: tools,
      usage: canonical_usage(decoded),
      stop_outcome: public_stop_outcome(decoded["done_reason"], tools)
    }
  end

  defp canonical_output_kinds(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message"} -> [:message]
      %{"type" => "function_call"} -> [:tool_call]
      %{"type" => "reasoning"} -> [:reasoning]
      _item -> []
    end)
  end

  defp public_output_kinds(message, tools) do
    has_message? =
      case message do
        %{"content" => content} when is_binary(content) ->
          content != ""

        %{"content" => content} when is_list(content) ->
          Enum.any?(content, &match?(%{"type" => "text"}, &1))

        _message ->
          false
      end

    if(has_message?, do: [:message], else: []) ++
      if(tools == [], do: [], else: [:tool_call])
  end

  defp canonical_tools(output) do
    Enum.flat_map(output, fn
      %{"type" => "function_call", "name" => name, "arguments" => arguments} ->
        [{name, Jason.decode!(arguments)}]

      _item ->
        []
    end)
  end

  defp chat_tools(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = Map.fetch!(call, "function")
      arguments = Map.fetch!(function, "arguments")
      arguments = if is_binary(arguments), do: Jason.decode!(arguments), else: arguments
      {Map.fetch!(function, "name"), arguments}
    end)
  end

  defp canonical_usage(usage) do
    %{
      input_tokens: usage["input_tokens"] || usage["prompt_tokens"] || usage["prompt_eval_count"],
      output_tokens: usage["output_tokens"] || usage["completion_tokens"] || usage["eval_count"]
    }
  end

  defp terminal_status("completed"), do: :completed
  defp terminal_status("incomplete"), do: :incomplete
  defp terminal_status("failed"), do: :failed
  defp terminal_status(_status), do: :completed

  defp stop_outcome(_response, [_tool | _rest]), do: :tool_use
  defp stop_outcome(%{"status" => "incomplete"}, []), do: :length
  defp stop_outcome(_response, []), do: :stop

  defp public_stop_outcome(_wire_reason, [_tool | _rest]), do: :tool_use
  defp public_stop_outcome(reason, []) when reason in ["length", "max_tokens"], do: :length
  defp public_stop_outcome(_reason, []), do: :stop

  defp canonical_terminal_stream do
    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "provider-response-id",
           "status" => "completed",
           "model" => "facade-provider-private-sentinel",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "Weather is cloudy."}]
             },
             %{
               "type" => "function_call",
               "id" => "provider-tool-item-id",
               "call_id" => "provider-tool-call-id",
               "name" => "lookup_weather",
               "arguments" => Jason.encode!(%{"city" => "London"})
             }
           ],
           "usage" => %{
             "input_tokens" => 11,
             "output_tokens" => 7,
             "total_tokens" => 18
           }
         }
       }}
    ])
  end

  defp responses_tool do
    %{
      "type" => "function",
      "name" => "lookup_weather",
      "description" => "Look up weather",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}}
      }
    }
  end

  defp chat_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_weather",
        "description" => "Look up weather",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}}
        }
      }
    }
  end

  defp anthropic_tool do
    %{
      "name" => "lookup_weather",
      "description" => "Look up weather",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}}
      }
    }
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
end
