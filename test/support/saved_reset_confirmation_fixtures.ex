defmodule CodexPooler.SavedResetConfirmationFixtures do
  @moduledoc """
  Helpers for automatic saved-reset corroboration in tests.

  Automatic redemption requires two temporally distinct, equivalent provider
  observations on the exact persisted weekly window. These helpers drive the
  real observation writer with synthetic receipts so fixtures that need a
  corroborated window can obtain one, and expose the current proof references
  a hand-built gateway context must carry.
  """

  import Ecto.Query

  alias CodexPooler.Quotas.AccountAvailability
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.AutomaticConfirmation
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @provider_source "codex_usage_api"
  @default_usage_url "/api/codex/usage"
  @receipt_spacing_seconds 60

  @doc """
  Writes `observations` (default two) synthetic provider receipts for every
  fresh `codex_usage_api` weekly window of the identity through the real
  observation writer, returning the reloaded identity.

  The identity policy and saved-reset snapshot must already be persisted: the
  writer reads both from the identity exactly as reconciliation does. Receipts
  are spaced one minute apart and end at the window's `observed_at`, so the
  latest proof clock is never in the future.
  """
  @spec confirm_automatic_pressure!(UpstreamIdentity.t() | Ecto.UUID.t(), keyword()) ::
          UpstreamIdentity.t()
  def confirm_automatic_pressure!(identity_or_id, opts \\ []) do
    identity = reload!(identity_or_id)
    observations = Keyword.get(opts, :observations, 2)
    usage_url = Keyword.get(opts, :usage_url, @default_usage_url)
    windows = Keyword.get_lazy(opts, :windows, fn -> weekly_provider_windows(identity.id) end)

    for %AccountQuotaWindow{reset_at: %DateTime{}, observed_at: %DateTime{}} = window <- windows,
        ordinal <- 1..observations do
      observe_window!(identity, window, ordinal, observations, usage_url, opts)
    end

    reload!(identity)
  end

  @doc """
  Writes one synthetic provider receipt for the given window at `provider_at`
  through the real writer. `permission` defaults to the coherent tuple implied
  by the window's used percent.
  """
  @spec observe_window!(
          UpstreamIdentity.t() | Ecto.UUID.t(),
          AccountQuotaWindow.t(),
          DateTime.t(),
          keyword()
        ) :: :ok
  def observe_window!(
        identity_or_id,
        %AccountQuotaWindow{} = window,
        %DateTime{} = provider_at,
        opts
      ) do
    identity = reload!(identity_or_id)
    usage_url = Keyword.get(opts, :usage_url, @default_usage_url)
    observed_at = Keyword.get(opts, :observed_at, window.observed_at)
    {allowed, reached, state, basis} = permission(window, Keyword.get(opts, :permission))

    # The provider clock is reconstructed as reset_at - reset_after_seconds;
    # round the countdown up so the reconstructed clock never lands in the
    # future of the intended receipt time.
    reset_after_seconds =
      div(DateTime.diff(window.reset_at, provider_at, :millisecond) + 999, 1000)

    metadata =
      (window.metadata || %{})
      |> AutomaticConfirmation.clear()
      |> Map.merge(%{
        "reset_after_seconds" => reset_after_seconds,
        "limit_window_seconds" => window.window_minutes * 60,
        "rate_limit_allowed" => allowed,
        "rate_limit_reached" => reached
      })

    attrs = %{
      quota_key: window.quota_key,
      window_kind: window.window_kind,
      window_minutes: window.window_minutes,
      used_percent: Keyword.get(opts, :used_percent, window.used_percent),
      reset_at: window.reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: window.source,
      source_precision: window.source_precision,
      quota_scope: window.quota_scope,
      quota_family: window.quota_family,
      model: window.model,
      upstream_model: window.upstream_model,
      raw_limit_id: window.raw_limit_id,
      raw_limit_name: window.raw_limit_name,
      raw_metered_feature: window.raw_metered_feature,
      freshness_state: window.freshness_state,
      metadata: metadata
    }

    availability = AccountAvailability.new!(state, basis, :present)

    AutomaticConfirmation.persist_provider_observation(
      identity,
      attrs,
      availability,
      usage_url,
      observed_at
    )
  end

  @doc "Returns the current confirmation proof references for a trigger and target identity."
  @spec confirmation_refs(
          AutoEligibility.trigger(),
          UpstreamIdentity.t() | Ecto.UUID.t(),
          [Ecto.UUID.t()] | nil,
          DateTime.t() | nil
        ) :: [map()]
  def confirmation_refs(trigger, identity_or_id, candidate_identity_ids \\ nil, timestamp \\ nil)

  def confirmation_refs(trigger, identity_or_id, candidate_identity_ids, timestamp)
      when trigger in [:blocked_weekly_exhaustion, :threshold_pressure] do
    identity = reload!(identity_or_id)
    candidates = candidate_identity_ids || [identity.id]
    AutoEligibility.confirmation_refs(trigger, identity, candidates, timestamp || now())
  end

  def confirmation_refs(_trigger, _identity_or_id, _candidate_identity_ids, _timestamp), do: []

  @doc "Adds the current proof references to a hand-built gateway auto context."
  @spec put_confirmation_refs(map(), DateTime.t() | nil) :: map()
  def put_confirmation_refs(context, timestamp \\ nil) when is_map(context) do
    trigger = Map.get(context, :trigger)
    identity_id = Map.get(context, :upstream_identity_id)
    candidates = Map.get(context, :candidate_identity_ids) || [identity_id]

    Map.put(
      context,
      :automatic_confirmation_refs,
      confirmation_refs(trigger, identity_id, candidates, timestamp)
    )
  end

  @doc "Returns the persisted marker state of a window: nil, candidate or confirmed."
  @spec marker_state(AccountQuotaWindow.t() | Ecto.UUID.t()) :: String.t() | nil
  def marker_state(%AccountQuotaWindow{id: id}), do: marker_state(id)

  def marker_state(window_id) when is_binary(window_id) do
    AccountQuotaWindow
    |> Repo.get!(window_id)
    |> Map.get(:metadata)
    |> AutomaticConfirmation.state()
  end

  @doc "Lists the identity's persisted provider-sourced weekly windows."
  @spec weekly_provider_windows(Ecto.UUID.t()) :: [AccountQuotaWindow.t()]
  def weekly_provider_windows(identity_id) do
    Repo.all(
      from window in AccountQuotaWindow,
        where:
          window.upstream_identity_id == ^identity_id and window.source == ^@provider_source and
            window.window_kind == "secondary",
        order_by: [asc: window.id]
    )
  end

  defp observe_window!(identity, window, ordinal, observations, usage_url, opts) do
    provider_at =
      DateTime.add(
        Keyword.get(opts, :observed_at, window.observed_at),
        -(observations - ordinal) * @receipt_spacing_seconds,
        :second
      )

    observe_window!(identity, window, provider_at, Keyword.put(opts, :usage_url, usage_url))
  end

  defp permission(_window, {allowed, reached, state}) when is_boolean(allowed) do
    basis = if state == :blocked, do: :blocker, else: :affirmative
    {allowed, reached, state, basis}
  end

  defp permission(%AccountQuotaWindow{used_percent: used_percent}, nil) do
    if Decimal.compare(used_percent, Decimal.new(100)) != :lt,
      do: {false, true, :blocked, :blocker},
      else: {true, false, :available, :affirmative}
  end

  defp reload!(%UpstreamIdentity{id: id}), do: Repo.get!(UpstreamIdentity, id)
  defp reload!(id) when is_binary(id), do: Repo.get!(UpstreamIdentity, id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
