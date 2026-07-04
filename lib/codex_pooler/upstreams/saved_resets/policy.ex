defmodule CodexPooler.Upstreams.SavedResetPolicy do
  @moduledoc """
  Scoped operator policy updates for Codex saved reset redemption.
  """

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.{AccountAudit, AccountLifecycle}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec update_for_scope(Scope.t(), UpstreamIdentity.t() | Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  def update_for_scope(%Scope{} = scope, identity_or_id, attrs) when is_map(attrs) do
    with {:ok, identity} <- AccountLifecycle.authorize(scope, identity_or_id) do
      identity
      |> update_policy(attrs)
      |> AccountAudit.record_change(scope, "upstream_account.saved_reset_policy_update",
        trigger_kind: trigger_kind(attrs)
      )
    end
  end

  def update_for_scope(_scope, _identity_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  defp update_policy(%UpstreamIdentity{} = identity, attrs) do
    attrs = normalize_attrs(identity, attrs)

    result =
      identity
      |> UpstreamIdentity.changeset(Map.put(attrs, :updated_at, now()))
      |> Repo.update()
      |> case do
        {:ok, updated_identity} -> {:ok, result(updated_identity, :saved_reset_policy_updated)}
        {:error, changeset} -> {:error, changeset}
      end

    tap_broadcasts(result, "upstream_account_saved_reset_policy_updated")
  end

  defp result(%UpstreamIdentity{} = identity, status) do
    identity = Repo.reload!(identity)

    %{
      status: status,
      identity: identity,
      assignments: PoolAssignments.list_pool_assignments_for_identity(identity.id),
      secret_status: Secrets.secret_status(identity)
    }
  end

  defp normalize_attrs(%UpstreamIdentity{} = identity, attrs) do
    %{
      saved_reset_auto_redeem_enabled:
        truthy?(fetch_any(attrs, [:auto_redeem_enabled, :saved_reset_auto_redeem_enabled])),
      saved_reset_auto_redeem_min_blocked_minutes:
        non_negative_integer(
          fetch_any(attrs, [:min_blocked_minutes, :saved_reset_auto_redeem_min_blocked_minutes]),
          60
        ),
      saved_reset_auto_redeem_keep_credits:
        non_negative_integer(
          fetch_any(attrs, [:keep_credits, :saved_reset_auto_redeem_keep_credits]),
          0
        ),
      saved_reset_auto_redeem_trigger_mode:
        trigger_mode(
          fetch_any(attrs, [:trigger_mode, :saved_reset_auto_redeem_trigger_mode]),
          identity.saved_reset_auto_redeem_trigger_mode
        ),
      saved_reset_auto_redeem_quota_threshold_percent:
        bounded_integer(
          fetch_any(attrs, [
            :quota_threshold_percent,
            :saved_reset_auto_redeem_quota_threshold_percent
          ]),
          identity.saved_reset_auto_redeem_quota_threshold_percent || 95,
          1,
          100
        )
    }
  end

  defp fetch_any(attrs, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:found, value}
        :error -> fetch_string_key(attrs, key)
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp fetch_string_key(attrs, key) do
    case Map.fetch(attrs, Atom.to_string(key)) do
      {:ok, value} -> {:found, value}
      :error -> nil
    end
  end

  defp truthy?(value) when value in [true, "true", "1", "on", 1], do: true
  defp truthy?(_value), do: false

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp bounded_integer(value, _default, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: value

  defp bounded_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= min and integer <= max -> integer
      _invalid -> default
    end
  end

  defp bounded_integer(_value, default, _min, _max), do: default

  defp trigger_mode("threshold", _default), do: "threshold"
  defp trigger_mode("blocked", _default), do: "blocked"
  defp trigger_mode(_value, "threshold"), do: "threshold"
  defp trigger_mode(_value, _default), do: "blocked"

  defp trigger_kind(attrs) do
    case fetch_any(attrs, [:trigger_kind]) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp tap_broadcasts({:ok, %{assignments: assignments, identity: identity}} = result, reason) do
    Enum.each(assignments, fn assignment ->
      Events.broadcast_upstreams(assignment.pool_id, reason, %{
        assignment_id: assignment.id,
        upstream_identity_id: identity.id
      })
    end)

    result
  end

  defp tap_broadcasts(result, _reason), do: result

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
