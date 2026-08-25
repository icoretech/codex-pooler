defmodule CodexPooler.Quotas.AdditionalMeterIdentity do
  @moduledoc """
  Canonical provider meter identity for additional quota windows.

  Account windows and the canonical Codex Spark model window retain their
  legacy logical identity. Other additional windows may use a provider meter
  token so distinct meters sharing one compatibility quota key stay separate.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.Evidence.Descriptors

  @type group_key ::
          {:legacy, Evidence.logical_window_key()}
          | {:metered, Evidence.logical_window_key(), String.t()}

  @spec group_key(Evidence.t() | map()) :: group_key()
  def group_key(evidence) when is_map(evidence) do
    logical_key = Evidence.logical_window_key(evidence)

    case token(evidence) do
      nil -> {:legacy, logical_key}
      meter_token -> {:metered, logical_key, meter_token}
    end
  end

  @spec token(Evidence.t() | map()) :: String.t() | nil
  def token(evidence) when is_map(evidence) do
    case evidence
         |> Evidence.logical_window_key()
         |> Descriptors.canonical_logical_window_key() do
      {"account", _family, _model, _upstream_model, "account", _kind, _minutes} ->
        nil

      {scope, _family, _model, _upstream_model, "codex_spark", _kind, _minutes}
      when scope in ["model", "upstream_model"] ->
        nil

      _additional_key ->
        present_string(fetch(evidence, :raw_metered_feature)) ||
          present_string(fetch(evidence, :raw_limit_id))
    end
  end

  @doc """
  Splits legacy quota-key groups by canonical provider meter identity.

  Generic observations remain readable when they are the only evidence for a
  quota key. Once rich observations exist, their meter groups replace the
  generic group without manufacturing an extra public meter.
  """
  @spec split_quota_groups(%{optional(String.t()) => [Evidence.t() | map()]}) ::
          [{{String.t(), String.t() | nil}, [Evidence.t() | map()]}]
  def split_quota_groups(quota_groups) when is_map(quota_groups) do
    quota_groups
    |> Enum.flat_map(fn {quota_key, windows} ->
      meter_groups = Enum.group_by(windows, &token/1)

      case Enum.reject(meter_groups, fn {meter_token, _windows} -> is_nil(meter_token) end) do
        [] ->
          [{{quota_key, nil}, windows}]

        groups ->
          Enum.map(groups, fn {meter_token, grouped} -> {{quota_key, meter_token}, grouped} end)
      end
    end)
    |> Enum.sort_by(fn {{quota_key, meter_token}, windows} ->
      first_window = Enum.min_by(windows, &{fetch(&1, :window_kind), fetch(&1, :window_minutes)})

      {quota_key, meter_token || "", fetch(first_window, :window_kind),
       fetch(first_window, :window_minutes)}
    end)
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp present_string(_value), do: nil
end
