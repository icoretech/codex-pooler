defmodule CodexPooler.Gateway.Facade.Dispatch do
  @moduledoc """
  Installs and verifies the server-owned facade routing decision.
  """

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.IdentityInstruction
  alias CodexPooler.Gateway.Facade.Policy
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @transcription_endpoint "/backend-api/transcribe"
  @transcription_helper "gpt-4o-transcribe"
  @image_helper "gpt-image-1"
  @native_image_endpoints [
    "/backend-api/codex/images/generations",
    "/backend-api/codex/images/edits"
  ]
  @responses_endpoint "/backend-api/codex/responses"

  @type gateway_error :: CodexPooler.Gateway.Contracts.gateway_error()
  @type preparation ::
          :passthrough
          | {:ok, map(), RequestOptions.t()}
          | {:error, gateway_error(), map(), RequestOptions.t()}
          | {:policy_error, atom(), map(), RequestOptions.t()}

  @spec prepare(Access.auth_context(), String.t(), map(), RequestOptions.t()) :: preparation()
  def prepare(_auth, _endpoint, _payload, %RequestOptions{persona: nil}), do: :passthrough

  def prepare(auth, endpoint, payload, %RequestOptions{persona: %Persona{} = persona} = options)
      when is_map(payload) do
    media_route = media_route(endpoint, options)
    canonical_payload = canonical_payload(payload, persona, media_route)

    options =
      options
      |> RequestOptions.for_payload(endpoint, canonical_payload)
      |> install_routing(persona, nil, media_route)

    cond do
      not Persona.fixed?(persona) ->
        {:error, invariant_error(), canonical_payload, options}

      media_route == :invalid_media ->
        {:error, invariant_error(), canonical_payload, options}

      true ->
        prepare_policy(auth, canonical_payload, options, persona, media_route)
    end
  end

  @spec facade?(RequestOptions.t()) :: boolean()
  def facade?(%RequestOptions{persona: %Persona{}}), do: true
  def facade?(%RequestOptions{}), do: false

  @spec verify(map(), RequestOptions.t(), Model.t()) :: :ok | {:error, gateway_error()}
  def verify(_payload, %RequestOptions{persona: nil}, %Model{}), do: :ok

  def verify(
        payload,
        %RequestOptions{persona: %Persona{}} = options,
        %Model{} = model
      )
      when is_map(payload) do
    valid? =
      case media_route(options.transport.upstream_endpoint, options) do
        {:direct_media, helper_model} ->
          direct_media_invariant?(payload, options, model, helper_model)

        {:responses_image, helper_model} ->
          reasoning_invariant?(payload, options, model) and
            fixed_image_tools?(payload, helper_model)

        :reasoning ->
          reasoning_invariant?(payload, options, model) and
            no_client_selected_image_tools?(payload)

        :invalid_media ->
          false
      end

    if valid? do
      :ok
    else
      {:error, invariant_error()}
    end
  end

  def verify(_payload, %RequestOptions{persona: %Persona{}}, %Model{}),
    do: {:error, invariant_error()}

  @spec unavailable_error() :: gateway_error()
  def unavailable_error do
    error(503, "facade_model_unavailable", "gemma3 is not currently available", "model")
  end

  @spec invariant_error() :: gateway_error()
  def invariant_error do
    error(500, "facade_invariant_failed", "facade routing invariant failed", nil)
    |> Map.put(:accounting_disposition, :zero_work)
  end

  defp prepare_policy(auth, canonical_payload, options, persona, media_route) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        options = install_routing(options, persona, policy, media_route)

        case Policy.authorize(policy, persona) do
          :ok ->
            {:ok, canonical_payload, options}

          {:error, _reason} ->
            {:error, policy_conflict_error(), canonical_payload, options}
        end

      {:error, reason} ->
        {:policy_error, reason, canonical_payload, options}
    end
  end

  defp install_routing(options, persona, policy, {:direct_media, helper_model}) do
    RequestOptions.put_routing(options,
      api_key_policy: policy,
      requested_model: persona.public_model,
      effective_model: helper_model,
      reasoning_effort_decision: nil
    )
  end

  defp install_routing(options, persona, policy, _reasoning_route) do
    RequestOptions.put_routing(options,
      api_key_policy: policy,
      requested_model: persona.public_model,
      effective_model: persona.effective_model,
      reasoning_effort_decision: fixed_decision()
    )
  end

  defp canonical_payload(payload, _persona, {:direct_media, helper_model}) do
    payload
    |> drop_client_selectors()
    |> Map.put("model", helper_model)
  end

  defp canonical_payload(payload, persona, {:responses_image, helper_model}) do
    payload
    |> canonical_reasoning_payload(persona)
    |> normalize_image_tool_models(helper_model)
  end

  defp canonical_payload(payload, persona, :reasoning) do
    payload
    |> canonical_reasoning_payload(persona)
    |> normalize_image_tool_models(nil)
  end

  defp canonical_payload(payload, persona, :invalid_media) do
    payload
    |> canonical_reasoning_payload(persona)
    |> normalize_image_tool_models(nil)
  end

  defp canonical_reasoning_payload(payload, persona) do
    reasoning =
      payload
      |> field("reasoning")
      |> reasoning_summary()
      |> Map.put("effort", persona.reasoning_effort)

    payload
    |> drop_client_selectors()
    |> Map.put("model", persona.effective_model)
    |> Map.put("reasoning", reasoning)
    |> IdentityInstruction.install()
  end

  defp drop_client_selectors(payload) do
    Map.drop(payload, [
      :model,
      :reasoning,
      :reasoning_effort,
      :reasoningEffort,
      :thinking,
      :enable_thinking,
      "model",
      "reasoning",
      "reasoning_effort",
      "reasoningEffort",
      "thinking",
      "enable_thinking"
    ])
  end

  defp normalize_image_tool_models(%{"tools" => tools} = payload, helper_model)
       when is_list(tools) do
    tools =
      Enum.map(tools, fn
        %{"type" => "image_generation"} = tool when is_binary(helper_model) ->
          Map.put(tool, "model", helper_model)

        %{"type" => "image_generation"} = tool ->
          Map.delete(tool, "model")

        tool ->
          tool
      end)

    Map.put(payload, "tools", tools)
  end

  defp normalize_image_tool_models(payload, _helper_model), do: payload

  defp media_route(
         @transcription_endpoint,
         %RequestOptions{
           persona: %Persona{protocol: :media},
           payload_context: %{forced_transcription_model: @transcription_helper}
         }
       ),
       do: {:direct_media, @transcription_helper}

  defp media_route(
         endpoint,
         %RequestOptions{
           persona: %Persona{protocol: :media},
           payload_context: %{
             native_image_request?: true,
             forced_image_model: @image_helper
           }
         }
       )
       when endpoint in @native_image_endpoints,
       do: {:direct_media, @image_helper}

  defp media_route(
         @responses_endpoint,
         %RequestOptions{
           persona: %Persona{protocol: :media},
           payload_context: %{forced_image_model: @image_helper},
           openai_compatibility: %{collect_openai_image_stream: true}
         }
       ),
       do: {:responses_image, @image_helper}

  defp media_route(
         endpoint,
         %RequestOptions{persona: %Persona{protocol: :media}}
       )
       when endpoint == @transcription_endpoint or endpoint == @responses_endpoint or
              endpoint in @native_image_endpoints,
       do: :invalid_media

  defp media_route(_endpoint, %RequestOptions{}), do: :reasoning

  defp reasoning_invariant?(payload, %RequestOptions{persona: persona, routing: routing}, model) do
    Persona.fixed?(persona) and
      routing.requested_model == Facade.public_model() and
      routing.effective_model == Facade.effective_model() and
      Map.get(payload, "model") == Facade.effective_model() and
      get_in(payload, ["reasoning", "effort"]) == Facade.reasoning_effort() and
      model.exposed_model_id == Facade.effective_model() and
      fixed_decision?(routing.reasoning_effort_decision)
  end

  defp direct_media_invariant?(
         payload,
         %RequestOptions{persona: persona, routing: routing},
         model,
         helper_model
       ) do
    Persona.fixed?(persona) and
      routing.requested_model == Facade.public_model() and
      routing.effective_model == helper_model and
      Map.get(payload, "model") == helper_model and
      not Map.has_key?(payload, "reasoning") and
      model.exposed_model_id == Facade.effective_model() and
      is_nil(routing.reasoning_effort_decision)
  end

  defp fixed_image_tools?(%{"tools" => tools}, helper_model) when is_list(tools) do
    image_tools = Enum.filter(tools, &match?(%{"type" => "image_generation"}, &1))

    image_tools != [] and
      Enum.all?(image_tools, &(Map.get(&1, "model") == helper_model))
  end

  defp fixed_image_tools?(_payload, _helper_model), do: false

  defp no_client_selected_image_tools?(%{"tools" => tools}) when is_list(tools) do
    Enum.all?(tools, fn
      %{"type" => "image_generation"} = tool -> not Map.has_key?(tool, "model")
      _tool -> true
    end)
  end

  defp no_client_selected_image_tools?(_payload), do: true

  defp reasoning_summary(%{} = reasoning) do
    case field(reasoning, "summary") do
      summary when is_binary(summary) and summary != "" -> %{"summary" => summary}
      _summary -> %{}
    end
  end

  defp reasoning_summary(_reasoning), do: %{}

  defp field(map, "reasoning") when is_map(map),
    do: Map.get(map, "reasoning") || Map.get(map, :reasoning)

  defp field(map, "summary") when is_map(map),
    do: Map.get(map, "summary") || Map.get(map, :summary)

  defp fixed_decision do
    %Decision{
      mode: :always_use,
      configured_effort: Facade.reasoning_effort(),
      requested_effort: nil,
      applied_effort: Facade.reasoning_effort()
    }
  end

  defp fixed_decision?(%Decision{} = decision), do: decision == fixed_decision()
  defp fixed_decision?(_decision), do: false

  defp policy_conflict_error do
    error(403, "facade_policy_conflict", "API key policy does not permit gemma3", nil)
  end

  defp error(status, code, message, param),
    do: %{status: status, code: code, message: message, param: param}
end
