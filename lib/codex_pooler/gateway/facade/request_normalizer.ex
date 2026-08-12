defmodule CodexPooler.Gateway.Facade.RequestNormalizer do
  @moduledoc """
  Normalizes client protocol selectors into the immutable facade target before
  public request validation runs.

  Only documented selector locations are changed. User input, tool schemas,
  and arbitrary nested values are never traversed.
  """

  alias CodexPooler.Gateway.Facade.IdentityInstruction
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @selector_keys [
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
  ]

  @spec openai(map(), RequestOptions.t()) ::
          {:ok, map(), %{optional(:public_model) => String.t()}}
  def openai(payload, %RequestOptions{persona: %Persona{} = persona}) when is_map(payload) do
    if Persona.fixed?(persona) do
      normalized =
        payload
        |> Map.drop(@selector_keys)
        |> Map.put("model", persona.effective_model)
        |> Map.put("reasoning", forced_reasoning(payload, persona))
        |> IdentityInstruction.install()

      {:ok, normalized, %{public_model: persona.public_model}}
    else
      {:ok, payload, %{}}
    end
  end

  def openai(payload, %RequestOptions{}) when is_map(payload), do: {:ok, payload, %{}}

  @spec chat(map(), RequestOptions.t()) ::
          {:ok, map(), %{optional(:public_model) => String.t()}}
  def chat(payload, %RequestOptions{persona: %Persona{} = persona}) when is_map(payload) do
    if Persona.fixed?(persona) do
      normalized =
        payload
        |> Map.drop(@selector_keys)
        |> Map.put("model", persona.effective_model)
        |> Map.put("reasoning_effort", persona.reasoning_effort)
        |> IdentityInstruction.install()

      {:ok, normalized, %{public_model: persona.public_model}}
    else
      {:ok, payload, %{}}
    end
  end

  def chat(payload, %RequestOptions{}) when is_map(payload), do: {:ok, payload, %{}}

  defp forced_reasoning(payload, persona) do
    payload
    |> field("reasoning")
    |> reasoning_summary()
    |> Map.put("effort", persona.reasoning_effort)
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
end
