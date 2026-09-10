defmodule CodexPooler.Upstreams.SavedResets.AutomaticConfirmation do
  @moduledoc """
  Metadata-only corroboration state for automatic saved-reset spend.

  Automatic redemption is an irreversible provider action, so it must not
  fire from one provider observation. Every successful Usage API probe that
  reports a weekly window which could authorize an automatic trigger writes a
  bounded marker on that exact `account_quota_windows` row:

    * `candidate` — one coherent observation with a complete binding
    * `confirmed` — a strictly newer, equivalent observation from a separate
      successful probe receipt corroborated the first one

  A non-qualifying, conflicting, replayed, malformed or differently bound
  observation clears or restarts the marker; it is never repaired during a
  claim. The marker is pressure evidence only. Spend, interruption, replay and
  convergence remain owned by the redemption lifecycle.
  """

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.RelativeLiveness
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @metadata_key "__saved_reset_auto_confirmation_v1"
  @version 1
  @provider_source "codex_usage_api"
  @default_max_age_seconds 900
  @confirmed_count 2
  @binding_keys ~w(identity_id credential_epoch reset_identity provider_scope descriptor trigger threshold_percent bank_count keep_credits permission)a
  @permission_keys ~w(allowed reached account_state)a
  @triggers [:blocked, :threshold]
  @account_states ["available", "blocked"]

  @type trigger :: :blocked | :threshold
  @type permission :: %{
          required(:allowed) => boolean(),
          required(:reached) => boolean(),
          required(:account_state) => String.t()
        }
  @type binding :: %{
          required(:identity_id) => Ecto.UUID.t(),
          required(:credential_epoch) => pos_integer(),
          required(:reset_identity) => String.t(),
          required(:provider_scope) => String.t(),
          required(:descriptor) => String.t(),
          required(:trigger) => trigger(),
          required(:threshold_percent) => number() | nil,
          required(:bank_count) => non_neg_integer() | nil,
          required(:keep_credits) => non_neg_integer(),
          required(:permission) => permission()
        }
  @type observation :: %{
          required(:binding) => binding(),
          required(:provider_observed_at) => DateTime.t(),
          required(:observed_at) => DateTime.t(),
          required(:used_percent) => number(),
          required(:rate_limit_allowed) => boolean(),
          required(:rate_limit_reached) => boolean(),
          required(:reset_at) => DateTime.t(),
          required(:available_count) => non_neg_integer() | nil
        }

  @doc "Returns the strict metadata key used for automatic saved-reset pressure proofs."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  Copies an existing marker into freshly merged window attributes.

  Quota evidence merging rebuilds the window metadata from the incoming
  observation; the confirmation marker is not provider evidence and must
  survive that rebuild so the post-upsert observation writer can advance or
  clear it from the observation that actually arrived.
  """
  @spec retain(map(), AccountQuotaWindow.t() | nil) :: map()
  def retain(attrs, %AccountQuotaWindow{metadata: metadata}) when is_map(attrs) do
    case marker(metadata) do
      nil -> attrs
      marker -> Map.update(attrs, :metadata, %{@metadata_key => marker}, &put_marker(&1, marker))
    end
  end

  def retain(attrs, _existing), do: attrs

  @doc """
  Records one coherent Usage API observation on the exact persisted window.

  Must run inside the reconciliation transaction that already holds the
  identity lock, after quota windows, account availability and the saved-reset
  snapshot from the same provider receipt were persisted. Any observation that
  does not qualify for an automatic trigger clears the marker on that window.
  """
  @spec persist_provider_observation(
          UpstreamIdentity.t(),
          map(),
          CodexPooler.Quotas.AccountAvailability.t() | nil,
          String.t() | nil,
          DateTime.t()
        ) :: :ok
  def persist_provider_observation(
        %UpstreamIdentity{} = identity,
        attrs,
        account_availability,
        usage_url,
        %DateTime{} = observed_at
      )
      when is_map(attrs) do
    with {:ok, evidence} <- to_evidence(attrs, observed_at),
         true <- evidence.source == @provider_source,
         %AccountQuotaWindow{} = window <- find_window(identity.id, evidence) do
      metadata = window.metadata || %{}

      next =
        case build_observation(identity, evidence, account_availability, usage_url, observed_at) do
          {:ok, observation} -> observe(metadata, observation)
          :error -> clear(metadata)
        end

      if next != metadata do
        window
        |> AccountQuotaWindow.changeset(%{metadata: next})
        |> Repo.update!()
      end

      :ok
    else
      _not_applicable -> :ok
    end
  end

  @doc "Adds one coherent provider observation to a window metadata map."
  @spec observe(map() | nil, observation()) :: map()
  def observe(metadata, observation) when is_map(observation) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    case normalize_observation(observation) do
      {:ok, incoming} ->
        if qualifying?(incoming) do
          put_marker(metadata, transition(marker(metadata), incoming))
        else
          clear(metadata)
        end

      :error ->
        clear(metadata)
    end
  end

  @doc """
  Returns true only for a fresh two-receipt confirmation whose binding still
  matches the caller's current trigger, policy and identity facts.

  `require_bank?` (default true) additionally demands a reported saved-reset
  bank above the bound keep-credits floor; a pressure member that is not the
  consuming target passes `require_bank?: false` because its bank is not spent.
  """
  @spec confirmed?(map() | nil, DateTime.t(), keyword()) :: boolean()
  def confirmed?(metadata, %DateTime{} = now, opts \\ []) do
    trigger = Keyword.get(opts, :trigger, :blocked)

    with {:ok, parsed} <- parse(metadata),
         true <- parsed.state == "confirmed" and parsed.observation_count == @confirmed_count,
         latest = parsed.latest,
         true <- latest.binding.trigger == trigger,
         true <- threshold_matches?(latest.binding, Keyword.get(opts, :threshold_percent)),
         true <- policy_matches?(latest.binding, Keyword.get(opts, :keep_credits)),
         true <- identity_matches?(latest.binding, Keyword.get(opts, :identity)),
         true <- bank_spendable?(latest, Keyword.get(opts, :require_bank?, true)),
         true <- DateTime.compare(now, latest.reset_at) == :lt,
         true <-
           fresh?(
             latest.provider_observed_at,
             now,
             Keyword.get(opts, :max_age_seconds, @default_max_age_seconds)
           ),
         true <- qualifying?(latest) do
      true
    else
      _not_confirmed -> false
    end
  end

  @doc "Returns a stable fingerprint for a persisted marker, or nil when absent."
  @spec fingerprint(map() | nil) :: String.t() | nil
  def fingerprint(metadata) do
    case marker(metadata) do
      nil -> nil
      marker -> marker |> canonical_binary() |> sha256()
    end
  end

  @doc "Removes an automatic confirmation without changing other window metadata."
  @spec clear(map() | nil) :: map()
  def clear(metadata) when is_map(metadata), do: Map.delete(metadata, @metadata_key)
  def clear(_metadata), do: %{}

  @doc "Returns the persisted marker state, or nil when absent or malformed."
  @spec state(map() | nil) :: String.t() | nil
  def state(metadata) do
    case parse(metadata) do
      {:ok, parsed} -> parsed.state
      :error -> nil
    end
  end

  # -- observation construction -------------------------------------------

  defp to_evidence(%Evidence{} = evidence, _observed_at), do: {:ok, evidence}
  defp to_evidence(attrs, observed_at), do: Evidence.new(attrs, observed_at)

  defp find_window(identity_id, evidence) do
    key = Evidence.identity_key(evidence)

    Repo.all(
      from window in AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id and window.source == ^@provider_source
    )
    |> Enum.find(&(Evidence.identity_key(&1) == key))
  end

  defp build_observation(identity, evidence, account_availability, usage_url, observed_at) do
    policy = SavedResets.auto_policy(identity)
    snapshot = SavedResets.snapshot(identity, observed_at)
    metadata = evidence.metadata || %{}
    state = account_state(account_availability)

    count = if is_integer(snapshot.available_count), do: max(snapshot.available_count, 0)

    with %DateTime{} = reset_at <- evidence.reset_at,
         %Decimal{} = used_percent <- evidence.used_percent,
         {:ok, provider_observed_at} <- RelativeLiveness.provider_observed_at(evidence),
         allowed when is_boolean(allowed) <- metadata["rate_limit_allowed"],
         reached when is_boolean(reached) <- metadata["rate_limit_reached"],
         epoch when is_integer(epoch) and epoch > 0 <-
           CredentialFencing.credential_epoch(identity),
         true <- state in @account_states,
         {:ok, trigger} <- trigger_for(policy, used_percent, allowed, reached, state) do
      {:ok,
       %{
         binding: %{
           identity_id: identity.id,
           credential_epoch: epoch,
           reset_identity: DateTime.to_iso8601(reset_at),
           provider_scope: provider_scope(identity, usage_url),
           descriptor: descriptor(evidence),
           trigger: trigger,
           threshold_percent: threshold_percent(trigger, policy),
           bank_count: count,
           keep_credits: policy.keep_credits,
           permission: %{allowed: allowed, reached: reached, account_state: state}
         },
         provider_observed_at: provider_observed_at,
         observed_at: observed_at,
         used_percent: Decimal.to_float(used_percent),
         rate_limit_allowed: allowed,
         rate_limit_reached: reached,
         reset_at: reset_at,
         available_count: count
       }}
    else
      _not_qualifying -> :error
    end
  end

  defp trigger_for(%{enabled?: false}, _used_percent, _allowed, _reached, _state), do: :error

  defp trigger_for(policy, %Decimal{} = used_percent, allowed, reached, state) do
    permission = {allowed, reached, state}

    cond do
      blocked_receipt?(used_percent, permission) -> {:ok, :blocked}
      threshold_receipt?(policy, used_percent, permission) -> {:ok, :threshold}
      true -> :error
    end
  end

  defp blocked_receipt?(used_percent, {false, true, "blocked"}), do: exhausted?(used_percent)
  defp blocked_receipt?(_used_percent, _permission), do: false

  defp threshold_receipt?(
         %{trigger_mode: "threshold"} = policy,
         used_percent,
         {true, false, "available"}
       ),
       do: at_or_above?(used_percent, policy.quota_threshold_percent)

  defp threshold_receipt?(_policy, _used_percent, _permission), do: false

  defp threshold_percent(:threshold, policy), do: policy.quota_threshold_percent
  defp threshold_percent(:blocked, _policy), do: nil

  defp exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp at_or_above?(%Decimal{} = used_percent, threshold) when is_number(threshold),
    do: Decimal.compare(used_percent, Decimal.from_float(threshold / 1)) != :lt

  defp at_or_above?(_used_percent, _threshold), do: false

  defp account_state(%{state: state}) when state in [:available, :blocked],
    do: Atom.to_string(state)

  defp account_state(_availability), do: "unknown"

  defp descriptor(evidence) do
    evidence
    |> Evidence.identity_key()
    |> canonical_binary()
    |> sha256()
  end

  # The scope binds the provider account and the usage endpoint family the
  # receipt came from. The host is deliberately not part of it: the consume
  # endpoint is resolved from the identity's current configuration under the
  # claim lock, and a different serving host does not make two receipts of the
  # same account and path incoherent.
  defp provider_scope(%UpstreamIdentity{} = identity, usage_url) do
    path =
      case usage_url && URI.parse(usage_url).path do
        path when is_binary(path) and path != "" -> path
        _absent -> ""
      end

    sha256("#{path}|#{identity.chatgpt_account_id || ""}")
  end

  # -- marker state machine ------------------------------------------------

  defp transition(nil, incoming), do: new_marker("candidate", incoming, incoming, 1)

  defp transition(existing, incoming) when is_map(existing) do
    with {:ok, parsed} <- parse_marker(existing),
         true <- equivalent?(parsed.latest, incoming) do
      case DateTime.compare(incoming.provider_observed_at, parsed.latest.provider_observed_at) do
        :gt -> new_marker("confirmed", parsed.first, incoming, @confirmed_count)
        _replayed_or_older -> existing
      end
    else
      _restart -> new_marker("candidate", incoming, incoming, 1)
    end
  end

  defp equivalent?(left, right) do
    left.binding == right.binding and DateTime.compare(left.reset_at, right.reset_at) == :eq
  end

  defp new_marker(state, first, latest, count) do
    %{
      "version" => @version,
      "state" => state,
      "binding" => encode_binding(first.binding),
      "first" => encode_observation(first),
      "latest" => encode_observation(latest),
      "observation_count" => count
    }
  end

  defp qualifying?(%{binding: %{trigger: :blocked} = binding} = observation) do
    observation.used_percent >= 100 and observation.rate_limit_allowed == false and
      observation.rate_limit_reached == true and
      binding.permission == %{allowed: false, reached: true, account_state: "blocked"} and
      observation.available_count == binding.bank_count
  end

  defp qualifying?(
         %{binding: %{trigger: :threshold, threshold_percent: threshold} = binding} = observation
       )
       when is_number(threshold) do
    observation.used_percent >= threshold and observation.rate_limit_allowed == true and
      observation.rate_limit_reached == false and
      binding.permission == %{allowed: true, reached: false, account_state: "available"} and
      observation.available_count == binding.bank_count
  end

  defp qualifying?(_observation), do: false

  defp bank_spendable?(_latest, false), do: true

  defp bank_spendable?(
         %{available_count: count, binding: %{keep_credits: keep_credits}},
         _require
       ),
       do: is_integer(count) and count > keep_credits

  defp threshold_matches?(%{trigger: :blocked, threshold_percent: nil}, _expected), do: true

  defp threshold_matches?(%{trigger: :threshold, threshold_percent: bound}, expected)
       when is_number(bound) and is_number(expected),
       do: bound == expected

  defp threshold_matches?(_binding, _expected), do: false

  defp policy_matches?(_binding, nil), do: true

  defp policy_matches?(%{keep_credits: keep_credits}, expected) when is_integer(expected),
    do: keep_credits == expected

  defp policy_matches?(_binding, _expected), do: false

  defp identity_matches?(_binding, nil), do: true

  defp identity_matches?(binding, %UpstreamIdentity{} = identity) do
    binding.identity_id == identity.id and
      binding.credential_epoch == CredentialFencing.credential_epoch(identity)
  end

  defp identity_matches?(_binding, _identity), do: false

  defp fresh?(%DateTime{} = provider_observed_at, now, max_age_seconds)
       when is_integer(max_age_seconds) and max_age_seconds >= 0 do
    DateTime.compare(provider_observed_at, now) != :gt and
      DateTime.diff(now, provider_observed_at, :second) <= max_age_seconds
  end

  defp fresh?(_provider_observed_at, _now, _max_age_seconds), do: false

  # -- parsing and encoding ------------------------------------------------

  defp marker(metadata) when is_map(metadata) do
    case Map.get(metadata, @metadata_key) do
      marker when is_map(marker) -> marker
      _absent -> nil
    end
  end

  defp marker(_metadata), do: nil

  defp put_marker(metadata, marker) when is_map(metadata),
    do: Map.put(metadata, @metadata_key, marker)

  defp put_marker(_metadata, marker), do: %{@metadata_key => marker}

  defp parse(metadata) do
    case marker(metadata) do
      nil -> :error
      marker -> parse_marker(marker)
    end
  end

  defp parse_marker(marker) when is_map(marker) do
    with true <- marker["version"] == @version,
         state when state in ["candidate", "confirmed"] <- marker["state"],
         count when is_integer(count) and count in 1..@confirmed_count <-
           marker["observation_count"],
         true <- state == "confirmed" == (count == @confirmed_count),
         {:ok, first} <- decode_observation(marker["first"]),
         {:ok, latest} <- decode_observation(marker["latest"]),
         {:ok, binding} <- normalize_binding(marker["binding"]),
         true <- binding == first.binding and binding == latest.binding,
         true <- DateTime.compare(latest.provider_observed_at, first.provider_observed_at) != :lt do
      {:ok, %{state: state, observation_count: count, first: first, latest: latest}}
    else
      _malformed -> :error
    end
  end

  defp normalize_observation(observation) when is_map(observation) do
    with {:ok, provider_observed_at} <- datetime(field(observation, :provider_observed_at)),
         {:ok, observed_at} <- datetime(field(observation, :observed_at)),
         {:ok, reset_at} <- datetime(field(observation, :reset_at)),
         {:ok, binding} <- normalize_binding(field(observation, :binding)),
         used_percent when is_number(used_percent) <- field(observation, :used_percent),
         allowed when is_boolean(allowed) <- field(observation, :rate_limit_allowed),
         reached when is_boolean(reached) <- field(observation, :rate_limit_reached),
         count when is_nil(count) or (is_integer(count) and count >= 0) <-
           field(observation, :available_count) do
      {:ok,
       %{
         binding: binding,
         provider_observed_at: provider_observed_at,
         observed_at: observed_at,
         used_percent: used_percent,
         rate_limit_allowed: allowed,
         rate_limit_reached: reached,
         reset_at: reset_at,
         available_count: count
       }}
    else
      _malformed -> :error
    end
  end

  defp normalize_binding(binding) when is_map(binding) do
    values = Map.new(@binding_keys, &{&1, field(binding, &1)})

    with {:ok, identity_id} <- uuid(values.identity_id),
         epoch when is_integer(epoch) and epoch > 0 <- values.credential_epoch,
         reset_identity when is_binary(reset_identity) and reset_identity != "" <-
           values.reset_identity,
         scope when is_binary(scope) and byte_size(scope) == 64 <- values.provider_scope,
         descriptor when is_binary(descriptor) and byte_size(descriptor) == 64 <-
           values.descriptor,
         trigger when trigger in @triggers <- trigger_atom(values.trigger),
         {:ok, threshold} <- threshold_value(trigger, values.threshold_percent),
         bank_count when is_nil(bank_count) or (is_integer(bank_count) and bank_count >= 0) <-
           values.bank_count,
         keep_credits when is_integer(keep_credits) and keep_credits >= 0 <- values.keep_credits,
         {:ok, permission} <- normalize_permission(values.permission) do
      {:ok,
       %{
         identity_id: identity_id,
         credential_epoch: epoch,
         reset_identity: reset_identity,
         provider_scope: scope,
         descriptor: descriptor,
         trigger: trigger,
         threshold_percent: threshold,
         bank_count: bank_count,
         keep_credits: keep_credits,
         permission: permission
       }}
    else
      _malformed -> :error
    end
  end

  defp normalize_binding(_binding), do: :error

  defp normalize_permission(permission) when is_map(permission) do
    values = Map.new(@permission_keys, &{&1, field(permission, &1)})

    if is_boolean(values.allowed) and is_boolean(values.reached) and
         values.account_state in @account_states,
       do: {:ok, values},
       else: :error
  end

  defp normalize_permission(_permission), do: :error

  defp trigger_atom(trigger) when trigger in @triggers, do: trigger
  defp trigger_atom("blocked"), do: :blocked
  defp trigger_atom("threshold"), do: :threshold
  defp trigger_atom(_trigger), do: :invalid

  defp threshold_value(:blocked, nil), do: {:ok, nil}
  defp threshold_value(:threshold, value) when is_number(value), do: {:ok, value}
  defp threshold_value(_trigger, _value), do: :error

  defp encode_binding(binding) do
    binding
    |> Map.update!(:trigger, &Atom.to_string/1)
    |> Map.update!(:permission, &stringify_keys/1)
    |> stringify_keys()
  end

  defp encode_observation(observation) do
    observation
    |> Map.update!(:binding, &encode_binding/1)
    |> Map.update!(:provider_observed_at, &DateTime.to_iso8601/1)
    |> Map.update!(:observed_at, &DateTime.to_iso8601/1)
    |> Map.update!(:reset_at, &DateTime.to_iso8601/1)
    |> stringify_keys()
  end

  defp decode_observation(value) when is_map(value), do: normalize_observation(value)
  defp decode_observation(_value), do: :error

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_value), do: :error

  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp datetime(_value), do: :error

  defp canonical_binary(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp sha256(binary) when is_binary(binary),
    do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
end
