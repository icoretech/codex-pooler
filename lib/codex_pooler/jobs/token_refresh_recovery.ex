defmodule CodexPooler.Jobs.TokenRefreshRecovery do
  @moduledoc """
  Selects upstream identities that are eligible for scheduled token-refresh recovery.
  """

  import Ecto.Query

  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @refresh_due UpstreamIdentity.refresh_due_status()
  @refreshing UpstreamIdentity.refreshing_status()
  @refresh_failed UpstreamIdentity.refresh_failed_status()
  @candidate_statuses [@refresh_due, @refreshing, @refresh_failed]
  @assignment_active PoolUpstreamAssignment.active_status()
  @pool_active "active"
  @incomplete_job_states ~w(available scheduled executing retryable)
  @default_limit 100
  @refresh_failed_cooldown_seconds 6 * 60 * 60

  @type opts :: keyword()

  @spec list_candidates(opts()) :: [UpstreamIdentity.t()]
  def list_candidates(opts \\ []) when is_list(opts) do
    now = normalize_now(Keyword.get(opts, :now))
    limit = normalize_limit(Keyword.get(opts, :limit))

    opts
    |> candidate_query()
    |> Repo.all()
    |> Enum.reject(&fresh_token_refresh_in_progress?(&1, now))
    |> Enum.flat_map(&with_eligibility_timestamp(&1, now))
    |> Enum.sort_by(fn {identity, eligible_at} ->
      {DateTime.to_unix(eligible_at, :microsecond), identity.id}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {identity, _eligible_at} -> identity end)
  end

  defp candidate_query(_opts) do
    worker = worker_name(TokenRefreshWorker)

    from identity in UpstreamIdentity,
      join: assignment in PoolUpstreamAssignment,
      on:
        assignment.upstream_identity_id == identity.id and
          assignment.status == ^@assignment_active,
      join: pool in Pool,
      on: pool.id == assignment.pool_id and pool.status == ^@pool_active,
      left_join: job in Oban.Job,
      on:
        job.worker == ^worker and job.state in ^@incomplete_job_states and
          fragment("?->>? = ?::text", job.args, ^"upstream_identity_id", identity.id),
      where: identity.status in ^@candidate_statuses,
      where: is_nil(job.id),
      distinct: true,
      select: identity
  end

  defp with_eligibility_timestamp(
         %UpstreamIdentity{status: status} = identity,
         now
       )
       when status == @refresh_due do
    [{identity, timestamp_or_now(identity.updated_at || identity.created_at, now)}]
  end

  defp with_eligibility_timestamp(
         %UpstreamIdentity{status: status} = identity,
         now
       )
       when status == @refresh_failed do
    reference_at =
      identity.metadata
      |> token_refresh_metadata()
      |> finished_at()
      |> Kernel.||(timestamp_or_now(identity.updated_at || identity.created_at, now))

    eligible_at = DateTime.add(reference_at, @refresh_failed_cooldown_seconds, :second)

    if DateTime.compare(eligible_at, now) in [:lt, :eq] do
      [{identity, eligible_at}]
    else
      []
    end
  end

  defp with_eligibility_timestamp(
         %UpstreamIdentity{status: status} = identity,
         now
       )
       when status == @refreshing do
    reference_at =
      identity.metadata
      |> token_refresh_metadata()
      |> started_at()
      |> Kernel.||(timestamp_or_now(identity.updated_at || identity.created_at, now))

    [{identity, reference_at}]
  end

  defp fresh_token_refresh_in_progress?(%UpstreamIdentity{} = identity, now) do
    identity.metadata
    |> token_refresh_metadata()
    |> active_refresh_attempt?(now)
  end

  defp active_refresh_attempt?(%{} = metadata, now) do
    with "refreshing" <- metadata["status"],
         attempt_id when is_binary(attempt_id) <- metadata["attempt_id"],
         generation when is_integer(generation) and generation >= 0 <- metadata["generation"],
         started_at when is_binary(started_at) <- metadata["started_at"],
         stale_after_ms when is_integer(stale_after_ms) and stale_after_ms > 0 <-
           metadata["stale_after_ms"],
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at),
         true <- DateTime.diff(now, started_at, :millisecond) < stale_after_ms do
      true
    else
      _value -> false
    end
  end

  defp finished_at(%{} = metadata) do
    case metadata["finished_at"] do
      finished_at when is_binary(finished_at) ->
        case DateTime.from_iso8601(finished_at) do
          {:ok, parsed, _offset} -> DateTime.truncate(parsed, :microsecond)
          _invalid -> nil
        end

      _value ->
        nil
    end
  end

  defp started_at(%{} = metadata) do
    case metadata["started_at"] do
      started_at when is_binary(started_at) ->
        case DateTime.from_iso8601(started_at) do
          {:ok, parsed, _offset} -> DateTime.truncate(parsed, :microsecond)
          _invalid -> nil
        end

      _value ->
        nil
    end
  end

  defp token_refresh_metadata(%{} = metadata) do
    case Map.get(metadata, "token_refresh") do
      %{} = token_refresh -> token_refresh
      _value -> %{}
    end
  end

  defp token_refresh_metadata(_metadata), do: %{}

  defp normalize_now(%DateTime{} = now), do: DateTime.truncate(now, :microsecond)
  defp normalize_now(_now), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp normalize_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_limit(_limit), do: @default_limit

  defp timestamp_or_now(%DateTime{} = timestamp, _now),
    do: DateTime.truncate(timestamp, :microsecond)

  defp timestamp_or_now(_timestamp, now), do: now

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
