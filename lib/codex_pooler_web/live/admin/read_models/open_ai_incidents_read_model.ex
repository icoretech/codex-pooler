defmodule CodexPoolerWeb.Admin.OpenAIIncidentsReadModel do
  @moduledoc "Metadata-only projection for the authenticated OpenAI incidents page."
  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Status.Freshness
  alias CodexPooler.Status.Schemas.Incident

  @history_limit 50

  @type row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:title) => String.t(),
          required(:summary) => String.t(),
          required(:status) => String.t(),
          required(:status_key) => atom(),
          required(:component) => String.t(),
          required(:link) => String.t() | nil,
          required(:published_at) => DateTime.t(),
          required(:first_seen_at) => DateTime.t(),
          required(:last_seen_at) => DateTime.t(),
          required(:resolved_at) => DateTime.t() | nil,
          required(:retired_at) => DateTime.t() | nil
        }

  @type page :: %{
          required(:active) => [row()],
          required(:history) => [row()],
          required(:history_total) => non_neg_integer(),
          required(:history_overflow) => non_neg_integer(),
          required(:last_success_at) => DateTime.t() | nil,
          required(:last_error_code) => String.t() | nil,
          required(:stale?) => boolean(),
          required(:available?) => boolean(),
          required(:polling_enabled?) => boolean()
        }

  @spec load() :: page()
  def load do
    state = OpenAIStatus.feed_state()
    incidents = OpenAIStatus.list_incidents()

    active = Enum.filter(incidents, &(is_nil(&1.resolved_at) and is_nil(&1.retired_at)))
    history = Enum.reject(incidents, &(is_nil(&1.resolved_at) and is_nil(&1.retired_at)))
    history_rows = history |> Enum.take(@history_limit) |> Enum.map(&row/1)

    %{
      active: Enum.map(active, &row/1),
      history: history_rows,
      history_total: length(history),
      history_overflow: max(length(history) - @history_limit, 0),
      last_success_at: state && state.last_success_at,
      last_error_code: state && state.last_error_code,
      stale?: Freshness.stale?(state && state.last_success_at),
      available?: not is_nil(state && state.last_success_at),
      polling_enabled?: CodexPooler.InstanceSettings.current().operator.openai_status_polling_enabled
    }
  end

  @spec row(Incident.t()) :: row()
  def row(%Incident{} = incident) do
    %{
      id: incident.id,
      title: safe_text(incident.title),
      summary: safe_text(incident.summary),
      status: display_status(incident),
      status_key: status_key(incident),
      component: safe_component(incident.component),
      link: safe_link(incident.link),
      published_at: incident.published_at,
      first_seen_at: incident.first_seen_at,
      last_seen_at: incident.last_seen_at,
      resolved_at: incident.resolved_at,
      retired_at: incident.retired_at
    }
  end

  defp status_key(%Incident{retired_at: %DateTime{}}), do: :retired
  defp status_key(%Incident{status: "Investigating"}), do: :investigating
  defp status_key(%Incident{status: "Identified"}), do: :identified
  defp status_key(%Incident{status: "Monitoring"}), do: :monitoring
  defp status_key(%Incident{status: "Resolved"}), do: :resolved
  defp status_key(%Incident{}), do: :unknown

  defp display_status(%Incident{retired_at: %DateTime{}}), do: gettext("Retired")
  defp display_status(%Incident{status: "Investigating"}), do: gettext("Investigating")
  defp display_status(%Incident{status: "Identified"}), do: gettext("Identified")
  defp display_status(%Incident{status: "Monitoring"}), do: gettext("Monitoring")
  defp display_status(%Incident{status: "Resolved"}), do: gettext("Resolved")
  defp display_status(%Incident{status: status}), do: safe_text(status) || gettext("Unknown")

  defp safe_text(nil), do: nil
  defp safe_text(value) when is_binary(value), do: String.trim(value)
  defp safe_text(_), do: nil

  defp safe_component(value) do
    case safe_text(value) do
      nil -> gettext("Unspecified")
      "" -> gettext("Unspecified")
      component -> component
    end
  end

  defp safe_link(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: "status.openai.com", path: path} = uri
      when is_binary(path) and path != "" ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp safe_link(_), do: nil
end
