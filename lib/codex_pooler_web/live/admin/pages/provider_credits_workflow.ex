defmodule CodexPoolerWeb.Admin.ProviderCreditsWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.AccountLifecycle
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPoolerWeb.Admin.ProviderCreditsPolicyForm

  @type socket :: Phoenix.LiveView.Socket.t()
  @type account :: %{required(:identity) => %{required(:id) => Ecto.UUID.t(), optional(atom()) => term()}, required(:provider_credits_policy) => ProviderCreditsPolicyForm.policy(), optional(atom()) => term()}

  @spec initial_assigns() :: map()
  def initial_assigns, do: %{editing_provider_credits_policy: nil, provider_credits_policy_form: nil}

  @spec authorized?(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t()) :: boolean()
  def authorized?(scope, identity_id), do: match?({:ok, _identity}, AccountLifecycle.authorize(scope, identity_id))

  @spec open(socket(), account() | nil) :: socket()
  def open(socket, %{identity: %{id: identity_id}} = account) do
    with true <- authorized?(socket.assigns.current_scope, identity_id),
         %RoutingQuotaSnapshot{} = snapshot <- RoutingQuotaSnapshot.load_by_identity_ids([identity_id], DateTime.utc_now()) |> Map.get(identity_id) do
      policy = %{allow_provider_credits: snapshot.allow_provider_credits}

      assign(socket,
        editing_provider_credits_policy: Map.put(account, :provider_credits_policy, policy),
        provider_credits_policy_form: ProviderCreditsPolicyForm.form(policy)
      )
    else
      _unavailable -> socket |> close() |> put_flash(:error, gettext("You must have access to every Pool using this upstream to change provider credits"))
    end
  end

  def open(socket, _account), do: socket |> close() |> put_flash(:error, gettext("Upstream account was not found"))

  @spec close(socket()) :: socket()
  def close(socket), do: assign(socket, initial_assigns())

  @spec validate(socket(), term()) :: socket()
  def validate(%{assigns: %{editing_provider_credits_policy: %{provider_credits_policy: policy}}} = socket, params) do
    assign(socket, provider_credits_policy_form: ProviderCreditsPolicyForm.form(policy, params, :validate))
  end

  def validate(socket, _params), do: put_flash(socket, :error, gettext("Open an authorized provider credits policy before saving"))

  @spec save(socket(), term(), (socket() -> socket())) :: socket()
  def save(%{assigns: %{editing_provider_credits_policy: %{identity: %{id: identity_id}}}} = socket, params, reload) do
    with {:ok, attrs} <- ProviderCreditsPolicyForm.parse(params),
         {:ok, _result} <- Upstreams.update_provider_credits_policy_for_scope(socket.assigns.current_scope, identity_id, attrs) do
      socket |> close() |> reload.() |> put_flash(:info, gettext("Provider credits policy updated"))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, provider_credits_policy_form: ProviderCreditsPolicyForm.form_for_changeset(changeset))

      {:error, _reason} ->
        socket |> close() |> reload.() |> put_flash(:error, gettext("Provider credits policy could not be changed; access to every Pool is required"))
    end
  end

  def save(socket, _params, _reload), do: put_flash(socket, :error, gettext("Open an authorized provider credits policy before saving"))

  @spec refresh(socket(), [account()]) :: socket()
  def refresh(%{assigns: %{editing_provider_credits_policy: %{identity: %{id: identity_id}} = previous}} = socket, accounts) do
    case Enum.find(accounts, &(&1.identity.id == identity_id)) do
      %{can_manage_provider_credits?: true} = account ->
        form =
          if account.provider_credits_policy == previous.provider_credits_policy do
            socket.assigns.provider_credits_policy_form
          else
            ProviderCreditsPolicyForm.form(account.provider_credits_policy)
          end

        assign(socket, editing_provider_credits_policy: account, provider_credits_policy_form: form)

      _lost ->
        close(socket)
    end
  end

  def refresh(socket, _accounts), do: socket
end
