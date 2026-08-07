defmodule CodexPoolerWeb.Admin.SystemSettingsForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.InstanceSettings.Settings

  @json_fields [{"gateway", "bulkheads"}, {"gateway", "model_context_window_overrides"}]
  @array_fields [
    {"ingress", "firewall_allowlist"},
    {"ingress", "trusted_proxies"},
    {"ingress", "decompression_algorithms"}
  ]
  @forwarded_client_ip_source_options [
    {"Peer connection", "peer"},
    {"X-Forwarded-For", "x_forwarded_for"},
    {"X-Real-IP", "x_real_ip"}
  ]
  @settings_groups ~w(gateway ingress files transcription operator catalog development mcp metrics smtp)

  @spec settings_groups() :: [String.t()]
  def settings_groups, do: @settings_groups

  @spec forwarded_client_ip_source_options() :: [{String.t(), String.t()}]
  def forwarded_client_ip_source_options, do: @forwarded_client_ip_source_options

  @spec forms(Settings.t(), map()) :: map()
  def forms(%Settings{} = settings, form_params) do
    Map.new(@settings_groups, fn group ->
      changeset = group_changeset(settings, form_params, group)
      {group, to_form(changeset, as: :instance_settings)}
    end)
  end

  @spec group_changeset(Settings.t(), map(), String.t()) :: Ecto.Changeset.t()
  def group_changeset(%Settings{} = settings, form_params, group) do
    settings
    |> params_for_group_changeset(form_params, group)
    |> then(&Settings.changeset(settings, &1))
  end

  @spec params_for_group_changeset(Settings.t(), map(), String.t()) :: map()
  def params_for_group_changeset(%Settings{} = settings, form_params, group) do
    settings
    |> params_from_settings()
    |> Map.put(group, Map.get(form_params, group, %{}))
    |> Map.put("lock_version", Map.get(form_params, "lock_version", settings.lock_version))
  end

  @spec group_only_params(Settings.t(), map(), String.t()) :: map()
  def group_only_params(%Settings{} = settings, form_params, group) do
    settings
    |> params_from_settings()
    |> Map.put(group, Map.get(form_params, group, %{}))
    |> Map.put("lock_version", settings.lock_version)
    |> normalize_params()
  end

  @spec merge_group_params(map(), String.t(), map()) :: map()
  def merge_group_params(form_params, group, params) do
    form_params
    |> Map.put(group, Map.get(params, group, %{}))
    |> Map.put("lock_version", Map.get(params, "lock_version", form_params["lock_version"]))
  end

  @spec strip_form_meta(map()) :: map()
  def strip_form_meta(params), do: Map.drop(params, ["_group"])

  @spec submitted_group(map()) :: String.t()
  def submitted_group(params) do
    case Map.get(params, "_group") do
      group when group in @settings_groups ->
        group

      _missing_or_invalid ->
        params
        |> Map.keys()
        |> Enum.find("gateway", &(&1 in @settings_groups))
    end
  end

  @spec group_snapshots(map()) :: map()
  def group_snapshots(params), do: Map.new(@settings_groups, &{&1, Map.get(params, &1, %{})})

  @spec initial_card_statuses() :: map()
  def initial_card_statuses, do: Map.new(@settings_groups, &{&1, nil})

  @spec group_stale?(map(), Settings.t(), String.t()) :: boolean()
  def group_stale?(group_snapshots, %Settings{} = latest_settings, group) do
    latest_group = latest_settings |> params_from_settings() |> Map.get(group, %{})
    Map.get(group_snapshots, group, %{}) != latest_group
  end

  @spec refresh_saved_group_params(map(), map(), String.t()) :: map()
  def refresh_saved_group_params(form_params, saved_params, group) do
    form_params
    |> Map.put(group, Map.fetch!(saved_params, group))
    |> Map.put("lock_version", saved_params["lock_version"])
  end

  @spec refresh_group_snapshots(map(), map(), String.t()) :: map()
  def refresh_group_snapshots(assigns, saved_params, saved_group) do
    Map.new(@settings_groups, fn group ->
      dirty? = dirty_group?(assigns.form_params, assigns.group_snapshots, group)

      cond do
        group == saved_group -> {group, Map.fetch!(saved_params, group)}
        dirty? -> {group, Map.fetch!(assigns.group_snapshots, group)}
        true -> {group, Map.fetch!(saved_params, group)}
      end
    end)
  end

  @spec saved_card_statuses(map(), map(), String.t()) :: map()
  def saved_card_statuses(form_params, group_snapshots, saved_group) do
    Map.new(@settings_groups, fn group ->
      cond do
        group == saved_group ->
          {group, %{tone: :success, message: "Saved"}}

        dirty_group?(form_params, group_snapshots, group) ->
          {group, %{tone: :warning, message: "Unsaved changes, not saved by this action"}}

        true ->
          {group, nil}
      end
    end)
  end

  @spec dirty_card_status(map(), map(), String.t()) :: map() | nil
  def dirty_card_status(form_params, group_snapshots, group) do
    if dirty_group?(form_params, group_snapshots, group),
      do: %{tone: :warning, message: "Unsaved changes"},
      else: nil
  end

  @spec dirty_group?(map(), map(), String.t()) :: boolean()
  def dirty_group?(form_params, group_snapshots, group) do
    Map.get(form_params, group, %{}) != Map.get(group_snapshots, group, %{})
  end

  @spec normalize_params(map()) :: map()
  def normalize_params(params) when is_map(params) do
    params
    |> strip_form_meta()
    |> normalize_array_fields()
    |> normalize_json_fields()
    |> normalize_write_only("metrics", "bearer_token", "bearer_token_action")
    |> normalize_write_only("smtp", "password", "password_action")
  end

  @spec params_from_settings(Settings.t()) :: map()
  def params_from_settings(%Settings{} = settings) do
    %{
      "lock_version" => settings.lock_version,
      "gateway" =>
        settings.gateway
        |> Map.from_struct()
        |> stringify_keys(),
      "ingress" =>
        settings.ingress
        |> Map.from_struct()
        |> stringify_keys(),
      "files" =>
        settings.files
        |> Map.from_struct()
        |> stringify_keys(),
      "transcription" =>
        settings.transcription
        |> Map.from_struct()
        |> stringify_keys(),
      "operator" =>
        settings.operator
        |> Map.from_struct()
        |> stringify_keys(),
      "catalog" =>
        settings.catalog
        |> Map.from_struct()
        |> stringify_keys(),
      "development" =>
        settings.development
        |> Map.from_struct()
        |> stringify_keys(),
      "mcp" =>
        settings.mcp
        |> Map.from_struct()
        |> stringify_keys(),
      "metrics" => %{
        "bearer_token" => nil,
        "bearer_token_action" => "preserve",
        "bearer_token_hmac_digest" => settings.metrics.bearer_token_hmac_digest,
        "bearer_token_fingerprint" => settings.metrics.bearer_token_fingerprint,
        "bearer_token_key_version" => settings.metrics.bearer_token_key_version
      },
      "smtp" =>
        settings.smtp
        |> Map.from_struct()
        |> Map.drop([:password, :password_action, :password_status])
        |> stringify_keys()
        |> Map.merge(%{"password" => nil, "password_action" => "preserve"})
    }
  end

  defp normalize_array_fields(params),
    do: Enum.reduce(@array_fields, params, &normalize_array_field/2)

  defp normalize_json_fields(params),
    do: Enum.reduce(@json_fields, params, &normalize_json_field/2)

  defp normalize_array_field({group, field}, params) do
    update_nested(params, group, field, fn
      value when is_binary(value) -> split_list(value)
      value when is_list(value) -> normalize_list_values(value)
      value -> value
    end)
  end

  defp normalize_json_field({group, field}, params) do
    update_nested(params, group, field, fn
      value when is_binary(value) -> decode_json_map(value)
      value -> value
    end)
  end

  defp normalize_write_only(params, group, value_field, action_field) do
    group_params = Map.get(params, group, %{})
    value = group_params |> Map.get(value_field) |> blank_to_nil()
    action = Map.get(group_params, action_field)

    {value, action} =
      cond do
        action == "clear" -> {nil, "clear"}
        is_binary(value) -> {value, "set"}
        true -> {nil, "preserve"}
      end

    group_params =
      group_params
      |> Map.put(value_field, value)
      |> Map.put(action_field, action)

    Map.put(params, group, group_params)
  end

  defp update_nested(params, group, field, fun) do
    case Map.get(params, group) do
      %{} = group_params when is_map_key(group_params, field) ->
        Map.put(params, group, Map.update!(group_params, field, fun))

      _missing ->
        params
    end
  end

  defp split_list(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> normalize_list_values()
  end

  defp normalize_list_values(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp decode_json_map(value) do
    value = String.trim(value)

    if value == "" do
      %{}
    else
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _invalid -> value
      end
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
