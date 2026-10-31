defmodule CodexPoolerWeb.Admin.JobsPresentation.Targets do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext
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

  defp job_target_variant(%{target_kind: "upstream_identity"}), do: :direct_identity

  defp job_target_variant(target) do
    target
    |> target_variant_candidates()
    |> Enum.find_value(&present_target_variant/1)
  end

  defp target_variant_candidates(target) do
    [
      {:assignment, [target.assignment_label, target.assignment_id]},
      {:direct_identity, [target.direct_identity_label, target.upstream_identity_id]},
      {:pool, [target.pool_name, target.pool_id]},
      {:api_key, [target.api_key_label, target.api_key_id]},
      {:rollup, [target.rollup_date]}
    ]
  end

  defp present_target_variant({variant, values}) do
    if target_variant_present?(values), do: variant
  end

  defp target_variant_present?(values) do
    Enum.any?(values, &present?/1)
  end

  defp assignment_job_target(target) do
    target =
      labeled_target(
        gettext("Account"),
        target.assignment_identity_label,
        target.assignment_id,
        target_assignment_secondary(target),
        target_assignment_secondary_title(target)
      )

    Map.put(target, :kind, :assignment)
  end

  defp direct_identity_job_target(target) do
    status = target_status(gettext("Status"), target.direct_identity_status)

    target =
      labeled_target(
        gettext("Account"),
        target.direct_identity_label,
        target.upstream_identity_id,
        status,
        status
      )

    Map.put(target, :kind, :direct_identity)
  end

  # The slug restates the Pool name it is derived from, so it stays out of the
  # row and the card; the drawer still carries the identifying detail.
  defp pool_job_target(target) do
    target = labeled_target(gettext("Pool"), target.pool_name, target.pool_id, nil, nil)
    Map.put(target, :kind, :pool)
  end

  defp api_key_job_target(target) do
    prefix = target_status(gettext("Prefix"), target.api_key_prefix)
    target = labeled_target(gettext("API key"), target.api_key_label, target.api_key_id, prefix, prefix)
    Map.put(target, :kind, :api_key)
  end

  defp rollup_job_target(target) do
    primary = gettext("Rollup %{date}", date: target.rollup_date)

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
      target_label(gettext("Assignment"), target.assignment_label, target.assignment_id),
      target_label(gettext("Pool"), target.pool_name, target.pool_id),
      target_status(gettext("Status"), target.assignment_status || target.assignment_identity_status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp target_assignment_secondary_title(target) do
    [
      target_title(gettext("Assignment"), target.assignment_label, target.assignment_id),
      target_title(gettext("Pool"), target.pool_name, target.pool_id),
      target_status(gettext("Status"), target.assignment_status || target.assignment_identity_status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp target_label(kind, label, id) do
    kind = translate_target_kind(kind)

    cond do
      present?(label) -> gettext("%{kind}: %{label}", kind: kind, label: label)
      present?(id) -> gettext("%{kind}: %{id}", kind: kind, id: short_id(id))
      true -> nil
    end
  end

  defp target_title(kind, label, id) do
    kind = translate_target_kind(kind)

    cond do
      present?(label) and present?(id) -> gettext("%{kind}: %{label} (%{id})", kind: kind, label: label, id: id)
      present?(label) -> gettext("%{kind}: %{label}", kind: kind, label: label)
      present?(id) -> gettext("%{kind}: %{id}", kind: kind, id: id)
      true -> nil
    end
  end

  defp target_status(kind, value) do
    if present?(value), do: gettext("%{kind}: %{value}", kind: kind, value: translate_status(value))
  end

  defp translate_target_kind("Account"), do: gettext("Account")
  defp translate_target_kind("Assignment"), do: gettext("Assignment")
  defp translate_target_kind("Pool"), do: gettext("Pool")
  defp translate_target_kind("API key"), do: gettext("API key")
  defp translate_target_kind(kind), do: kind

  defp translate_status("active"), do: gettext("active")
  defp translate_status("pending"), do: gettext("pending")
  defp translate_status("refresh_due"), do: gettext("refresh due")
  defp translate_status("refreshing"), do: gettext("refreshing")
  defp translate_status("paused"), do: gettext("paused")
  defp translate_status("refresh_failed"), do: gettext("refresh failed")
  defp translate_status("reauth_required"), do: gettext("reauth required")
  defp translate_status("disabled"), do: gettext("disabled")
  defp translate_status("deleted"), do: gettext("deleted")
  defp translate_status("errored"), do: gettext("errored")
  defp translate_status(value), do: value

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
