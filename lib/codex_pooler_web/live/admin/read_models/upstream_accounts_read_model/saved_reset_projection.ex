defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection do
  @moduledoc false

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting
  alias CodexPoolerWeb.DateTimeDisplay

  @usable_refresh_statuses ~w(succeeded imported refreshing)

  @type action :: %{
          required(:available?) => boolean(),
          required(:reason) => String.t() | nil
        }
  @type available_expiration :: %{
          required(:expires_at) => String.t(),
          required(:first_seen_at) => String.t() | nil
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
          required(:last_redemption) => map() | nil
        }

  @spec snapshot(UpstreamIdentity.t() | map() | nil, DateTimeDisplay.preferences()) :: snapshot()
  def snapshot(identity, datetime_preferences) do
    snapshot = SavedResets.snapshot(identity)

    Map.merge(snapshot, %{
      next_expires_label: next_expires_label(snapshot, datetime_preferences),
      next_expires_title: next_expires_title(snapshot, datetime_preferences)
    })
  end

  @spec policy(map()) :: SavedResets.auto_policy_projection()
  def policy(identity), do: SavedResets.auto_policy(identity)

  @spec redemption_action(map()) :: action()
  def redemption_action(account) do
    cond do
      account.identity.status == "deleted" ->
        action(false, "deleted accounts cannot redeem saved resets")

      account.identity.status == "disabled" ->
        action(false, "disabled accounts cannot redeem saved resets")

      not auth_clearly_usable?(account) ->
        action(false, "saved reset redemption requires usable credentials")

      account.assignments == [] ->
        action(false, "saved reset redemption requires a Pool assignment")

      account.saved_resets.reported? == false ->
        action(false, "saved reset count is not reported")

      account.saved_resets.available? == false ->
        action(false, "no saved resets are available")

      account.saved_resets.in_progress? == true ->
        action(false, "saved reset redemption is already in progress")

      true ->
        action(true, nil)
    end
  end

  defp next_expires_label(%{next_expires_at: expires_at}, datetime_preferences) do
    case Formatting.parse_datetime(expires_at) do
      %DateTime{} = datetime ->
        "Next expires " <> DateTimeDisplay.format_datetime(datetime, datetime_preferences)

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
         access_token_label: access_token_label
       }) do
    refresh_status in @usable_refresh_statuses and
      not expired_access_token_label?(access_token_label)
  end

  defp auth_clearly_usable?(_account), do: false

  defp expired_access_token_label?(label) when is_binary(label),
    do: String.starts_with?(label, "access token expired")
end
