defmodule CodexPooler.Upstreams.Reconciliation.QuotaConvergenceVerifier do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @modes ~w(stable stale converged)
  @safe_scopes ~w(account model upstream_model feature)

  @type mode :: String.t()
  @type run_result :: {:ok, map()} | {:error, map()}

  @doc false
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, "stable")
    sample_count = Keyword.get(opts, :samples, 5)
    interval_ms = Keyword.get(opts, :interval_ms, 1_000)

    with :ok <- validate_options(mode, sample_count, interval_ms),
         {:ok, candidate} <- select_candidate(opts),
         {:ok, samples} <- collect_samples(candidate, sample_count, interval_ms, opts),
         :ok <- validate_expectation(mode, samples) do
      {:ok, report(mode, candidate, samples)}
    else
      {:error, %{code: _code} = error} -> {:error, error}
      {:error, reason} -> {:error, error("observation_failed", reason_class(reason))}
    end
  end

  defp validate_options(mode, samples, interval_ms)
       when mode in @modes and is_integer(samples) and samples > 1 and samples <= 60 and
              is_integer(interval_ms) and interval_ms >= 0 and interval_ms <= 60_000,
       do: :ok

  defp validate_options(_mode, _samples, _interval_ms),
    do: {:error, error("invalid_options", "unsupported observation options")}

  defp select_candidate(opts) do
    candidates =
      opts
      |> Keyword.get_lazy(:candidate_source, &discover_candidates/0)
      |> Enum.filter(&eligible_candidate?/1)

    case candidates do
      [candidate] ->
        {:ok, candidate}

      [] ->
        {:error, error("no_accepted_selector", "no unambiguous selector was accepted")}

      candidates ->
        {:error,
         error("ambiguous_selector", "multiple selectors were accepted", length(candidates))}
    end
  end

  defp discover_candidates do
    assignments =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          join: identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id,
          where: assignment.status == "active" and identity.status == "active",
          order_by: [asc: assignment.created_at, asc: assignment.id],
          select: {assignment, identity}
      )

    Enum.flat_map(assignments, fn {assignment, identity} ->
      observed_at = now()

      case UsageProbe.fetch_from_identity(identity, assignment, observed_at,
             receive_timeout: 30_000
           ) do
        {:ok, %UsageProbe.Result{} = probe} -> candidates_from_probe(assignment, identity, probe)
        _unavailable -> []
      end
    end)
  end

  defp candidates_from_probe(assignment, identity, probe) do
    probe.windows
    |> Enum.group_by(&Evidence.descriptor_key/1)
    |> Enum.flat_map(fn {descriptor_key, descriptor_windows} ->
      persisted_rows =
        identity
        |> Windows.list_evidence()
        |> Enum.filter(&(Evidence.descriptor_key(&1) == descriptor_key))

      case {descriptor_windows, persisted_rows} do
        {[provider_window], [persisted_row]} ->
          [
            %{
              assignment: assignment,
              identity: identity,
              selector: {identity.id, descriptor_key},
              descriptor_count: 1,
              row_count: 1,
              provider_window: provider_window,
              persisted_row: persisted_row
            }
          ]

        _ambiguous ->
          []
      end
    end)
  end

  defp eligible_candidate?(%{
         descriptor_count: 1,
         row_count: 1,
         provider_window: provider,
         persisted_row: persisted
       }) do
    normalized_scope(provider) in @safe_scopes and
      normalized_scope(provider) == normalized_scope(persisted) and
      normalized_family(provider) == normalized_family(persisted) and
      valid_observation?(provider) and valid_observation?(persisted)
  end

  defp eligible_candidate?(_candidate), do: false

  defp collect_samples(candidate, sample_count, interval_ms, opts) do
    sampler = Keyword.get(opts, :sampler, &sample/1)

    1..sample_count
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, samples} ->
      if index > 1 and interval_ms > 0, do: Process.sleep(interval_ms)

      case sampler.(candidate) do
        {:ok, sample} -> {:cont, {:ok, [sample | samples]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, samples} -> {:ok, Enum.reverse(samples)}
      error -> error
    end
  end

  defp sample(candidate) do
    observed_at = now()

    with {:ok, %UsageProbe.Result{} = probe} <-
           UsageProbe.fetch_from_identity(
             candidate.identity,
             candidate.assignment,
             observed_at,
             receive_timeout: 30_000
           ),
         [provider_window] <- matching_provider_windows(probe, candidate.selector),
         {:ok, %{status: status}} when status in [:succeeded, :partial] <-
           Upstreams.reconcile_pool_account(candidate.assignment.pool_id, candidate.assignment.id),
         [persisted_row] <- matching_persisted_rows(candidate.identity, candidate.selector),
         true <- valid_observation?(provider_window) and valid_observation?(persisted_row) do
      {:ok, observation(provider_window, persisted_row, observed_at)}
    else
      [] ->
        {:error, error("missing_match", "selector no longer has exactly one match")}

      [_first, _second | _rest] ->
        {:error, error("duplicate_match", "selector became ambiguous")}

      false ->
        {:error, error("malformed_observation", "observation shape is invalid")}

      {:error, reason} ->
        {:error, reason}

      _unexpected ->
        {:error, error("observation_failed", "normal reconciliation did not complete")}
    end
  end

  defp matching_provider_windows(probe, {_identity_id, descriptor_key}) do
    Enum.filter(probe.windows, &(Evidence.descriptor_key(&1) == descriptor_key))
  end

  defp matching_persisted_rows(identity, {_identity_id, descriptor_key}) do
    identity
    |> Windows.list_evidence()
    |> Enum.filter(&(Evidence.descriptor_key(&1) == descriptor_key))
  end

  defp observation(provider, persisted, observed_at) do
    %{
      observed_at: observed_at,
      provider: normalized_observation(provider, observed_at),
      persisted: normalized_observation(persisted, observed_at),
      converged: equivalent_pair?(provider, persisted)
    }
  end

  defp normalized_observation(window, timestamp) do
    %{
      used_percent: decimal_string(field(window, :used_percent)),
      reset_at: iso8601(field(window, :reset_at)),
      freshness: freshness_class(window, timestamp),
      source_class: source_class(field(window, :source))
    }
  end

  defp validate_expectation("stable", samples) do
    if Enum.uniq(Enum.map(samples, &pair_signature/1)) |> length() == 1,
      do: :ok,
      else: {:error, error("unstable_pairs", "stable samples changed")}
  end

  defp validate_expectation("stale", samples) do
    if Enum.all?(samples, &(not &1.converged)),
      do: :ok,
      else: {:error, error("stale_expectation_mismatch", "a stale sample converged")}
  end

  defp validate_expectation("converged", samples) do
    if List.last(samples).converged,
      do: :ok,
      else: {:error, error("converged_expectation_mismatch", "final sample did not converge")}
  end

  defp report(mode, candidate, samples) do
    salt = :crypto.strong_rand_bytes(32)

    %{
      schema_version: 1,
      status: "passed",
      mode: mode,
      selector_fingerprint: fingerprint(candidate.selector, salt),
      descriptor_count: candidate.descriptor_count,
      persisted_row_count: candidate.row_count,
      scope: normalized_scope(candidate.provider_window),
      family: normalized_family(candidate.provider_window),
      sample_count: length(samples),
      samples: Enum.with_index(samples, 1) |> Enum.map(&sample_report/1)
    }
  end

  defp sample_report({sample, index}) do
    %{
      index: index,
      observed_at: iso8601(sample.observed_at),
      provider: sample.provider,
      persisted: sample.persisted,
      converged: sample.converged
    }
  end

  defp pair_signature(sample), do: {sample.provider, sample.persisted, sample.converged}

  defp equivalent_pair?(provider, persisted) do
    decimal_equal?(field(provider, :used_percent), field(persisted, :used_percent)) and
      iso8601(field(provider, :reset_at)) == iso8601(field(persisted, :reset_at))
  end

  defp valid_observation?(window) do
    normalized_scope(window) in @safe_scopes and is_binary(normalized_family(window)) and
      match?(%Decimal{}, field(window, :used_percent)) and
      match?(%DateTime{}, field(window, :reset_at)) and
      match?(%DateTime{}, field(window, :observed_at))
  end

  defp fingerprint(selector, salt) do
    :crypto.mac(:hmac, :sha256, salt, :erlang.term_to_binary(selector))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 20)
  end

  defp normalized_scope(window), do: field(window, :quota_scope) || "account"
  defp normalized_family(window), do: field(window, :quota_family) || "account"

  defp freshness_class(window, timestamp) do
    observed_at = field(window, :observed_at)
    reset_at = field(window, :reset_at)

    if match?(%DateTime{}, observed_at) and match?(%DateTime{}, reset_at) and
         DateTime.compare(observed_at, DateTime.add(timestamp, 300, :second)) != :gt and
         DateTime.compare(reset_at, timestamp) == :gt,
       do: "fresh",
       else: "stale"
  end

  defp source_class("codex_usage_api"), do: "provider_usage"

  defp source_class(source) when source in ["codex_rate_limit_event", "codex_rate_limit_error"],
    do: "runtime_event"

  defp source_class(source)
       when source in ["x-codex-primary-used-percent", "x-codex-secondary-used-percent"],
       do: "runtime_header"

  defp source_class(_source), do: "other"

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(_value), do: nil
  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  defp decimal_equal?(_left, _right), do: false
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp error(code, message, count \\ nil) do
    %{schema_version: 1, status: "failed", code: code, message: message}
    |> then(fn error ->
      if is_integer(count), do: Map.put(error, :candidate_count, count), else: error
    end)
  end

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unknown"
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
