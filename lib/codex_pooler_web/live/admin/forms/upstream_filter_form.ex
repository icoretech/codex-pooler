defmodule CodexPoolerWeb.Admin.UpstreamFilterForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @filter_keys ~w(query pool_id status)

  @spec query_params(map()) :: map()
  def query_params(filter_params) do
    filter_params
    |> filter_values()
    |> Map.take(@filter_keys)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  @spec filter_values(map(), [term()]) :: map()
  def filter_values(params, pools) do
    values = filter_values(params)

    %{
      "query" => values["query"],
      "pool_id" => normalize_pool_id(values["pool_id"], pools),
      "status" => normalize_status(values["status"])
    }
  end

  @spec filter_form(map()) :: Phoenix.HTML.Form.t()
  def filter_form(values \\ %{}) do
    values
    |> filter_values()
    |> to_form(as: :filters)
  end

  @spec status_options() :: [map()]
  def status_options do
    [any_status_option() | Enum.map(visible_statuses(), &status_option/1)]
  end

  @spec selected_status_option(String.t() | nil) :: map()
  def selected_status_option(status) do
    Enum.find(status_options(), &(&1.value == (status || ""))) || any_status_option()
  end

  defp filter_values(params) when is_map(params) do
    %{
      "query" => string_param(params, "query") || "",
      "pool_id" => string_param(params, "pool_id") || "",
      "status" => string_param(params, "status") || ""
    }
  end

  defp filter_values(_params), do: filter_values(%{})

  defp normalize_pool_id("", _pools), do: ""

  defp normalize_pool_id(pool_id, pools) do
    if Enum.any?(pools, &(&1.id == pool_id)), do: pool_id, else: ""
  end

  defp normalize_status(""), do: ""
  defp normalize_status(status), do: if(status in visible_statuses(), do: status, else: "")

  defp visible_statuses do
    Enum.reject(UpstreamIdentity.statuses(), &(&1 == UpstreamIdentity.deleted_status()))
  end

  defp any_status_option do
    %{
      label: "Any status",
      value: "",
      icon: "hero-circle-stack",
      tone: :neutral
    }
  end

  defp status_option(status) do
    %{
      label: status_label(status),
      value: status,
      icon: status_icon(status),
      tone: status_tone(status)
    }
  end

  defp status_label(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_icon("active"), do: "hero-check-circle"
  defp status_icon("paused"), do: "hero-pause-circle"
  defp status_icon("refresh_due"), do: "hero-arrow-path"
  defp status_icon("refreshing"), do: "hero-arrow-path"
  defp status_icon("refresh_failed"), do: "hero-exclamation-triangle"
  defp status_icon("reauth_required"), do: "hero-key"
  defp status_icon("disabled"), do: "hero-no-symbol"
  defp status_icon("errored"), do: "hero-exclamation-circle"
  defp status_icon(_status), do: "hero-circle-stack"

  defp status_tone("active"), do: :success
  defp status_tone("paused"), do: :warning
  defp status_tone("refresh_due"), do: :warning
  defp status_tone("refreshing"), do: :primary
  defp status_tone("refresh_failed"), do: :error
  defp status_tone("reauth_required"), do: :error
  defp status_tone("disabled"), do: :neutral
  defp status_tone("errored"), do: :error
  defp status_tone(_status), do: :neutral

  defp string_param(params, key) do
    params
    |> Map.get(key)
    |> blank_to_empty()
  end

  defp blank_to_empty(value) when is_binary(value), do: String.trim(value)
  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(_value), do: ""

  defp blank?(value), do: String.trim(to_string(value || "")) == ""
end
