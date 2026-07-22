defmodule CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe do
  @moduledoc false

  @version 2

  @enforce_keys [:token]
  defstruct [
    :token,
    :version,
    :pool_upstream_assignment_id,
    :upstream_identity_id,
    :effective_model,
    :route_class
  ]

  @type t :: %__MODULE__{
          token: Ecto.UUID.t(),
          version: 2 | nil,
          pool_upstream_assignment_id: Ecto.UUID.t() | nil,
          upstream_identity_id: Ecto.UUID.t() | nil,
          effective_model: String.t() | nil,
          route_class: String.t() | nil
        }

  @type bind_error :: :invalid_scope | :scope_mismatch

  @spec new() :: t()
  def new, do: %__MODULE__{token: Ecto.UUID.generate()}

  @spec bind(t(), term(), term(), term(), term()) :: {:ok, t()} | {:error, bind_error()}
  def bind(
        %__MODULE__{} = probe,
        pool_upstream_assignment_id,
        upstream_identity_id,
        effective_model,
        route_class
      ) do
    with true <- valid_uuid?(probe.token),
         {:ok, scope} <-
           validated_scope(
             pool_upstream_assignment_id,
             upstream_identity_id,
             effective_model,
             route_class
           ) do
      bind_scope(probe, scope)
    else
      _invalid -> {:error, :invalid_scope}
    end
  end

  @spec bound?(t()) :: boolean()
  def bound?(%__MODULE__{version: @version} = probe) do
    valid_uuid?(probe.token) and
      match?(
        {:ok, _scope},
        validated_scope(
          probe.pool_upstream_assignment_id,
          probe.upstream_identity_id,
          probe.effective_model,
          probe.route_class
        )
      )
  end

  def bound?(%__MODULE__{}), do: false

  @spec unbound?(t()) :: boolean()
  def unbound?(%__MODULE__{
        token: token,
        version: nil,
        pool_upstream_assignment_id: nil,
        upstream_identity_id: nil,
        effective_model: nil,
        route_class: nil
      }),
      do: valid_uuid?(token)

  def unbound?(%__MODULE__{}), do: false

  @spec matches?(t(), term(), term(), term(), term()) :: boolean()
  def matches?(
        %__MODULE__{} = probe,
        pool_upstream_assignment_id,
        upstream_identity_id,
        effective_model,
        route_class
      ) do
    with true <- bound?(probe),
         {:ok, scope} <-
           validated_scope(
             pool_upstream_assignment_id,
             upstream_identity_id,
             effective_model,
             route_class
           ) do
      scope_matches?(probe, scope)
    else
      _invalid -> false
    end
  end

  @spec valid_transition?(t() | nil, t() | nil) :: boolean()
  def valid_transition?(nil, nil), do: true

  def valid_transition?(nil, %__MODULE__{} = next),
    do: unbound?(next) or bound?(next)

  def valid_transition?(%__MODULE__{} = current, %__MODULE__{} = next)
      when current == next,
      do: unbound?(current) or bound?(current)

  def valid_transition?(%__MODULE__{token: token} = current, %__MODULE__{token: token} = next),
    do: unbound?(current) and bound?(next)

  def valid_transition?(_current, _next), do: false

  defp bind_scope(
         %__MODULE__{
           version: nil,
           pool_upstream_assignment_id: nil,
           upstream_identity_id: nil,
           effective_model: nil,
           route_class: nil
         } = probe,
         scope
       ) do
    {:ok,
     %__MODULE__{
       probe
       | version: @version,
         pool_upstream_assignment_id: scope.pool_upstream_assignment_id,
         upstream_identity_id: scope.upstream_identity_id,
         effective_model: scope.effective_model,
         route_class: scope.route_class
     }}
  end

  defp bind_scope(%__MODULE__{} = probe, scope) do
    if bound?(probe) and scope_matches?(probe, scope) do
      {:ok, probe}
    else
      {:error, :scope_mismatch}
    end
  end

  defp validated_scope(
         pool_upstream_assignment_id,
         upstream_identity_id,
         effective_model,
         route_class
       ) do
    if valid_uuid?(pool_upstream_assignment_id) and valid_uuid?(upstream_identity_id) and
         valid_exact_string?(effective_model) and valid_exact_string?(route_class) do
      {:ok,
       %{
         pool_upstream_assignment_id: pool_upstream_assignment_id,
         upstream_identity_id: upstream_identity_id,
         effective_model: effective_model,
         route_class: route_class
       }}
    else
      {:error, :invalid_scope}
    end
  end

  defp scope_matches?(probe, scope) do
    probe.version == @version and
      probe.pool_upstream_assignment_id == scope.pool_upstream_assignment_id and
      probe.upstream_identity_id == scope.upstream_identity_id and
      probe.effective_model == scope.effective_model and
      probe.route_class == scope.route_class
  end

  defp valid_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp valid_uuid?(_value), do: false

  defp valid_exact_string?(value) when is_binary(value),
    do: value != "" and String.trim(value) == value

  defp valid_exact_string?(_value), do: false
end
