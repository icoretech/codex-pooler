defmodule CodexPooler.Upstreams.SavedResets.ProbeLease do
  @moduledoc """
  The one-shot, cross-node probe claim for a pending saved-reset redemption.

  After a credit is consumed but the account quota window is omitted by the
  provider, exactly one request is allowed to route to that identity as a guarded
  probe. This module makes that claim under the identity's `FOR UPDATE` lock so
  that competing replicas cannot both probe: the first correlation token to claim
  wins, everyone else is rejected before dispatch.

  The claim is irreversible. If the claiming request fails (network, 5xx,
  cancellation), the probe is NOT handed to another request — recovery then comes
  only from fresh provider evidence (see `Convergence`) or the bounded-window
  expiry. This guarantees a consumed credit can never trigger a second
  consumption or a second account's probe.
  """

  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type claim_result :: {:ok, :claimed} | {:error, :unavailable | :not_found}

  @doc """
  Attempts to claim the probe for `token` on the identity's pending redemption,
  matching the expected `generation` and `attempt_id` (compare-and-set).

  Returns `{:ok, :claimed}` for the winning token (idempotent for the same token)
  and `{:error, :unavailable}` when the probe is already claimed by another
  token, the redemption is not pending, or the window has elapsed.
  """
  @spec claim(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          integer(),
          term(),
          ResetProbe.t() | String.t()
        ) :: claim_result()
  @spec claim(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          integer(),
          term(),
          ResetProbe.t() | String.t(),
          DateTime.t()
        ) :: claim_result()
  def claim(identity_or_id, generation, attempt_id, probe, now \\ now())
      when is_binary(probe) or is_struct(probe, ResetProbe) do
    case identity_id(identity_or_id) do
      nil ->
        {:error, :not_found}

      id ->
        Repo.transaction(fn -> claim_locked(id, generation, attempt_id, probe, now) end)
        |> case do
          {:ok, :claimed} -> {:ok, :claimed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Confirms a successful probe: transitions `consumed_pending_probe ->
  confirmed_by_upstream` when `token` still holds the claim, so the identity
  becomes temporarily routeable for subsequent requests within the window. A
  no-op if the probe was superseded (already confirmed by quota, reblocked, or
  expired) or the token no longer holds the claim.
  """
  @spec confirm_upstream(UpstreamIdentity.t() | Ecto.UUID.t(), String.t()) ::
          {:ok, :confirmed | :unchanged} | {:error, :not_found}
  @spec confirm_upstream(UpstreamIdentity.t() | Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {:ok, :confirmed | :unchanged} | {:error, :not_found}
  def confirm_upstream(identity_or_id, token, now \\ now()) when is_binary(token) do
    case identity_id(identity_or_id) do
      nil ->
        {:error, :not_found}

      id ->
        Repo.transaction(fn -> confirm_locked(id, token, now) end)
        |> case do
          {:ok, outcome} -> {:ok, outcome}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec confirm_upstream(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          integer(),
          term(),
          ResetProbe.t()
        ) :: {:ok, :confirmed | :unchanged} | {:error, :not_found}
  @spec confirm_upstream(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          integer(),
          term(),
          ResetProbe.t(),
          DateTime.t()
        ) :: {:ok, :confirmed | :unchanged} | {:error, :not_found}
  def confirm_upstream(
        identity_or_id,
        generation,
        attempt_id,
        %ResetProbe{} = probe,
        now \\ now()
      ) do
    case identity_id(identity_or_id) do
      nil ->
        {:error, :not_found}

      id ->
        Repo.transaction(fn -> confirm_locked(id, generation, attempt_id, probe, now) end)
        |> case do
          {:ok, outcome} -> {:ok, outcome}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp confirm_locked(id, token, now) do
    identity = lock_identity!(id)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]
    target = RedemptionLifecycle.confirmed_by_upstream()

    can_confirm? =
      valid_legacy_probe?(redemption, token) and
        valid_future_deadline?(redemption, now) and
        RedemptionLifecycle.can_transition?(
          redemption,
          target,
          Map.get(redemption, "generation"),
          Map.get(redemption, "attempt_id")
        )

    confirm_transition(identity, redemption, target, can_confirm?, now)
  end

  defp confirm_locked(id, generation, attempt_id, %ResetProbe{} = probe, now) do
    identity = lock_identity!(id)

    case lock_probe_assignment(probe, id) do
      :ok ->
        redemption = (identity.metadata || %{})["saved_reset_redemption"]
        target = RedemptionLifecycle.confirmed_by_upstream()

        can_confirm? =
          valid_v2_probe?(identity, redemption, generation, attempt_id, probe) and
            valid_future_deadline?(redemption, now) and
            RedemptionLifecycle.can_transition?(redemption, target, generation, attempt_id)

        confirm_transition(identity, redemption, target, can_confirm?, now)

      :error ->
        :unchanged
    end
  end

  defp confirm_transition(identity, redemption, target, true, now) do
    updated =
      Map.merge(redemption, %{
        "phase" => target,
        "status" => RedemptionLifecycle.legacy_status_for(target),
        "finished_at" => DateTime.to_iso8601(now),
        "terminal_reason" => "probe_upstream_confirmed"
      })

    persist_redemption!(identity, updated, now)
    :confirmed
  end

  defp confirm_transition(_identity, _redemption, _target, false, _now), do: :unchanged

  defp claim_locked(id, generation, attempt_id, %ResetProbe{} = probe, now) do
    identity = lock_identity!(id)

    case lock_probe_assignment(probe, id) do
      :ok -> claim_locked_identity(identity, generation, attempt_id, probe, now)
      :error -> Repo.rollback(:unavailable)
    end
  end

  defp claim_locked(id, generation, attempt_id, token, now) when is_binary(token) do
    id
    |> lock_identity!()
    |> claim_locked_identity(generation, attempt_id, token, now)
  end

  defp claim_locked_identity(identity, generation, attempt_id, probe, now) do
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    cond do
      held_probe_matches?(identity, redemption, generation, attempt_id, probe) and
          valid_claim_deadline?(redemption, probe, now) ->
        :claimed

      is_struct(probe, ResetProbe) and
          claimable?(identity, redemption, generation, attempt_id, probe, now) ->
        write_probe!(identity, redemption, probe, now)
        :claimed

      true ->
        Repo.rollback(:unavailable)
    end
  end

  defp claimable?(identity, redemption, generation, attempt_id, probe, now) do
    valid_claim_deadline?(redemption, probe, now) and
      RedemptionLifecycle.probe_claimable?(redemption, now) and
      Map.get(redemption, "generation") == generation and
      Map.get(redemption, "attempt_id") == attempt_id and
      valid_claim_probe?(identity, probe)
  end

  defp write_probe!(identity, redemption, %ResetProbe{} = probe, now) do
    updated = Map.put(redemption, "probe", persisted_v2_probe(probe, now))

    persist_redemption!(identity, updated, now)
  end

  defp held_probe_matches?(identity, redemption, generation, attempt_id, %ResetProbe{} = probe),
    do: valid_v2_probe?(identity, redemption, generation, attempt_id, probe)

  defp held_probe_matches?(_identity, redemption, generation, attempt_id, token)
       when is_binary(token) do
    Map.get(redemption || %{}, "generation") == generation and
      Map.get(redemption || %{}, "attempt_id") == attempt_id and
      valid_legacy_probe?(redemption, token)
  end

  defp valid_claim_probe?(%UpstreamIdentity{id: identity_id}, %ResetProbe{} = probe) do
    ResetProbe.bound?(probe) and probe.upstream_identity_id == identity_id
  end

  defp valid_claim_probe?(_identity, _probe), do: false

  defp persisted_v2_probe(%ResetProbe{} = probe, now) do
    %{
      "version" => probe.version,
      "token" => probe.token,
      "claimed_at" => DateTime.to_iso8601(now),
      "scope" => %{
        "pool_upstream_assignment_id" => probe.pool_upstream_assignment_id,
        "upstream_identity_id" => probe.upstream_identity_id,
        "effective_model" => probe.effective_model,
        "route_class" => probe.route_class
      }
    }
  end

  defp valid_v2_probe?(identity, redemption, generation, attempt_id, %ResetProbe{} = probe) do
    Map.get(redemption || %{}, "generation") == generation and
      Map.get(redemption || %{}, "attempt_id") == attempt_id and
      valid_claim_probe?(identity, probe) and
      exact_v2_probe?(Map.get(redemption || %{}, "probe"), probe)
  end

  defp exact_v2_probe?(
         %{
           "version" => 2,
           "token" => token,
           "claimed_at" => claimed_at,
           "scope" =>
             %{
               "pool_upstream_assignment_id" => assignment_id,
               "upstream_identity_id" => identity_id,
               "effective_model" => effective_model,
               "route_class" => route_class
             } = scope
         } = persisted,
         %ResetProbe{} = probe
       ) do
    Enum.sort(Map.keys(persisted)) == ~w(claimed_at scope token version) and
      Enum.sort(Map.keys(scope)) ==
        ~w(effective_model pool_upstream_assignment_id route_class upstream_identity_id) and
      valid_datetime?(claimed_at) and token == probe.token and
      assignment_id == probe.pool_upstream_assignment_id and
      identity_id == probe.upstream_identity_id and effective_model == probe.effective_model and
      route_class == probe.route_class
  end

  defp exact_v2_probe?(_persisted, _probe), do: false

  defp valid_legacy_probe?(redemption, token) when is_binary(token) do
    case Map.get(redemption || %{}, "probe") do
      %{"token" => ^token, "claimed_at" => claimed_at} = probe ->
        Enum.sort(Map.keys(probe)) == ~w(claimed_at token) and valid_datetime?(claimed_at)

      _invalid ->
        false
    end
  end

  defp valid_datetime?(value) when is_binary(value),
    do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))

  defp valid_datetime?(_value), do: false

  defp valid_future_deadline?(%{"deadline_at" => deadline_at}, %DateTime{} = now)
       when is_binary(deadline_at) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} -> DateTime.compare(now, deadline) == :lt
      _invalid -> false
    end
  end

  defp valid_future_deadline?(_redemption, _now), do: false

  defp valid_claim_deadline?(redemption, probe, now)
       when is_binary(probe) or is_struct(probe, ResetProbe),
       do: valid_future_deadline?(redemption, now)

  defp lock_probe_assignment(%ResetProbe{} = probe, identity_id) do
    assignment =
      Repo.one(
        from assignment in PoolUpstreamAssignment,
          where: assignment.id == ^probe.pool_upstream_assignment_id,
          lock: "FOR UPDATE"
      )

    if match?(%PoolUpstreamAssignment{upstream_identity_id: ^identity_id}, assignment),
      do: :ok,
      else: :error
  end

  defp persist_redemption!(identity, redemption, now) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", redemption),
      updated_at: now
    })
    |> Repo.update!()
  end

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
