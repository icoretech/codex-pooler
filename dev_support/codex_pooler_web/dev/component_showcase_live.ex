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

  # Every branch the OAuth dialog can render, so a review sees the states that
  # only appear when something goes wrong or when a route other than the browser
  # one is taken. `browser` stays the default: it is what the plain review URL
  # has always shown.
  @oauth_cases [
    {"start", "Start"},
    {"browser", "Browser pending"},
    {"browser-error", "Callback rejected"},
    {"device", "Device pending"},
    {"device-expired", "Code expired"},
    {"completed", "Linked"},
    {"device-linked", "Device linked"},
    {"relink", "Relink"},
    {"relink-linked", "Relinked"},
    {"relink-mismatch", "Identity mismatch"}
  ]

  @oauth_case_values Enum.map(@oauth_cases, &elem(&1, 0))

  # Synthetic, but shaped like the real column so the cockpit link in the footer
  # renders the route it would render in production.
  @oauth_completed_identity_id "00000000-0000-4000-8000-00000000c0de"

  def component_contract, do: ComponentShowcaseCatalog.entries()
  def render_contracts, do: Map.new([ComponentShowcaseStats.contract()], &{&1.id, &1})

  @impl true
  def mount(params, session, socket) do
    review_state = selected_review_state(params, session)
    oauth_case = selected_oauth_case(params)

    socket =
      socket
      |> assign(
        theme: selected_theme(params, session),
        paused: false,
        review_state: review_state,
        oauth_case: oauth_case,
        oauth_cases: @oauth_cases,
        variants: ComponentShowcaseData.primitive_variants(),
        observatory: ComponentShowcaseData.observatory_presentation(),
        oauth_link_form:
          to_form(%{"pool_id" => "dev-component-showcase", "callback_url" => ""},
            as: :oauth_link
          )
      )
      |> assign(oauth_fixture(oauth_case))
      |> select_review_state(review_state)

    {:ok, socket}
  end

  defp selected_oauth_case(%{"case" => oauth_case}) when oauth_case in @oauth_case_values,
    do: oauth_case

  defp selected_oauth_case(_params), do: "browser"

  defp select_oauth_case(socket, oauth_case) do
    socket
    |> assign(:oauth_case, oauth_case)
    |> assign(oauth_fixture(oauth_case))
  end

  # Synthetic throughout: no real authorization URL, account, or device code.
  defp oauth_fixture("start") do
    %{
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_flow: nil,
      oauth_link_authorization_url: nil,
      oauth_link_result: nil,
      oauth_link_error: nil
    }
  end

  defp oauth_fixture("browser-error") do
    "browser"
    |> oauth_fixture()
    |> Map.put(:oauth_link_error, %{
      message: "That callback URL is from an earlier attempt. Open the page again and paste the new one."
    })
  end

  defp oauth_fixture("device") do
    %{
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_flow: %{
        flow_kind: "device",
        status: "pending",
        device_user_code: "FJDK-XRQP",
        verification_uri: "https://auth.example.com/device",
        interval_seconds: 5,
        expires_at: ~U[2026-08-13 17:45:00.000000Z]
      },
      oauth_link_authorization_url: nil,
      oauth_link_result: %{message: "Device authorization pending"},
      oauth_link_error: nil
    }
  end

  # Shown the way the dialog renders it today, dead code and all: the expired
  # code stays on screen beside the controls that would start a new one, which
  # is the point of being able to look at this state.
  defp oauth_fixture("device-expired") do
    "device"
    |> oauth_fixture()
    |> Map.merge(%{
      oauth_link_result: nil,
      oauth_link_error: %{
        message: "The authorization window expired. Start onboarding again from a fresh invite."
      }
    })
  end

  # The message and the identity stamp are the real ones: `complete_message/1`
  # produces this exact string, and `mark_oauth_flow_completed/4` puts the linked
  # identity on the flow, which is what the footer's cockpit link reads.
  defp oauth_fixture("completed") do
    %{
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_flow: %{
        flow_kind: "browser",
        status: "completed",
        result_upstream_identity_id: @oauth_completed_identity_id
      },
      oauth_link_authorization_url: nil,
      oauth_link_result: %{message: "OpenAI account linked"},
      oauth_link_error: nil
    }
  end

  # The device route reaching its own end: `completed` above is the browser one,
  # and the two differ in what the operator did to get there.
  defp oauth_fixture("device-linked") do
    "completed"
    |> oauth_fixture()
    |> Map.put(:oauth_link_flow, %{
      flow_kind: "device",
      status: "completed",
      result_upstream_identity_id: @oauth_completed_identity_id
    })
  end

  # The third finished screen: a relink ends on its own header and its own
  # message, so reviewing only the two link ones would leave that copy unseen.
  defp oauth_fixture("relink-linked") do
    "relink"
    |> oauth_fixture()
    |> Map.merge(%{
      oauth_link_flow: %{
        flow_kind: "browser",
        status: "completed",
        result_upstream_identity_id: @oauth_completed_identity_id
      },
      oauth_link_authorization_url: nil,
      oauth_link_result: %{message: "OpenAI account relinked"}
    })
  end

  defp oauth_fixture("relink-mismatch") do
    "relink"
    |> oauth_fixture()
    |> Map.merge(%{
      oauth_link_result: nil,
      oauth_link_error: %{
        message: "The authorized Codex account does not match the account being relinked."
      }
    })
  end

  defp oauth_fixture("relink") do
    "browser"
    |> oauth_fixture()
    |> Map.merge(%{
      oauth_link_mode: :relink,
      oauth_link_target_account: %{label: "design-review-account"}
    })
  end

  defp oauth_fixture(_browser) do
    %{
      oauth_link_mode: :link,
      oauth_link_target_account: nil,
      oauth_link_flow: %{flow_kind: "browser", status: "pending"},
      oauth_link_authorization_url: @oauth_browser_authorization_url,
      oauth_link_result: %{message: "Browser authorization pending"},
      oauth_link_error: nil
    }
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

  # The dialog's own controls walk the review between fixtures, so the states can
  # be reached the way an operator reaches them rather than only by URL. Without
  # these the door buttons had no matching clause at all and the click took the
  # LiveView down, which is why the dialog could be looked at but not used.
  def handle_event("start_oauth_browser", _params, socket),
    do: {:noreply, select_oauth_case(socket, "browser")}

  def handle_event("start_oauth_device", _params, socket),
    do: {:noreply, select_oauth_case(socket, "device")}

  def handle_event("cancel_oauth_link", _params, socket),
    do: {:noreply, select_oauth_case(socket, "start")}

  def handle_event("submit_oauth_callback", _params, socket),
    do: {:noreply, select_oauth_case(socket, "completed")}

  def handle_event("validate_oauth_link_pool", _params, socket), do: {:noreply, socket}

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
          <nav
            id="showcase-oauth-case-switcher"
            aria-label="OAuth dialog state"
            class="fixed inset-x-0 top-0 flex flex-wrap items-center gap-1.5 border-b border-base-300 bg-base-100 px-3 py-2"
            {%{"style" => "z-index:1000"}}
          >
            <span class="mr-1 text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/45">
              State
            </span>
            <a
              :for={{value, label} <- @oauth_cases}
              id={"showcase-oauth-case-#{value}"}
              href={"/dev/component-showcase/#{@theme}?state=oauth-browser-dialog&case=#{value}"}
              aria-current={value == @oauth_case && "page"}
              class={[
                "rounded-field border px-2 py-1 text-xs font-semibold transition-colors",
                value == @oauth_case && "border-primary bg-primary/10 text-base-content",
                value != @oauth_case &&
                  "border-base-300 text-base-content/60 hover:border-primary/50 hover:text-base-content"
              ]}
            >
              {label}
            </a>
          </nav>

          <UpstreamPageComponents.oauth_link_dialog
            oauth_linking
            oauth_link_mode={@oauth_link_mode}
            oauth_link_target_account={@oauth_link_target_account}
            oauth_link_form={@oauth_link_form}
            oauth_link_flow={@oauth_link_flow}
            oauth_link_authorization_url={@oauth_link_authorization_url}
            oauth_link_result={@oauth_link_result}
            oauth_link_error={@oauth_link_error}
            pool_options={[{"Design review Pool", "dev-component-showcase"}]}
            datetime_preferences={CodexPoolerWeb.DateTimeDisplay.preferences_for_user(nil)}
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
