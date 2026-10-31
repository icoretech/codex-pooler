defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting
  alias CodexPoolerWeb.DateTimeDisplay

  @type action :: %{
          required(:available?) => boolean(),
          required(:reason) => String.t() | nil
        }
  @type available_expiration :: %{
          required(:expires_at) => String.t(),
          required(:first_seen_at) => String.t() | nil,
          required(:granted_at) => String.t() | nil
        }
  @type snapshot :: %{
          required(:status) => String.t(),
          required(:available_count) => non_neg_integer() | nil,
          required(:reported?) => boolean(),
          required(:available?) => boolean(),
          required(:label) => String.t(),
          required(:source) => String.t() | nil,
          required(:path_style) => String.t() | nil,
          required(:usage_path) => String.t() | nil,
          required(:observed_at) => String.t() | nil,
          required(:available_expires_at) => [String.t()],
          required(:available_expirations) => [available_expiration()],
          required(:next_expires_at) => String.t() | nil,
          required(:next_expires_label) => String.t() | nil,
          required(:next_expires_title) => String.t() | nil,
          required(:expires_observed_at) => String.t() | nil,
          required(:expires_refresh_attempted_at) => String.t() | nil,
          required(:expires_reported?) => boolean(),
          required(:in_progress?) => boolean(),
          required(:redemption_stale?) => boolean(),
          required(:last_auto_redemption_cause) => auto_redemption_cause() | nil,
          required(:reset_lifecycle) => reset_lifecycle() | nil
        }
  @type auto_redemption_cause :: %{required(:label) => String.t()}
  # Only the recognized phase: `redemption_action/1` names the claim's blocker from it. The receipt
  # (`SavedResetOperationProjection`) owns every operator-facing lifecycle fact.
  @type reset_lifecycle :: %{required(:phase) => String.t()}

  @spec snapshot(UpstreamIdentity.t() | map() | nil, DateTimeDisplay.preferences()) :: snapshot()
  def snapshot(identity, datetime_preferences) do
    snapshot =
      identity
      |> SavedResets.snapshot()
      |> Map.update!(:available_expirations, &sanitize_available_expirations/1)

    snapshot
    |> Map.drop([:last_redemption])
    |> Map.merge(%{
      label: snapshot_label(snapshot),
      next_expires_label: next_expires_label(snapshot, datetime_preferences),
      next_expires_title: next_expires_title(snapshot, datetime_preferences),
      last_auto_redemption_cause: last_auto_redemption_cause(snapshot.last_redemption),
      reset_lifecycle: reset_lifecycle(snapshot.last_redemption)
    })
  end

  defp last_auto_redemption_cause(%{
         "trigger_kind" => "gateway_auto",
         "trigger_detail" => "exhausted"
       }),
       do: %{label: gettext("Request · long-window quota exhausted")}

  defp last_auto_redemption_cause(%{
         "trigger_kind" => "gateway_auto",
         "trigger_detail" => "threshold"
       }),
       do: %{label: gettext("Request · quota threshold")}

  defp last_auto_redemption_cause(%{
         "trigger_kind" => "scheduled_expiry_rescue",
         "trigger_detail" => "exhausted"
       }),
       do: %{label: gettext("Scheduled · long-window quota exhausted")}

  defp last_auto_redemption_cause(%{
         "trigger_kind" => "scheduled_expiry_rescue",
         "trigger_detail" => "threshold"
       }),
       do: %{label: gettext("Scheduled · quota threshold")}

  defp last_auto_redemption_cause(%{
         "trigger_kind" => "scheduled_expiry_rescue",
         "trigger_detail" => "last_call"
       }),
       do: %{label: gettext("Scheduled · last call")}

  defp last_auto_redemption_cause(_redemption), do: nil

  defp reset_lifecycle(redemption) do
    case RedemptionLifecycle.phase(redemption) do
      phase when is_binary(phase) -> %{phase: phase}
      _legacy_or_unknown -> nil
    end
  end

  defp sanitize_available_expirations(rows) when is_list(rows) do
    Enum.map(rows, fn %{expires_at: expires_at, first_seen_at: first_seen_at} = row ->
      %{
        expires_at: expires_at,
        first_seen_at: first_seen_at,
        granted_at: sanitize_granted_at(Map.get(row, :granted_at))
      }
    end)
  end

  defp sanitize_available_expirations(_rows), do: []

  defp sanitize_granted_at(value) do
    case Formatting.parse_datetime(value) do
      %DateTime{} = granted_at -> DateTime.to_iso8601(granted_at)
      nil -> nil
    end
  end

  @spec policy(map()) :: SavedResets.auto_policy_projection()
  def policy(identity), do: SavedResets.auto_policy(identity)

  @doc """
  Whether a manual redemption can be offered: the account and bank checks, then the recorded status
  (`status_hold/1`), each with the reason the controls show.
  """
  @spec redemption_action(map()) :: action()
  def redemption_action(account) do
    existing_action = domain_redemption_action(account)

    case existing_action.available? && status_hold(Map.get(account, :saved_reset_operation)) do
      reason when is_binary(reason) -> action(false, reason)
      _available_or_refused -> existing_action
    end
  end

  @doc """
  Why the recorded saved-reset status holds back another manual redemption, or `nil`: an accepted
  request, a request status that could not be read, a reset still in progress, or an outcome that is
  not established yet. The operator reviews that status instead of submitting again.
  """
  @spec status_hold(map() | nil) :: String.t() | nil
  def status_hold(%{request: %{state: state}}) when state in [:queued, :processing], do: gettext("saved reset request is already accepted")
  def status_hold(%{request: %{state: :unavailable}}), do: gettext("saved reset request status is unavailable")
  def status_hold(%{active?: true}), do: gettext("the last saved reset is still in progress")
  def status_hold(%{unresolved?: true}), do: gettext("the last saved reset is unresolved; another redemption waits until it resolves")
  def status_hold(_operation), do: nil

  defp domain_redemption_action(account) do
    cond do
      account.identity.status == "deleted" ->
        action(false, gettext("deleted accounts cannot redeem saved resets"))

      account.identity.status == "disabled" ->
        action(false, gettext("disabled accounts cannot redeem saved resets"))

      not auth_clearly_usable?(account) ->
        action(false, gettext("saved reset redemption requires usable credentials"))

      account.assignments == [] ->
        action(false, gettext("saved reset redemption requires a Pool assignment"))

      true ->
        bank_redemption_action(account.saved_resets)
    end
  end

  defp bank_redemption_action(saved_resets) do
    cond do
      saved_resets.reported? == false ->
        action(false, gettext("saved reset count is not reported"))

      saved_resets.available? == false ->
        action(false, gettext("no saved resets are available"))

      saved_resets.in_progress? == true ->
        action(false, gettext("saved reset redemption is already in progress"))

      Map.get(saved_resets, :redemption_blocked?) == true ->
        action(false, blocked_redemption_reason(get_in(saved_resets, [:reset_lifecycle, :phase])))

      true ->
        action(true, nil)
    end
  end

  # The claim refuses these records too, so offering the action would only
  # queue a request that stops before reaching the provider.
  defp blocked_redemption_reason("reblocked"),
    do: gettext("the last saved reset was applied and quota is still blocked; another redemption waits until a usage report shows quota recovered")

  defp blocked_redemption_reason("expired"),
    do: gettext("the last saved reset was not confirmed in time; another redemption waits until a usage report shows quota recovered")

  defp blocked_redemption_reason(_phase), do: gettext("the last saved reset is unresolved; another redemption waits until it resolves")

  defp next_expires_label(%{next_expires_at: expires_at}, datetime_preferences) do
    case Formatting.parse_datetime(expires_at) do
      %DateTime{} = datetime ->
        gettext("Next expires %{timestamp}", timestamp: DateTimeDisplay.format_datetime(datetime, datetime_preferences))

      nil ->
        nil
    end
  end

  defp next_expires_title(%{next_expires_at: expires_at}, datetime_preferences) do
    case Formatting.parse_datetime(expires_at) do
      %DateTime{} = datetime -> DateTimeDisplay.format_datetime(datetime, datetime_preferences)
      nil -> nil
    end
  end

  defp action(true, _reason), do: %{available?: true, reason: nil}
  defp action(false, reason), do: %{available?: false, reason: reason}

  defp auth_clearly_usable?(%{
         reauth_required?: false,
         refresh_status: refresh_status,
         secret_status: :present
       }) do
    refresh_status in ~w(succeeded imported refreshing)
  end

  defp auth_clearly_usable?(_account), do: false

  defp snapshot_label(%{reported?: true, available_count: count}) when is_integer(count) and count > 0,
    do: ngettext("%{count} saved reset", "%{count} saved resets", count)

  defp snapshot_label(%{reported?: true}), do: gettext("No saved resets")
  defp snapshot_label(%{status: "unavailable"}), do: gettext("Saved resets unavailable")
  defp snapshot_label(_snapshot), do: gettext("Saved resets not reported")
end
