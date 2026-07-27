defmodule CodexPooler.Jobs.SavedResetRedemptionWorker do
  @moduledoc """
  Redeems one saved Codex reset credit for an upstream assignment.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["saved_reset_redemption"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:pool_upstream_assignment_id],
      states: :incomplete,
      period: {10, :minutes}
    ]

  alias CodexPooler.Upstreams.SavedResetRedemption

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(45)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "pool_upstream_assignment_id" => assignment_id,
          "trigger_kind" => "scheduled_expiry_rescue",
          "upstream_identity_id" => expected_identity_id
        }
      })
      when is_binary(expected_identity_id) and expected_identity_id != "" do
    redeem_scheduled_expiry(assignment_id, expected_identity_id)
  end

  def perform(%Oban.Job{args: %{"trigger_kind" => "scheduled_expiry_rescue"}}),
    do: {:cancel, :scheduled_expiry_target_invalid}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pool_upstream_assignment_id" => assignment_id} = args}) do
    trigger_kind = Map.get(args, "trigger_kind", "admin_manual")

    case SavedResetRedemption.ensure_manual_available(assignment_id) do
      {:ok, _assignment, _identity} ->
        redeem(assignment_id, trigger_kind)

      {:error, :redemption_in_progress} ->
        {:snooze, 5}

      {:error, %{code: :saved_reset_unavailable}} ->
        {:cancel, :saved_reset_unavailable}

      {:error, %{code: code}}
      when code in [:pool_assignment_not_found, :upstream_identity_not_found] ->
        {:cancel, code}

      {:error, %{code: code}} ->
        {:error, code}
    end
  end

  defp redeem_scheduled_expiry(assignment_id, expected_identity_id) do
    assignment_id
    |> SavedResetRedemption.redeem_scheduled_expiry(expected_identity_id, [])
    |> map_scheduled_result()
  rescue
    _error in [
      DBConnection.ConnectionError,
      Ecto.InvalidChangesetError,
      Ecto.StaleEntryError,
      Postgrex.Error
    ] ->
      {:error, :saved_reset_persistence_failed}
  end

  defp map_scheduled_result({:ok, %{status: :succeeded}}), do: :ok

  defp map_scheduled_result({:ok, %{status: :noop, code: code}})
       when code in [
              "scheduled_expiry_identity_unavailable",
              "scheduled_expiry_assignment_unavailable",
              "scheduled_expiry_identity_mismatch"
            ],
       do: {:cancel, scheduled_target_error(code)}

  defp map_scheduled_result({:ok, %{status: :noop}}), do: :ok

  defp map_scheduled_result({:ok, %{status: :failed, code: "transport_error"}}),
    do: {:error, :saved_reset_redemption_request_failed}

  defp map_scheduled_result({:ok, %{status: :failed, code: "missing_access_token"}}),
    do: {:error, :saved_reset_access_token_unavailable}

  defp map_scheduled_result({:ok, %{status: :failed}}),
    do: {:error, "saved reset redemption failed"}

  defp map_scheduled_result({:error, :redemption_in_progress}), do: {:snooze, 5}

  defp map_scheduled_result({:error, %{code: code}})
       when code in [:pool_assignment_not_found, :upstream_identity_not_found],
       do: {:cancel, code}

  defp map_scheduled_result({:error, _reason}), do: {:error, :saved_reset_redemption_failed}

  defp scheduled_target_error("scheduled_expiry_identity_unavailable"),
    do: :scheduled_expiry_identity_unavailable

  defp scheduled_target_error("scheduled_expiry_assignment_unavailable"),
    do: :scheduled_expiry_assignment_unavailable

  defp scheduled_target_error("scheduled_expiry_identity_mismatch"),
    do: :scheduled_expiry_identity_mismatch

  defp redeem(assignment_id, trigger_kind) do
    case SavedResetRedemption.redeem(assignment_id, trigger_kind: trigger_kind) do
      {:ok, %{status: :succeeded}} ->
        :ok

      {:ok, %{status: :noop}} ->
        :discard

      {:ok, %{status: :failed, reason: reason}} ->
        {:error, reason}

      {:ok, %{status: :failed}} ->
        {:error, :saved_reset_redemption_failed}

      {:error, :redemption_in_progress} ->
        {:snooze, 5}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
