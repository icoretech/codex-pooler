defmodule CodexPoolerWeb.Dev.ComponentShowcaseLive do
  @moduledoc false

  use CodexPoolerWeb, :live_view

  alias CodexPoolerWeb.Admin.UpstreamPageComponents

  alias CodexPoolerWeb.Dev.{
    ComponentShowcase,
    ComponentShowcaseCatalog,
    ComponentShowcaseData,
    ComponentShowcaseStats
  }

  @review_states ~w(catalog flash oauth-browser-dialog policy-dialog request-drawer)

  @oauth_browser_authorization_url "https://auth.example.com/oauth/authorize?client_id=dev-component-showcase&response_type=code&state=synthetic-review-state"

  def component_contract, do: ComponentShowcaseCatalog.entries()
  def render_contracts, do: Map.new([ComponentShowcaseStats.contract()], &{&1.id, &1})

  @impl true
  def mount(params, session, socket) do
    review_state = selected_review_state(params, session)

    socket =
      socket
      |> assign(
        theme: selected_theme(params, session),
        paused: false,
        review_state: review_state,
        variants: ComponentShowcaseData.primitive_variants(),
        observatory: ComponentShowcaseData.observatory_presentation(),
        oauth_link_form:
          to_form(%{"pool_id" => "dev-component-showcase", "callback_url" => ""},
            as: :oauth_link
          ),
        oauth_link_flow: %{flow_kind: "browser", status: "pending"},
        oauth_link_authorization_url: @oauth_browser_authorization_url,
        oauth_link_result: %{message: "Browser authorization pending"}
      )
      |> select_review_state(review_state)

    {:ok, socket}
  end

  @impl true
  def handle_event("showcase-toggle-paused", _params, socket) do
    {:noreply, update(socket, :paused, &(!&1))}
  end

  def handle_event("showcase-show-flash", _params, socket) do
    {:noreply, select_review_state(socket, "flash")}
  end

  def handle_event("showcase-open-request-drawer", _params, socket) do
    {:noreply, select_review_state(socket, "request-drawer")}
  end

  def handle_event("showcase-open-policy-editor", _params, socket) do
    {:noreply, select_review_state(socket, "policy-dialog")}
  end

  def handle_event("showcase-close-policy-editor", _params, socket) do
    {:noreply, select_review_state(socket, "catalog")}
  end

  def handle_event("cancel_oauth_link", _params, socket), do: {:noreply, socket}
  def handle_event("submit_oauth_callback", _params, socket), do: {:noreply, socket}

  def handle_event("close_request_log", _params, socket),
    do: {:noreply, select_review_state(socket, "catalog")}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="showcase-theme-boundary" data-theme={@theme} class="min-h-svh">
      <Layouts.app flash={@flash} chrome={:observatory}>
        <div
          :if={@review_state == "oauth-browser-dialog"}
          id="showcase-oauth-browser-dialog-fixture"
          class="min-h-svh bg-base-200 text-base-content"
        >
          <UpstreamPageComponents.oauth_link_dialog
            oauth_linking
            oauth_link_form={@oauth_link_form}
            oauth_link_flow={@oauth_link_flow}
            oauth_link_authorization_url={@oauth_link_authorization_url}
            oauth_link_result={@oauth_link_result}
            pool_options={[{"Design review Pool", "dev-component-showcase"}]}
          />
        </div>

        <ComponentShowcase.component_showcase
          :if={@review_state != "oauth-browser-dialog"}
          theme={@theme}
          paused={@paused}
          review_state={@review_state}
          variants={@variants}
          observatory={@observatory}
        />
      </Layouts.app>
    </div>
    """
  end

  defp selected_theme(%{"theme" => theme}, _session) when theme in ~w(light dark), do: theme

  defp selected_theme(_params, %{"theme" => theme}) when theme in ~w(light dark), do: theme
  defp selected_theme(_params, _session), do: "dark"

  defp selected_review_state(%{"state" => review_state}, _session)
       when review_state in @review_states,
       do: review_state

  defp selected_review_state(_params, %{"review_state" => review_state})
       when review_state in @review_states,
       do: review_state

  defp selected_review_state(_params, _session), do: "catalog"

  defp select_review_state(socket, review_state) do
    socket = socket |> clear_flash() |> assign(:review_state, review_state)

    if review_state == "flash" do
      put_flash(socket, :info, "Showcase notification rendered through the real flash group.")
    else
      socket
    end
  end
end
