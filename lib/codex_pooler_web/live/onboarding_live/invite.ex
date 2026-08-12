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
    />
    """
  end

  @impl true
  def mount(%{"invite_token" => token}, _session, socket) do
    {:ok,
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
       error_message: nil
     )
     |> assign_invite(token)}
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

  defp handle_invite_workflow_tick(%{assigns: %{invite_state: :device_pending}} = socket),
    do: poll_device_authorization(socket)

  defp handle_invite_workflow_tick(socket), do: socket

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
        ref = make_ref()
        socket = clear_invite_timer(socket)

        timer =
          Process.send_after(
            self(),
            {:invite_workflow_tick, ref},
            max(retry_seconds, 0) * 1_000
          )

        assign(socket, invite_timer: timer, invite_timer_ref: ref)

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
