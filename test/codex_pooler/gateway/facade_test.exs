defmodule CodexPooler.GatewayTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Usage

  test "execute rejects whitespace-only model values as missing model" do
    payload = %{"model" => " \n\t "}
    request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

    assert {:error,
            %{
              status: 400,
              code: "invalid_request",
              message: "model is required",
              param: "model"
            }} =
             Gateway.execute(%{}, "/backend-api/codex/responses", payload, request_options)
  end

  test "usage auth fallback accepts typed request options at the public boundary" do
    request_options =
      RequestOptions.build([chatgpt_account_id: "acct_example"], "/api/codex/usage", %{})

    assert {:error,
            %{
              status: 401,
              code: "invalid_authorization",
              message: "chatgpt token is required"
            }} =
             Usage.resolve_codex_usage_auth({:error, :invalid_api_key}, request_options)
  end
end

defmodule CodexPooler.Gateway.FacadeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @protocols [
    :ollama_chat,
    :ollama_generate,
    :openai_responses,
    :openai_chat,
    :openai_completions,
    :anthropic_messages,
    :codex,
    :media,
    :metadata
  ]

  test "publishes one facade identity and one fixed reasoning target" do
    assert Facade.public_model() == "gemma3"
    assert Facade.effective_model() == "gpt-5.6-sol"
    assert Facade.reasoning_effort() == "max"
  end

  test "builds the fixed persona for every supported protocol" do
    for protocol <- @protocols do
      assert %Persona{
               public_model: "gemma3",
               effective_model: "gpt-5.6-sol",
               reasoning_effort: "max",
               protocol: ^protocol
             } = Persona.fixed(protocol)
    end
  end

  test "rejects unsupported protocol tags" do
    assert_raise FunctionClauseError, fn -> apply(Persona, :fixed, [:unknown]) end
  end

  test "persona attachment is idempotent but immutable" do
    persona = Persona.fixed(:ollama_chat)
    options = RequestOptions.build(%{persona: persona}, "/api/chat", %{})

    assert options.persona == persona
    assert RequestOptions.put_persona(options, persona) == options

    assert_raise ArgumentError, ~r/facade persona is immutable/, fn ->
      RequestOptions.put_persona(options, Persona.fixed(:anthropic_messages))
    end
  end
end
