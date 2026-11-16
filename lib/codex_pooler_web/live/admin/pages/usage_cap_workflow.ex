defmodule CodexPoolerWeb.Admin.UsageCapWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.AccountLifecycle
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPoolerWeb.Admin.UsageCapPolicyForm

  @type socket :: Phoenix.LiveView.Socket.t()
  @type account :: %{required(:identity) => %{required(:id) => Ecto.UUID.t(), optional(atom()) => term()}, optional(atom()) => term()}

  @spec initial_assigns() :: map()
  def initial_assigns, do: %{editing_usage_cap_policy: nil, usage_cap_policy_form: nil}

  @spec authorized?(CodexPooler.Accounts.Scope.t(), Ecto.UUID.t()) :: boolean()
  def authorized?(scope, identity_id), do: match?({:ok, _identity}, AccountLifecycle.authorize(scope, identity_id))

  # The cap shares the provider-credits rule (access to every Pool using the account), so the account's `can_manage_provider_credits?` flag gates it.
  @spec open(socket(), account() | nil) :: socket()
  def open(socket, %{identity: %{id: identity_id}} = account) do
    with true <- authorized?(socket.assigns.current_scope, identity_id),
         %RoutingQuotaSnapshot{} = snapshot <- RoutingQuotaSnapshot.load_by_identity_ids([identity_id], DateTime.utc_now()) |> Map.get(identity_id) do
      policy = %{usage_cap_percent: snapshot.usage_cap_percent}

      assign(socket,
        editing_usage_cap_policy: Map.put(account, :usage_cap_policy, policy),
        usage_cap_policy_form: UsageCapPolicyForm.form(policy)
      )
    else
      _unavailable -> socket |> close() |> put_flash(:error, gettext("You must have access to every Pool using this upstream to change the usage cap"))
    end
  end

  def open(socket, _account), do: socket |> close() |> put_flash(:error, gettext("Upstream account was not found"))

  @spec close(socket()) :: socket()
  def close(socket), do: assign(socket, initial_assigns())

  @spec validate(socket(), term()) :: socket()
  def validate(%{assigns: %{editing_usage_cap_policy: %{usage_cap_policy: policy}}} = socket, params) do
    assign(socket, usage_cap_policy_form: UsageCapPolicyForm.form(policy, params, :validate))
  end

  def validate(socket, _params), do: put_flash(socket, :error, gettext("Open an authorized usage cap before saving"))

  @spec save(socket(), term(), (socket() -> socket())) :: socket()
  def save(%{assigns: %{editing_usage_cap_policy: %{identity: %{id: identity_id}}}} = socket, params, reload) do
    with {:ok, attrs} <- UsageCapPolicyForm.parse(params),
         {:ok, _result} <- Upstreams.update_usage_cap_policy_for_scope(socket.assigns.current_scope, identity_id, attrs) do
      socket |> close() |> reload.() |> put_flash(:info, gettext("Usage cap updated"))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, usage_cap_policy_form: UsageCapPolicyForm.form_for_changeset(changeset))

      {:error, _reason} ->
        socket |> close() |> reload.() |> put_flash(:error, gettext("Usage cap could not be changed; access to every Pool is required"))
    end
  end

  def save(socket, _params, _reload), do: put_flash(socket, :error, gettext("Open an authorized usage cap before saving"))

  @spec refresh(socket(), [account()]) :: socket()
  def refresh(%{assigns: %{editing_usage_cap_policy: %{identity: %{id: identity_id}} = previous}} = socket, accounts) do
    case Enum.find(accounts, &(&1.identity.id == identity_id)) do
      %{can_manage_provider_credits?: true} = account ->
        policy = %{usage_cap_percent: account.usage_cap_percent}

        form =
          if policy == previous.usage_cap_policy do
            socket.assigns.usage_cap_policy_form
          else
            UsageCapPolicyForm.form(policy)
          end

        assign(socket, editing_usage_cap_policy: Map.put(account, :usage_cap_policy, policy), usage_cap_policy_form: form)

      _lost ->
        close(socket)
    end
  end

  def refresh(socket, _accounts), do: socket
end
