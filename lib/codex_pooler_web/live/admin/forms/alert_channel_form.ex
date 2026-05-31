defmodule CodexPoolerWeb.Admin.AlertChannelForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Alerts.Schemas.AlertChannel

  @type attrs :: %{String.t() => term()}
  @type channel_projection :: CodexPooler.Alerts.channel_projection()
  @type option :: {String.t(), String.t()}

  @default_channel_type "email"
  @default_state AlertChannel.active_state()

  @channel_type_options [
    {"Email", "email"},
    {"Webhook", "webhook"}
  ]

  @state_options [
    {"Enabled", "active"},
    {"Disabled", "disabled"}
  ]

  @spec create_form(attrs() | map(), keyword()) :: Phoenix.HTML.Form.t()
  def create_form(attrs \\ %{}, opts \\ []) do
    attrs
    |> default_attrs()
    |> normalize_attrs()
    |> to_form(as: :alert_channel, errors: Keyword.get(opts, :errors, []))
  end

  @spec edit_form(channel_projection(), attrs() | map(), keyword()) :: Phoenix.HTML.Form.t()
  def edit_form(channel, attrs \\ %{}, opts \\ []) when is_map(channel) do
    channel
    |> attrs_from_channel()
    |> Map.merge(Map.new(attrs))
    |> normalize_attrs()
    |> to_form(as: :alert_channel, errors: Keyword.get(opts, :errors, []))
  end

  @spec delete_form(channel_projection() | nil) :: Phoenix.HTML.Form.t()
  def delete_form(nil), do: to_form(%{"id" => ""}, as: :alert_channel_delete)

  def delete_form(channel) when is_map(channel),
    do: to_form(%{"id" => channel.id}, as: :alert_channel_delete)

  @spec normalize_submit(attrs() | map(), :create | :edit) :: map()
  def normalize_submit(attrs, mode \\ :create) do
    attrs
    |> normalize_attrs()
    |> Map.take([
      "channel_type",
      "display_name",
      "state",
      "email_to",
      "endpoint_url",
      "webhook_signing_secret",
      "webhook_signing_secret_action"
    ])
    |> prune_channel_type_fields()
    |> drop_blank_optional_values(mode)
  end

  @spec changeset_errors(Ecto.Changeset.t()) :: keyword(String.t())
  def changeset_errors(%Ecto.Changeset{} = changeset), do: changeset.errors

  @spec channel_type_options() :: [option()]
  def channel_type_options, do: @channel_type_options

  @spec state_options() :: [option()]
  def state_options, do: @state_options

  @spec channel_type_label(String.t()) :: String.t()
  def channel_type_label(value), do: label_for(@channel_type_options, value, "Channel")

  @spec state_label(String.t()) :: String.t()
  def state_label(value), do: label_for(@state_options, value, "Unknown state")

  @spec secret_status_label(String.t() | nil) :: String.t()
  def secret_status_label(value) when is_binary(value) and value != "", do: "configured"
  def secret_status_label(_value), do: "not configured"

  @spec value(Phoenix.HTML.FormField.t()) :: term()
  def value(field), do: field.value

  defp default_attrs(attrs) do
    %{
      "channel_type" => @default_channel_type,
      "display_name" => "",
      "state" => @default_state,
      "email_to" => "",
      "endpoint_url" => "",
      "webhook_signing_secret" => "",
      "webhook_signing_secret_action" => "preserve"
    }
    |> Map.merge(Map.new(attrs))
  end

  defp attrs_from_channel(channel) do
    %{
      "id" => channel.id,
      "channel_type" => channel.channel_type,
      "display_name" => channel.display_name,
      "state" => channel.state,
      "email_to" => channel.email_to || "",
      "endpoint_url" => "",
      "webhook_signing_secret" => "",
      "webhook_signing_secret_action" => "preserve"
    }
  end

  defp normalize_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put(
      "channel_type",
      normalize_option(
        string_value(attrs, "channel_type"),
        AlertChannel.channel_types(),
        @default_channel_type
      )
    )
    |> Map.put(
      "state",
      normalize_option(string_value(attrs, "state"), AlertChannel.states(), @default_state)
    )
    |> Map.put(
      "webhook_signing_secret_action",
      normalize_secret_action(string_value(attrs, "webhook_signing_secret_action"))
    )
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value

  defp string_value(attrs, key) do
    attrs = Map.new(attrs)

    case Map.get(attrs, key) || Map.get(attrs, known_atom_key(key)) do
      value when is_binary(value) -> String.trim(value)
      nil -> nil
      value -> to_string(value)
    end
  end

  defp known_atom_key("channel_type"), do: :channel_type
  defp known_atom_key("state"), do: :state
  defp known_atom_key("webhook_signing_secret_action"), do: :webhook_signing_secret_action
  defp known_atom_key(_key), do: :unknown

  defp normalize_option(value, options, default) when is_binary(value) do
    if value in options, do: value, else: default
  end

  defp normalize_option(_value, _options, default), do: default

  defp normalize_secret_action("clear"), do: "clear"
  defp normalize_secret_action(_value), do: "preserve"

  defp prune_channel_type_fields(%{"channel_type" => "webhook"} = attrs),
    do: Map.drop(attrs, ["email_to"])

  defp prune_channel_type_fields(attrs),
    do:
      Map.drop(attrs, ["endpoint_url", "webhook_signing_secret", "webhook_signing_secret_action"])

  defp drop_blank_optional_values(attrs, mode) do
    Enum.reduce(
      ["email_to", "webhook_signing_secret", "webhook_signing_secret_action"],
      attrs,
      fn key, acc ->
        if blank?(Map.get(acc, key)), do: Map.delete(acc, key), else: acc
      end
    )
    |> maybe_drop_blank_endpoint_url(mode)
  end

  defp maybe_drop_blank_endpoint_url(attrs, :edit) do
    if blank?(Map.get(attrs, "endpoint_url")), do: Map.delete(attrs, "endpoint_url"), else: attrs
  end

  defp maybe_drop_blank_endpoint_url(attrs, _mode), do: attrs

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp label_for(options, value, fallback) do
    options
    |> Enum.find_value(fn {label, option_value} -> option_value == value && label end)
    |> case do
      nil -> fallback
      label -> label
    end
  end
end
