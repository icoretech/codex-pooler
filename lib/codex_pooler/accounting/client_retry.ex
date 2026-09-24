defmodule CodexPooler.Accounting.ClientRetry do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey

  alias CodexPooler.Accounting.{
    Attempt,
    LedgerEntry,
    PreAttemptRelease,
    Request,
    RequestClientRetryLink,
    RequestReplayEntitlement
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Platform.ExecutionTerminalProofs
  alias CodexPooler.Repo

  @version 1
  @digest_bytes 32
  @max_done_count 65_535
  @successor_prefix "client-retry-v1:"
  @failed_predecessor_prefix "codex-request-retry:"
  @retry_window_seconds 30
  @max_chain_depth 16
  @task_exception_code "owner_task_exception"
  @pre_attempt_phase_key PreAttemptRelease.detail_key()
  @turn_interrupted_phase PreAttemptRelease.turn_interrupted()
  @stream_error_code "upstream_stream_error"
  @compaction_retry_window_seconds 330
  @authority_poison_reasons [:malformed_event, :unknown_completed_item, :unknown_response_event]
  # `DeliveryReceipt.resendable_frame_classes/0`, kept literal: accounting does
  # not reference the gateway receipt module at compile time.
  @resendable_frame_classes ~w(lifecycle item_added part_added delta)
  # `DeliveryReceipt.write_failures/0`, kept literal for the same reason.
  @write_failures ~w(timeout closed other)
  # How long after the provider's completion a failed downstream write may
  # still start the client-retry window (`retry_window_start/3`). A client that
  # stops reading without closing is noticed when a write times out: 30 s after
  # the stall with the listener's default send timeout, and the stall can come
  # after the provider finished while the socket was still writing the turn.
  # Four send timeouts cover that; a later failure starts the window here.
  @write_failure_window_start_limit_seconds 120

  defmodule SuccessorClaim do
    @moduledoc false
    @enforce_keys [
      :predecessor_request_id,
      :request,
      :codex_turn,
      :reservation,
      :pricing_snapshot,
      :pricing_status,
      :pricing_service_tier,
      :estimate,
      :link,
      :correlation_id,
      :dispatch_authority
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            predecessor_request_id: Ecto.UUID.t(),
            request: Request.t(),
            codex_turn: CodexTurn.t(),
            reservation: CodexPooler.Accounting.LedgerEntry.t(),
            pricing_snapshot: struct() | nil,
            pricing_status: atom(),
            pricing_service_tier: String.t() | nil,
            estimate: map(),
            link: RequestClientRetryLink.t(),
            correlation_id: String.t(),
            dispatch_authority: CodexPooler.Accounting.ClientRetry.DispatchAuthority.t()
          }
  end

  defmodule DispatchAuthority do
    @moduledoc false
    @enforce_keys [
      :version,
      :predecessor_request_id,
      :successor_request_id,
      :link_id,
      :successor_claim
    ]
    defstruct @enforce_keys ++ [:compaction_owner]

    @type t :: %__MODULE__{
            version: 1,
            predecessor_request_id: Ecto.UUID.t(),
            successor_request_id: Ecto.UUID.t(),
            link_id: Ecto.UUID.t(),
            successor_claim: String.t(),
            compaction_owner: %{owner_instance_id: String.t(), downstream_epoch: pos_integer()} | nil
          }
  end

  defmodule OriginalWitness do
    @moduledoc false
    @enforce_keys [:version, :digest, :auth_epoch]
    defstruct [:version, :digest, :auth_epoch, alternates: [], grown: []]

    # `alternates` never reaches a row: they are the digests the anchored
    # original of a full-history resend may have stored as `digest`
    # (`WebsocketTurnIdentity.replay_claim_alternates/2`), carried with the
    # resend so every predecessor check can recognise it (findings#232
    # row 232-160). `grown` never reaches a row either: the requests this one
    # can be the grown resend of, each named by the witness it would have
    # stored and the completed-item digests appended to it
    # (`WebsocketTurnIdentity.grown_resend_candidates/2`, row 232-232).
    @type grown_candidate :: %{
            required(:items) => [String.t()],
            required(:digest) => <<_::256>>,
            required(:alternates) => [<<_::256>>]
          }

    @type t :: %__MODULE__{
            version: pos_integer(),
            digest: <<_::256>>,
            auth_epoch: non_neg_integer(),
            alternates: [<<_::256>>],
            grown: [grown_candidate()]
          }
  end

  defmodule Observation do
    @moduledoc false
    defstruct version: 1,
              authority_complete?: false,
              authority_poisoned?: false,
              authority_poison_reason: nil,
              output_item_done_count: 0,
              output_item_done_count_saturated?: false,
              partial_reasoning_seen?: false,
              first_visible_at: nil,
              terminal_seen?: false,
              terminal_candidate_seen?: false

    @type poison_reason :: :malformed_event | :unknown_completed_item | :unknown_response_event

    @type t :: %__MODULE__{
            version: pos_integer(),
            authority_complete?: boolean(),
            authority_poisoned?: boolean(),
            authority_poison_reason: poison_reason() | nil,
            output_item_done_count: non_neg_integer(),
            output_item_done_count_saturated?: boolean(),
            partial_reasoning_seen?: boolean(),
            first_visible_at: DateTime.t() | nil,
            terminal_seen?: boolean(),
            terminal_candidate_seen?: boolean()
          }
  end

  defmodule NativeHttpProgress do
    @moduledoc false
    @enforce_keys [:version, :count, :digest]
    defstruct version: 1, count: 0, digest: nil

    @type t :: %__MODULE__{
            version: 1,
            count: non_neg_integer(),
            digest: <<_::256>>
          }
  end

  @type observation_metadata :: %{
          required(String.t()) => boolean() | non_neg_integer() | String.t() | nil
        }

  @type authority_loss_metadata :: %{
          required(String.t()) => pos_integer() | String.t()
        }

  @type reclaimable_successor :: %{
          request: Request.t(),
          turn: CodexTurn.t(),
          reservation: LedgerEntry.t(),
          link: RequestClientRetryLink.t()
        }

  @type eligible_predecessor :: %{
          request: Request.t(),
          turn: CodexTurn.t() | nil,
          attempt: Attempt.t() | nil,
          db_now: DateTime.t(),
          successor: reclaimable_successor() | nil,
          original: Request.t()
        }

  @spec original_witness(binary(), non_neg_integer(), [binary()], [OriginalWitness.grown_candidate()]) ::
          {:ok, OriginalWitness.t()} | {:error, :invalid_witness}
  def original_witness(digest, auth_epoch, alternates \\ [], grown \\ [])

  def original_witness(digest, auth_epoch, alternates, grown)
      when is_binary(digest) and byte_size(digest) == @digest_bytes and is_integer(auth_epoch) and
             auth_epoch >= 0 and is_list(alternates) and is_list(grown) do
    if Enum.all?(alternates, &digest?/1) and Enum.all?(grown, &grown_candidate?/1) do
      {:ok, %OriginalWitness{version: @version, digest: digest, auth_epoch: auth_epoch, alternates: alternates, grown: grown}}
    else
      {:error, :invalid_witness}
    end
  end

  def original_witness(_digest, _auth_epoch, _alternates, _grown), do: {:error, :invalid_witness}

  defp digest?(value), do: is_binary(value) and byte_size(value) == @digest_bytes

  defp grown_candidate?(%{items: [_first | _rest] = items, digest: digest, alternates: alternates}) when is_list(alternates),
    do: digest?(digest) and Enum.all?(alternates, &digest?/1) and Enum.all?(items, &is_binary/1)

  defp grown_candidate?(_candidate), do: false

  @doc """
  True when `stored` is the witness digest a predecessor recorded for the
  request `digest` and `alternates` describe: the same digest (a byte-identical
  resend), or one of the alternates (the full-history resend of an anchored
  request, findings#232 row 232-160).
  """
  @spec witness_matches?(term(), term(), term()) :: boolean()
  def witness_matches?(stored, digest, alternates)
      when is_binary(stored) and byte_size(stored) == @digest_bytes do
    secure_compare(stored, digest) or
      (is_list(alternates) and Enum.any?(alternates, &secure_compare(stored, &1)))
  end

  def witness_matches?(_stored, _digest, _alternates), do: false

  @spec original_witness!(binary(), non_neg_integer()) :: OriginalWitness.t()
  def original_witness!(digest, auth_epoch) do
    case original_witness(digest, auth_epoch) do
      {:ok, witness} -> witness
      {:error, :invalid_witness} -> raise ArgumentError, "invalid native client retry witness"
    end
  end

  @spec request_attrs(OriginalWitness.t() | term()) :: map()
  def request_attrs(%OriginalWitness{version: @version, digest: digest, auth_epoch: auth_epoch})
      when is_binary(digest) and byte_size(digest) == @digest_bytes and is_integer(auth_epoch) and
             auth_epoch >= 0 do
    %{
      native_client_retry_version: @version,
      native_client_retry_digest: digest,
      native_client_retry_auth_epoch: auth_epoch
    }
  end

  def request_attrs(_witness), do: %{}

  @spec original_witness_eligible?(Request.t()) :: boolean()
  def original_witness_eligible?(%Request{
        native_client_retry_version: @version,
        native_client_retry_digest: digest,
        native_client_retry_auth_epoch: auth_epoch
      })
      when is_binary(digest) and byte_size(digest) == @digest_bytes and is_integer(auth_epoch) and
             auth_epoch >= 0,
      do: true

  def original_witness_eligible?(%Request{}), do: false

  @spec completion_timestamp(Request.t(), DateTime.t()) :: DateTime.t()
  def completion_timestamp(%Request{} = request, fallback) do
    if original_witness_eligible?(request), do: db_now(), else: fallback
  end

  @spec reserved_successor_claim?(term()) :: boolean()
  def reserved_successor_claim?(value) when is_binary(value),
    do: String.starts_with?(value, @successor_prefix)

  def reserved_successor_claim?(_value), do: false

  @spec retry_window_seconds() :: pos_integer()
  def retry_window_seconds, do: @retry_window_seconds

  @doc """
  When the client-retry window of `request` starts, given its final attempt and
  the database's `now`: the request's `completed_at`, unless the attempt's
  delivery receipt says the downstream connection failed a write before the
  turn's terminal was written (`write_failure` with its `write_failed_at`).
  Then the window starts at that failure, at the earliest at `completed_at`
  and at the latest `#{@write_failure_window_start_limit_seconds}` s after it
  or at `now` (findings#232 row 232-261). A client that stops reading without
  closing is noticed only when a write times out, 30 s later with the default
  send timeout: the provider had long finished, and the resend the released
  client sends once its connection is gone always arrived after a window
  measured from the completion, although the receipt proves the turn was not
  delivered. Every other predecessor keeps the window from its completion.
  """
  @spec retry_window_start(Request.t(), Attempt.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def retry_window_start(%Request{completed_at: %DateTime{} = completed_at}, attempt, %DateTime{} = now) do
    case receipt_write_failed_at(attempt) do
      %DateTime{} = failed_at ->
        latest = earlier(DateTime.add(completed_at, @write_failure_window_start_limit_seconds, :second), now)
        failed_at |> earlier(latest) |> later(completed_at)

      nil ->
        completed_at
    end
  end

  def retry_window_start(%Request{completed_at: completed_at}, _attempt, _now), do: completed_at

  defp receipt_write_failed_at(%Attempt{
         response_metadata: %{"downstream_delivery" => %{"write_failure" => failure, "write_failed_at" => failed_at}}
       })
       when failure in @write_failures and is_binary(failed_at) and byte_size(failed_at) <= 64 do
    case DateTime.from_iso8601(failed_at) do
      {:ok, datetime, 0} -> datetime
      _invalid -> nil
    end
  end

  defp receipt_write_failed_at(_attempt), do: nil

  defp earlier(left, right), do: if(DateTime.compare(left, right) == :gt, do: right, else: left)
  defp later(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  @spec failed_predecessor_claim?(term()) :: boolean()
  def failed_predecessor_claim?(value) when is_binary(value),
    do: String.starts_with?(value, @failed_predecessor_prefix)

  def failed_predecessor_claim?(_value), do: false

  # A byte-identical websocket resend after a terminally failed predecessor is
  # recorded under a claim derived from the original request claim and the
  # predecessor request id, so concurrent duplicates of the same resend still
  # collapse on the request claim constraint and a later resend after the
  # retry itself fails chains from the retry request. The prefix is distinct
  # from `client-retry-v1:`, which keeps its own dispatch-authority contract.
  @spec deterministic_failed_predecessor_claim(String.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def deterministic_failed_predecessor_claim(original_claim, predecessor_request_id)
      when is_binary(original_claim) and original_claim != "" and
             is_binary(predecessor_request_id) do
    if uuid?(predecessor_request_id) do
      with {:ok, mac} <-
             AppSecretCrypto.hmac_digest(
               :erlang.term_to_binary(
                 {"codex_pooler.failed_predecessor_resend", 1, original_claim, predecessor_request_id},
                 [:deterministic]
               )
             ) do
        {:ok, @failed_predecessor_prefix <> Base.url_encode64(mac, padding: false)}
      end
    else
      {:error, :invalid_predecessor}
    end
  end

  def deterministic_failed_predecessor_claim(_original_claim, _predecessor_request_id),
    do: {:error, :invalid_predecessor}

  @spec dispatch_authority(Request.t(), Request.t(), RequestClientRetryLink.t()) ::
          DispatchAuthority.t()
  def dispatch_authority(predecessor, successor, link) do
    %DispatchAuthority{
      version: @version,
      predecessor_request_id: predecessor.id,
      successor_request_id: successor.id,
      link_id: link.id,
      successor_claim: successor.correlation_id,
      compaction_owner: compaction_dispatch_owner(successor)
    }
  end

  @spec validate_dispatch_authority(Request.t(), DispatchAuthority.t() | term()) ::
          :ok | {:error, :invalid_client_retry_dispatch_authority}
  def validate_dispatch_authority(
        %Request{} = request,
        %DispatchAuthority{
          version: @version,
          predecessor_request_id: predecessor_request_id,
          successor_request_id: successor_request_id,
          link_id: link_id,
          successor_claim: successor_claim
        } = authority
      ) do
    link =
      Repo.one(
        from link in RequestClientRetryLink,
          where: link.id == ^link_id and link.successor_request_id == ^request.id,
          lock: "FOR UPDATE"
      )

    if match?(
         %RequestClientRetryLink{
           predecessor_request_id: ^predecessor_request_id,
           successor_request_id: ^successor_request_id
         },
         link
       ) and successor_request_id == request.id and successor_claim == request.correlation_id and
         reserved_successor_claim?(request.correlation_id) and
         not original_witness_eligible?(request) and dispatch_owner_matches?(request, authority) do
      :ok
    else
      {:error, :invalid_client_retry_dispatch_authority}
    end
  end

  def validate_dispatch_authority(%Request{}, _authority),
    do: {:error, :invalid_client_retry_dispatch_authority}

  @spec dispatch_authority_shape?(term()) :: boolean()
  def dispatch_authority_shape?(%DispatchAuthority{} = authority) do
    authority.version == @version and uuid?(authority.predecessor_request_id) and
      uuid?(authority.successor_request_id) and uuid?(authority.link_id) and
      reserved_successor_claim?(authority.successor_claim) and
      compaction_owner_shape?(Map.get(authority, :compaction_owner))
  end

  def dispatch_authority_shape?(_authority), do: false

  defp compaction_dispatch_owner(%Request{
         correlation_id: @successor_prefix <> "compaction:" <> _,
         request_metadata: metadata
       }) do
    case Map.get(metadata, "websocket_owner_forwarding") do
      %{"owner_instance_id" => owner, "downstream_epoch" => epoch}
      when is_binary(owner) and is_integer(epoch) and epoch > 0 ->
        %{owner_instance_id: owner, downstream_epoch: epoch}

      _ ->
        nil
    end
  end

  defp compaction_dispatch_owner(_request), do: nil

  defp dispatch_owner_matches?(request, authority),
    do: Map.get(authority, :compaction_owner) == compaction_dispatch_owner(request)

  defp compaction_owner_shape?(nil), do: true

  defp compaction_owner_shape?(%{owner_instance_id: owner, downstream_epoch: epoch}),
    do: is_binary(owner) and byte_size(owner) > 0 and is_integer(epoch) and epoch > 0

  defp compaction_owner_shape?(_owner), do: false

  @spec validate_dispatch_attempt(term(), term(), DispatchAuthority.t() | term()) ::
          :ok | {:error, :stale_owner}
  def validate_dispatch_attempt(
        request_id,
        attempt_id,
        %DispatchAuthority{} = authority
      )
      when is_binary(request_id) and is_binary(attempt_id) do
    if authority_matches_request?(authority, request_id) and
         current_dispatch_attempt?(request_id, attempt_id, authority),
       do: :ok,
       else: {:error, :stale_owner}
  end

  def validate_dispatch_attempt(_request_id, _attempt_id, _authority),
    do: {:error, :stale_owner}

  defp authority_matches_request?(authority, request_id),
    do: authority.version == @version and authority.successor_request_id == request_id

  # The explicit conjunction is the cross-table dispatch fence; keeping every
  # bound row predicate in one query prevents a time-of-check/time-of-use gap.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp current_dispatch_attempt?(request_id, attempt_id, authority) do
    request =
      Repo.one(
        from request in Request,
          join: link in RequestClientRetryLink,
          on: link.successor_request_id == request.id,
          join: attempt in Attempt,
          on: attempt.request_id == request.id,
          where:
            request.id == ^request_id and request.status == "in_progress" and
              is_nil(request.completed_at) and
              request.correlation_id == ^authority.successor_claim and
              link.id == ^authority.link_id and
              link.predecessor_request_id == ^authority.predecessor_request_id and
              link.successor_request_id == ^authority.successor_request_id and
              attempt.id == ^attempt_id and attempt.attempt_number == 1 and
              attempt.replay_generation == 0 and attempt.status == "in_progress" and
              is_nil(attempt.completed_at),
          select: request
      )

    match?(%Request{}, request) and dispatch_owner_matches?(request, authority)
  end

  @spec deterministic_successor_claim(Request.t()) :: {:ok, String.t()} | {:error, atom()}
  def deterministic_successor_claim(%Request{id: request_id} = original),
    do: deterministic_successor_claim(original, request_id)

  # The claim of the successor chained onto `predecessor_request_id`: the
  # original request itself, or the last of its client-retry successors
  # (`lock_eligible_predecessor!/4`). Every hop is named by the original's
  # claim and witness, so concurrent resends of one hop collapse on one claim.
  @spec deterministic_successor_claim(Request.t(), Ecto.UUID.t()) :: {:ok, String.t()} | {:error, atom()}
  def deterministic_successor_claim(
        %Request{correlation_id: original_claim, native_client_retry_digest: digest},
        request_id
      )
      when is_binary(request_id) and is_binary(original_claim) and is_binary(digest) and
             byte_size(digest) == @digest_bytes do
    with {:ok, mac} <-
           AppSecretCrypto.hmac_digest(
             :erlang.term_to_binary(
               {"codex_pooler.client_retry_successor", 1, original_claim, request_id, digest},
               [:deterministic]
             )
           ) do
      {:ok, @successor_prefix <> Base.url_encode64(mac, padding: false)}
    end
  end

  def deterministic_successor_claim(%Request{}, _request_id), do: {:error, :missing_witness}

  @spec deterministic_compaction_successor_claim(Request.t(), CodexTurn.t(), binary()) ::
          {:ok, String.t()} | {:error, atom()}
  def deterministic_compaction_successor_claim(
        request,
        %CodexTurn{semantic_turn_digest: semantic},
        replay
      )
      when is_binary(semantic) and byte_size(semantic) == @digest_bytes and
             is_binary(replay) and byte_size(replay) == @digest_bytes do
    with {:ok, mac} <-
           AppSecretCrypto.hmac_digest(
             :erlang.term_to_binary(
               {"codex_pooler.compaction_retry_successor", 1, request.id, request.correlation_id, semantic, replay},
               [:deterministic]
             )
           ) do
      {:ok, @successor_prefix <> "compaction:" <> Base.url_encode64(mac, padding: false)}
    end
  end

  def deterministic_compaction_successor_claim(_request, _turn, _replay),
    do: {:error, :payload_mismatch}

  @spec preflight_snapshot(CodexSession.t(), APIKey.t(), CodexPooler.Catalog.Model.t(), map()) ::
          :none | {:ok, map()} | {:error, atom()}
  def preflight_snapshot(session, api_key, model, input) do
    input = Map.put(input, :defer_owner_idle_validation?, true)
    digest = Map.get(input, :semantic_turn_digest)

    existing_turn? = existing_turn_for_policy?(session, digest, input)

    if existing_turn? or not is_nil(claimed_original(session, api_key, input)) do
      case lock_eligible_predecessor!(session, api_key, model, input) do
        {:ok, %{request: request}} ->
          {:ok, %{replay_generation: 0, client_retry_predecessor_request_id: request.id}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :none
    end
  end

  @doc """
  The recorded rejection metadata of the failed attempt that ended the newest
  original request of this turn, when the resend described by `input` is that
  request (its witness matches) and the attempt recorded the provider status of
  a refusal (`rejection_upstream_status`); `:none` otherwise. The caller decides
  whether that refusal was final and answers the resend with it instead of
  `409 duplicate_turn` (findings#254 row 254-100). Read-only.

  A native HTTP turn stores no semantic digest of its own; it is found by its
  request's claim, the turn claim the resend derives (`codex-turn:`), and its
  attempt records the provider's response status as `status_code` beside the
  rejection fields instead (the HTTP metadata `/v1` shares, which must not
  change). A refused one is read with that status as its
  `rejection_upstream_status` and marked `rejection_predecessor_transport`
  `http`, for the caller to answer the HTTP resend of a finally refused HTTP
  turn instead of dispatching it again where that refusal must repeat
  (findings#254 row 254-141).
  """
  @spec final_refusal_predecessor(CodexSession.t(), map()) :: {:ok, map()} | :none
  def final_refusal_predecessor(%CodexSession{id: session_id}, input) when is_map(input) do
    digest = Map.get(input, :semantic_turn_digest)
    successor_pattern = @successor_prefix <> "%"

    with true <- is_binary(digest) and byte_size(digest) == @digest_bytes,
         turn_claim = "codex-turn:" <> Base.url_encode64(digest, padding: false),
         {%Request{status: "failed"} = request, attempt_id} when is_binary(attempt_id) <-
           Repo.one(
             from turn in CodexTurn,
               join: request in Request,
               on: request.id == turn.request_id,
               where:
                 turn.codex_session_id == ^session_id and
                   (turn.semantic_turn_digest == ^digest or request.correlation_id == ^turn_claim) and
                   not like(request.correlation_id, ^successor_pattern),
               order_by: [desc: turn.turn_sequence],
               limit: 1,
               select: {request, turn.final_attempt_id}
           ),
         :ok <- validate_original_witness(request, input),
         %Attempt{status: "failed"} = attempt <- Repo.one(from(attempt in Attempt, where: attempt.id == ^attempt_id and attempt.request_id == ^request.id)),
         {:ok, metadata} <- recorded_refusal_metadata(attempt) do
      {:ok, metadata}
    else
      _no_recorded_refusal -> :none
    end
  end

  defp recorded_refusal_metadata(%Attempt{response_metadata: %{"rejection_upstream_status" => status} = metadata}) when is_integer(status),
    do: {:ok, metadata}

  defp recorded_refusal_metadata(%Attempt{transport: transport, response_metadata: %{"status_code" => status, "rejection_error_type" => type} = metadata})
       when transport in ["http_sse", "http_json"] and is_integer(status) and status in 400..499 and status != 429 and is_binary(type),
       do: {:ok, Map.merge(metadata, %{"rejection_upstream_status" => status, "rejection_predecessor_transport" => "http"})}

  defp recorded_refusal_metadata(_attempt), do: :none

  defp existing_turn_for_policy?(session, digest, input)
       when is_binary(digest) and byte_size(digest) == @digest_bytes do
    query =
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session.id and turn.semantic_turn_digest == ^digest

    query =
      case input do
        %{retry_policy: :native_compaction} ->
          from turn in query,
            join: request in Request,
            on: request.id == turn.request_id,
            where: request.endpoint == "/backend-api/codex/responses/compact"

        _other_policy ->
          query
      end

    Repo.exists?(query)
  end

  defp existing_turn_for_policy?(_session, _digest, _input), do: false

  @spec lock_eligible_predecessor!(
          CodexSession.t(),
          APIKey.t(),
          CodexPooler.Catalog.Model.t(),
          map()
        ) ::
          {:ok, eligible_predecessor()} | {:error, atom()}
  def lock_eligible_predecessor!(
        %CodexSession{} = session,
        %APIKey{} = api_key,
        %CodexPooler.Catalog.Model{} = model,
        input
      )
      when is_map(input) do
    with :ok <- reject_anchor(input),
         {:ok, turn, request} <- lock_predecessor(session, api_key, input),
         attempt <- lock_attempt(if(turn, do: turn.final_attempt_id), request.id),
         owner_lease <- lock_owner_lease(session),
         lineage <- lock_lineage(request.id, input),
         entitlement <- lock_entitlement(request.id),
         :ok <- maybe_test_after_locks(input),
         db_now <- db_now(),
         :ok <-
           validate_locked_predecessor(
             session,
             api_key,
             model,
             turn,
             request,
             attempt,
             owner_lease,
             lineage,
             entitlement,
             input,
             db_now
           ),
         input <-
           Map.put(
             input,
             :reclaim_owner_validated?,
             reclaim_owner_valid?(session, owner_lease, input, db_now)
           ),
         :ok <- validate_no_turn_claim_successor(request, input),
         {:ok, successor} <- lock_compaction_successor(lineage, request, turn, input),
         {:ok, tail} <- lock_chain_tail(session, request, %{request: request, turn: turn, attempt: attempt}, lineage, input, db_now) do
      {:ok, %{request: tail.request, turn: tail.turn, attempt: tail.attempt, db_now: db_now, successor: successor, original: request}}
    else
      {:error, _reason} = error -> error
    end
  end

  # The native HTTP claim walk steps over a zero-output request of the turn and
  # serves the HTTPS fallback under the claim derived from it, without a link
  # (findings#212 row 212-50). With owner forwarding on, a websocket resend of
  # the same request afterwards met no link on the original and was admitted
  # again: the provider generated a turn the fallback had already served
  # (findings#206 row 206-538). A request holding that derived claim means the
  # turn went on under its turn claim, so the owner's preflight leaves it to
  # that chain (whose own walk refuses a served request).
  defp validate_no_turn_claim_successor(_request, %{retry_policy: :native_compaction}), do: :ok

  defp validate_no_turn_claim_successor(%Request{id: id, correlation_id: claim}, _input) do
    with {:ok, derived} <- deterministic_failed_predecessor_claim(claim, id),
         true <- Repo.exists?(from(request in Request, where: request.correlation_id == ^derived)) do
      {:error, :successor_claimed}
    else
      _no_turn_claim_successor -> :ok
    end
  end

  @doc """
  The state of the owner's client-retry chain behind `request`, for a native
  HTTP resend that is about to step over or chain onto it: `:none` when no
  `client-retry-v1:` successor follows it, `{:armed, tail_request_id}` when the
  last one holds an armed replay entitlement, `:live` when the last one is
  still running or its replay was consumed, `:settled` otherwise. Locks the
  rows it reads (findings#206 row 206-538).
  """
  @spec forwarded_chain_state(Request.t()) :: :none | :live | :settled | {:armed, Ecto.UUID.t()}
  def forwarded_chain_state(%Request{id: id}), do: forwarded_chain_state(id, 0)

  defp forwarded_chain_state(_request_id, depth) when depth > @max_chain_depth, do: :live

  defp forwarded_chain_state(request_id, depth) do
    successor_pattern = @successor_prefix <> "%"

    successor =
      Repo.one(
        from request in Request,
          join: link in RequestClientRetryLink,
          on: link.successor_request_id == request.id,
          where: link.predecessor_request_id == ^request_id and like(request.correlation_id, ^successor_pattern),
          lock: "FOR UPDATE OF r0"
      )

    case successor do
      nil when depth == 0 -> :none
      nil -> :settled
      %Request{} -> forwarded_tail_state(successor, depth)
    end
  end

  defp forwarded_tail_state(%Request{id: id} = successor, depth) do
    next? = Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^id))

    cond do
      next? -> forwarded_chain_state(id, depth + 1)
      match?(%RequestReplayEntitlement{status: "armed"}, lock_entitlement(id)) -> {:armed, id}
      successor.status in ["accepted", "in_progress"] or is_nil(successor.completed_at) -> :live
      true -> :settled
    end
  end

  # A turn's client-retry successor may itself be cut before any output
  # reached the client and settled with nothing armed: with owner forwarding
  # on, the owner could not suspend it into a replay (the arm's transaction
  # failed). That successor is a pre-visible disconnect like any other, and the
  # released client resends the turn once more. The original request's link
  # used to refuse that resend (`successor_claimed`, `409 duplicate_turn`) on
  # every websocket retry (findings#206 row 206-525). The resend now chains onto
  # the last successor under the same edge rule as the turn-claim chain
  # (`FailedPredecessorResend.chain_edges_only?/2`, row 206-519): every node
  # after the original must hold the claim derived for it from the original
  # and the node before it, share the original's scope and the session's turn,
  # be a verified retryable shape with no replay entitlement and nothing live,
  # and only the node the resend chains onto is held to the retry window. A
  # successor under any other claim, a live or served node, or an entitlement
  # keeps `successor_claimed`.
  defp lock_chain_tail(_session, _original, node, nil, _input, _db_now), do: {:ok, node}

  defp lock_chain_tail(_session, _original, node, _lineage, %{retry_policy: :native_compaction}, _db_now),
    do: {:ok, node}

  defp lock_chain_tail(session, original, node, %RequestClientRetryLink{successor_request_id: successor_id}, input, db_now),
    do: walk_chain(session, original, node.request, successor_id, input, db_now, 1)

  defp walk_chain(_session, _original, _previous, _successor_id, _input, _db_now, depth) when depth > @max_chain_depth,
    do: {:error, :retry_exhausted}

  defp walk_chain(session, original, previous, successor_id, input, db_now, depth) do
    request = lock_request!(successor_id)
    turn = Repo.one(from(turn in CodexTurn, where: turn.request_id == ^request.id, lock: "FOR UPDATE"))
    attempt = lock_attempt(if(turn, do: turn.final_attempt_id), request.id)

    # One successor per predecessor and one predecessor per successor
    # (`request_client_retry_links` is unique on each side), so the node's
    # only other link is to its own successor, which must hold the claim
    # derived for this node.
    next_id =
      Repo.one(
        from link in RequestClientRetryLink,
          where: link.predecessor_request_id == ^request.id,
          select: link.successor_request_id,
          lock: "FOR UPDATE"
      )

    with {:ok, claim} <- deterministic_successor_claim(original, previous.id),
         true <- request.correlation_id == claim,
         true <- chain_node_scoped?(request, original, turn, session, input),
         nil <- lock_entitlement(request.id),
         :ok <- validate_retry_lifecycle(turn, request, attempt),
         :ok <- validate_chain_tail_window(next_id, request, attempt, db_now) do
      if next_id,
        do: walk_chain(session, original, request, next_id, input, db_now, depth + 1),
        else: {:ok, %{request: request, turn: turn, attempt: attempt}}
    else
      {:error, :retry_expired} = expired -> expired
      _refused -> {:error, :successor_claimed}
    end
  end

  # Only the node the resend chains onto is held to the retry window.
  defp validate_chain_tail_window(nil, request, attempt, db_now),
    do: validate_retry_window(retry_window_start(request, attempt, db_now), db_now, @retry_window_seconds)

  defp validate_chain_tail_window(_next_id, _request, _attempt, _db_now), do: :ok

  defp chain_node_scoped?(request, original, %CodexTurn{} = turn, session, input) do
    Map.take(request, [:pool_id, :api_key_id, :model_id, :requested_model, :endpoint, :transport]) ==
      Map.take(original, [:pool_id, :api_key_id, :model_id, :requested_model, :endpoint, :transport]) and
      turn.codex_session_id == session.id and turn.semantic_turn_digest == Map.get(input, :semantic_turn_digest)
  end

  defp chain_node_scoped?(_request, _original, _turn, _session, _input), do: false

  defp lock_predecessor(session, api_key, input) do
    case claimed_original(session, api_key, input) do
      %Request{} = request ->
        {:ok, nil, lock_request!(request.id)}

      nil ->
        with {:ok, turn} <- lock_predecessor_turn(session.id, input) do
          {:ok, turn, lock_request!(turn.request_id)}
        end
    end
  end

  defp claimed_original(session, api_key, %{
         original_request_claim: claim,
         semantic_turn_digest: digest
       })
       when is_binary(claim) and is_binary(digest) and byte_size(digest) == @digest_bytes do
    if claim == "codex-turn:" <> Base.url_encode64(digest, padding: false) do
      Repo.one(
        from request in Request,
          left_join: turn in CodexTurn,
          on: turn.request_id == request.id,
          where:
            request.correlation_id == ^claim and request.api_key_id == ^api_key.id and
              request.pool_id == ^session.pool_id and is_nil(turn.id),
          select: request
      )
    end
  end

  defp claimed_original(_session, _api_key, _input), do: nil

  @spec insert_successor_turn!(CodexSession.t(), Request.t(), binary(), DateTime.t()) ::
          CodexTurn.t()
  def insert_successor_turn!(session, request, semantic_turn_digest, now) do
    sequence =
      Repo.one(
        from turn in CodexTurn,
          where: turn.codex_session_id == ^session.id,
          select: coalesce(max(turn.turn_sequence), 0)
      ) + 1

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: "websocket",
      semantic_turn_digest: semantic_turn_digest,
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })
  end

  @spec insert_link!(Request.t(), Request.t(), DateTime.t()) :: RequestClientRetryLink.t()
  def insert_link!(predecessor, successor, now) do
    %RequestClientRetryLink{}
    |> RequestClientRetryLink.changeset(%{
      predecessor_request_id: predecessor.id,
      successor_request_id: successor.id,
      created_at: now
    })
    |> Repo.insert!()
  end

  @spec create_link(Request.t(), Request.t(), DateTime.t()) ::
          {:ok, RequestClientRetryLink.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_link(%Request{} = predecessor, %Request{} = successor, %DateTime{} = created_at) do
    Repo.transaction(fn ->
      predecessor = lock_request!(predecessor.id)
      successor = lock_request!(successor.id)

      with :ok <- validate_link_requests(predecessor, successor),
           :ok <- validate_shared_session(predecessor.id, successor.id),
           {:ok, link} <-
             %RequestClientRetryLink{}
             |> RequestClientRetryLink.changeset(%{
               predecessor_request_id: predecessor.id,
               successor_request_id: successor.id,
               created_at: DateTime.truncate(created_at, :microsecond)
             })
             |> Repo.insert() do
        link
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, link} -> {:ok, link}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_link(_predecessor, _successor, _created_at), do: {:error, :invalid_link}

  @spec new_observation() :: Observation.t()
  def new_observation, do: %Observation{}

  @spec new_native_http_progress() :: NativeHttpProgress.t() | nil
  def new_native_http_progress do
    case native_http_progress_digest(<<0::256>>, :initial) do
      {:ok, digest} -> %NativeHttpProgress{version: 1, count: 0, digest: digest}
      {:error, _reason} -> nil
    end
  end

  @spec observe_native_http_output_item(NativeHttpProgress.t() | nil, term()) ::
          NativeHttpProgress.t() | nil
  def observe_native_http_output_item(%NativeHttpProgress{} = progress, %{} = item) do
    case native_http_progress_digest(progress.digest, item) do
      {:ok, digest} -> %{progress | count: progress.count + 1, digest: digest}
      {:error, _reason} -> nil
    end
  end

  def observe_native_http_output_item(_progress, _item), do: nil

  @spec native_http_progress_metadata(NativeHttpProgress.t() | nil) :: map()
  def native_http_progress_metadata(%NativeHttpProgress{version: 1, count: count, digest: digest})
      when is_integer(count) and count >= 0 and is_binary(digest) and byte_size(digest) == 32 do
    %{
      "version" => 1,
      "output_item_done_count" => count,
      "digest" => Base.url_encode64(digest, padding: false)
    }
  end

  def native_http_progress_metadata(_progress), do: %{}

  @spec native_http_progress_matches?(map() | term(), [term()]) :: boolean()
  def native_http_progress_matches?(
        %{
          "version" => 1,
          "output_item_done_count" => expected_count,
          "digest" => encoded_digest
        },
        items
      )
      when is_integer(expected_count) and expected_count >= 0 and is_binary(encoded_digest) and
             is_list(items) do
    with true <- length(items) == expected_count,
         {:ok, expected_digest} when byte_size(expected_digest) == 32 <-
           Base.url_decode64(encoded_digest, padding: false),
         %NativeHttpProgress{} = progress <- new_native_http_progress(),
         %NativeHttpProgress{} = observed <- observe_native_http_items(progress, items) do
      secure_compare(observed.digest, expected_digest)
    else
      _invalid -> false
    end
  end

  def native_http_progress_matches?(_metadata, _items), do: false

  defp observe_native_http_items(progress, items) do
    Enum.reduce_while(items, progress, fn item, acc ->
      case observe_native_http_output_item(acc, item) do
        %NativeHttpProgress{} = next -> {:cont, next}
        nil -> {:halt, nil}
      end
    end)
  end

  defp native_http_progress_digest(previous_digest, item)
       when is_binary(previous_digest) and byte_size(previous_digest) == 32 do
    AppSecretCrypto.hmac_digest(
      :erlang.term_to_binary(
        {"codex_pooler.native_http_progress", 1, previous_digest, normalize_native_http_progress_item(item)},
        [:deterministic]
      )
    )
  end

  # Codex stamps completed response items with local turn/create metadata before
  # rebuilding a retry prompt, and clears that metadata again for some provider
  # paths. It is not provider output and cannot decide whether the retry history
  # contains the item the Pooler delivered. Every substantive field remains in
  # the HMAC projection.
  defp normalize_native_http_progress_item(%{} = item),
    do: Map.delete(item, "internal_chat_message_metadata_passthrough")

  defp normalize_native_http_progress_item(item), do: item

  @spec observe_frame(Observation.t(), term(), DateTime.t()) :: Observation.t()
  def observe_frame(%Observation{} = observation, decoded, %DateTime{} = observed_at) do
    observation
    |> mark_first_visible(decoded, observed_at)
    |> observe_decoded_frame(decoded)
  end

  @spec complete_without_terminal(Observation.t()) :: Observation.t()
  def complete_without_terminal(%Observation{} = observation),
    do: %{observation | authority_complete?: true}

  # A lifecycle-only stream (nothing but `response.created`,
  # `response.in_progress`, `response.queued`, or `codex.*` frames before the
  # cut) never sets `first_visible_at`; its complete observation is persisted
  # with a null timestamp so the zero-output evidence is not dropped.
  @spec final_observation_metadata(Observation.t()) :: {:ok, observation_metadata()} | :ineligible
  def final_observation_metadata(
        %Observation{
          version: @version,
          authority_complete?: true,
          authority_poisoned?: false,
          first_visible_at: first_visible_at
        } = observation
      )
      when is_nil(first_visible_at) or is_struct(first_visible_at, DateTime) do
    {:ok,
     %{
       "version" => @version,
       "authority_complete" => true,
       "output_item_done_count" => observation.output_item_done_count,
       "output_item_done_count_saturated" => observation.output_item_done_count_saturated?,
       "partial_reasoning_seen" => observation.partial_reasoning_seen?,
       "first_visible_at" => first_visible_at_metadata(first_visible_at),
       "terminal_seen" => observation.terminal_seen?,
       "terminal_candidate_seen" => observation.terminal_candidate_seen?
     }}
  end

  def final_observation_metadata(%Observation{}), do: :ineligible

  # Why an observation lost its authority, kept separately from the witness it
  # is no longer allowed to be. A poisoned observation is omitted from the
  # attempt entirely today, so an operator reading a failed websocket turn
  # cannot tell a malformed frame from a response event this build does not
  # know yet. The reason travels under its own key, carries no
  # `authority_complete`, and no admission path reads it: it explains a
  # fail-closed decision, it never relaxes one.
  @spec authority_loss_metadata(Observation.t()) :: {:ok, authority_loss_metadata()} | :none
  def authority_loss_metadata(%Observation{
        version: @version,
        authority_poisoned?: true,
        authority_poison_reason: reason
      })
      when reason in @authority_poison_reasons do
    {:ok, %{"version" => @version, "authority_lost_reason" => Atom.to_string(reason)}}
  end

  def authority_loss_metadata(%Observation{}), do: :none

  @spec authority_poison_reasons() :: [Observation.poison_reason()]
  def authority_poison_reasons, do: @authority_poison_reasons

  defp first_visible_at_metadata(nil), do: nil
  defp first_visible_at_metadata(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # A verified lifecycle-only stream cut: the provider sent only lifecycle
  # frames before the connection closed under the receive loop, so no output
  # item, no reasoning, and no terminal reached the client. Turn, request, and
  # the generation-zero websocket attempt failed together with the stream
  # code, the complete observation proves the stream stayed lifecycle-only, and
  # the attempt carries the close evidence the partial-reasoning cut requires.
  @spec verified_lifecycle_cut?(term(), term(), term()) :: boolean()
  def verified_lifecycle_cut?(
        %CodexTurn{status: "failed", error_code: @stream_error_code, completed_at: %DateTime{}},
        %Request{
          status: "failed",
          last_error_code: @stream_error_code,
          completed_at: %DateTime{}
        },
        %Attempt{
          status: "failed",
          network_error_code: @stream_error_code,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata:
            %{
              "native_client_retry_observation" => %{
                "version" => @version,
                "authority_complete" => true,
                "output_item_done_count" => 0,
                "output_item_done_count_saturated" => false,
                "partial_reasoning_seen" => false,
                "first_visible_at" => nil,
                "terminal_seen" => false,
                "terminal_candidate_seen" => false
              }
            } = metadata
        }
      ),
      do: validate_close_evidence(metadata) == :ok

  def verified_lifecycle_cut?(_turn, _request, _attempt), do: false

  # The postvisible stream cut the client retry contract has always admitted:
  # visible output that was only partial reasoning, no completed output item,
  # no terminal, an authority-complete observation, and close evidence.
  @spec verified_partial_reasoning_cut?(term(), term(), term()) :: boolean()
  def verified_partial_reasoning_cut?(
        %CodexTurn{} = turn,
        %Request{} = request,
        %Attempt{} = attempt
      ) do
    with :ok <- validate_terminal_lifecycle(turn, request, attempt),
         :ok <- validate_observation(attempt.response_metadata) do
      validate_close_evidence(attempt.response_metadata) == :ok
    else
      {:error, _reason} -> false
    end
  end

  def verified_partial_reasoning_cut?(_turn, _request, _attempt), do: false

  defp observe_decoded_frame(observation, %{"type" => type} = decoded) when is_binary(type) do
    observation
    |> maybe_mark_partial_reasoning(type)
    |> maybe_count_completed_item(type, decoded)
    |> maybe_mark_terminal(type)
    |> maybe_poison_unknown_response_event(type)
  end

  defp observe_decoded_frame(observation, _decoded),
    do: poison_authority(observation, :malformed_event)

  defp mark_first_visible(%Observation{first_visible_at: nil} = observation, decoded, observed_at) do
    if visible_frame?(decoded),
      do: %{observation | first_visible_at: DateTime.truncate(observed_at, :microsecond)},
      else: observation
  end

  defp mark_first_visible(observation, _decoded, _observed_at), do: observation

  defp visible_frame?(%{"type" => type})
       when type in ["response.created", "response.in_progress", "response.queued"],
       do: false

  defp visible_frame?(%{"type" => type}) when is_binary(type),
    do: not String.starts_with?(type, "codex.")

  defp visible_frame?(_decoded), do: false

  defp maybe_mark_partial_reasoning(observation, type)
       when type in [
              "response.reasoning_text.delta",
              "response.reasoning_summary.delta",
              "response.reasoning_summary_text.delta"
            ],
       do: %{observation | partial_reasoning_seen?: true}

  defp maybe_mark_partial_reasoning(observation, _type), do: observation

  defp maybe_count_completed_item(observation, "response.output_item.done", %{
         "item" => %{"type" => item_type}
       })
       when item_type in [
              "message",
              "reasoning",
              "function_call",
              "custom_tool_call",
              "local_shell_call",
              "computer_call",
              "web_search_call",
              "file_search_call",
              "code_interpreter_call",
              "image_generation_call",
              "mcp_call",
              "mcp_list_tools"
            ],
       do: increment_done_count(observation)

  defp maybe_count_completed_item(observation, "response.output_item.done", _decoded),
    do: observation |> increment_done_count() |> poison_authority(:unknown_completed_item)

  defp maybe_count_completed_item(observation, _type, _decoded), do: observation

  defp increment_done_count(%Observation{output_item_done_count: @max_done_count} = observation),
    do: %{observation | output_item_done_count_saturated?: true}

  defp increment_done_count(%Observation{output_item_done_count: count} = observation),
    do: %{observation | output_item_done_count: count + 1}

  defp maybe_mark_terminal(observation, type)
       when type in [
              "response.completed",
              "response.done",
              "response.failed",
              "response.incomplete",
              "error"
            ],
       do: %{observation | terminal_seen?: true, terminal_candidate_seen?: true}

  defp maybe_mark_terminal(observation, _type), do: observation

  defp maybe_poison_unknown_response_event(observation, "response.output_item.done"),
    do: observation

  defp maybe_poison_unknown_response_event(observation, "response." <> _suffix = type) do
    if known_response_type?(type),
      do: observation,
      else: poison_authority(observation, :unknown_response_event)
  end

  defp maybe_poison_unknown_response_event(observation, _type), do: observation

  # Authority is lost once. The first frame that poisons an observation is the
  # one that explains the loss; later frames on an already poisoned stream
  # describe consequences, so the first reason wins.
  @spec poison_authority(Observation.t(), Observation.poison_reason()) :: Observation.t()
  defp poison_authority(%Observation{authority_poisoned?: true} = observation, _reason),
    do: observation

  defp poison_authority(%Observation{} = observation, reason)
       when reason in @authority_poison_reasons,
       do: %{observation | authority_poisoned?: true, authority_poison_reason: reason}

  defp known_response_type?(type) do
    type in [
      "response.created",
      "response.in_progress",
      "response.queued",
      "response.completed",
      "response.done",
      "response.failed",
      "response.incomplete",
      "response.output_item.added",
      "response.output_text.delta",
      "response.output_text.done",
      "response.output_text.annotation.added",
      "response.content_part.added",
      "response.content_part.done",
      "response.reasoning",
      "response.reasoning_text.delta",
      "response.reasoning_text.done",
      "response.reasoning_summary.delta",
      "response.reasoning_summary.done",
      "response.reasoning_summary_text.delta",
      "response.reasoning_summary_text.done",
      "response.reasoning_summary_part.added",
      "response.reasoning_summary_part.done",
      "response.refusal.delta",
      "response.refusal.done",
      "response.function_call_arguments.delta",
      "response.function_call_arguments.done",
      "response.custom_tool_call_input.delta",
      "response.custom_tool_call_input.done"
    ]
  end

  defp lock_request!(request_id) do
    Repo.one!(from request in Request, where: request.id == ^request_id, lock: "FOR UPDATE")
  end

  defp reject_anchor(input) do
    if Map.get(input, :anchor_present?) == true, do: {:error, :anchor_unavailable}, else: :ok
  end

  defp lock_predecessor_turn(session_id, input) do
    digest = Map.get(input, :semantic_turn_digest)

    if is_binary(digest) and byte_size(digest) == @digest_bytes do
      query =
        from turn in CodexTurn,
          where: turn.codex_session_id == ^session_id and turn.semantic_turn_digest == ^digest,
          limit: 1,
          lock: "FOR UPDATE"

      case lock_predecessor_turn_row(query, input) do
        %CodexTurn{} = turn -> {:ok, resolve_predecessor_turn(turn, input)}
        nil -> {:error, :terminal_predecessor}
      end
    else
      {:error, :payload_mismatch}
    end
  end

  defp lock_predecessor_turn_row(query, %{retry_policy: :native_compaction}),
    do: Repo.one(from(turn in query, order_by: [desc: turn.turn_sequence]))

  # Every tool continuation of one user turn shares the semantic digest, so the
  # client retry policy judges the newest original request of that turn rather
  # than its long-settled first request. A claimed successor is consulted only
  # when no original turn exists, so lineage and reserved-claim rejections keep
  # their vocabulary and a successor never becomes its own predecessor.
  defp lock_predecessor_turn_row(query, _input) do
    successor_pattern = @successor_prefix <> "%"

    original_query =
      from turn in query,
        join: request in Request,
        on: request.id == turn.request_id,
        where: not like(request.correlation_id, ^successor_pattern),
        order_by: [desc: turn.turn_sequence]

    Repo.one(original_query) ||
      Repo.one(from(turn in query, order_by: [desc: turn.turn_sequence]))
  end

  defp resolve_predecessor_turn(turn, %{retry_policy: :native_compaction}) do
    # A claimed successor may be reclaimed, but a newer unrelated turn must
    # never let this lookup revive an older eligible compaction.
    Repo.one(
      from predecessor in CodexTurn,
        join: link in RequestClientRetryLink,
        on: link.predecessor_request_id == predecessor.request_id,
        where:
          link.successor_request_id == ^turn.request_id and
            predecessor.codex_session_id == ^turn.codex_session_id and
            predecessor.semantic_turn_digest == ^turn.semantic_turn_digest and
            predecessor.turn_sequence < ^turn.turn_sequence,
        select: predecessor,
        lock: "FOR UPDATE OF c0"
    ) || turn
  end

  defp resolve_predecessor_turn(turn, _input), do: turn

  defp lock_attempt(attempt_id, request_id) when is_binary(attempt_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.id == ^attempt_id and attempt.request_id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_attempt(_attempt_id, _request_id), do: nil

  # The locked lifecycle is deliberately passed as one immutable validation snapshot.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp validate_locked_predecessor(
         session,
         api_key,
         model,
         turn,
         request,
         attempt,
         owner_lease,
         lineage,
         entitlement,
         input,
         db_now
       ) do
    with :ok <- validate_authorization(session, api_key, model, request, input),
         {:ok, witness_match} <- validate_policy_witness(request, input),
         :ok <- validate_original_claim(request),
         :ok <- maybe_validate_owner_idle(session, owner_lease, input, db_now),
         :ok <- validate_policy_lineage(lineage, request.id, input),
         :ok <- validate_no_entitlement(entitlement),
         :ok <- validate_retry_lifecycle_for_policy(turn, request, attempt, input, witness_match) do
      window =
        if input[:retry_policy] == :native_compaction,
          do: @compaction_retry_window_seconds,
          else: @retry_window_seconds

      # A request with an admitted successor is passed through by the chain
      # walk (`lock_chain_tail/6`), which holds the node it chains onto to the
      # window instead.
      if chained_successor?(lineage, request.id, input),
        do: :ok,
        else: validate_retry_window(retry_window_start(request, attempt, db_now), db_now, window)
    end
  end

  defp chained_successor?(%RequestClientRetryLink{predecessor_request_id: request_id}, request_id, input),
    do: input[:retry_policy] != :native_compaction

  defp chained_successor?(_lineage, _request_id, _input), do: false

  defp validate_policy_witness(_request, %{
         retry_policy: :native_compaction,
         full_history?: true,
         compaction_trigger_bridge?: true,
         anchor_present?: false
       }),
       do: {:ok, :exact}

  defp validate_policy_witness(_request, %{retry_policy: :native_compaction}),
    do: {:error, :missing_witness}

  defp validate_policy_witness(request, input), do: validate_resend_witness(request, input)

  # The request itself (`:exact`), or the grown resend of it: the predecessor's
  # witness names the resend without its trailing items, which must then be the
  # completed items its receipt proves were pushed (findings#232 row 232-232).
  defp validate_resend_witness(request, input) do
    case validate_original_witness(request, input) do
      :ok ->
        {:ok, :exact}

      {:error, :payload_mismatch} = mismatch ->
        case grown_witness_candidates(request, Map.get(input, :grown_resend_candidates, [])) do
          [] -> mismatch
          candidates -> {:ok, {:grown, candidates}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_retry_lifecycle_for_policy(turn, request, attempt, %{retry_policy: :native_compaction}, _witness_match) do
    if verified_compaction_execution_failure?(turn, request, attempt) or verified_unreceived_compaction?(turn, request, attempt),
      do: :ok,
      else: validate_compaction_lifecycle(turn, request, attempt)
  end

  defp validate_retry_lifecycle_for_policy(turn, request, attempt, _input, {:grown, candidates}) do
    if verified_completed_item_resend?(turn, request, attempt, candidates),
      do: :ok,
      else: {:error, :terminal_predecessor}
  end

  defp validate_retry_lifecycle_for_policy(turn, request, attempt, _input, :exact),
    do: validate_retry_lifecycle(turn, request, attempt)

  # Local execution failures carry no provider terminal. Compaction still
  # requires an unseen compact response; ordinary turn retries allow visible
  # output and must not broaden this policy through their shared matchers.
  defp verified_compaction_execution_failure?(
         %CodexTurn{first_visible_output_at: nil} = turn,
         %Request{endpoint: "/backend-api/codex/responses/compact"} = request,
         %Attempt{usage_status: "usage_unknown"} = attempt
       ) do
    verified_task_exception?(turn, request, attempt) or
      verified_dead_execution?(turn, request, attempt)
  end

  defp verified_compaction_execution_failure?(_turn, _request, _attempt), do: false

  defp validate_compaction_lifecycle(
         %CodexTurn{
           status: turn_status,
           error_code: error,
           transport_kind: "websocket",
           first_visible_output_at: nil,
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           last_error_code: error,
           endpoint: "/backend-api/codex/responses/compact",
           completed_at: %DateTime{}
         },
         %Attempt{
           status: "failed",
           network_error_code: error,
           transport: "websocket",
           replay_generation: 0,
           completed_at: %DateTime{}
         }
       )
       when turn_status in ["failed", "interrupted"] and
              error in ["upstream_stream_error", "client_disconnected", "owner_drained"] do
    :ok
  end

  defp validate_compaction_lifecycle(
         %CodexTurn{
           status: "failed",
           error_code: error,
           transport_kind: "websocket",
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           last_error_code: error,
           endpoint: "/backend-api/codex/responses/compact",
           completed_at: %DateTime{}
         },
         %Attempt{
           status: "failed",
           network_error_code: error,
           transport: "websocket",
           replay_generation: 0,
           completed_at: %DateTime{},
           response_metadata: %{"stream_terminal_type" => terminal_type}
         }
       ) do
    if ErrorCodes.codex_compaction_terminal_retryable?(terminal_type, error),
      do: :ok,
      else: {:error, :terminal_predecessor}
  end

  defp validate_compaction_lifecycle(_turn, _request, _attempt),
    do: {:error, :terminal_predecessor}

  defp validate_retry_lifecycle(turn, request, %Attempt{} = attempt) do
    if verified_retry_shape?(turn, request, attempt) do
      :ok
    else
      with :ok <- validate_terminal_lifecycle(turn, request, attempt),
           :ok <- validate_observation(attempt.response_metadata) do
        validate_close_evidence(attempt.response_metadata)
      end
    end
  end

  defp validate_retry_lifecycle(nil, request, nil) do
    if verified_claim_only_drain?(request) and
         not Repo.exists?(from turn in CodexTurn, where: turn.request_id == ^request.id) and
         not Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^request.id) and
         not Repo.exists?(from entry in LedgerEntry, where: entry.request_id == ^request.id) do
      :ok
    else
      {:error, :terminal_predecessor}
    end
  end

  defp validate_retry_lifecycle(turn, request, nil) do
    if verified_pre_attempt_drain?(turn, request) and
         not Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^request.id) and
         released_without_settlement?(request.id) do
      :ok
    else
      {:error, :terminal_predecessor}
    end
  end

  # Each predicate matches exactly one settled shape its own finalization writes.
  defp verified_retry_shape?(turn, request, attempt) do
    Enum.any?(
      [
        &verified_task_exception?/3,
        &verified_dead_execution?/3,
        &verified_proven_owner_crash?/3,
        &verified_provider_terminal_failure?/3,
        &verified_latest_quota_rejection?/3,
        &verified_lifecycle_cut?/3,
        &verified_previsible_disconnect?/3,
        &verified_undelivered_completion?/3,
        &verified_undelivered_partial_output?/3
      ],
      & &1.(turn, request, attempt)
    )
  end

  defp verified_latest_quota_rejection?(turn, request, attempt),
    do: verified_quota_rejection?(turn, request, attempt) and latest_attempt?(attempt)

  # Only the response task's own exception finalization writes this exact
  # shape (turn, request, and attempt failed together with the health-neutral
  # reason and a 500). The upstream never reported a terminal for it, so the
  # client's byte-identical resend is admitted as one successor instead of
  # meeting `duplicate_turn` until the turn is abandoned.
  defp verified_task_exception?(
         %CodexTurn{
           status: "failed",
           error_code: @task_exception_code,
           final_attempt_id: attempt_id,
           transport_kind: "websocket",
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           response_status_code: 500,
           last_error_code: @task_exception_code,
           usage_status: "usage_unknown",
           completed_at: %DateTime{}
         },
         %Attempt{
           id: attempt_id,
           status: "failed",
           network_error_code: @task_exception_code,
           transport: "websocket",
           replay_generation: 0,
           completed_at: %DateTime{}
         }
       )
       when is_binary(attempt_id),
       do: true

  defp verified_task_exception?(_turn, _request, _attempt), do: false

  @doc false
  @spec verified_dead_execution?(term(), term(), term()) :: boolean()
  def verified_dead_execution?(
        %CodexTurn{
          status: "interrupted",
          error_code: "dead_execution_recovered",
          final_attempt_id: attempt_id,
          transport_kind: "websocket",
          completed_at: %DateTime{}
        },
        %Request{
          status: "failed",
          response_status_code: 499,
          last_error_code: "dead_execution_recovered",
          usage_status: "usage_unknown",
          completed_at: %DateTime{}
        },
        %Attempt{
          id: attempt_id,
          status: "failed",
          network_error_code: "dead_execution_recovered",
          transport: "websocket",
          replay_generation: 0,
          usage_status: "usage_unknown",
          owner_instance_id: owner,
          owner_instance_boot_id: boot,
          owner_process_id: pid,
          owner_execution_id: execution,
          completed_at: %DateTime{}
        }
      )
      when is_binary(attempt_id) and is_binary(owner) and is_binary(boot) and is_binary(pid) and
             is_binary(execution),
      do: true

  def verified_dead_execution?(_turn, _request, _attempt), do: false

  # Owner-forwarded cleanup can commit milliseconds before the one-second
  # terminal-proof publisher reaches PostgreSQL. The row then carries the
  # generic owner_crashed reason even though exact executor death becomes
  # durable immediately afterwards. Admit only that exact generation-zero
  # shape, and only while the matching proof still exists; the existing sealed
  # payload witness, authorization, session, lineage and retry-window checks
  # remain mandatory around this predicate.
  defp verified_proven_owner_crash?(
         %CodexTurn{
           status: "interrupted",
           error_code: "owner_crashed",
           final_attempt_id: attempt_id,
           transport_kind: "websocket",
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           response_status_code: 499,
           last_error_code: "owner_crashed",
           usage_status: "usage_unknown",
           completed_at: %DateTime{}
         },
         %Attempt{
           id: attempt_id,
           status: "failed",
           network_error_code: "owner_crashed",
           transport: "websocket",
           replay_generation: 0,
           usage_status: "usage_unknown",
           completed_at: %DateTime{}
         } = attempt
       )
       when is_binary(attempt_id),
       do: ExecutionTerminalProofs.terminal?(attempt)

  defp verified_proven_owner_crash?(_turn, _request, _attempt), do: false

  # Only the provider's own terminal failure finalization writes this shape:
  # turn, request, and attempt failed together with the same provider code on
  # the generation-zero websocket attempt. The provider already ended the
  # response, so the client's byte-identical resend is admitted as one
  # successor instead of meeting `duplicate_turn` for the whole user turn. The
  # vocabulary is the retryable first-event set (server errors and overload),
  # never policy, quota, or auth codes that a resend would only repeat. The
  # owner's client-retry preflight asks it, and so does the turn-claim resend
  # path with owner forwarding off (`FailedPredecessorResend`, findings#121
  # variant B, findings#232 row 232-280).
  @doc false
  @spec verified_provider_terminal_failure?(term(), term(), term()) :: boolean()
  def verified_provider_terminal_failure?(
        %CodexTurn{
          status: "failed",
          error_code: code,
          final_attempt_id: attempt_id,
          transport_kind: "websocket",
          completed_at: %DateTime{}
        },
        %Request{
          status: "failed",
          last_error_code: code,
          completed_at: %DateTime{}
        },
        %Attempt{
          id: attempt_id,
          status: "failed",
          network_error_code: code,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{}
        }
      )
      when is_binary(attempt_id) and is_binary(code),
      do: ErrorCodes.retryable_first_event_code?(code)

  def verified_provider_terminal_failure?(_turn, _request, _attempt), do: false

  @doc false
  @spec verified_quota_rejection?(term(), term(), term()) :: boolean()
  # Only the native receive classifier writes the marker after proving no
  # provider output and absent or zero usage. A quota code alone is insufficient.
  def verified_quota_rejection?(
        %CodexTurn{
          request_id: request_id,
          status: "failed",
          error_code: code,
          final_attempt_id: attempt_id,
          transport_kind: "websocket",
          first_visible_output_at: nil,
          completed_at: %DateTime{}
        },
        %Request{
          id: request_id,
          status: "failed",
          last_error_code: code,
          transport: "websocket",
          completed_at: %DateTime{}
        },
        %Attempt{
          id: attempt_id,
          request_id: request_id,
          status: "failed",
          network_error_code: code,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata: %{"quota_rejection_before_output" => true}
        }
      )
      when is_binary(request_id) and is_binary(attempt_id) and
             code in ["usage_limit_reached", "usage_limit_exceeded"],
      do: true

  def verified_quota_rejection?(_turn, _request, _attempt), do: false

  @doc """
  A native websocket turn whose anchored request was refused because its
  connection cannot resolve `previous_response_id` (the provider's refusal, or
  the Pooler's connection-bound guard), which the attempt records as
  `upstream_error_code` `previous_response_not_found` and the client read as
  its signal to resend the full request without the anchor. The refusal is the
  only frame its socket pushed (`downstream_delivery`: one frame, the
  terminal; `aborted` when the client closed the socket right after it, as the
  released client does before it resends), so nothing was generated or shown,
  and that resend is admitted as one successor. `FailedPredecessorResend` refuses an anchored resend before
  this is asked. Only the ordinary Responses route, generation zero
  (findings#232 row 232-278).
  """
  @spec verified_previous_response_miss?(term(), term(), term()) :: boolean()
  def verified_previous_response_miss?(
        %CodexTurn{status: "failed", error_code: code, final_attempt_id: attempt_id, transport_kind: "websocket", completed_at: %DateTime{}},
        %Request{status: "failed", last_error_code: code, transport: "websocket", endpoint: "/backend-api/codex/responses", completed_at: %DateTime{}},
        %Attempt{
          id: attempt_id,
          status: "failed",
          network_error_code: code,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata: %{
            "upstream_error_code" => "previous_response_not_found",
            "downstream_delivery" => %{"outcome" => outcome, "terminal_class" => "error", "highest_frame_class" => "terminal", "frames_after_visible" => 1}
          }
        }
      )
      when is_binary(attempt_id) and code == "stream_incomplete" and outcome in ["delivered", "aborted"],
      do: true

  def verified_previous_response_miss?(_turn, _request, _attempt), do: false

  # A websocket turn whose client left before any output reached it and that
  # the owner never armed for replay (the entitlement check around this
  # predicate refuses an armed one). Owner forwarding produces it when the
  # owner had accepted nothing of the closing downstream and refused its task's
  # later submission `client_disconnected` before any dispatch, or when a
  # pre-visible suspension could not arm; the resend is the same request the
  # provider never answered, so it is admitted as one successor, the rule
  # `FailedPredecessorResend` applies to the same shape with forwarding off
  # (findings#232 rows 232-112, 232-171 and 232-175). The turn row is
  # authoritative for visibility: the Pooler stamps `first_visible_output_at`
  # before it writes any provider event to the client. Only the ordinary
  # Responses route: a native compaction keeps its own retry policy.
  defp verified_previsible_disconnect?(
         %CodexTurn{
           status: "interrupted",
           error_code: "client_disconnected",
           final_attempt_id: attempt_id,
           transport_kind: "websocket",
           first_visible_output_at: nil,
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           last_error_code: "client_disconnected",
           transport: "websocket",
           endpoint: "/backend-api/codex/responses",
           completed_at: %DateTime{}
         },
         %Attempt{
           id: attempt_id,
           status: "failed",
           network_error_code: "client_disconnected",
           transport: "websocket",
           replay_generation: 0,
           completed_at: %DateTime{}
         }
       )
       when is_binary(attempt_id),
       do: true

  defp verified_previsible_disconnect?(_turn, _request, _attempt), do: false

  @doc """
  A native websocket compaction that ended before its client completed it: the
  provider finished it and the Pooler billed it, or the client left while the
  Pooler was still collecting it (`client_disconnected`, whatever the turn's
  `first_visible_output_at` says: the Pooler stamps it when it starts
  collecting, but writes the client nothing of a native compaction before its
  terminal). The released client resends a remote compaction only when it did
  not read its `response.completed`, and advances `x-codex-window-id` after
  every compaction it completes, so a resend under the compaction claim
  (which binds the window) is proof the reply was lost. It used to be refused
  `409` twice and then bought again, unchained, by the client's HTTPS
  fallback; it is admitted as one successor with its own single settlement,
  like an undelivered completion (findings#206 rows 206-330 and 206-332,
  precedent row 232-201). Only the compact route, generation zero.
  """
  @spec verified_unreceived_compaction?(term(), term(), term()) :: boolean()
  def verified_unreceived_compaction?(
        %CodexTurn{final_attempt_id: attempt_id, transport_kind: "websocket", completed_at: %DateTime{}} = turn,
        %Request{transport: "websocket", endpoint: "/backend-api/codex/responses/compact", completed_at: %DateTime{}} = request,
        %Attempt{id: attempt_id, transport: "websocket", replay_generation: 0, completed_at: %DateTime{}} = attempt
      )
      when is_binary(attempt_id),
      do: unreceived_compaction_settlement?(turn, request, attempt)

  # The same compaction over native HTTP, which the released client uses for the
  # rest of a session once a websocket request fell back to HTTPS: it retries a
  # remote compaction whose `response.completed` it never read with the same
  # prompt, up to twice (`compact_remote_v2.rs` `run_remote_compaction_request_v2`,
  # `MAX_REMOTE_COMPACTION_V2_STREAM_RETRIES`), and three refusals fail the turn
  # and lose the compaction. The HTTP compaction claim is its own domain over the
  # compacted payload, and a completed compaction replaces the history the next
  # one would be built from, so the claim is only ever met again by a resend of
  # a compaction the client did not complete (findings#206 row 206-404).
  def verified_unreceived_compaction?(
        %CodexTurn{final_attempt_id: attempt_id, transport_kind: turn_transport, completed_at: %DateTime{}} = turn,
        %Request{
          transport: transport,
          request_metadata: %{"native_http_claim_arm" => "compaction"},
          completed_at: %DateTime{}
        } = request,
        %Attempt{id: attempt_id, replay_generation: 0, completed_at: %DateTime{}} = attempt
      )
      when is_binary(attempt_id) and turn_transport in ["http_json", "http_sse"] and
             transport in ["http_json", "http_sse", "http_compact_json"],
      do: unreceived_compaction_settlement?(turn, request, attempt)

  def verified_unreceived_compaction?(_turn, _request, _attempt), do: false

  defp unreceived_compaction_settlement?(%CodexTurn{status: "succeeded"}, %Request{status: "succeeded"}, %Attempt{status: "succeeded"}), do: true

  defp unreceived_compaction_settlement?(
         %CodexTurn{status: "interrupted", error_code: "client_disconnected"},
         %Request{status: "failed", last_error_code: "client_disconnected"},
         %Attempt{status: "failed", network_error_code: "client_disconnected"}
       ),
       do: true

  defp unreceived_compaction_settlement?(_turn, _request, _attempt), do: false

  @doc """
  A native websocket turn the provider completed while its client was already
  gone: the socket that carried it acknowledged it aborted and pushed nothing of
  it, not even a lifecycle event (`downstream_delivery` outcome `aborted`,
  terminal class `none`, zero frames). The answer was billed but the client saw
  nothing and resends the same request; refusing that resend failed the turn on
  every retry and then over HTTPS (findings#232 row 232-201, production and the
  released Codex 0.156.1 locally). It is admitted as one successor, a new
  dispatch as a direct connection would make, and each request keeps its own
  single settlement. Only the ordinary Responses route; a push of any frame,
  even one the client may not have received, keeps the fence (row 232-203).
  """
  @spec verified_undelivered_completion?(term(), term(), term()) :: boolean()
  def verified_undelivered_completion?(
        %CodexTurn{
          status: "succeeded",
          final_attempt_id: attempt_id,
          transport_kind: "websocket",
          completed_at: %DateTime{}
        },
        %Request{
          status: "succeeded",
          transport: "websocket",
          endpoint: "/backend-api/codex/responses",
          completed_at: %DateTime{}
        },
        %Attempt{
          id: attempt_id,
          status: "succeeded",
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata: %{
            "downstream_delivery" => %{"outcome" => "aborted", "terminal_class" => "none", "frames_after_visible" => 0}
          }
        }
      )
      when is_binary(attempt_id),
      do: true

  def verified_undelivered_completion?(_turn, _request, _attempt), do: false

  @doc """
  A native websocket turn whose socket pushed the client nothing beyond
  lifecycle frames, the opening of an output item or of a content/summary part
  and deltas before the client left (`downstream_delivery` outcome `aborted`,
  terminal class `none`, `highest_frame_class` one of
  `DeliveryReceipt.resendable_frame_classes/0`). The released Codex client
  treats such a turn as not received: it discards the partial output and
  resends the identical request, and nothing it was shown completed an item or
  ran a tool (findings#232 row 232-203, measured with Codex 0.156.1; a direct
  provider serves that resend). The turn either settled `client_disconnected`
  after its output became visible (the owner, or the closing socket, stopped
  its generation) or the provider completed it after the client left; either
  way the resend is admitted as one successor, a new dispatch with its own
  single settlement. A pushed `response.output_item.done`, a terminal, or a
  frame the classification does not know keeps the fence, and so does a
  receipt without the field (written before it existed). Only the ordinary
  Responses route, generation zero.
  """
  @spec verified_undelivered_partial_output?(term(), term(), term()) :: boolean()
  def verified_undelivered_partial_output?(
        %CodexTurn{final_attempt_id: attempt_id, transport_kind: "websocket", completed_at: %DateTime{}} = turn,
        %Request{transport: "websocket", endpoint: "/backend-api/codex/responses", completed_at: %DateTime{}} = request,
        %Attempt{
          id: attempt_id,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata: %{"downstream_delivery" => %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => class}}
        } = attempt
      )
      when is_binary(attempt_id) and class in @resendable_frame_classes,
      do: undelivered_partial_output_settlement?(turn, request, attempt)

  def verified_undelivered_partial_output?(_turn, _request, _attempt), do: false

  defp undelivered_partial_output_settlement?(
         %CodexTurn{status: "succeeded"},
         %Request{status: "succeeded"},
         %Attempt{status: "succeeded"}
       ),
       do: true

  defp undelivered_partial_output_settlement?(
         %CodexTurn{status: "interrupted", error_code: "client_disconnected"},
         %Request{status: "failed", last_error_code: "client_disconnected"},
         %Attempt{status: "failed", network_error_code: "client_disconnected"}
       ),
       do: true

  defp undelivered_partial_output_settlement?(_turn, _request, _attempt), do: false

  @doc """
  The grown-resend candidates (`WebsocketTurnIdentity.grown_resend_candidates/2`)
  whose predecessor witness is the one `request` stored: the resend is `request`
  with the candidate's items appended (findings#232 row 232-232). Empty when the
  request stored no witness or none matches.
  """
  @spec grown_witness_candidates(term(), term()) :: [OriginalWitness.grown_candidate()]
  def grown_witness_candidates(%Request{} = request, candidates) when is_list(candidates) do
    if original_witness_eligible?(request) do
      Enum.filter(candidates, &grown_candidate_matches?(request.native_client_retry_digest, &1))
    else
      []
    end
  end

  def grown_witness_candidates(_request, _candidates), do: []

  defp grown_candidate_matches?(stored, %{digest: digest, alternates: alternates} = candidate),
    do: grown_candidate?(candidate) and witness_matches?(stored, digest, alternates)

  defp grown_candidate_matches?(_stored, _candidate), do: false

  @doc """
  A native websocket turn whose socket pushed the client completed items and
  nothing that ended the turn before the client left, resent by the released
  Codex client as the same request with exactly those items appended
  (findings#232 row 232-232, measured with Codex 0.156.1: the client records
  every `response.output_item.done` item and its retry rebuilds the request from
  that history; a direct provider serves it). `candidates` are the grown-resend
  candidates whose witness already matched this predecessor
  (`grown_witness_candidates/2`); one of them must carry exactly the digests the
  receipt names, in order, and the receipt must name every item it counted. The
  receipt is otherwise the partial-output one with the class `item_done`: outcome
  `aborted`, no terminal. The turn settled `client_disconnected` after its
  output became visible (the owner, or the closing socket, stopped it) or the
  provider completed it after the client left; either way the resend is one
  successor, a new dispatch with its own single settlement. Only the ordinary
  Responses route, generation zero.
  """
  @spec verified_completed_item_resend?(term(), term(), term(), term()) :: boolean()
  def verified_completed_item_resend?(
        %CodexTurn{final_attempt_id: attempt_id, transport_kind: "websocket", completed_at: %DateTime{}} = turn,
        %Request{transport: "websocket", endpoint: "/backend-api/codex/responses", completed_at: %DateTime{}} = request,
        %Attempt{
          id: attempt_id,
          transport: "websocket",
          replay_generation: 0,
          completed_at: %DateTime{},
          response_metadata: %{
            "downstream_delivery" => %{
              "outcome" => "aborted",
              "terminal_class" => "none",
              "highest_frame_class" => "item_done",
              "completed_items" => count,
              "completed_item_digests" => [_first | _rest] = digests
            }
          }
        } = attempt,
        candidates
      )
      when is_binary(attempt_id) and is_integer(count) and is_list(candidates) do
    length(digests) == count and Enum.any?(candidates, &match?(%{items: ^digests}, &1)) and
      undelivered_partial_output_settlement?(turn, request, attempt)
  end

  def verified_completed_item_resend?(_turn, _request, _attempt, _candidates), do: false

  defp latest_attempt?(%Attempt{} = attempt) do
    not Repo.exists?(
      from newer in Attempt,
        where:
          newer.request_id == ^attempt.request_id and
            newer.attempt_number > ^attempt.attempt_number
    )
  end

  defp verified_claim_only_drain?(%Request{
         status: "failed",
         response_status_code: 499,
         last_error_code: "owner_drained",
         usage_status: "usage_unknown",
         request_metadata: %{"websocket_pre_attempt_drain" => true},
         completed_at: %DateTime{}
       }),
       do: true

  defp verified_claim_only_drain?(_request), do: false

  # Only receipt-validated owner cleanup writes this marker. The request lock
  # also fences create_attempt, so absence remains authoritative through claim.
  defp verified_pre_attempt_drain?(
         %CodexTurn{
           status: "interrupted",
           error_code: "owner_drained",
           final_attempt_id: nil,
           first_visible_output_at: nil,
           completed_at: %DateTime{}
         },
         %Request{
           status: "failed",
           response_status_code: 499,
           last_error_code: "owner_drained",
           usage_status: "usage_unknown",
           request_metadata: %{"websocket_pre_attempt_drain" => true},
           completed_at: %DateTime{}
         }
       ),
       do: true

  defp verified_pre_attempt_drain?(_turn, _request), do: false

  # The reason alone no longer carries the whole claim. `owner_drained` is a
  # caller-chosen error code, and any future path that releases a reservation
  # for that reason at a different boundary would have passed this predicate
  # unread -- admitting a resend whose predecessor may still hold reserved
  # budget, which is the one harm this gate exists to prevent. The bounded
  # phase is what the releasing path *declares*, so requiring both means the
  # entry has to agree with itself. It fails closed for exactly one cohort:
  # a release written before icoretech/codex-pooler-findings#187 carries
  # `unrecorded` and is refused, which costs a resend admitted during the
  # deploy that lands it and nothing after.
  defp released_without_settlement?(request_id) do
    entries =
      Repo.all(
        from entry in LedgerEntry,
          where: entry.request_id == ^request_id,
          order_by: [asc: entry.entry_kind],
          lock: "FOR UPDATE"
      )

    case entries do
      [
        %LedgerEntry{
          entry_kind: "release",
          attempt_id: nil,
          settled_cost_micros: %Decimal{},
          details: %{
            "release_reason" => "owner_drained",
            @pre_attempt_phase_key => @turn_interrupted_phase
          }
        } = release,
        %LedgerEntry{entry_kind: "reservation", attempt_id: nil} = reservation
      ] ->
        release.usage_status == "usage_unknown" and
          release.details["reservation_source_event_id"] == reservation.source_event_id and
          Decimal.equal?(release.settled_cost_micros, 0)

      _incomplete_or_settled ->
        false
    end
  end

  defp validate_original_claim(%Request{correlation_id: correlation_id}) do
    if reserved_successor_claim?(correlation_id), do: {:error, :retry_exhausted}, else: :ok
  end

  defp lock_owner_lease(%CodexSession{owner_lease_token: nil}), do: nil

  defp lock_owner_lease(%CodexSession{} = session) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session.id and
            lease.lease_token == ^session.owner_lease_token and
            lease.status == "active",
        lock: "FOR UPDATE"
    )
  end

  defp maybe_validate_owner_idle(
         _session,
         _lease,
         %{defer_owner_idle_validation?: true},
         _db_now
       ),
       do: :ok

  defp maybe_validate_owner_idle(session, lease, input, db_now),
    do: validate_owner_idle(session, lease, input, db_now)

  defp validate_owner_idle(
         %CodexSession{owner_lease_expires_at: nil},
         nil,
         _input,
         _db_now
       ),
       do: :ok

  defp validate_owner_idle(%CodexSession{} = session, %BridgeOwnerLease{} = lease, input, db_now) do
    expired? =
      DateTime.compare(session.owner_lease_expires_at, db_now) != :gt or
        DateTime.compare(lease.expires_at, db_now) != :gt

    if expired? or
         (Map.get(input, :owner_idle_validated?) == true and
            secure_compare(session.owner_lease_token, Map.get(input, :owner_lease_token)) and
            secure_compare(lease.lease_token, Map.get(input, :owner_lease_token)) and
            session.owner_instance_id == Map.get(input, :owner_instance_id) and
            lease.owner_instance_id == Map.get(input, :owner_instance_id)) do
      :ok
    else
      {:error, :active_predecessor}
    end
  end

  defp validate_owner_idle(%CodexSession{}, _lease, _input, _db_now),
    do: {:error, :active_predecessor}

  defp validate_authorization(session, api_key, model, request, input) do
    requested_model = Map.get(input, :requested_model)

    if session.pool_id == request.pool_id and session.api_key_id == request.api_key_id and
         api_key.id == request.api_key_id and api_key.pool_id == request.pool_id and
         model.id == request.model_id and request.requested_model == requested_model and
         request.endpoint == Map.get(input, :endpoint) and request.transport == "websocket" do
      :ok
    else
      {:error, :authorization_changed}
    end
  end

  defp validate_original_witness(request, input) do
    digest = Map.get(input, :replay_claim_digest)

    cond do
      not original_witness_eligible?(request) ->
        {:error, :missing_witness}

      request.native_client_retry_auth_epoch != Map.get(input, :runtime_revocation_epoch) ->
        {:error, :authorization_changed}

      not witness_matches?(
        request.native_client_retry_digest,
        digest,
        Map.get(input, :replay_claim_alternates, [])
      ) ->
        {:error, :payload_mismatch}

      true ->
        :ok
    end
  end

  defp lock_lineage(request_id, %{retry_policy: :native_compaction}) do
    # Dispatch locks the successor request before its link. Preserve that order
    # when reclaiming; the caller already holds the session and predecessor.
    case Repo.one(
           from link in RequestClientRetryLink,
             where: link.predecessor_request_id == ^request_id
         ) do
      %RequestClientRetryLink{} = link -> lock_request!(link.successor_request_id)
      nil -> :ok
    end

    lock_lineage(request_id, %{})
  end

  # A request carries at most one link on each side (both sides of
  # `request_client_retry_links` are unique), so it can carry two: a
  # turn-claim successor whose own successor is a native HTTP fallback, which
  # records no semantic digest and is never the preflight's predecessor, is
  # the newest websocket request of its turn once owner forwarding is switched
  # on (findings#206 row 206-533). The link naming it as a successor decides:
  # it has spent its retry (`validate_policy_lineage/3`).
  defp lock_lineage(request_id, _input) do
    links =
      Repo.all(
        from link in RequestClientRetryLink,
          where: link.predecessor_request_id == ^request_id or link.successor_request_id == ^request_id,
          lock: "FOR UPDATE"
      )

    Enum.find(links, &(&1.successor_request_id == request_id)) || List.first(links)
  end

  # A request that is itself a successor has spent its retry. A request with a
  # successor is reclaimed by the compaction policy (`lock_compaction_successor/4`)
  # or passed through by the chain walk (`lock_chain_tail/6`), which refuses a
  # successor that is live, served or foreign with `successor_claimed`.
  defp validate_policy_lineage(nil, _request_id, _input), do: :ok
  defp validate_policy_lineage(%RequestClientRetryLink{predecessor_request_id: request_id}, request_id, _input), do: :ok
  defp validate_policy_lineage(%RequestClientRetryLink{}, _request_id, _input), do: {:error, :retry_exhausted}

  defp lock_compaction_successor(nil, _request, _turn, _input), do: {:ok, nil}

  defp lock_compaction_successor(link, request, turn, %{retry_policy: :native_compaction} = input) do
    successor = lock_request!(link.successor_request_id)

    successor_turn =
      Repo.one(
        from candidate in CodexTurn,
          where: candidate.request_id == ^successor.id,
          lock: "FOR UPDATE"
      )

    entries =
      Repo.all(
        from entry in LedgerEntry,
          where: entry.request_id == ^successor.id,
          lock: "FOR UPDATE"
      )

    with {:ok, correlation} <-
           deterministic_compaction_successor_claim(request, turn, input.replay_claim_digest),
         true <- input.reclaim_owner_validated?,
         true <- successor.correlation_id == correlation,
         true <- unattempted_compaction_successor?(successor, successor_turn, request, turn),
         [
           %LedgerEntry{
             entry_kind: "reservation",
             amount_status: "recorded",
             attempt_id: nil,
             usage_status: "usage_pending"
           } = reservation
         ] <-
           entries,
         false <-
           Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^successor.id),
         nil <- lock_entitlement(successor.id) do
      {:ok, %{request: successor, turn: successor_turn, reservation: reservation, link: link}}
    else
      _ -> {:error, :successor_claimed}
    end
  end

  # Any other policy passes an admitted successor to the chain walk
  # (`lock_chain_tail/6`).
  defp lock_compaction_successor(_link, _request, _turn, _input), do: {:ok, nil}

  defp unattempted_compaction_successor?(
         %Request{status: "in_progress", completed_at: nil} = successor,
         %CodexTurn{
           status: "in_progress",
           completed_at: nil,
           first_visible_output_at: nil,
           final_attempt_id: nil,
           transport_kind: "websocket"
         } = successor_turn,
         request,
         turn
       ) do
    Map.take(successor, [
      :pool_id,
      :api_key_id,
      :model_id,
      :requested_model,
      :endpoint,
      :transport
    ]) ==
      Map.take(request, [
        :pool_id,
        :api_key_id,
        :model_id,
        :requested_model,
        :endpoint,
        :transport
      ]) and
      successor_turn.codex_session_id == turn.codex_session_id and
      successor_turn.semantic_turn_digest == turn.semantic_turn_digest
  end

  defp unattempted_compaction_successor?(_successor, _successor_turn, _request, _turn), do: false

  defp reclaim_owner_valid?(session, %BridgeOwnerLease{status: "active"} = lease, input, db_now) do
    input[:owner_idle_validated?] == true and
      session.owner_instance_id == input[:owner_instance_id] and
      lease.owner_instance_id == input[:owner_instance_id] and
      secure_compare(session.owner_lease_token, input[:owner_lease_token]) and
      secure_compare(lease.lease_token, input[:owner_lease_token]) and
      match?(%DateTime{}, session.owner_lease_expires_at) and
      DateTime.compare(session.owner_lease_expires_at, db_now) == :gt and
      DateTime.compare(lease.expires_at, db_now) == :gt
  end

  defp reclaim_owner_valid?(_session, _lease, _input, _db_now), do: false

  defp lock_entitlement(request_id) do
    Repo.one(
      from entitlement in RequestReplayEntitlement,
        where: entitlement.request_id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_no_entitlement(entitlement) do
    case entitlement do
      nil -> :ok
      %RequestReplayEntitlement{} -> {:error, :entitlement_present}
    end
  end

  # Explicit tuple checks keep every terminal requirement visible and fail closed.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_terminal_lifecycle(turn, request, attempt) do
    cond do
      turn.status == "in_progress" or request.status in ["accepted", "in_progress"] or
          attempt.status in ["queued", "in_progress"] ->
        {:error, :active_predecessor}

      turn.status != "failed" or request.status != "failed" or attempt.status != "failed" or
        turn.error_code != "upstream_stream_error" or
        request.last_error_code != "upstream_stream_error" or
        attempt.network_error_code != "upstream_stream_error" or attempt.transport != "websocket" or
        attempt.replay_generation != 0 or is_nil(turn.first_visible_output_at) or
        is_nil(turn.completed_at) or is_nil(request.completed_at) or is_nil(attempt.completed_at) ->
        {:error, :terminal_predecessor}

      true ->
        :ok
    end
  end

  # Explicit observation checks prevent permissive truthy/missing-field admission.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_observation(%{"native_client_retry_observation" => observation})
       when is_map(observation) do
    cond do
      observation["version"] != 1 or observation["authority_complete"] != true ->
        {:error, :missing_witness}

      observation["output_item_done_count"] != 0 or
          observation["output_item_done_count_saturated"] != false ->
        {:error, :unsafe_completed_output}

      observation["partial_reasoning_seen"] != true or observation["terminal_seen"] != false or
        observation["terminal_candidate_seen"] != false or
          not is_binary(observation["first_visible_at"]) ->
        {:error, :terminal_predecessor}

      true ->
        :ok
    end
  end

  defp validate_observation(_metadata), do: {:error, :missing_witness}

  defp validate_close_evidence(%{"transport_failure" => failure}) when is_map(failure) do
    if failure["termination_source"] in ["peer_close_frame", "mint_stream_done"] or
         exact_mint_closed_evidence?(failure) do
      :ok
    else
      {:error, :terminal_predecessor}
    end
  end

  defp validate_close_evidence(_metadata), do: {:error, :terminal_predecessor}

  defp exact_mint_closed_evidence?(failure) do
    failure["phase"] == "receive" and failure["termination_source"] == "mint_transport_error" and
      failure["exception"] == "Mint.TransportError" and failure["reason"] == "closed" and
      failure["transport_signal"] in ["ssl_closed", "tcp_closed"]
  end

  defp validate_retry_window(%DateTime{} = completed_at, %DateTime{} = db_now, window_seconds) do
    age = DateTime.diff(db_now, completed_at, :millisecond)
    if age in 0..(window_seconds * 1_000), do: :ok, else: {:error, :retry_expired}
  end

  defp validate_retry_window(_completed_at, _db_now, _window), do: {:error, :terminal_predecessor}

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

  defp uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp uuid?(_value), do: false

  if Mix.env() == :test do
    defp maybe_test_after_locks(%{after_locks: callback}) when is_function(callback, 0) do
      callback.()
      :ok
    end

    defp maybe_test_after_locks(_input), do: :ok
  else
    defp maybe_test_after_locks(_input), do: :ok
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end

  defp validate_link_requests(predecessor, successor) do
    cond do
      not shared_request_snapshot?(predecessor, successor) -> {:error, :snapshot_mismatch}
      not original_witness_eligible?(predecessor) -> {:error, :missing_witness}
      original_witness_eligible?(successor) -> {:error, :retry_chain}
      true -> :ok
    end
  end

  defp shared_request_snapshot?(predecessor, successor) do
    predecessor.id != successor.id and predecessor.pool_id == successor.pool_id and
      predecessor.api_key_id == successor.api_key_id and
      predecessor.model_id == successor.model_id and
      predecessor.requested_model == successor.requested_model and
      predecessor.endpoint == successor.endpoint and predecessor.transport == "websocket" and
      successor.transport == "websocket"
  end

  defp validate_shared_session(predecessor_id, successor_id) do
    sessions =
      Repo.all(
        from turn in CodexTurn,
          where: turn.request_id in ^[predecessor_id, successor_id],
          select: {turn.request_id, turn.codex_session_id},
          lock: "FOR UPDATE"
      )
      |> Map.new()

    case {Map.fetch(sessions, predecessor_id), Map.fetch(sessions, successor_id)} do
      {{:ok, session_id}, {:ok, session_id}} -> :ok
      _missing_or_mismatched -> {:error, :session_mismatch}
    end
  end
end
