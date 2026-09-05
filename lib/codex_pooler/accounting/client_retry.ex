defmodule CodexPooler.Accounting.ClientRetry do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey

  alias CodexPooler.Accounting.{
    Attempt,
    Request,
    RequestClientRetryLink,
    RequestReplayEntitlement
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Repo

  @version 1
  @digest_bytes 32
  @max_done_count 65_535
  @successor_prefix "client-retry-v1:"
  @retry_window_seconds 30

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
            dispatch_authority: DispatchAuthority.t()
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
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            version: 1,
            predecessor_request_id: Ecto.UUID.t(),
            successor_request_id: Ecto.UUID.t(),
            link_id: Ecto.UUID.t(),
            successor_claim: String.t()
          }
  end

  defmodule OriginalWitness do
    @moduledoc false
    @enforce_keys [:version, :digest, :auth_epoch]
    defstruct [:version, :digest, :auth_epoch]

    @type t :: %__MODULE__{
            version: pos_integer(),
            digest: <<_::256>>,
            auth_epoch: non_neg_integer()
          }
  end

  defmodule Observation do
    @moduledoc false
    defstruct version: 1,
              authority_complete?: false,
              authority_poisoned?: false,
              output_item_done_count: 0,
              output_item_done_count_saturated?: false,
              partial_reasoning_seen?: false,
              first_visible_at: nil,
              terminal_seen?: false,
              terminal_candidate_seen?: false

    @type t :: %__MODULE__{
            version: pos_integer(),
            authority_complete?: boolean(),
            authority_poisoned?: boolean(),
            output_item_done_count: non_neg_integer(),
            output_item_done_count_saturated?: boolean(),
            partial_reasoning_seen?: boolean(),
            first_visible_at: DateTime.t() | nil,
            terminal_seen?: boolean(),
            terminal_candidate_seen?: boolean()
          }
  end

  @type observation_metadata :: %{
          required(String.t()) => boolean() | non_neg_integer() | String.t()
        }

  @spec original_witness(binary(), non_neg_integer()) ::
          {:ok, OriginalWitness.t()} | {:error, :invalid_witness}
  def original_witness(digest, auth_epoch)
      when is_binary(digest) and byte_size(digest) == @digest_bytes and is_integer(auth_epoch) and
             auth_epoch >= 0 do
    {:ok, %OriginalWitness{version: @version, digest: digest, auth_epoch: auth_epoch}}
  end

  def original_witness(_digest, _auth_epoch), do: {:error, :invalid_witness}

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

  @spec reserved_successor_claim?(term()) :: boolean()
  def reserved_successor_claim?(value) when is_binary(value),
    do: String.starts_with?(value, @successor_prefix)

  def reserved_successor_claim?(_value), do: false

  @spec dispatch_authority(Request.t(), Request.t(), RequestClientRetryLink.t()) ::
          DispatchAuthority.t()
  def dispatch_authority(predecessor, successor, link) do
    %DispatchAuthority{
      version: @version,
      predecessor_request_id: predecessor.id,
      successor_request_id: successor.id,
      link_id: link.id,
      successor_claim: successor.correlation_id
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
        }
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
         not original_witness_eligible?(request) do
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
      reserved_successor_claim?(authority.successor_claim)
  end

  def dispatch_authority_shape?(_authority), do: false

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
    Repo.exists?(
      from request in Request,
        join: link in RequestClientRetryLink,
        on: link.successor_request_id == request.id,
        join: attempt in Attempt,
        on: attempt.request_id == request.id,
        where:
          request.id == ^request_id and request.status == "in_progress" and
            is_nil(request.completed_at) and request.correlation_id == ^authority.successor_claim and
            link.id == ^authority.link_id and
            link.predecessor_request_id == ^authority.predecessor_request_id and
            link.successor_request_id == ^authority.successor_request_id and
            attempt.id == ^attempt_id and attempt.attempt_number == 1 and
            attempt.replay_generation == 0 and attempt.status == "in_progress" and
            is_nil(attempt.completed_at)
    )
  end

  @spec deterministic_successor_claim(Request.t()) :: {:ok, String.t()} | {:error, atom()}
  def deterministic_successor_claim(%Request{
        id: request_id,
        correlation_id: original_claim,
        native_client_retry_digest: digest
      })
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

  def deterministic_successor_claim(%Request{}), do: {:error, :missing_witness}

  @spec preflight_snapshot(CodexSession.t(), APIKey.t(), CodexPooler.Catalog.Model.t(), map()) ::
          :none | {:ok, map()} | {:error, atom()}
  def preflight_snapshot(session, api_key, model, input) do
    input = Map.put(input, :defer_owner_idle_validation?, true)
    digest = Map.get(input, :semantic_turn_digest)

    existing_turn? =
      is_binary(digest) and byte_size(digest) == @digest_bytes and
        Repo.exists?(
          from turn in CodexTurn,
            where: turn.codex_session_id == ^session.id and turn.semantic_turn_digest == ^digest
        )

    if existing_turn? do
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

  @spec lock_eligible_predecessor!(
          CodexSession.t(),
          APIKey.t(),
          CodexPooler.Catalog.Model.t(),
          map()
        ) ::
          {:ok,
           %{
             request: Request.t(),
             turn: CodexTurn.t(),
             attempt: Attempt.t(),
             db_now: DateTime.t()
           }}
          | {:error, atom()}
  def lock_eligible_predecessor!(
        %CodexSession{} = session,
        %APIKey{} = api_key,
        %CodexPooler.Catalog.Model{} = model,
        input
      )
      when is_map(input) do
    with :ok <- reject_anchor(input),
         {:ok, turn} <- lock_predecessor_turn(session.id, input),
         %Request{} = request <- lock_request!(turn.request_id),
         %Attempt{} = attempt <- lock_attempt(turn.final_attempt_id, request.id),
         owner_lease <- lock_owner_lease(session),
         lineage <- lock_lineage(request.id),
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
           ) do
      {:ok, %{request: request, turn: turn, attempt: attempt, db_now: db_now}}
    else
      nil -> {:error, :terminal_predecessor}
      {:error, _reason} = error -> error
    end
  end

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

  @spec observe_frame(Observation.t(), term(), DateTime.t()) :: Observation.t()
  def observe_frame(%Observation{} = observation, decoded, %DateTime{} = observed_at) do
    observation
    |> mark_first_visible(decoded, observed_at)
    |> observe_decoded_frame(decoded)
  end

  @spec complete_without_terminal(Observation.t()) :: Observation.t()
  def complete_without_terminal(%Observation{} = observation),
    do: %{observation | authority_complete?: true}

  @spec final_observation_metadata(Observation.t()) :: {:ok, observation_metadata()} | :ineligible
  def final_observation_metadata(
        %Observation{
          version: @version,
          authority_complete?: true,
          authority_poisoned?: false,
          first_visible_at: %DateTime{} = first_visible_at
        } = observation
      ) do
    {:ok,
     %{
       "version" => @version,
       "authority_complete" => true,
       "output_item_done_count" => observation.output_item_done_count,
       "output_item_done_count_saturated" => observation.output_item_done_count_saturated?,
       "partial_reasoning_seen" => observation.partial_reasoning_seen?,
       "first_visible_at" => DateTime.to_iso8601(first_visible_at),
       "terminal_seen" => observation.terminal_seen?,
       "terminal_candidate_seen" => observation.terminal_candidate_seen?
     }}
  end

  def final_observation_metadata(%Observation{}), do: :ineligible

  defp observe_decoded_frame(observation, %{"type" => type} = decoded) when is_binary(type) do
    observation
    |> maybe_mark_partial_reasoning(type)
    |> maybe_count_completed_item(type, decoded)
    |> maybe_mark_terminal(type)
    |> maybe_poison_unknown_response_event(type)
  end

  defp observe_decoded_frame(observation, _decoded),
    do: %{observation | authority_poisoned?: true}

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
    do: %{increment_done_count(observation) | authority_poisoned?: true}

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
      else: %{observation | authority_poisoned?: true}
  end

  defp maybe_poison_unknown_response_event(observation, _type), do: observation

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
      case Repo.one(
             from turn in CodexTurn,
               where:
                 turn.codex_session_id == ^session_id and turn.semantic_turn_digest == ^digest,
               order_by: [asc: turn.turn_sequence],
               limit: 1,
               lock: "FOR UPDATE"
           ) do
        %CodexTurn{} = turn -> {:ok, turn}
        nil -> {:error, :terminal_predecessor}
      end
    else
      {:error, :payload_mismatch}
    end
  end

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
         :ok <- validate_original_witness(request, input),
         :ok <- validate_original_claim(request),
         :ok <- maybe_validate_owner_idle(session, owner_lease, input, db_now),
         :ok <- validate_no_lineage(lineage, request.id),
         :ok <- validate_no_entitlement(entitlement),
         :ok <- validate_terminal_lifecycle(turn, request, attempt),
         :ok <- validate_observation(attempt.response_metadata),
         :ok <- validate_close_evidence(attempt.response_metadata) do
      validate_retry_window(request.completed_at, db_now)
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

      not secure_compare(request.native_client_retry_digest, digest) ->
        {:error, :payload_mismatch}

      true ->
        :ok
    end
  end

  defp lock_lineage(request_id) do
    Repo.one(
      from link in RequestClientRetryLink,
        where:
          link.predecessor_request_id == ^request_id or link.successor_request_id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_no_lineage(lineage, request_id) do
    case lineage do
      %RequestClientRetryLink{predecessor_request_id: ^request_id} -> {:error, :successor_claimed}
      %RequestClientRetryLink{} -> {:error, :retry_exhausted}
      nil -> :ok
    end
  end

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

  defp validate_retry_window(%DateTime{} = completed_at, %DateTime{} = db_now) do
    age = DateTime.diff(db_now, completed_at, :millisecond)
    if age in 0..(@retry_window_seconds * 1_000), do: :ok, else: {:error, :retry_expired}
  end

  defp validate_retry_window(_completed_at, _db_now), do: {:error, :terminal_predecessor}

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
