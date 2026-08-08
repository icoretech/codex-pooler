defmodule CodexPooler.Upstreams.SavedResets.Convergence do
  @moduledoc """
  Converges a pending saved-reset redemption toward a settled phase using only
  fresh provider evidence, under the identity's `FOR UPDATE` lock.

  Called after reconciliation persists quota windows. It never fabricates quota:
  it reads the identity's stored account windows and lets
  `PostResetEvidence.classify/3` decide, then applies the transition through the
  lifecycle compare-and-set guard so a stale generation or a concurrent replica
  cannot reopen a settled record.

    * fresh usable account evidence -> `confirmed_by_quota` (normal routing)
    * fresh exhausted account evidence -> `reblocked`
    * no qualifying fresh evidence, window elapsed -> `expired` (fail-closed)
    * otherwise -> left pending, untouched

  Phase-bearing pending records (`consumed_pending_probe`,
  `confirmed_by_upstream`) and exact applied `reblocked` records are eligible.
  Legacy, malformed, non-applied, and other settled records are ignored, so
  this is safe to call on every identity during reconciliation.
  """

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResets.ConfirmationMetadata
  alias CodexPooler.Upstreams.SavedResets.ConvergenceTelemetry
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  # `expired` is convergeable too: fresh provider evidence remains the only way
  # out of an elapsed confirmation window, otherwise a single expiry would
  # disable saved resets on the identity forever.
  @convergeable_phases [
    RedemptionLifecycle.consumed_pending_probe(),
    RedemptionLifecycle.confirmed_by_upstream(),
    RedemptionLifecycle.expired()
  ]

  @type outcome :: :confirmed_by_quota | :reblocked | :expired | :unchanged

  @doc """
  Cheap metadata-only pre-filter: whether the identity carries a lifecycle that
  `converge/2` could act on. Lets hot paths (per-request evidence observers)
  skip the locking transaction for the overwhelmingly common no-lifecycle case.
  """
  @spec convergeable_lifecycle?(UpstreamIdentity.t() | term()) :: boolean()
  def convergeable_lifecycle?(%UpstreamIdentity{metadata: metadata}) do
    metadata
    |> Kernel.||(%{})
    |> Map.get("saved_reset_redemption")
    |> convergeable_redemption?()
  end

  def convergeable_lifecycle?(_identity), do: false

  @spec converge(UpstreamIdentity.t() | Ecto.UUID.t()) :: {:ok, outcome()} | {:error, term()}
  @spec converge(UpstreamIdentity.t() | Ecto.UUID.t(), DateTime.t()) ::
          {:ok, outcome()} | {:error, term()}
  @spec converge(UpstreamIdentity.t() | Ecto.UUID.t(), DateTime.t(), String.t()) ::
          {:ok, outcome()} | {:error, term()}
  def converge(identity_or_id, now \\ now()) do
    converge(identity_or_id, now, "unknown")
  end

  def converge(identity_or_id, now, source) when is_binary(source) do
    emit_after_commit? = not Repo.in_transaction?()

    case identity_id(identity_or_id) do
      nil ->
        {:ok, :unchanged}

      id ->
        converge_transaction(id, now, source, emit_after_commit?)
    end
  end

  defp converge_transaction(id, now, source, emit_after_commit?) do
    case Repo.transaction(fn -> converge_locked(id, now, source) end) do
      {:ok, {outcome, redemption}} ->
        if emit_after_commit? and is_map(redemption),
          do: ConvergenceTelemetry.emit(redemption)

        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp converge_locked(id, now, source) do
    identity = lock_identity!(id)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    case target_transition(identity, redemption, now) do
      nil -> {:unchanged, nil}
      {target, windows} -> apply_transition!(identity, redemption, target, windows, now, source)
    end
  end

  defp target_transition(identity, redemption, now) do
    with true <- convergeable_redemption?(redemption),
         %DateTime{} = consumed_at <- consumed_at(redemption) do
      windows = Windows.list_evidence(identity)

      case windows
           |> PostResetEvidence.classify(consumed_at, now)
           |> phase_for_classification(redemption, now) do
        nil -> nil
        target -> {target, windows}
      end
    else
      _not_convergeable -> nil
    end
  end

  defp phase_for_classification(:confirmed, _redemption, _now),
    do: RedemptionLifecycle.confirmed_by_quota()

  defp phase_for_classification(:reblocked, _redemption, _now),
    do: RedemptionLifecycle.reblocked()

  defp phase_for_classification(:pending, redemption, now) do
    if RedemptionLifecycle.phase(redemption) == RedemptionLifecycle.reblocked(),
      do: nil,
      else: expired_phase(redemption, now)
  end

  defp expired_phase(redemption, now) do
    if RedemptionLifecycle.expired?(redemption, now),
      do: RedemptionLifecycle.expired(),
      else: nil
  end

  defp convergeable_redemption?(redemption) do
    RedemptionLifecycle.phase(redemption) in @convergeable_phases or
      RedemptionLifecycle.applied_reblocked?(redemption)
  end

  defp apply_transition!(identity, redemption, target, windows, now, source) do
    generation = Map.get(redemption, "generation")
    attempt_id = Map.get(redemption, "attempt_id")

    if RedemptionLifecycle.can_transition?(redemption, target, generation, attempt_id) do
      outcome = outcome_for(target)

      updated =
        redemption
        |> Map.merge(%{
          "phase" => target,
          "status" => RedemptionLifecycle.legacy_status_for(target),
          "finished_at" => DateTime.to_iso8601(now),
          "terminal_reason" => terminal_reason(target)
        })
        |> Map.merge(
          ConfirmationMetadata.build(source, outcome, windows, consumed_at(redemption), now)
        )

      _updated_identity =
        identity
        |> UpstreamIdentity.changeset(%{
          metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", updated),
          updated_at: now
        })
        |> Repo.update!()

      {outcome, updated}
    else
      {:unchanged, nil}
    end
  end

  defp outcome_for(target) do
    cond do
      target == RedemptionLifecycle.confirmed_by_quota() -> :confirmed_by_quota
      target == RedemptionLifecycle.reblocked() -> :reblocked
      target == RedemptionLifecycle.expired() -> :expired
      true -> :unchanged
    end
  end

  defp terminal_reason(target), do: "converged_" <> target

  defp consumed_at(%{"consumed_at" => consumed_at}) when is_binary(consumed_at) do
    case DateTime.from_iso8601(consumed_at) do
      {:ok, consumed, _offset} -> consumed
      _invalid -> nil
    end
  end

  defp consumed_at(_redemption), do: nil

  defp lock_identity!(id) do
    Repo.one!(
      from identity in UpstreamIdentity,
        where: identity.id == ^id,
        lock: "FOR UPDATE"
    )
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity_or_id), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
