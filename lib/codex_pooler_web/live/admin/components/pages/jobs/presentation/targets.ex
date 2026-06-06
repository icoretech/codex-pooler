defmodule CodexPoolerWeb.Admin.JobsPresentation.Targets do
  @moduledoc false

  @spec job_target(map()) :: map() | nil
  def job_target(%{target: target}) when is_map(target) do
    case job_target_variant(target) do
      :assignment -> assignment_job_target(target)
      :direct_identity -> direct_identity_job_target(target)
      :pool -> pool_job_target(target)
      :api_key -> api_key_job_target(target)
      :rollup -> rollup_job_target(target)
      nil -> nil
    end
  end

  def job_target(_job), do: nil

  defp job_target_variant(target) do
    [
      {:assignment, [target.assignment_label, target.assignment_id]},
      {:direct_identity, [target.direct_identity_label, target.upstream_identity_id]},
      {:pool, [target.pool_name, target.pool_id]},
      {:api_key, [target.api_key_label, target.api_key_id]},
      {:rollup, [target.rollup_date]}
    ]
    |> Enum.find_value(fn {variant, values} ->
      if target_variant_present?(values), do: variant
    end)
  end

  defp target_variant_present?(values) do
    Enum.any?(values, &present?/1)
  end

  defp assignment_job_target(target) do
    target =
      labeled_target(
        "Account",
        target.assignment_identity_label,
        target.assignment_id,
        target_assignment_secondary(target),
        target_assignment_secondary_title(target)
      )

    Map.put(target, :kind, :assignment)
  end

  defp direct_identity_job_target(target) do
    status = target_status("Status", target.direct_identity_status)

    target =
      labeled_target(
        "Account",
        target.direct_identity_label,
        target.upstream_identity_id,
        status,
        status
      )

    Map.put(target, :kind, :direct_identity)
  end

  defp pool_job_target(target) do
    slug = target_status("Slug", target.pool_slug)
    target = labeled_target("Pool", target.pool_name, target.pool_id, slug, slug)
    Map.put(target, :kind, :pool)
  end

  defp api_key_job_target(target) do
    prefix = target_status("Prefix", target.api_key_prefix)
    target = labeled_target("API key", target.api_key_label, target.api_key_id, prefix, prefix)
    Map.put(target, :kind, :api_key)
  end

  defp rollup_job_target(target) do
    primary = "Rollup #{target.rollup_date}"

    %{
      primary: primary,
      primary_title: primary,
      secondary: nil,
      secondary_title: nil,
      kind: :rollup
    }
  end

  defp labeled_target(kind, label, id, secondary, secondary_title) do
    %{
      primary: target_label(kind, label, id),
      primary_title: target_title(kind, label, id),
      secondary: secondary,
      secondary_title: secondary_title
    }
  end

  defp target_assignment_secondary(target) do
    [
      target_label("Assignment", target.assignment_label, target.assignment_id),
      target_label("Pool", target.pool_name, target.pool_id),
      target_status("Status", target.assignment_status || target.assignment_identity_status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp target_assignment_secondary_title(target) do
    [
      target_title("Assignment", target.assignment_label, target.assignment_id),
      target_title("Pool", target.pool_name, target.pool_id),
      target_status("Status", target.assignment_status || target.assignment_identity_status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp target_label(kind, label, id) do
    cond do
      present?(label) -> "#{kind}: #{label}"
      present?(id) -> "#{kind}: #{short_id(id)}"
      true -> nil
    end
  end

  defp target_title(kind, label, id) do
    cond do
      present?(label) and present?(id) -> "#{kind}: #{label} (#{id})"
      present?(label) -> "#{kind}: #{label}"
      present?(id) -> "#{kind}: #{id}"
      true -> nil
    end
  end

  defp target_status(kind, value) do
    if present?(value), do: "#{kind}: #{value}"
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
