defmodule CodexPoolerWeb.OnboardingLive.Invite do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Access
  alias CodexPooler.Access.InviteOnboarding
  alias CodexPoolerWeb.OnboardingLive.Invite.Components

  @impl true
  def render(assigns) do
    ~H"""
    <Components.invite_page
      flash={@flash}
      current_scope={@current_scope}
      contract={@contract}
      device_authorization={@device_authorization}
      device_poll_status={@device_poll_status}
      completed_onboarding={@completed_onboarding}
      invite_state={@invite_state}
      error_message={@error_message}
      now={@now}
    />
    """
  end

  @impl true
  def mount(%{"invite_token" => token}, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Codex account onboarding",
        current_origin: nil,
        invite_token: token,
        device_authorization: nil,
        invite_timer: nil,
        invite_timer_ref: nil,
        device_poll_status: "Waiting for approval.",
        completed_onboarding: nil,
        invite_state: :loading,
        error_message: nil,
        now: DateTime.utc_now()
      )
      |> assign_invite(token)

    {:ok, if(connected?(socket), do: schedule_invite_countdown(socket), else: socket)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    origin = origin_from_uri(uri) || socket.assigns.current_origin

    {:noreply,
     socket
     |> assign(:current_origin, origin)
     |> refresh_completed_config()}
  end

  @impl true
  def handle_event("start_device", _params, socket) do
    case InviteOnboarding.start_device(socket.assigns.invite_token) do
      {:ok, %{account: account, verification: verification}} ->
        authorization = %{
          account_id: account.identity.id,
          url: verification["verification_url"],
          user_code: verification["user_code"],
          expires_at: verification["expires_at"],
          poll_interval_seconds: verification["poll_interval_seconds"]
        }

        {:noreply,
         socket
         |> put_flash(:info, "Device authorization started")
         |> transition_device_pending(
           authorization,
           "Open the verification page, enter the code, and keep this page open."
         )
         |> schedule_device_poll()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_info({:invite_workflow_tick, ref}, %{assigns: %{invite_timer_ref: ref}} = socket) do
    {:noreply,
     socket
     |> clear_invite_timer()
     |> handle_invite_workflow_tick()}
  end

  def handle_info({:invite_workflow_tick, _ref}, socket) do
    {:noreply, socket}
  end

  defp handle_invite_workflow_tick(socket) do
    socket = assign(socket, :now, DateTime.utc_now())

    case socket.assigns.invite_state do
      :device_pending -> poll_device_authorization(socket)
      state when state in [:ready, :device_error] -> refresh_invite_countdown(socket)
      _state -> socket
    end
  end

  defp poll_device_authorization(socket) do
    with %{account_id: account_id} <- socket.assigns.device_authorization,
         {:ok, completed} <- InviteOnboarding.poll_device(socket.assigns.invite_token, account_id) do
      socket
      |> put_flash(:info, "Codex account connected")
      |> transition_accepted(completed_response(completed, codex_base_url(socket)))
    else
      nil ->
        transition_device_error(socket, "Start device authorization again.")

      {:error, %{code: code} = reason}
      when code in [:codex_device_authorization_pending, :codex_device_authorization_slow_down] ->
        socket
        |> assign(:device_poll_status, pending_message(reason))
        |> schedule_device_poll(reason)

      {:error, %{code: :codex_device_code_expired} = reason} ->
        socket
        |> put_flash(:error, error_message(reason))
        |> transition_device_error(error_message(reason))

      {:error, reason} ->
        socket
        |> put_flash(:error, error_message(reason))
        |> transition_device_error(error_message(reason))
    end
  end

  defp schedule_device_poll(socket, reason \\ %{}) do
    case {socket.assigns.invite_state, socket.assigns.device_authorization} do
      {:device_pending, %{poll_interval_seconds: interval_seconds}} ->
        retry_seconds = Map.get(reason, :retry_after_seconds) || interval_seconds
        schedule_invite_workflow_tick(socket, retry_seconds)

      _state ->
        transition_device_error(socket, "Start device authorization again.")
    end
  end

  defp clear_invite_timer(socket) do
    if socket.assigns.invite_timer do
      Process.cancel_timer(socket.assigns.invite_timer)
    end

    assign(socket, invite_timer: nil, invite_timer_ref: nil)
  end

  defp schedule_invite_countdown(socket) do
    with true <- connected?(socket),
         state when state in [:ready, :device_error] <- socket.assigns.invite_state,
         %{expires_at: expires_at} <- socket.assigns.contract do
      case countdown_refresh_seconds(expires_at, socket.assigns.now) do
        0 ->
          transition_invite_expired(socket)

        refresh_seconds when is_integer(refresh_seconds) ->
          schedule_invite_workflow_tick(socket, refresh_seconds)

        _unavailable ->
          socket
      end
    else
      _state -> socket
    end
  end

  defp schedule_invite_workflow_tick(socket, delay_seconds) do
    ref = make_ref()
    socket = clear_invite_timer(socket)

    timer =
      Process.send_after(
        self(),
        {:invite_workflow_tick, ref},
        max(delay_seconds, 0) * 1_000
      )

    assign(socket, invite_timer: timer, invite_timer_ref: ref)
  end

  defp refresh_invite_countdown(socket) do
    case countdown_refresh_seconds(socket.assigns.contract.expires_at, socket.assigns.now) do
      0 -> transition_invite_expired(socket)
      _refresh_seconds -> schedule_invite_countdown(socket)
    end
  end

  defp countdown_refresh_seconds(expires_at, now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} -> countdown_refresh_seconds(expires_at, now)
      _error -> nil
    end
  end

  defp countdown_refresh_seconds(%DateTime{} = expires_at, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt do
      seconds = max(DateTime.diff(expires_at, now, :second), 1)

      cond do
        seconds < 60 -> seconds
        seconds < 3_600 -> seconds_until_label_change(seconds, 60)
        seconds < 86_400 -> seconds_until_label_change(seconds, 3_600)
        true -> seconds_until_label_change(seconds, 86_400)
      end
    else
      0
    end
  end

  defp countdown_refresh_seconds(_expires_at, _now), do: nil

  defp seconds_until_label_change(seconds, unit) when seconds == unit, do: 1

  defp seconds_until_label_change(seconds, unit) do
    case rem(seconds, unit) do
      0 -> unit
      remainder -> remainder
    end
  end

  defp transition_device_pending(socket, authorization, status) do
    socket
    |> clear_invite_timer()
    |> assign(
      invite_state: :device_pending,
      device_authorization: authorization,
      device_poll_status: status
    )
  end

  defp transition_device_error(socket, status) do
    socket
    |> clear_invite_timer()
    |> assign(
      invite_state: :device_error,
      device_authorization: nil,
      device_poll_status: status
    )
    |> schedule_invite_countdown()
  end

  defp transition_accepted(socket, completed_onboarding) do
    socket
    |> clear_invite_timer()
    |> assign(
      invite_state: :accepted,
      contract: nil,
      device_authorization: nil,
      device_poll_status: "Codex account connected.",
      completed_onboarding: completed_onboarding
    )
  end

  defp transition_invite_expired(socket) do
    socket
    |> clear_invite_timer()
    |> assign(
      invite_state: :expired,
      contract: nil,
      device_authorization: nil,
      completed_onboarding: nil,
      error_message: nil
    )
  end

  defp assign_invite(socket, token) do
    case Access.load_usable_invite_contract(token) do
      {:ok, %{invite: contract}} ->
        assign(socket, contract: contract, invite_state: :ready, error_message: nil)

      {:error, _reason} ->
        if expired_invite?(token) do
          assign(socket, contract: nil, invite_state: :expired, error_message: nil)
        else
          assign(socket,
            contract: nil,
            invite_state: :invalid,
            error_message: "This invite link cannot be used. Ask the operator for a fresh invite."
          )
        end
    end
  end

  defp expired_invite?(token) do
    case Access.get_invite_by_token(token) do
      %{status: "active", expires_at: %DateTime{} = expires_at} ->
        DateTime.compare(expires_at, DateTime.utc_now()) != :gt

      _invite ->
        false
    end
  end

  defp error_message(%{code: :codex_device_code_expired}),
    do: "The authorization window expired. Start device approval again."

  defp error_message(%{code: :invite_email_mismatch}),
    do: "The authorized Codex account email does not match this invite."

  defp error_message(_reason),
    do: "Onboarding could not continue. Try again or ask for a fresh invite."

  defp completed_response(completed, base_url) do
    completed.info.email
    |> completed_onboarding(base_url)
    |> Map.merge(%{
      upstream_identity_id: completed.identity.id,
      pool_upstream_assignment_id: completed.assignment.id
    })
  end

  defp completed_onboarding(account_email, base_url) do
    %{
      account_email: account_email,
      config_text: codex_config_toml(base_url)
    }
  end

  defp codex_config_toml(base_url) do
    """
    model = "gpt-5"
    model_provider = "codex-pooler"

    [model_providers.codex-pooler]
    name = "Codex Pooler"
    base_url = "#{base_url}"
    env_key = "CODEX_POOLER_API_KEY"
    wire_api = "responses"
    requires_openai_auth = true
    supports_websockets = false
    """
    |> String.trim_trailing()
  end

  defp codex_base_url(socket), do: public_origin(socket) <> "/backend-api/codex"

  defp refresh_completed_config(%{assigns: %{completed_onboarding: nil}} = socket), do: socket

  defp refresh_completed_config(socket) do
    update(socket, :completed_onboarding, fn completed_onboarding ->
      Map.put(completed_onboarding, :config_text, codex_config_toml(codex_base_url(socket)))
    end)
  end

  defp pending_message(reason) do
    retry_after = Map.get(reason, :retry_after_seconds, 5)
    "Approval is still pending. Checking again in #{retry_after} seconds."
  end

  defp public_origin(socket) do
    configured_public_origin() || endpoint_origin() || socket.assigns.current_origin ||
      local_origin(socket)
  end

  defp origin_from_uri(uri) when is_binary(uri) do
    uri = URI.parse(uri)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) <- uri.host do
      port = if uri.port in [nil, 80, 443], do: "", else: ":#{uri.port}"
      "#{scheme}://#{host}#{port}"
    else
      _value -> nil
    end
  end

  defp origin_from_uri(_uri), do: nil

  defp configured_public_origin do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:public_origin)
    |> normalize_origin()
  end

  defp endpoint_origin do
    CodexPoolerWeb.Endpoint.url()
    |> normalize_origin()
  rescue
    _error -> nil
  end

  defp local_origin(socket) do
    endpoint = socket.endpoint
    config = endpoint.config(:url)
    scheme = Keyword.get(config, :scheme, "http")
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port)

    if port in [nil, 80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp normalize_origin(origin) when is_binary(origin) do
    origin = String.trim(origin)

    if origin == "" do
      nil
    else
      String.trim_trailing(origin, "/")
    end
  end

  defp normalize_origin(_origin), do: nil
end
