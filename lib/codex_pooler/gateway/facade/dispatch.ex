defmodule CodexPooler.Gateway.Facade.Dispatch do
  @moduledoc """
  Installs and verifies the server-owned facade routing decision.
  """

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Policy
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

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
    canonical_payload = canonical_payload(payload, persona)

    options =
      options
      |> RequestOptions.for_payload(endpoint, canonical_payload)
      |> install_routing(persona, nil)

    cond do
      not Persona.fixed?(persona) ->
        {:error, invariant_error(), canonical_payload, options}

      true ->
        prepare_policy(auth, canonical_payload, options, persona)
    end
  end

  @spec facade?(RequestOptions.t()) :: boolean()
  def facade?(%RequestOptions{persona: %Persona{}}), do: true
  def facade?(%RequestOptions{}), do: false

  @spec verify(map(), RequestOptions.t(), Model.t()) :: :ok | {:error, gateway_error()}
  def verify(_payload, %RequestOptions{persona: nil}, %Model{}), do: :ok

  def verify(
        payload,
        %RequestOptions{persona: %Persona{} = persona, routing: routing},
        %Model{} = model
      )
      when is_map(payload) do
    if Persona.fixed?(persona) and
         routing.requested_model == Facade.public_model() and
         routing.effective_model == Facade.effective_model() and
         Map.get(payload, "model") == Facade.effective_model() and
         get_in(payload, ["reasoning", "effort"]) == Facade.reasoning_effort() and
         model.exposed_model_id == Facade.effective_model() and
         fixed_decision?(routing.reasoning_effort_decision) do
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

  defp prepare_policy(auth, canonical_payload, options, persona) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        options = install_routing(options, persona, policy)

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

  defp install_routing(options, persona, policy) do
    RequestOptions.put_routing(options,
      api_key_policy: policy,
      requested_model: persona.public_model,
      effective_model: persona.effective_model,
      reasoning_effort_decision: fixed_decision()
    )
  end

  defp canonical_payload(payload, persona) do
    reasoning =
      payload
      |> field("reasoning")
      |> reasoning_summary()
      |> Map.put("effort", persona.reasoning_effort)

    payload
    |> Map.drop([
      :model,
      :reasoning,
      :reasoning_effort,
      :reasoningEffort,
      :thinking,
      :enable_thinking,
      "reasoning_effort",
      "reasoningEffort",
      "thinking",
      "enable_thinking"
    ])
    |> Map.put("model", persona.effective_model)
    |> Map.put("reasoning", reasoning)
  end

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
