defmodule CodexPooler.Gateway.Payloads.NativeHttpTurnIdentity do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry

  # The duplicate-turn fence was structurally websocket-only (findings#212): a
  # native Codex turn sent over `POST /backend-api/codex/responses` reserved
  # under a freshly generated UUID, so a resend of the same turn never met
  # `requests_correlation_id_uq`, never reached the resend policy, and bought a
  # second upstream dispatch. The same resend over a websocket is refused
  # `409 duplicate_turn`.
  #
  # The identity is not missing on HTTP, only the resolver was: the released
  # client puts the same canonical `x-codex-turn-metadata` document in the HTTP
  # body's `client_metadata` that it puts in a websocket frame
  # (`codex-rs/core/src/client.rs:893`), and echoes a bounded copy as a request
  # header. Either source yields the same `turn_id`, and the derivation is
  # `WebsocketTurnIdentity`'s own, so both transports name one turn the same way.
  #
  # ## One turn id, several requests
  #
  # The claim must survive a *rebuilt* retry body. The released client records
  # each completed output item into history as it arrives and rebuilds the
  # retry prompt from `clone_history()` with no rollback
  # (`stream_events_utils.rs:300-380`, `session/turn.rs:1578-1583`,
  # `responses_retry.rs`), so any cut that already delivered an item retries
  # with a LONGER body. A payload-scoped claim therefore misses exactly the
  # cohort the row measures -- turns still relaying ~85 s after preStop, which
  # by construction have delivered items.
  #
  # But one `turn_id` covers every request made about a turn, not just the turn
  # itself: a compaction, a prewarm, every tool-result continuation and the
  # request that resumes the turn after a compaction all carry it, because they
  # are built from one `TurnMetadataState` (`session.rs:686-701`,
  # `turn_metadata.rs:169`). So the bare claim is reserved for the one request
  # that can be shown to have opened the turn, and everything else that shares
  # the `turn_id` is named by its own payload inside its own domain:
  #
  #   * a compaction request       -> the payload-scoped compaction claim, whose
  #                                   own HMAC domain keeps it clear of the turn
  #   * a `prewarm` or `memory`    -> a payload-scoped claim in a domain named
  #                                   by the declared kind
  #   * a tool-result continuation -> the payload-scoped request claim, which is
  #                                   what keeps the several tool rounds of one
  #                                   turn from colliding with each other
  #   * the request that RESUMES a
  #     turn from its compaction   -> a claim derived from the turn and an opaque
  #                                   digest of that compaction, and from nothing
  #                                   else in the body
  #   * the request that opened it -> the BARE, payload-independent
  #                                   `codex-turn:` claim, which survives any
  #                                   rebuilt body -- including for a turn in a
  #                                   session that has already compacted, which
  #                                   is what keeps this module agreeing with the
  #                                   websocket codec
  #
  # Only the middle three are payload-scoped, and that is deliberate rather than
  # incidental. Ledger row 212-20 is the record of why: a claim is an HMAC over a
  # projection, so whatever the projection includes is what a retry can move, and
  # the client rebuilds its whole `Prompt` from live session state on every
  # attempt rather than resending a serialized body. The two claims that must
  # survive a retry therefore include no body projection at all.
  #
  # Every discriminator above is `NativeTurnContinuation`'s, and this module
  # reaches only the ones that resolve the canonical document through
  # `canonical_document/2`, so a header-only client is classified exactly like a
  # body client. The deliberate transport difference is narrower than the
  # discriminators suggest:
  #
  #   * the COMPACTION arm. The websocket codec keeps the native compaction
  #     bridge's established claim ordering, while HTTP names compaction in its
  #     payload-scoped domain. Opening, tool-continuation and post-compaction
  #     resume roles use the shared discriminator and corresponding claims.
  #   * `request_kind`. The websocket compaction arm reads it from
  #     `%NativeCodexTurnMetadata{}`, parsed by exact string match, so this
  #     module's trimming and case folding does NOT reach it. A `"TURN"` frame is
  #     a hard `:unsupported_request_kind` rejection on websocket and fences
  #     normally here. The websocket behaviour is the stricter of the two.
  #   * the fail-open gate. A websocket frame always takes some claim because the
  #     claim feeds replay; an HTTP request with nothing to go on keeps its
  #     generated id.
  #
  # KNOWN MISS, inherited by the two payload-scoped claims: a tool-result
  # continuation or a compaction whose retry body has grown is a different claim
  # and is not fenced. That is the price of keeping the several requests of one
  # turn from colliding, and the websocket path has the same miss for the same
  # reason. The prefix arm deliberately does NOT inherit it.
  #
  # ## The scope a claim is named under
  #
  # Every claim above is derived from `WebsocketTurnIdentity.claim_scope/2`
  # rather than from the Pooler session id. A remote compaction rotates
  # `x-codex-window-id`, the session key prefers that window, and the session
  # therefore moves in the middle of a thread -- so a session-scoped claim stops
  # seeing its own predecessor exactly when a client resends the first
  # post-compaction turn (findings#250). The scope is the client's thread when
  # the request carries one and the session id otherwise, so a client that sends
  # no thread identity keeps today's naming.
  #
  # ## Failing open
  #
  # A non-native route, a translated `/v1` request, a missing session, an absent
  # header and body document, a malformed document, a document without a usable
  # `turn_id`, and a document declaring a `request_kind` this module has no rule
  # for all return `:none`, which leaves the generated correlation id and
  # today's behaviour exactly as they are.

  alias CodexPooler.Gateway.Payloads.NativeTurnContinuation
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.CodexSession

  @metadata_key "x-codex-turn-metadata"
  @websocket_lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"

  @type claim_arm ::
          :opening
          | :tool_continuation
          | :compaction
          | :post_compaction_resume
          | :prewarm
          | :memory

  @type request_claim :: %{
          required(:key) => String.t(),
          required(:arm) => claim_arm(),
          required(:native_client_retry_witness) => ClientRetry.OriginalWitness.t() | nil,
          required(:input_count) => non_neg_integer() | nil,
          required(:semantic_turn_key) => <<_::256>>,
          optional(:websocket_compaction_claims) => [String.t()],
          optional(:turn_progress) => <<_::256>>,
          optional(:turn_position) => NativeTurnContinuation.progress_position(),
          optional(:steered_claim) => String.t()
        }

  # Kinds that are about a turn rather than one of its model requests, and that
  # the released client sends at most once for a given turn. They are fenced in
  # their own domain so a duplicate still costs one dispatch; any other declared
  # kind is unknown and fails open rather than being guessed at.
  @kind_scoped_request_kinds ["prewarm", "memory"]

  @doc """
  True when this request is a native Codex HTTP turn, i.e. on a route this
  fence can apply to. Deliberately payload-independent and route-level: the
  identity itself usually lives in the body, which callers that only hold
  request options (constraint classification, rejection logging) do not have.
  """
  @spec fenced?(RequestOptions.t()) :: boolean()
  def fenced?(%RequestOptions{} = request_options), do: native_route?(request_options)

  def fenced?(_request_options), do: false

  @doc """
  Resolves the durable request claim for a native Codex HTTP turn, or `:none`
  when no usable identity is present.
  """
  @spec request_claim_key(RequestOptions.t(), map()) :: {:ok, String.t()} | :none
  def request_claim_key(%RequestOptions{} = request_options, payload) when is_map(payload) do
    case request_claim(request_options, payload) do
      {:ok, %{key: key}} -> {:ok, key}
      :none -> :none
    end
  end

  def request_claim_key(_request_options, _payload), do: :none

  @doc """
  Resolves the durable request claim and its bounded semantic arm.

  The arm is persisted only as metadata so operators can distinguish claim
  domains whose rolling-compatible wire prefix is shared. It never
  participates in the HMAC or uniqueness key.
  """
  @spec request_claim(RequestOptions.t(), map()) :: {:ok, request_claim()} | :none
  def request_claim(%RequestOptions{} = request_options, payload) when is_map(payload) do
    with true <- native_route?(request_options),
         metadata when not is_nil(metadata) <-
           NativeTurnContinuation.canonical_document(payload, request_options),
         %CodexSession{} = session <- Map.get(request_options.continuity, :codex_session),
         claim_scope when is_binary(claim_scope) <-
           WebsocketTurnIdentity.claim_scope(
             session,
             NativeTurnContinuation.thread_identity(metadata)
           ),
         {:ok, identity} <-
           WebsocketTurnIdentity.resolve(canonical_payload(metadata), claim_scope),
         {:ok, claim} <- claim_for(identity, request_options, payload) do
      {:ok,
       claim
       |> Map.put(
         :native_client_retry_witness,
         native_client_retry_witness(identity, payload, request_options, claim.arm)
       )
       |> Map.put(:input_count, input_count(payload, claim.arm))
       |> Map.put(:semantic_turn_key, identity.semantic_turn_key)
       |> put_steered_claim(identity, payload)}
    else
      _fail_open -> :none
    end
  end

  def request_claim(_request_options, _payload), do: :none

  defp claim_for(identity, request_options, payload) do
    cond do
      NativeTurnContinuation.compaction_request?(payload, request_options) ->
        with {:ok, claim} <-
               claim(
                 WebsocketTurnIdentity.compaction_claim_key(identity.semantic_turn_key, payload),
                 :compaction
               ),
             do: {:ok, Map.put(claim, :websocket_compaction_claims, websocket_compaction_claims(identity, payload))}

      turn_request?(payload, request_options) ->
        turn_claim(identity, payload)

      true ->
        kind_claim(identity, request_options, payload)
    end
  end

  # One rule, read from `NativeTurnContinuation`, so nothing here re-implements
  # the discriminator the module exists to own (findings#212, row 212-51).
  #
  # WHAT THIS DOES NOT COVER, enumerated because every round of this ticket has
  # closed on an unstated scope:
  #
  #   1. A tool-result continuation is named by its whole payload, so a retry
  #      whose body has grown is a different claim and is not fenced. That is
  #      the price of separating the several tool rounds of one turn, and the
  #      websocket path has the same miss.
  #   2. A compaction request is named by its whole payload, so a compaction
  #      resent with a changed body is not fenced.
  #   3. A request carrying a USER MESSAGE after the last compaction output item
  #      is classified as a turn's opening request. In the released client it is
  #      either that (a new turn, new `turn_id`) or user input steered into the
  #      running turn under the SAME `turn_id`. The reservation tells them apart
  #      only against a native HTTP opener that recorded its progress; against a
  #      websocket opener (no progress recorded) such a request is still refused
  #      (findings#206 row 206-403).
  #   4. Websocket and HTTP share the post-compaction resume claim, while the
  #      websocket compaction bridge retains its established claim ordering.
  defp turn_claim(identity, payload) do
    case NativeTurnContinuation.turn_role(payload) do
      :opening ->
        claim(identity.turn_claim_key, :opening)

      :tool_continuation ->
        claim(
          WebsocketTurnIdentity.request_claim_key(identity.semantic_turn_key, payload),
          :tool_continuation
        )

      {:post_compaction_resume, anchor} ->
        claim(
          WebsocketTurnIdentity.resume_claim_key(identity.semantic_turn_key, anchor),
          :post_compaction_resume
        )
    end
  end

  # An `:opening` request also carries what it would be claimed under if it is a
  # later request of its turn, steered in by the user (see
  # `NativeTurnContinuation.turn_progress/1`), and the progress digest the
  # opener's row records. The reservation decides between the two: the bare
  # `codex-turn:` claim unless it is already held by a native HTTP request of the
  # turn that recorded a DIFFERENT progress, which no retry of that request can
  # produce (findings#206 row 206-403), and only when this request is further
  # along the turn than that holder (its position, row 206-423). The steered
  # claim is named by the turn and that digest alone, so a rebuilt retry of the
  # steered request (model output appended) derives it again and meets its own
  # predecessor.
  defp put_steered_claim(%{arm: :opening} = claim, identity, payload) do
    progress = NativeTurnContinuation.turn_progress(payload)

    claim
    |> Map.put(:turn_progress, progress)
    |> Map.put(:turn_position, NativeTurnContinuation.turn_position(payload))
    |> Map.put(:steered_claim, WebsocketTurnIdentity.steered_claim_key(identity.semantic_turn_key, progress))
  end

  defp put_steered_claim(claim, _identity, _payload), do: claim

  defp kind_claim(identity, request_options, payload) do
    case NativeTurnContinuation.request_kind(payload, request_options) do
      kind when kind in @kind_scoped_request_kinds ->
        claim(
          WebsocketTurnIdentity.kind_claim_key(identity.semantic_turn_key, payload, kind),
          kind_claim_arm(kind)
        )

      _unknown_or_absent ->
        :none
    end
  end

  defp claim(key, arm), do: {:ok, %{key: key, arm: arm}}

  # The claim a websocket compaction of this body holds. The released client's
  # HTTPS fallback for a remote compaction it did not complete over the
  # websocket is `POST /responses` with the websocket frame's body minus `type`
  # and the websocket start timestamp, the Lite marker moved to a header (P69
  # wire probe of Codex 0.156.1). Both transports derive their claim from the
  # payload coerced for the compact route, which drops `type` and the client
  # metadata; the websocket one keeps the `stream: true` every native frame
  # carries and the HTTP one does not, so the websocket payload is rebuilt by
  # restoring it. The marked variant covers a coercion that keeps the Lite
  # marker. Deriving the websocket claim lets the reservation find the
  # websocket compaction this request repeats (findings#206 row 206-330); the
  # HTTP compaction still reserves under its own payload-scoped claim when no
  # such compaction exists.
  defp websocket_compaction_claims(identity, payload) do
    payload
    |> Map.put("stream", true)
    |> lite_marker_variants()
    |> Enum.map(&WebsocketTurnIdentity.native_compaction_claim_key(identity.semantic_turn_key, &1))
  end

  defp native_client_retry_witness(
         identity,
         %{"input" => input},
         request_options,
         :post_compaction_resume
       )
       when is_list(input) do
    with {:ok, digest} <-
           WebsocketTurnIdentity.http_resume_input_digest(identity.semantic_turn_key, input),
         {:ok, witness} <-
           ClientRetry.original_witness(
             digest,
             request_options.runtime.api_key_runtime_epoch
           ) do
      witness
    else
      _unavailable -> nil
    end
  end

  # The opening request of a turn the released client falls back to HTTPS for
  # after its websocket retries failed: the body is the websocket request's own
  # (measured with Codex 0.156.1 through a recording proxy, findings#232 row
  # 232-231), except the frame's `type` and the Lite marker the websocket frame
  # carries in `client_metadata` and HTTP sends as a request header instead
  # (`ws_request_header_x_openai_internal_codex_responses_lite`, rust-v0.156.1
  # `core/src/client.rs` `build_ws_client_metadata/2`). Its witness is therefore
  # the websocket frame's, under both Lite variants, together with the
  # trailing-slice digests an anchored websocket original is recognised by
  # (row 232-160). Without it the HTTP turn claim had no witness, and
  # `FailedPredecessorResend` refused every HTTPS fallback of a websocket
  # predecessor, whichever shape the websocket resend itself was admitted for.
  # The grown-resend candidates of both variants ride along: after a cut that
  # pushed completed items the fallback carries them appended (row 232-232).
  defp native_client_retry_witness(identity, %{"input" => input} = payload, request_options, :opening)
       when is_list(input) do
    frame = Map.put(payload, "type", "response.create")
    variants = lite_marker_variants(frame)

    # The two variants share their input, so its items are hashed once for the
    # trailing-slice digests of both.
    with {:ok, [digest | variant_digests]} <- collect_digests(variants, &WebsocketTurnIdentity.replay_claim_digest(identity.semantic_turn_key, &1)),
         {:ok, tail_digests} <- WebsocketTurnIdentity.replay_claim_alternates_of_variants(identity.semantic_turn_key, variants),
         {:ok, grown} <- collect_digests(variants, &WebsocketTurnIdentity.grown_resend_candidates(identity.semantic_turn_key, &1)),
         {:ok, witness} <-
           ClientRetry.original_witness(
             digest,
             request_options.runtime.api_key_runtime_epoch,
             Enum.uniq(variant_digests ++ List.flatten(tail_digests)) -- [digest],
             List.flatten(grown)
           ) do
      witness
    else
      _unavailable -> nil
    end
  end

  # Ordinary HTTP tool continuations can retry only their exact request after
  # a proved partial-tool cut, so they need no tail or grown-history witnesses.
  defp native_client_retry_witness(identity, %{"input" => input} = payload, request_options, :tool_continuation)
       when is_list(input) do
    with {:ok, digest} <- WebsocketTurnIdentity.replay_claim_digest(identity.semantic_turn_key, payload),
         {:ok, witness} <- ClientRetry.original_witness(digest, request_options.runtime.api_key_runtime_epoch) do
      witness
    else
      _unavailable -> nil
    end
  end

  defp native_client_retry_witness(_identity, _payload, _request_options, _arm), do: nil

  # A body that already carries the marker is its own marked variant; it is
  # digested once.
  defp lite_marker_variants(frame) do
    case put_websocket_lite_marker(frame) do
      ^frame -> [frame]
      marked -> [frame, marked]
    end
  end

  defp put_websocket_lite_marker(%{"client_metadata" => metadata} = frame) when is_map(metadata),
    do: Map.put(frame, "client_metadata", Map.put(metadata, @websocket_lite_marker, "true"))

  defp put_websocket_lite_marker(%{"client_metadata" => nil} = frame),
    do: Map.put(frame, "client_metadata", %{@websocket_lite_marker => "true"})

  defp put_websocket_lite_marker(frame) when not is_map_key(frame, "client_metadata"),
    do: Map.put(frame, "client_metadata", %{@websocket_lite_marker => "true"})

  defp put_websocket_lite_marker(frame), do: frame

  defp collect_digests(variants, fun) do
    Enum.reduce_while(variants, {:ok, []}, fn variant, {:ok, acc} ->
      case fun.(variant) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp input_count(%{"input" => input}, :post_compaction_resume) when is_list(input),
    do: length(input)

  defp input_count(_payload, _arm), do: nil

  defp kind_claim_arm("prewarm"), do: :prewarm
  defp kind_claim_arm("memory"), do: :memory

  defp turn_request?(payload, request_options),
    do: NativeTurnContinuation.request_kind(payload, request_options) == "turn"

  # Only the canonical document is offered to the resolver, never the request
  # body, so a body field named `turn_id`/`request_id` cannot become a turn
  # identity through `WebsocketTurnIdentity`'s legacy fallbacks.
  defp canonical_payload(metadata), do: %{"client_metadata" => %{@metadata_key => metadata}}

  # The endpoint list is read at runtime rather than through a module
  # attribute: evaluating `NativeTurnContinuation.native_endpoints/0` at
  # compile time makes this module a compile-time dependent of that one, which
  # `mix quality.xref` refuses (it forces a recompile cascade on every edit to
  # the shared discriminator).
  defp native_route?(%RequestOptions{
         transport: %{transport: transport, upstream_endpoint: endpoint},
         openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
       })
       when is_binary(transport) and transport != "websocket",
       do: endpoint in NativeTurnContinuation.native_endpoints()

  defp native_route?(%RequestOptions{}), do: false
end
