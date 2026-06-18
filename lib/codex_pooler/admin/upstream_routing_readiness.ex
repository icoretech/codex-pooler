defmodule CodexPooler.Admin.UpstreamRoutingReadiness do
  @moduledoc """
  Lifecycle-aware admin projection for account-level model routing readiness.

  This keeps quota readiness as its own signal and adds the extra gates that
  runtime model routing applies: identity lifecycle visibility and at least one
  healthy, eligible pool assignment.
  """

  alias CodexPooler.Admin.UpstreamQuotaReadiness
  alias CodexPooler.Upstreams.Lifecycle.IdentityRouting
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_health_active PoolUpstreamAssignment.active_health_status()
  @assignment_eligible PoolUpstreamAssignment.eligible_status()
  @blocked_lifecycle_projections %{
    "refresh_failed" => {
      "identity_refresh_failed",
      "Auth refresh failed",
      "Token refresh failed; this account is excluded from model routing until auth is recovered.",
      "Relink credentials or complete a successful token refresh.",
      :error
    },
    "reauth_required" => {
      "identity_reauth_required",
      "Reauthentication required",
      "Reauthentication is required before this account can be selected for model routing.",
      "Reauthenticate or replace the stored credentials.",
      :error
    },
    "refresh_due" => {
      "identity_refresh_due",
      "Token refresh due",
      "Token refresh is due before this account can be selected for model routing.",
      "Refresh the account token.",
      :warning
    },
    "deleted" => {
      "identity_deleted",
      "Account deleted",
      "Deleted upstream accounts are excluded from model routing.",
      nil,
      :error
    },
    "disabled" => {
      "identity_disabled",
      "Account disabled",
      "Disabled upstream accounts are excluded from model routing.",
      "Enable the upstream account before routing.",
      :error
    },
    "errored" => {
      "identity_errored",
      "Account errored",
      "The upstream account lifecycle is errored and excluded from model routing.",
      "Inspect the sanitized account error and recover the upstream account.",
      :error
    },
    "paused" => {
      "identity_paused",
      "Account paused",
      "Paused upstream accounts are excluded from model routing.",
      "Resume the upstream account before routing.",
      :warning
    },
    "pending" => {
      "identity_pending",
      "Account pending",
      "Pending upstream accounts are excluded from model routing until setup completes.",
      "Complete account setup and reconciliation.",
      :warning
    }
  }

  @type tone :: :success | :warning | :error
  @type identity_input :: UpstreamIdentity.t() | UpstreamIdentity.status() | map() | nil
  @type assignment_input ::
          PoolUpstreamAssignment.t() | map() | [PoolUpstreamAssignment.t() | map()] | nil
  @type t :: %{
          required(:routing_ready_now?) => boolean(),
          required(:state) => String.t(),
          required(:label) => String.t(),
          required(:tone) => tone(),
          required(:border_class) => String.t(),
          required(:reason) => String.t(),
          required(:reason_code) => String.t(),
          required(:recovery_action) => String.t() | nil,
          required(:identity_status) => UpstreamIdentity.status() | nil,
          required(:assignment_ready?) => boolean(),
          required(:quota_readiness) => UpstreamQuotaReadiness.t()
        }
  @type projection_base :: %{
          required(:routing_ready_now?) => boolean(),
          required(:state) => String.t(),
          required(:label) => String.t(),
          required(:tone) => tone(),
          required(:border_class) => String.t(),
          required(:reason) => String.t(),
          required(:reason_code) => String.t(),
          required(:recovery_action) => String.t() | nil
        }

  @spec from_inputs(identity_input(), assignment_input(), UpstreamQuotaReadiness.t()) :: t()
  def from_inputs(identity_or_status, assignments, quota_readiness)
      when is_map(quota_readiness) do
    identity_status = identity_status(identity_or_status)
    assignment_ready? = assignment_ready?(assignments)

    identity_status
    |> base_projection(assignment_ready?, quota_readiness)
    |> Map.merge(%{
      identity_status: identity_status,
      assignment_ready?: assignment_ready?,
      quota_readiness: quota_readiness
    })
  end

  @spec base_projection(UpstreamIdentity.status() | nil, boolean(), UpstreamQuotaReadiness.t()) ::
          projection_base()
  defp base_projection(identity_status, _assignment_ready?, _quota_readiness)
       when not is_binary(identity_status) do
    lifecycle_projection(
      "identity_unavailable",
      "Identity unavailable",
      "Identity lifecycle status is unavailable, so model routing cannot select this account.",
      "Verify the upstream account lifecycle state.",
      :warning
    )
  end

  defp base_projection(identity_status, assignment_ready?, quota_readiness) do
    cond do
      not IdentityRouting.model_routable?(identity_status) ->
        blocked_lifecycle_projection(identity_status)

      not assignment_ready? ->
        assignment_unavailable_projection()

      not Map.get(quota_readiness, :routing_ready_now?, false) ->
        quota_blocked_projection(quota_readiness)

      identity_status == UpstreamIdentity.refreshing_status() ->
        projection(%{
          routing_ready_now?: true,
          state: "ready_refreshing",
          label: "Routing while refreshing",
          tone: :warning,
          reason:
            "Identity refresh is in progress, but this lifecycle state remains visible for model routing.",
          reason_code: "identity_refreshing_model_routable",
          recovery_action: nil
        })

      true ->
        projection(%{
          routing_ready_now?: true,
          state: "ready",
          label: "Routing ready",
          tone: :success,
          reason:
            "Identity lifecycle, assignment availability, and quota readiness allow model routing.",
          reason_code: "routing_ready",
          recovery_action: nil
        })
    end
  end

  @spec blocked_lifecycle_projection(UpstreamIdentity.status()) :: projection_base()
  defp blocked_lifecycle_projection(status) do
    {reason_code, label, reason, recovery_action, tone} =
      Map.get(
        @blocked_lifecycle_projections,
        status,
        {
          "identity_#{status}",
          "Lifecycle blocked",
          "This upstream account lifecycle state is excluded from model routing.",
          "Recover the upstream account lifecycle before routing.",
          :warning
        }
      )

    lifecycle_projection(reason_code, label, reason, recovery_action, tone)
  end

  @spec lifecycle_projection(String.t(), String.t(), String.t(), String.t() | nil, tone()) ::
          projection_base()
  defp lifecycle_projection(reason_code, label, reason, recovery_action, tone) do
    projection(%{
      routing_ready_now?: false,
      state: "identity_blocked",
      label: label,
      tone: tone,
      reason: reason,
      reason_code: reason_code,
      recovery_action: recovery_action
    })
  end

  @spec assignment_unavailable_projection() :: projection_base()
  defp assignment_unavailable_projection do
    projection(%{
      routing_ready_now?: false,
      state: "assignment_unavailable",
      label: "Assignment unavailable",
      tone: :warning,
      reason:
        "No active, healthy, eligible pool assignment is available for this upstream account.",
      reason_code: "assignment_unavailable",
      recovery_action: "Enable a healthy, eligible pool assignment."
    })
  end

  @spec quota_blocked_projection(UpstreamQuotaReadiness.t()) :: projection_base()
  defp quota_blocked_projection(quota_readiness) do
    quota_state = Map.get(quota_readiness, :state, "blocked")
    label = Map.get(quota_readiness, :label, "Quota blocked")

    projection(%{
      routing_ready_now?: false,
      state: "quota_blocked",
      label: label,
      tone: Map.get(quota_readiness, :tone, :warning),
      reason: "Quota readiness blocks model routing: #{label}.",
      reason_code: "quota_#{quota_state}",
      recovery_action: "Refresh quota evidence or wait for quota reset."
    })
  end

  @spec projection(map()) :: projection_base()
  defp projection(attrs),
    do: Map.put(attrs, :border_class, border_class(Map.fetch!(attrs, :tone)))

  @spec border_class(tone()) :: String.t()
  defp border_class(:success), do: "border-l-success"
  defp border_class(:error), do: "border-l-error"
  defp border_class(_tone), do: "border-l-warning"

  @spec identity_status(identity_input()) :: UpstreamIdentity.status() | nil
  defp identity_status(%UpstreamIdentity{status: status}), do: status
  defp identity_status(%{status: status}), do: status
  defp identity_status(%{"status" => status}), do: status
  defp identity_status(status) when is_binary(status), do: status
  defp identity_status(_identity_or_status), do: nil

  @spec assignment_ready?(assignment_input()) :: boolean()
  defp assignment_ready?(assignments) when is_list(assignments) do
    Enum.any?(assignments, &assignment_ready?/1)
  end

  defp assignment_ready?(%PoolUpstreamAssignment{} = assignment) do
    assignment.status == @assignment_active and
      assignment.health_status == @assignment_health_active and
      assignment.eligibility_status == @assignment_eligible
  end

  defp assignment_ready?(%{} = assignment) do
    assignment_status(assignment, :status) == @assignment_active and
      assignment_status(assignment, :health_status) == @assignment_health_active and
      assignment_status(assignment, :eligibility_status) == @assignment_eligible
  end

  defp assignment_ready?(_assignment), do: false

  @spec assignment_status(map(), atom()) :: String.t() | nil
  defp assignment_status(assignment, field) do
    Map.get(assignment, field) || Map.get(assignment, Atom.to_string(field))
  end
end
