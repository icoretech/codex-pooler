defmodule CodexPooler.Gateway.Routing.PartitionRoutability do
  @moduledoc """
  Which assignments could still serve a turn, for canonical partition selection.

  Canonical partition selection runs before dispatch narrows candidates, so it
  needs its own answer to "can this partition serve anything?". This module is
  that answer and nothing more: it never filters candidates, never records
  exclusions, and never decides an outcome. Quota classification stays the
  single authority, reached through
  `CodexPooler.Gateway.Routing.CandidateEligibility.Quota.quota_routable?/4`.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @type candidate :: CandidateEligibility.candidate()
  @type candidates_by_model_id :: %{optional(Ecto.UUID.t()) => [candidate()]}
  @type quota_window_snapshots :: %{optional(Ecto.UUID.t()) => [AccountQuotaWindow.t()]}

  @doc """
  Reads a quota snapshot for every candidate identity, then classifies.

  Callers that already hold a snapshot covering the same candidates should use
  `routable_assignment_ids/4` instead of paying for a second read.
  """
  @spec routable_assignment_ids([Model.t()], candidates_by_model_id()) ::
          MapSet.t(Ecto.UUID.t())
  def routable_assignment_ids(models, candidates_by_model_id)
      when is_list(models) and is_map(candidates_by_model_id) do
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    identity_ids =
      models
      |> model_candidates(candidates_by_model_id)
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> Enum.uniq()

    routable_assignment_ids(
      models,
      candidates_by_model_id,
      QuotaWindows.list_quota_windows_by_identity_ids(identity_ids, at),
      at
    )
  end

  @spec routable_assignment_ids(
          [Model.t()],
          candidates_by_model_id(),
          quota_window_snapshots(),
          DateTime.t()
        ) :: MapSet.t(Ecto.UUID.t())
  def routable_assignment_ids(
        models,
        candidates_by_model_id,
        quota_window_snapshots,
        %DateTime{} = at
      )
      when is_list(models) and is_map(candidates_by_model_id) and is_map(quota_window_snapshots) do
    for %Model{} = model <- models,
        {assignment, identity} = candidate <- Map.get(candidates_by_model_id, model.id, []),
        Quota.quota_routable?(
          model,
          candidate,
          Map.get(quota_window_snapshots, identity.id, []),
          at
        ),
        into: MapSet.new(),
        do: assignment.id
  end

  defp model_candidates(models, candidates_by_model_id) do
    Enum.flat_map(models, fn
      %Model{} = model -> Map.get(candidates_by_model_id, model.id, [])
      _model -> []
    end)
  end
end
