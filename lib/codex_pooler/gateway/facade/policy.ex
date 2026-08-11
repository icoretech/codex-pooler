defmodule CodexPooler.Gateway.Facade.Policy do
  @moduledoc """
  Fail-closed API-key policy agreement for the fixed facade target.

  Facade policy is authorization only: it may accept or deny the server-owned
  target, but it never selects a replacement model or reasoning effort.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @effort_ranks Map.new(Enum.with_index(~w(none minimal low medium high xhigh max ultra)))

  @type denial_reason ::
          :invalid_policy
          | :model_not_allowed
          | :enforced_model_conflict
          | :enforced_reasoning_effort_conflict
          | :maximum_reasoning_effort_conflict

  @spec authorize(map(), Persona.t()) :: :ok | {:error, denial_reason()}
  def authorize(policy, %Persona{} = persona) when is_map(policy) do
    with :ok <-
           allowed_model(Map.get(policy, :allowed_model_identifiers), persona.effective_model),
         :ok <-
           enforced_model(Map.get(policy, :enforced_model_identifier), persona.effective_model),
         :ok <-
           enforced_effort(
             Map.get(policy, :enforced_reasoning_effort),
             persona.reasoning_effort
           ),
         :ok <-
           effort_ceiling(
             Map.get(policy, :maximum_reasoning_effort),
             persona.reasoning_effort
           ) do
      :ok
    end
  end

  def authorize(_policy, %Persona{}), do: {:error, :invalid_policy}

  defp allowed_model(nil, _effective_model), do: :ok

  defp allowed_model(allowed, effective_model) when is_list(allowed) do
    if Enum.any?(allowed, &(canonical(&1) == canonical(effective_model))) do
      :ok
    else
      {:error, :model_not_allowed}
    end
  end

  defp allowed_model(_allowed, _effective_model), do: {:error, :invalid_policy}

  defp enforced_model(nil, _effective_model), do: :ok

  defp enforced_model(enforced, effective_model) when is_binary(enforced) do
    if canonical(enforced) == canonical(effective_model),
      do: :ok,
      else: {:error, :enforced_model_conflict}
  end

  defp enforced_model(_enforced, _effective_model), do: {:error, :invalid_policy}

  defp enforced_effort(nil, _fixed_effort), do: :ok

  defp enforced_effort(enforced, fixed_effort) when is_binary(enforced) do
    if canonical(enforced) == canonical(fixed_effort),
      do: :ok,
      else: {:error, :enforced_reasoning_effort_conflict}
  end

  defp enforced_effort(_enforced, _fixed_effort), do: {:error, :invalid_policy}

  defp effort_ceiling(nil, _fixed_effort), do: :ok

  defp effort_ceiling(maximum, fixed_effort) when is_binary(maximum) do
    with {:ok, maximum_rank} <- effort_rank(maximum),
         {:ok, fixed_rank} <- effort_rank(fixed_effort),
         true <- maximum_rank >= fixed_rank do
      :ok
    else
      _reason -> {:error, :maximum_reasoning_effort_conflict}
    end
  end

  defp effort_ceiling(_maximum, _fixed_effort), do: {:error, :invalid_policy}

  defp effort_rank(effort) do
    case Map.fetch(@effort_ranks, canonical(effort)) do
      {:ok, rank} -> {:ok, rank}
      :error -> {:error, :unknown_effort}
    end
  end

  defp canonical(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp canonical(_value), do: nil
end
