defmodule CodexPooler.Gateway.Routing.CandidateEligibility.UsageCap do
  @moduledoc """
  Takes accounts at their operator usage cap out of the request.

  An operator can keep part of an account's quota for the account's owner
  (`upstream_identities.usage_cap_percent`, public issue
  icoretech/codex-pooler#637). Once its long window (weekly, or 30-day on a
  plan without a weekly window) reads that share used (`Quota.Windows.UsageCap`)
  the account behaves for the Pool like a paused one until the window resets or
  the operator lifts the cap: it takes no new work in any Pool it serves. An
  account whose long window cannot be read is not affected.

  `RouteFiltering` applies `exclude_capped/3` first, before circuits, quota
  eligibility and both saved-reset scans, and removes the capped accounts from
  the candidates and from the saved-reset capacity list, so a capped account
  never holds a sibling's banked reset back. Every capped identity is also
  recorded on the route state (`RouteState.put_usage_capped_identity_ids/2`),
  and automatic redemption never picks a recorded identity as its target, so
  Pool traffic never spends a capped account's own reset, not even while a
  running turn finishes on it. The cohort the consume barrier locks stays the
  whole runtime-compatible set.

  A capped account keeps the requests that would otherwise break: the rest of
  a Codex turn already running on it (on the websocket and on native HTTP), a
  request whose file lives only there, and an anchored `/v1` request (see
  `kept_assignment_id/1`). The next user turn of an anchored Codex websocket is
  refused like a pinned account that ran out:
  `Quota.quota_unavailable_error/3` answers `pinned_continuation_unavailable`,
  and the released client rebuilds the turn without the anchor on another
  account. Those kept requests can take the account past its cap, up to its
  provider limit. A candidate bound to a reset probe or admitted by its
  confirmed reset lifecycle keeps its exemption.

  Exclusions carry `reason_codes` `["exhausted", "operator_usage_cap"]` and the
  capping window's reset. When every candidate is capped the Pool answers the
  ordinary `quota_exhausted` 429 with the soonest reset; when the rest are
  exhausted, `merge_capped_returns/2` adds the capped accounts to that refusal
  so its advice names the soonest return of either (`UsageLimit.earliest_reset/2`).
  """

  alias CodexPooler.Gateway.Payloads.NativeTurnContinuation
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @reason_codes ["exhausted", "operator_usage_cap"]

  @doc """
  Removes capped accounts from the request's candidates and saved-reset
  capacity. Returns the narrowed input and route state with the exclusions it
  made, or the Pool's refusal when no candidate is left.

  In `:required` quota mode (model traffic) every capped account leaves, except
  the one account a request must keep (`kept_assignment_id/1`). In `:optional`
  mode (file uploads, which spend no model quota) the cap is a preference:
  capped accounts leave only while an uncapped candidate remains, so a later
  turn that needs the file does not land on a capped account when it can be
  helped. Every capped identity, a kept one included, is recorded on the route
  state so automatic redemption never makes it a target.
  """
  @spec exclude_capped(FilterInput.t(), RouteState.t(), :required | :optional) ::
          {:ok, FilterInput.t(), RouteState.t(), [map()]} | {:error, map()}
  def exclude_capped(%FilterInput{} = input, %RouteState{} = route_state, quota_mode) do
    kept_id = if quota_mode == :required, do: kept_assignment_id(input)
    capped = Enum.flat_map(input.candidates, &capped_candidate(&1, input, route_state))
    capped_identity_ids = Enum.map(capped, fn {{_assignment, identity}, _exclusion} -> identity.id end)
    excluded = Enum.reject(capped, fn {{assignment, _identity}, _exclusion} -> assignment.id == kept_id end)
    excluded_ids = MapSet.new(excluded, fn {{assignment, _identity}, _exclusion} -> assignment.id end)
    remaining = Enum.reject(input.candidates, fn {assignment, _identity} -> MapSet.member?(excluded_ids, assignment.id) end)

    route_state =
      route_state
      |> RouteState.put_usage_capped_identity_ids(capped_identity_ids)
      |> RouteState.put_saved_reset_auto_capacity(uncapped_capacity(route_state))

    cond do
      excluded == [] ->
        {:ok, input, route_state, []}

      quota_mode == :optional and remaining == [] ->
        {:ok, input, route_state, []}

      remaining == [] ->
        Quota.quota_unavailable_error(input, Enum.map(excluded, &elem(&1, 1)), false)

      true ->
        {:ok, FilterInput.put_candidates(input, remaining), RouteState.put_candidates(route_state, remaining), Enum.map(excluded, &elem(&1, 1))}
    end
  end

  @doc """
  Adds the capped accounts to a `quota_exhausted` refusal of the candidates
  that were left, so a Pool of capped and exhausted accounts advises the
  soonest return of either. Any other result passes through.
  """
  @spec merge_capped_returns(term(), [map()]) :: term()
  def merge_capped_returns({:error, %{code: "quota_exhausted"} = error}, [_ | _] = capped_exclusions) do
    exclusions = Map.get(error, :candidate_exclusions, []) ++ capped_exclusions
    error = Map.put(error, :candidate_exclusions, exclusions)

    case {Map.has_key?(error, :usage_limit), UsageLimit.earliest_reset(exclusions, DateTime.utc_now())} do
      {true, {:ok, usage_limit}} -> {:error, Map.put(error, :usage_limit, usage_limit)}
      {true, :unknown} -> {:error, UsageLimit.retryable(error)}
      {false, _advice} -> {:error, error}
    end
  end

  def merge_capped_returns(result, _capped_exclusions), do: result

  @doc """
  The exclusion this filter would record for `candidate` under `route_state`'s
  quota snapshot, or `nil` when its account is below its cap. Pool-return advice
  reads it without a request payload, so it applies no turn exemption.
  """
  @spec candidate_exclusion(FilterInput.candidate(), RouteState.t()) :: map() | nil
  def candidate_exclusion({assignment, identity}, %RouteState{} = route_state) do
    case usage_cap(identity, route_state) do
      nil -> nil
      cap -> exclusion(assignment, identity, cap)
    end
  end

  @doc "Whether the snapshot's account is at its operator usage cap right now."
  @spec capped?(CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot.t() | nil) :: boolean()
  def capped?(snapshot), do: not is_nil(QuotaWindows.routing_usage_cap(snapshot))

  # The one account a request keeps although it is capped, or nil:
  #
  #   * the account a running Codex turn is on, for any request that continues
  #     that turn (`running_turn_request?/2`). That is the session's own
  #     assignment: a websocket hard pin narrows the candidates to it, and a
  #     native HTTP session holds it as its soft pin, so the turn finishes there
  #     on both transports. A request whose session has no assignment yet keeps
  #     nothing, so an unresolved anchor cannot reach any capped account;
  #   * the account a referenced file lives on (file-affinity hard pin): the
  #     file exists nowhere else, so refusing it would strand every later turn
  #     that uses it until the window resets;
  #   * the account an anchored `/v1` request names: an SDK cannot rebuild a
  #     refused chain as full history the way the Codex client does.
  #
  # Anything else, such as the next user turn on an anchored Codex websocket,
  # is refused like a pinned account that ran out (`pinned_continuation_unavailable`),
  # and the released client rebuilds that turn without the anchor elsewhere.
  defp kept_assignment_id(%FilterInput{request_options: request_options, model: model, payload: payload}) do
    pin = SessionContinuity.hard_pin_metadata(request_options, model)
    session_assignment_id = session_assignment_id(request_options)

    cond do
      match?(%{"pin_reason" => "file_affinity"}, pin) -> request_options.routing.file_affinity_assignment_id
      match?(%{"pin_reason" => "previous_response_id"}, pin) and translated_surface?(request_options) -> session_assignment_id
      running_turn_request?(payload, request_options) -> session_assignment_id
      true -> nil
    end
  end

  defp session_assignment_id(%{continuity: %{codex_session: %{pool_upstream_assignment_id: assignment_id}}}) when is_binary(assignment_id), do: assignment_id
  defp session_assignment_id(_request_options), do: nil

  defp translated_surface?(%{openai_compatibility: %OpenAICompatibility{} = compatibility}), do: OpenAICompatibility.translated_responses_surface?(compatibility)
  defp translated_surface?(_request_options), do: false

  @doc """
  Whether a request continues a Codex turn already running, on any transport:
  a compaction, the resume right after a compaction, or a request that carries
  a tool result after its last user message. A websocket delta and a native
  HTTP full history read the same way: the next user turn ends with a user
  message, a running turn's next request ends with tool results. User input
  steered into a running turn ends with a user message too and therefore counts
  as the next turn.
  """
  @spec running_turn_request?(map(), CodexPooler.Gateway.Payloads.RequestOptions.t()) :: boolean()
  def running_turn_request?(payload, request_options) when is_map(payload) do
    NativeTurnContinuation.compaction_request?(payload, request_options) or
      case NativeTurnContinuation.turn_role(payload) do
        {:post_compaction_resume, _anchor} -> true
        :tool_continuation -> payload |> Map.get("input") |> tool_result_after_last_user_message?()
        _opening -> false
      end
  end

  def running_turn_request?(_payload, _request_options), do: false

  defp tool_result_after_last_user_message?(input) when is_list(input) do
    input
    |> Enum.reverse()
    |> Enum.take_while(&(not user_message?(&1)))
    |> ToolResultShape.any?()
  end

  defp tool_result_after_last_user_message?(_input), do: false

  defp user_message?(%{"role" => "user"} = item), do: Map.get(item, "type", "message") == "message"
  defp user_message?(_item), do: false

  defp capped_candidate({assignment, identity} = candidate, %FilterInput{model: model}, %RouteState{} = route_state) do
    case usage_cap(identity, route_state) do
      nil ->
        []

      cap ->
        if bound_probe_candidate?(candidate, route_state.reset_probe) or Quota.reset_probe_candidate?(model, candidate, route_state),
          do: [],
          else: [{candidate, exclusion(assignment, identity, cap)}]
    end
  end

  # Saved-reset capacity is the request-compatible set before the session pin;
  # a capped sibling is no capacity, whether or not this request keeps it.
  defp uncapped_capacity(%RouteState{saved_reset_auto_capacity: capacity} = route_state),
    do: Enum.reject(capacity, fn {_assignment, identity} -> not is_nil(usage_cap(identity, route_state)) end)

  defp usage_cap(identity, route_state), do: route_state.quota_snapshots |> Map.get(identity.id) |> QuotaWindows.routing_usage_cap()

  defp bound_probe_candidate?({assignment, identity}, %ResetProbe{} = probe),
    do: ResetProbe.bound?(probe) and probe.pool_upstream_assignment_id == assignment.id and probe.upstream_identity_id == identity.id

  defp bound_probe_candidate?(_candidate, _probe), do: false

  defp exclusion(assignment, identity, cap) do
    %{
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      reasons: [
        %{
          "code" => "quota_window_unusable",
          "message" => "the operator usage cap of this account is reached until its capping window resets",
          "reason_codes" => @reason_codes,
          "quota_key" => "account",
          "quota_scope" => "account",
          "quota_family" => "account",
          "window_kind" => cap.window.window_kind,
          "window_minutes" => cap.window.window_minutes,
          "usage_cap_percent" => cap.cap_percent,
          "reset_at" => DateTime.to_iso8601(cap.reset_at)
        }
      ]
    }
  end
end
