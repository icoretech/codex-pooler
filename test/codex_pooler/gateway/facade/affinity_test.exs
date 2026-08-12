defmodule CodexPooler.Gateway.Facade.AffinityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Affinity
  alias CodexPooler.Gateway.Facade.Anthropic.Messages
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @endpoint "/backend-api/codex/responses"
  @raw_cache_key "raw-cache-key-that-must-not-survive"
  @raw_session_id "raw-ollama-session-that-must-not-survive"

  test "namespaces OpenAI prompt-cache affinity by Pool, API key, source, and effective target" do
    payload = canonical_payload(@raw_cache_key)
    options = request_options(payload, :openai_responses)

    {first_payload, first_options} = Affinity.scope(auth("pool-a", "key-a"), payload, options)
    {repeat_payload, repeat_options} = Affinity.scope(auth("pool-a", "key-a"), payload, options)

    {other_pool_payload, _other_pool_options} =
      Affinity.scope(auth("pool-b", "key-a"), payload, options)

    {other_key_payload, _other_key_options} =
      Affinity.scope(auth("pool-a", "key-b"), payload, options)

    other_target_options =
      RequestOptions.put_routing(options, effective_model: "different-effective-target")

    {other_target_payload, _other_target_options} =
      Affinity.scope(auth("pool-a", "key-a"), payload, other_target_options)

    assert first_payload == repeat_payload
    assert first_options.routing.prompt_cache_key == repeat_options.routing.prompt_cache_key
    assert first_payload["prompt_cache_key"] == first_options.routing.prompt_cache_key
    assert first_payload["prompt_cache_key"] =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/

    refute first_payload["prompt_cache_key"] == other_pool_payload["prompt_cache_key"]
    refute first_payload["prompt_cache_key"] == other_key_payload["prompt_cache_key"]
    refute first_payload["prompt_cache_key"] == other_target_payload["prompt_cache_key"]

    scoped = inspect({first_payload, first_options})
    refute scoped =~ @raw_cache_key
    refute scoped =~ "client-model-must-not-affect-affinity"
    assert first_payload["model"] == Facade.effective_model()
  end

  test "derives stable Anthropic explicit-cache affinity from the marked prefix" do
    first = anthropic_request("first uncached suffix", "claude-client-model-a")
    second = anthropic_request("different uncached suffix", "claude-client-model-b")

    assert {:ok, first_coerced} = Messages.coerce(first, anthropic_options())
    assert {:ok, second_coerced} = Messages.coerce(second, anthropic_options())

    {first_payload, first_options} =
      Affinity.scope(
        auth("pool-a", "key-a"),
        first_coerced.payload,
        first_coerced.request_options
      )

    {second_payload, second_options} =
      Affinity.scope(
        auth("pool-a", "key-a"),
        second_coerced.payload,
        second_coerced.request_options
      )

    assert first_payload["prompt_cache_key"] == second_payload["prompt_cache_key"]
    assert first_options.routing.prompt_cache_key == second_options.routing.prompt_cache_key
    assert first_payload["prompt_cache_key"] =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/

    refute inspect({first_payload, first_options}) =~ "claude-client-model-a"
    refute inspect({second_payload, second_options}) =~ "claude-client-model-b"

    {other_key_payload, _options} =
      Affinity.scope(
        auth("pool-a", "key-b"),
        first_coerced.payload,
        first_coerced.request_options
      )

    refute first_payload["prompt_cache_key"] == other_key_payload["prompt_cache_key"]
  end

  test "namespaces only Ollama session headers and preserves stronger continuity inputs" do
    payload = canonical_payload(nil)

    ollama_options =
      payload
      |> request_options(:ollama_chat)
      |> RequestOptions.put_continuity(
        session_header_source: "x-ollama-session-id",
        session_header: @raw_session_id,
        previous_response_id: "resp_authoritative"
      )

    {_payload, first} = Affinity.scope(auth("pool-a", "key-a"), payload, ollama_options)
    {_payload, repeat} = Affinity.scope(auth("pool-a", "key-a"), payload, ollama_options)
    {_payload, other_key} = Affinity.scope(auth("pool-a", "key-b"), payload, ollama_options)

    assert first.continuity.session_header == repeat.continuity.session_header
    assert first.continuity.session_header =~ ~r/\Afacade:[A-Za-z0-9_-]{43}\z/
    refute first.continuity.session_header == other_key.continuity.session_header
    assert first.continuity.session_header_source == "x-ollama-session-id"
    assert first.continuity.previous_response_id == "resp_authoritative"
    refute inspect(first) =~ @raw_session_id

    codex_options =
      payload
      |> request_options(:codex)
      |> RequestOptions.put_continuity(
        session_header_source: "x-codex-session-id",
        session_header: "codex-session-authoritative",
        previous_response_id: "resp_authoritative"
      )

    {_payload, unchanged} = Affinity.scope(auth("pool-a", "key-a"), payload, codex_options)
    assert unchanged.continuity == codex_options.continuity
  end

  defp auth(pool_id, api_key_id),
    do: %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}

  defp canonical_payload(nil) do
    %{
      "model" => Facade.effective_model(),
      "reasoning" => %{"effort" => Facade.reasoning_effort()},
      "input" => "cache fixture"
    }
  end

  defp canonical_payload(prompt_cache_key) do
    canonical_payload(nil)
    |> Map.put("prompt_cache_key", prompt_cache_key)
  end

  defp request_options(payload, protocol) do
    RequestOptions.build(
      %{persona: Persona.fixed(protocol), request_method: "POST"},
      @endpoint,
      payload
    )
    |> RequestOptions.put_routing(
      requested_model: Facade.public_model(),
      effective_model: Facade.effective_model()
    )
  end

  defp anthropic_request(suffix, client_model) do
    %{
      "model" => client_model,
      "max_tokens" => 64,
      "system" => [
        %{
          "type" => "text",
          "text" => "stable cached system prefix",
          "cache_control" => %{"type" => "ephemeral"}
        }
      ],
      "messages" => [%{"role" => "user", "content" => suffix}]
    }
  end

  defp anthropic_options do
    %{
      persona: Persona.fixed(:anthropic_messages),
      upstream_endpoint: @endpoint,
      collect_openai_response_stream: true
    }
  end
end
