defmodule CodexPoolerWeb.Admin.RequestLogsDisplay.UserAgents do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Accounting.ClientIdentity

  @type css_class :: ClientIdentity.css_class()
  @type logo :: ClientIdentity.logo()
  @type classification :: ClientIdentity.classification()

  @spec display(map()) :: map() | nil
  def display(%{user_agent: user_agent}) when is_binary(user_agent) do
    user_agent = String.trim(user_agent)

    if user_agent == "" do
      nil
    else
      classification = classify(user_agent)

      %{
        text: compact(user_agent),
        title: if(classification.kind == "unknown", do: gettext("Client user agent"), else: gettext("%{client} user agent", client: classification.label)),
        kind: classification.kind,
        label: classification.label,
        icon: classification.icon,
        icon_class: classification.icon_class,
        logo: classification.logo
      }
    end
  end

  def display(_request_log), do: nil

  @spec format(map()) :: String.t() | nil
  def format(%{user_agent: user_agent}) when is_binary(user_agent) and user_agent != "",
    do: compact(user_agent)

  def format(_request_log), do: nil

  @spec classify(String.t() | nil) :: classification()
  defdelegate classify(user_agent), to: ClientIdentity

  defp compact(user_agent), do: ClientIdentity.compact_user_agent(user_agent)
end
