defmodule CodexPooler.Gateway.Routing.PartitionRoutability do
  @moduledoc """
  Which assignments could still serve a turn, for canonical partition selection.

  Canonical partition selection runs before dispatch narrows candidates, so it
  needs its own answer to "can this partition serve anything?". This module is
  that answer and nothing more: it never filters candidates, never records
  exclusions, and never decides an outcome. Quota classification stays the
  single authority, reached through
  `CodexPooler.Gateway.Routing.CandidateEligibility.Quota.quota_routable?/4`.
  An account at its operator usage cap counts as not routable, as a
  paused one does, because route filtering removes it before quota
  classification (`CandidateEligibility.UsageCap`).
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageCap
  alias CodexPooler.Gateway.Routing.ProviderCredits
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @type model_id :: Ecto.UUID.t()
  @type assignment_id :: Ecto.UUID.t()
  @type candidate :: CandidateEligibility.candidate()
  @type candidates_by_model_id :: %{optional(model_id()) => [candidate()]}
  @type quota_snapshots :: RoutingQuotaSnapshot.snapshot_map()
  @type routable_assignment_ids_by_model_id :: %{
          required(model_id()) => MapSet.t(assignment_id())
        }

  @doc """
  Reads one quota snapshot for every unique candidate identity, then classifies
  each model independently.

  Callers that already hold a snapshot covering the same candidates should use
  `routable_assignment_ids_by_model_id/4` instead of paying for a second read.
  """
  @spec routable_assignment_ids_by_model_id([Model.t()], candidates_by_model_id(), RequestOptions.t() | map()) :: routable_assignment_ids_by_model_id()
  def routable_assignment_ids_by_model_id(models, candidates_by_model_id, request_context)
      when is_list(models) and is_map(candidates_by_model_id) and is_map(request_context) do
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    identity_ids =
      models
      |> model_candidates(candidates_by_model_id)
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> Enum.uniq()

    routable_assignment_ids_by_model_id(
      models,
      candidates_by_model_id,
      QuotaWindows.load_routing_quota_snapshots(identity_ids, at),
      request_context
    )
  end

  @spec routable_assignment_ids_by_model_id(
          [Model.t()],
          candidates_by_model_id(),
          quota_snapshots(),
          RequestOptions.t() | map()
        ) :: routable_assignment_ids_by_model_id()
  def routable_assignment_ids_by_model_id(
        models,
        candidates_by_model_id,
        quota_snapshots,
        request_context
      )
      when is_list(models) and is_map(candidates_by_model_id) and is_map(quota_snapshots) and is_map(request_context) do
    Map.new(models, fn %Model{} = model ->
      assignment_ids =
        for {assignment, identity} = candidate <-
              Map.get(candidates_by_model_id, model.id, []),
            snapshot = Map.fetch!(quota_snapshots, identity.id),
            context = candidate_request_context(model, request_context, assignment.id),
            Quota.quota_routable?(model, candidate, snapshot, context),
            not UsageCap.capped?(snapshot),
            into: MapSet.new(),
            do: assignment.id

      {model.id, assignment_ids}
    end)
  end

  defp candidate_request_context(model, %RequestOptions{} = request_options, assignment_id),
    do: ProviderCredits.request_context(model, request_options, assignment_id)

  defp candidate_request_context(model, request_context, _assignment_id),
    do: Map.merge(ProviderCredits.request_context(model), request_context)

  defp model_candidates(models, candidates_by_model_id) do
    Enum.flat_map(models, fn
      %Model{} = model -> Map.get(candidates_by_model_id, model.id, [])
      _model -> []
    end)
  end
end
