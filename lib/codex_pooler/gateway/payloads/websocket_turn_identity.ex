defmodule CodexPooler.Gateway.Payloads.WebsocketTurnIdentity do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @direct_turn_param "client_metadata.turn_id"
  @canonical_metadata_key "x-codex-turn-metadata"
  @canonical_metadata_param "client_metadata.x-codex-turn-metadata"
  @canonical_turn_param "client_metadata.x-codex-turn-metadata.turn_id"
  @turn_param "turn_id"
  @request_param "request_id"
  @turn_id_pattern ~r/\A[A-Za-z0-9_.:-]+\z/
  @claim_prefix "codex-turn:"
  @request_claim_prefix "codex-request:"
  @request_claim_domain "native_websocket_response_claim_v1"
  @compaction_claim_domain "native_websocket_compaction_claim_v1"
  @native_compaction_claim_domain "native_websocket_compaction_claim_v2"
  @kind_claim_domain_prefix "native_turn_kind_claim_v1:"
  @resume_claim_domain "native_turn_compaction_resume_claim_v1"

  # One wire prefix per domain for the two claims only native HTTP produces, so
  # an operator can tell from `requests.correlation_id` which arm named a row
  # (findings#212, row 212-61). `codex-request:` still covers both the
  # tool-result continuation and the compaction claim, because the websocket
  # codec produces those two and keys on that prefix.
  @kind_claim_prefix "codex-kind:"
  @resume_claim_prefix "codex-resume:"
  # A claim SCOPE, never a claim: it is only ever an input to the digests below
  # and never reaches `requests.correlation_id`, so it is deliberately absent
  # from `@native_claim_prefixes`.
  @thread_scope_prefix "codex-thread:"
  @thread_scope_domain "native_turn_thread_claim_scope_v1"
  @native_claim_prefixes [
    @claim_prefix,
    @request_claim_prefix,
    @kind_claim_prefix,
    @resume_claim_prefix
  ]
  @replay_claim_domain "native_websocket_response_replay_claim_v1"
  @replay_tail_domain "native_websocket_response_replay_tail_v1"
  # How many trailing items of an unanchored resend are tried as the items an
  # anchored original carried. The released client's anchored tail is the
  # items it added after the previous response (a user message, or the outputs
  # of one tool round), far below this; a longer tail keeps today's refusal.
  @replay_tail_suffix_limit 256
  @http_resume_input_domain "native_http_resume_input_v1"
  @completed_item_domain "native_websocket_completed_item_v1"
  # How many trailing items of an unanchored request are tried as the completed
  # items a cut predecessor pushed before its client left (findings#232 row
  # 232-232). The released client appends what it recorded from
  # `response.output_item.done`: a reasoning item, a message, or both, far
  # below this; a longer run keeps the fence.
  @grown_resend_item_limit 4
  @replay_volatile_metadata_keys [
    "x-codex-ws-stream-request-start-ms",
    "ws_request_header_traceparent",
    "ws_request_header_tracestate"
  ]
  @excluded_client_metadata_keys [
    "turn_id",
    @canonical_metadata_key,
    "x-codex-ws-stream-request-start-ms",
    "ws_request_header_traceparent",
    "ws_request_header_tracestate"
  ]

  @type identity :: %{
          required(:semantic_turn_key) => <<_::256>>,
          required(:turn_claim_key) => String.t()
        }

  @type result :: {:ok, identity()} | :missing | {:error, Error.reason()}

  @type grown_candidate :: %{
          required(:items) => [String.t()],
          required(:digest) => <<_::256>>,
          required(:alternates) => [<<_::256>>]
        }

  @doc """
  The identity of a native Codex turn, under the claim scope `claim_scope/2`
  resolved for the request.

  The scope is an argument rather than the Pooler session id because the
  session is not stable for the life of a turn's thread: a remote compaction
  rotates `x-codex-window-id`, the session key prefers the window
  (`session_continuity.ex`, since `6441e83d`), and an identical post-visible
  resend of the first post-compaction turn therefore opened a SECOND session,
  where `f(session_uuid, turn_id)` could not collide with the predecessor's
  claim and the provider was asked the same history twice
  (findings#250). `claim_scope/2` keeps the claim on the thread the client
  never moved, while the session keeps following the window.
  """
  @spec resolve(map(), String.t()) :: result()
  def resolve(payload, claim_scope)
      when is_map(payload) and is_binary(claim_scope) and claim_scope != "" do
    with {:ok, raw_turn_id} <- raw_turn_id(payload) do
      digest = :crypto.hash(:sha256, claim_scope <> <<0>> <> raw_turn_id)

      {:ok,
       %{
         semantic_turn_key: digest,
         turn_claim_key: @claim_prefix <> Base.url_encode64(digest, padding: false)
       }}
    end
  end

  def resolve(payload, _claim_scope) when is_map(payload) do
    case raw_turn_id(payload) do
      :missing ->
        :missing

      {:ok, _raw_turn_id} ->
        {:error,
         Error.invalid_request(
           "native websocket session identity is unavailable",
           "codex_session_id"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The scope a native Codex turn claim is derived under, for one request.

  The client's thread identity when the request carries one, bound to the
  tenant that sent it, and the Pooler session id otherwise.

  Why the thread and not the session. `x-codex-window-id` is
  `"{thread_id}:{window_number}"` and the client bumps the number after a
  remote compaction (`session/mod.rs:4449-4459`,
  `compact_remote_v2.rs:323`), so every post-compaction request carries a
  window the predecessor's never did. The session key prefers that window
  (`6441e83d`, deliberately: a window is the finest continuity anchor a Codex
  client offers and two live windows of one `session-id` must not collapse
  into one session), so the successor opens a NEW session and a duplicate-turn
  claim built on the session UUID cannot see the predecessor. Scoping the claim
  on the thread leaves session keying, routing and affinity exactly where
  `6441e83d` put them and fences the duplicate anyway (findings#250).

  Why the tenant is in the digest. `requests_correlation_id_uq` is a GLOBAL
  unique index and the thread identity is client-supplied, so a bare digest of
  it would let one Pool's client name another Pool's claim. The session id it
  replaces was server-minted and carried that separation implicitly.

  Why an HMAC and not a plain hash. The scope decides a durable claim; keying
  it to `secret_key_base` under its own domain means the claim of a thread
  cannot be computed from values a client already knows, which is the property
  the session UUID had. Without a usable secret the scope falls back to the
  session id, which is today's behaviour rather than a weaker stand-in.
  """
  @spec claim_scope(term(), String.t() | nil) :: String.t() | nil
  def claim_scope(session, thread_id)

  def claim_scope(
        %{id: id, pool_id: pool_id, api_key_id: api_key_id},
        thread_id
      )
      when is_binary(id) and is_binary(pool_id) and is_binary(api_key_id) and
             is_binary(thread_id) and thread_id != "" do
    case thread_scope_hmac_key() do
      {:ok, key} ->
        digest =
          :crypto.mac(
            :hmac,
            :sha256,
            key,
            :erlang.term_to_binary(
              {@thread_scope_domain, pool_id, api_key_id, thread_id},
              [:deterministic]
            )
          )

        @thread_scope_prefix <> Base.url_encode64(digest, padding: false)

      :error ->
        id
    end
  end

  def claim_scope(%{id: id}, _thread_id) when is_binary(id) and id != "", do: id

  def claim_scope(_session, _thread_id), do: nil

  @doc "True for a payload-scoped native websocket request claim."
  @spec request_claim?(term()) :: boolean()
  def request_claim?(value) when is_binary(value),
    do: String.starts_with?(value, @request_claim_prefix)

  def request_claim?(_value), do: false

  @doc """
  True for any claim this module mints for a native Codex turn, whichever arm
  produced it. Callers that route a claim into the resend path must use this
  rather than `request_claim?/1`, or a new domain's wire prefix silently stops
  being routed.
  """
  @spec native_claim?(term()) :: boolean()
  def native_claim?(value) when is_binary(value),
    do: Enum.any?(@native_claim_prefixes, &String.starts_with?(value, &1))

  def native_claim?(_value), do: false

  @spec request_claim_key(<<_::256>>, map()) :: String.t()
  def request_claim_key(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload) do
    scoped_request_claim_key(semantic_turn_key, payload, @request_claim_domain)
  end

  @spec compaction_claim_key(<<_::256>>, map()) :: String.t()
  def compaction_claim_key(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload) do
    scoped_request_claim_key(semantic_turn_key, payload, @compaction_claim_domain)
  end

  @doc """
  The claim of one native websocket compaction, the same whether the client
  sent it anchored or as full history.

  The released client builds a remote compaction as one prompt and lets the
  websocket layer compress it: on the connection that produced the previous
  response it sends the items added since, anchored on that response; after
  any reconnect it sends the whole history without the anchor, with every
  other field unchanged (findings#232 row 232-160). An admitted anchored
  compaction used to hold no durable claim, so when its connection was cut the
  full-history resend found its payload-scoped claim free: with owner
  forwarding off it was served and billed again after the first one had been
  billed, or it raced the closing socket into the active-turn index
  (findings#206 row 206-310). Both forms therefore derive this claim, which
  binds the turn and every field except `input` and `previous_response_id`
  (`x-codex-window-id` among them). A second compaction of the same turn is a
  different claim, because the client advances the window after every
  compaction it completes.
  """
  @spec native_compaction_claim_key(<<_::256>>, map()) :: String.t()
  def native_compaction_claim_key(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload) do
    scoped_request_claim_key(
      semantic_turn_key,
      Map.drop(payload, ["input", "previous_response_id"]),
      @native_compaction_claim_domain
    )
  end

  @doc """
  The claim for the request that resumes a turn from the compaction it just
  produced, derived from the turn and an opaque digest of that compaction and
  from NOTHING else in the body.

  It cannot take the bare turn claim, which the turn's own opening request
  already holds. It must not be payload-scoped either: ledger row 212-20 is the
  record of why -- the claim is an HMAC over a projection, so whatever the
  projection includes is what a retry can move. A resume retried with a grown
  `input`, a changed `tools` list, a flipped `parallel_tool_calls` or a
  reordered history therefore keeps this claim, because none of that is in it.
  """
  @spec resume_claim_key(<<_::256>>, <<_::256>>) :: String.t()
  def resume_claim_key(semantic_turn_key, anchor)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_binary(anchor) and byte_size(anchor) == 32 do
    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        request_claim_hmac_key(),
        :erlang.term_to_binary(
          {@resume_claim_domain, semantic_turn_key, anchor},
          [:deterministic]
        )
      )

    @resume_claim_prefix <> Base.url_encode64(digest, padding: false)
  end

  @doc """
  The claim of a later request of a turn that the user steered in, derived from
  the turn and its full-history progress digest
  (`NativeTurnContinuation.turn_progress/1`) and from nothing else.

  Every form of one steered request derives it: a native HTTP request, a
  full-history frame on a new socket, and an anchored increment on the socket
  that delivered the turn's previous response, so a resend of any of them in
  any other form meets its predecessor (findings#206 rows 206-403 and 206-412).
  The anchor is domain-separated from the compaction anchor, so a steered claim
  can never equal a post-compaction resume claim of the same turn.
  """
  @spec steered_claim_key(<<_::256>>, <<_::256>>) :: String.t()
  def steered_claim_key(semantic_turn_key, progress)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_binary(progress) and byte_size(progress) == 32 do
    anchor = :crypto.hash(:sha256, :erlang.term_to_binary({"native_turn_steered_claim_v1", progress}, [:deterministic]))
    resume_claim_key(semantic_turn_key, anchor)
  end

  @doc """
  A payload-scoped claim for a request that is *about* a turn rather than one of
  its model requests, domain separated by the declared `request_kind`.

  A `prewarm` is built from the turn's own `TurnMetadataState` and so carries
  the turn's `turn_id` (`session_startup_prewarm.rs:303-310`); a `memory`
  request mints its own (`turn_metadata.rs:133-139`). Neither may take the
  turn's bare claim -- that refuses a request which has no duplicate -- but both
  are single-shot per turn, so an identical resend of one is a duplicate and
  stays fenced (findings#212, row 212-46).
  """
  @spec kind_claim_key(<<_::256>>, map(), String.t()) :: String.t()
  def kind_claim_key(semantic_turn_key, payload, kind)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_map(payload) and is_binary(kind) do
    scoped_claim_key(
      semantic_turn_key,
      payload,
      @kind_claim_domain_prefix <> kind,
      @kind_claim_prefix
    )
  end

  defp scoped_request_claim_key(semantic_turn_key, payload, domain),
    do: scoped_claim_key(semantic_turn_key, payload, domain, @request_claim_prefix)

  defp scoped_claim_key(semantic_turn_key, payload, domain, prefix) do
    projection = request_claim_projection(payload)

    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        request_claim_hmac_key(),
        :erlang.term_to_binary(
          {domain, semantic_turn_key, projection},
          [:deterministic]
        )
      )

    prefix <> Base.url_encode64(digest, padding: false)
  end

  @spec replay_claim_digest(<<_::256>>, map()) ::
          {:ok, <<_::256>>} | {:error, Error.reason()}
  def replay_claim_digest(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_map(payload) do
    with {:ok, projection} <- replay_claim_projection(payload),
         {:ok, key} <- replay_claim_hmac_key() do
      input =
        :erlang.term_to_binary(
          {@replay_claim_domain, semantic_turn_key, projection},
          [:deterministic]
        )

      {:ok, :crypto.mac(:hmac, :sha256, key, input)}
    end
  end

  def replay_claim_digest(_semantic_turn_key, _payload),
    do: invalid_replay_claim("semantic_turn_key")

  @doc """
  The resend identity of an anchored request, independent of its anchor.

  A `previous_response_id` is a transport compression, not part of what the
  client asked: it stands for the history the previous response closed, and
  the request adds only its own trailing items. The released Codex client
  drops the anchor whenever it reconnects (`client.rs` resets the websocket
  session, so the next `prepare_websocket_request` finds no last response)
  and resends the same request as full history: the history the anchor stood
  for, followed by exactly the items the anchored request carried, with every
  other field unchanged (findings#232 row 232-160, measured with the released
  client: the anchored request's items are a suffix of the resend, and no
  other field differs).

  This digest binds the semantic turn, every non-input field except the
  anchor, and the anchored request's items as a hash chain, so
  `replay_claim_alternates/2` can find it among the trailing items of the
  full-history resend. It is not the replay claim: `replay_claim_digest/2`
  still binds the anchor, so an anchored resend with a different anchor stays
  a different request. An unanchored request answers `:unanchored`.
  """
  @spec replay_tail_digest(<<_::256>>, map()) ::
          {:ok, <<_::256>>} | :unanchored | {:error, Error.reason()}
  def replay_tail_digest(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and
             is_map(payload) do
    if anchored?(payload) do
      with {:ok, key, base} <- replay_tail_base(semantic_turn_key, payload) do
        {:ok, Enum.reduce(Enum.reverse(replay_tail_items(payload)), base, &replay_tail_link(key, &1, &2))}
      end
    else
      :unanchored
    end
  end

  def replay_tail_digest(_semantic_turn_key, _payload),
    do: invalid_replay_claim("semantic_turn_key")

  @doc """
  The `replay_tail_digest/2` an anchored original would have had if an
  unanchored request is its full-history resend: one digest per proper
  trailing slice of the input (at least one history item before it), shortest
  slice first, bounded by `#{@replay_tail_suffix_limit}` items. Empty for an anchored
  request, a request without a list input, or a single-item input.
  """
  @spec replay_claim_alternates(<<_::256>>, map()) ::
          {:ok, [<<_::256>>]} | {:error, Error.reason()}
  def replay_claim_alternates(semantic_turn_key, %{"input" => [_first, _second | _rest] = input} = payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 do
    if anchored?(payload) do
      {:ok, []}
    else
      with {:ok, key, base} <- replay_tail_base(semantic_turn_key, payload) do
        {:ok, trailing_tail_digests(key, base, tl(input))}
      end
    end
  end

  def replay_claim_alternates(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload),
      do: {:ok, []}

  def replay_claim_alternates(_semantic_turn_key, _payload),
    do: invalid_replay_claim("semantic_turn_key")

  @doc """
  `replay_claim_alternates/2` of each of several variants of one request that
  share the very same `input` and differ only in other fields (the native HTTP
  opening request's websocket witness, with and without the websocket Lite
  marker, findings#232 row 232-231), in variant order. The digests are the ones
  `replay_claim_alternates/2` returns for each variant; every trailing item is
  hashed once for all variants instead of once per variant. Variants whose
  inputs differ are answered one by one.
  """
  @spec replay_claim_alternates_of_variants(<<_::256>>, [map()]) ::
          {:ok, [[<<_::256>>]]} | {:error, Error.reason()}
  def replay_claim_alternates_of_variants(semantic_turn_key, [%{"input" => [_first, _second | _rest] = input} | _more] = variants)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 do
    if Enum.all?(variants, &(is_map(&1) and Map.get(&1, "input") === input)) do
      item_digests = trailing_item_digests(tl(input))
      collect_variant_alternates(variants, &variant_alternates(semantic_turn_key, &1, item_digests))
    else
      collect_variant_alternates(variants, &replay_claim_alternates(semantic_turn_key, &1))
    end
  end

  def replay_claim_alternates_of_variants(semantic_turn_key, variants) when is_list(variants),
    do: collect_variant_alternates(variants, &replay_claim_alternates(semantic_turn_key, &1))

  defp variant_alternates(semantic_turn_key, variant, item_digests) do
    if anchored?(variant) do
      {:ok, []}
    else
      with {:ok, key, base} <- replay_tail_base(semantic_turn_key, variant) do
        {:ok, trailing_tail_chain(key, base, item_digests)}
      end
    end
  end

  defp collect_variant_alternates(variants, fun) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, acc} ->
      case fun.(variant) do
        {:ok, alternates} -> {:cont, {:ok, [alternates | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  # The chain is built from the last item back, so the digest of every trailing
  # slice is one link away from the next shorter one.
  defp trailing_tail_digests(key, base, items),
    do: trailing_tail_chain(key, base, trailing_item_digests(items))

  # The item digests of the trailing items, last item first, bounded like the
  # chain they feed.
  defp trailing_item_digests(items) do
    items
    |> Enum.reverse()
    |> Enum.take(@replay_tail_suffix_limit)
    |> Enum.map(&replay_tail_item_digest/1)
  end

  defp trailing_tail_chain(key, base, item_digests) do
    {_tail, digests} =
      Enum.reduce(item_digests, {base, []}, fn item_digest, {tail, digests} ->
        next = replay_tail_chain_link(key, item_digest, tail)
        {next, [next | digests]}
      end)

    Enum.reverse(digests)
  end

  defp anchored?(%{"previous_response_id" => anchor}) when is_binary(anchor), do: anchor != ""
  defp anchored?(_payload), do: false

  defp replay_tail_items(%{"input" => input}) when is_list(input), do: input
  defp replay_tail_items(%{"input" => nil}), do: []
  defp replay_tail_items(%{"input" => input}), do: [input]
  defp replay_tail_items(_payload), do: []

  defp replay_tail_base(semantic_turn_key, payload) do
    with {:ok, projection} <- replay_claim_projection(payload),
         {:ok, secret} <- configured_secret_key_base() do
      key = :crypto.hash(:sha256, secret <> <<0>> <> @replay_tail_domain)
      projection = Map.drop(projection, ["input", "previous_response_id"])

      base =
        :crypto.mac(
          :hmac,
          :sha256,
          key,
          :erlang.term_to_binary({@replay_tail_domain, semantic_turn_key, projection}, [:deterministic])
        )

      {:ok, key, base}
    end
  end

  defp replay_tail_link(key, item, tail),
    do: replay_tail_chain_link(key, replay_tail_item_digest(item), tail)

  defp replay_tail_item_digest(item), do: :crypto.hash(:sha256, :erlang.term_to_binary(item, [:deterministic]))

  defp replay_tail_chain_link(key, item_digest, tail), do: :crypto.mac(:hmac, :sha256, key, item_digest <> tail)

  @doc """
  The bounded identity of one completed output item, as the released Codex
  client resends it after a cut (findings#232 row 232-232).

  The client records every `response.output_item.done` item in its history and,
  when the connection drops before the terminal, resends the turn with those
  items appended (measured with Codex 0.156.1 through a recording proxy). It
  re-serializes each item from its own model, so the item it resends differs
  from the one it was pushed only in what that model does not keep: the item's
  `status`, a content part's `annotations` and `logprobs`, and fields it never
  had or writes as `null` (a reasoning item's `content`). The identity drops
  exactly those and binds everything else under a keyed digest, the house
  12-character shape, so a receipt can carry it without carrying content.
  `:error` for anything that is not an item map.
  """
  @spec completed_item_digest(term()) :: {:ok, String.t()} | :error
  def completed_item_digest(%{"type" => type} = item) when is_binary(type) do
    case completed_item_hmac_key() do
      {:ok, key} ->
        digest = :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(completed_item_identity(item), [:deterministic]))
        {:ok, digest |> Base.encode16(case: :lower) |> String.slice(0, 12)}

      {:error, _reason} ->
        :error
    end
  end

  def completed_item_digest(_item), do: :error

  @doc """
  The requests an unanchored native request can be the grown resend of.

  After a cut in which the client received completed items, the released
  client resends the turn as the original request with exactly those items
  appended (findings#232 row 232-232). For every count `k` of trailing items
  that could be such items (provider output: not a user, developer or system
  message and not a tool result), up to #{@grown_resend_item_limit}, this names the request
  without them (`digest`, its replay claim, which is an unanchored original's
  witness; `alternates`, the tail digests an anchored original's witness is
  found among) and the completed-item digests of the `k` items, in order. A
  predecessor is admitted only when its witness is one of those and its
  delivery receipt proves it pushed exactly those items. Empty for an anchored
  request, for a request that ends with the client's own input, and for an
  input of fewer than two items.
  """
  @spec grown_resend_candidates(<<_::256>>, map()) :: {:ok, [grown_candidate()]} | {:error, Error.reason()}
  def grown_resend_candidates(semantic_turn_key, %{"input" => [_first, _second | _rest] = input} = payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 do
    if anchored?(payload) do
      {:ok, []}
    else
      input
      |> trailing_output_run(min(@grown_resend_item_limit, length(input) - 1))
      |> Enum.reduce_while({:ok, []}, &collect_grown_resend_candidate(semantic_turn_key, payload, input, &1, &2))
      |> case do
        {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
        {:error, _reason} = error -> error
      end
    end
  end

  def grown_resend_candidates(semantic_turn_key, payload)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_map(payload),
      do: {:ok, []}

  def grown_resend_candidates(_semantic_turn_key, _payload),
    do: invalid_replay_claim("semantic_turn_key")

  defp collect_grown_resend_candidate(semantic_turn_key, payload, input, count, {:ok, candidates}) do
    case grown_resend_candidate(semantic_turn_key, payload, input, count) do
      {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp grown_resend_candidate(semantic_turn_key, payload, input, count) do
    {prefix, appended} = Enum.split(input, -count)
    prefix_payload = Map.put(payload, "input", prefix)

    with {:ok, digest} <- replay_claim_digest(semantic_turn_key, prefix_payload),
         {:ok, alternates} <- replay_claim_alternates(semantic_turn_key, prefix_payload),
         {:ok, items} <- completed_item_digests(appended) do
      {:ok, %{items: items, digest: digest, alternates: alternates}}
    end
  end

  defp completed_item_digests(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, digests} ->
      case completed_item_digest(item) do
        {:ok, digest} -> {:cont, {:ok, [digest | digests]}}
        :error -> {:halt, invalid_replay_claim("input")}
      end
    end)
    |> case do
      {:ok, digests} -> {:ok, Enum.reverse(digests)}
      {:error, _reason} = error -> error
    end
  end

  # The counts 1..n of the trailing items that could be completed provider
  # output, at most `limit`.
  defp trailing_output_run(input, limit) do
    run =
      input
      |> Enum.reverse()
      |> Enum.take(limit)
      |> Enum.take_while(&completed_output_item?/1)
      |> length()

    Enum.to_list(1..run//1)
  end

  defp completed_output_item?(%{"type" => "message", "role" => "assistant"}), do: true
  defp completed_output_item?(%{"type" => "message"}), do: false
  defp completed_output_item?(%{"type" => type}) when is_binary(type), do: not String.ends_with?(type, "_output")
  defp completed_output_item?(_item), do: false

  defp completed_item_identity(item) do
    item
    |> Map.drop(["status", "internal_chat_message_metadata_passthrough"])
    |> Map.new(fn
      {"content", parts} when is_list(parts) -> {"content", Enum.map(parts, &completed_item_part/1)}
      {key, value} -> {key, without_nulls(value)}
    end)
    |> without_nulls()
  end

  defp completed_item_part(%{} = part), do: part |> Map.drop(["annotations", "logprobs"]) |> without_nulls()
  defp completed_item_part(part), do: without_nulls(part)

  defp without_nulls(%{} = value), do: for({key, child} <- value, not is_nil(child), into: %{}, do: {key, without_nulls(child)})
  defp without_nulls(value) when is_list(value), do: Enum.map(value, &without_nulls/1)
  defp without_nulls(value), do: value

  defp completed_item_hmac_key do
    with {:ok, secret} <- configured_secret_key_base() do
      {:ok, :crypto.hash(:sha256, secret <> <<0>> <> @completed_item_domain)}
    end
  end

  @spec http_resume_input_digest(<<_::256>>, [term()]) ::
          {:ok, <<_::256>>} | {:error, Error.reason()}
  def http_resume_input_digest(semantic_turn_key, input)
      when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 and is_list(input) do
    with {:ok, key} <- replay_claim_hmac_key() do
      normalized_input = Enum.map(input, &normalize_http_resume_input_item/1)

      {:ok,
       :crypto.mac(
         :hmac,
         :sha256,
         key,
         :erlang.term_to_binary(
           {@http_resume_input_domain, semantic_turn_key, normalized_input},
           [:deterministic]
         )
       )}
    end
  end

  def http_resume_input_digest(_semantic_turn_key, _input),
    do: invalid_replay_claim("input")

  @spec raw_turn_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp raw_turn_id(payload) do
    case Map.fetch(payload, "client_metadata") do
      {:ok, client_metadata} when is_map(client_metadata) ->
        client_metadata_turn_id(client_metadata, payload)

      {:ok, nil} ->
        legacy_turn_id(payload)

      {:ok, _non_map_metadata} ->
        legacy_turn_id(payload)

      :error ->
        legacy_turn_id(payload)
    end
  end

  @spec client_metadata_turn_id(map(), map()) ::
          {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp client_metadata_turn_id(client_metadata, payload) do
    case Map.fetch(client_metadata, "turn_id") do
      {:ok, raw_turn_id} ->
        validate(raw_turn_id, @direct_turn_param)

      :error ->
        canonical_metadata_turn_id(client_metadata, payload)
    end
  end

  @spec canonical_metadata_turn_id(map(), map()) ::
          {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp canonical_metadata_turn_id(client_metadata, payload) do
    case Map.fetch(client_metadata, @canonical_metadata_key) do
      {:ok, value} ->
        case decode_canonical_metadata(value) do
          {:ok, metadata} -> canonical_turn_id(metadata, payload)
          {:error, _reason} = error -> error
        end

      :error ->
        legacy_turn_id(payload)
    end
  end

  defp canonical_turn_id(metadata, payload) do
    case fetch_canonical_turn_id(metadata) do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @canonical_turn_param)
      :missing -> legacy_turn_id(payload)
    end
  end

  @spec decode_canonical_metadata(term()) :: {:ok, map()} | {:error, Error.reason()}
  defp decode_canonical_metadata(value) when is_map(value), do: {:ok, value}

  defp decode_canonical_metadata(value) when is_binary(value) do
    case CodexPooler.JSON.decode(value) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _invalid} -> invalid(@canonical_metadata_param)
      {:error, _reason} -> invalid(@canonical_metadata_param)
    end
  end

  defp decode_canonical_metadata(_value), do: invalid(@canonical_metadata_param)

  @spec fetch_canonical_turn_id(map()) :: {:ok, term()} | :missing
  defp fetch_canonical_turn_id(metadata) do
    case Map.fetch(metadata, "turn_id") do
      {:ok, raw_turn_id} -> {:ok, raw_turn_id}
      :error -> :missing
    end
  end

  @spec legacy_turn_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp legacy_turn_id(payload) do
    case Map.fetch(payload, "turn_id") do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @turn_param)
      :error -> request_id(payload)
    end
  end

  @spec request_id(map()) :: {:ok, String.t()} | :missing | {:error, Error.reason()}
  defp request_id(payload) do
    case Map.fetch(payload, "request_id") do
      {:ok, raw_turn_id} -> validate(raw_turn_id, @request_param)
      :error -> :missing
    end
  end

  @spec validate(term(), String.t()) :: {:ok, String.t()} | {:error, Error.reason()}
  defp validate(value, param)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 256 do
    if String.valid?(value) and Regex.match?(@turn_id_pattern, value) do
      {:ok, value}
    else
      invalid(param)
    end
  end

  defp validate(_value, param), do: invalid(param)

  @spec invalid(String.t()) :: {:error, Error.reason()}
  defp invalid(param) do
    {:error, Error.invalid_request("native websocket turn identity is invalid", param)}
  end

  defp request_claim_projection(payload) do
    payload
    |> Map.drop([@turn_param, @request_param])
    |> scrub_request_client_metadata()
  end

  defp replay_claim_projection(payload) do
    payload
    |> Map.drop([@turn_param, @request_param])
    |> normalize_replay_client_metadata()
  end

  defp normalize_http_resume_input_item(%{} = item),
    do: Map.delete(item, "internal_chat_message_metadata_passthrough")

  defp normalize_http_resume_input_item(item), do: item

  defp normalize_replay_client_metadata(%{"client_metadata" => metadata} = payload)
       when is_map(metadata) do
    metadata = Map.drop(metadata, ["turn_id" | @replay_volatile_metadata_keys])

    case Map.fetch(metadata, @canonical_metadata_key) do
      {:ok, value} ->
        with {:ok, canonical} <- decode_canonical_metadata(value),
             {:ok, normalized} <- normalize_replay_metadata(canonical) do
          {:ok,
           Map.put(
             payload,
             "client_metadata",
             Map.put(metadata, @canonical_metadata_key, normalized)
           )}
        end

      :error ->
        {:ok, Map.put(payload, "client_metadata", metadata)}
    end
  end

  defp normalize_replay_client_metadata(%{"client_metadata" => nil} = payload),
    do: {:ok, payload}

  defp normalize_replay_client_metadata(%{"client_metadata" => _invalid}),
    do: invalid_replay_claim(@canonical_metadata_param)

  defp normalize_replay_client_metadata(payload), do: {:ok, payload}

  defp normalize_replay_metadata(value) when is_map(value) do
    value
    |> Map.drop(["turn_id"])
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, child}, {:ok, acc} when is_binary(key) ->
        case normalize_replay_metadata(child) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, invalid_replay_claim(@canonical_metadata_param)}
    end)
  end

  defp normalize_replay_metadata(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
      case normalize_replay_metadata(child) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_replay_metadata(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_replay_metadata(_value),
    do: invalid_replay_claim(@canonical_metadata_param)

  defp replay_claim_hmac_key do
    with {:ok, secret} <- configured_secret_key_base() do
      {:ok, :crypto.hash(:sha256, secret <> <<0>> <> @replay_claim_domain)}
    end
  end

  defp thread_scope_hmac_key do
    case configured_secret_key_base() do
      {:ok, secret} -> {:ok, :crypto.hash(:sha256, secret <> <<0>> <> @thread_scope_domain)}
      {:error, _reason} -> :error
    end
  end

  defp configured_secret_key_base do
    case Application.fetch_env(:codex_pooler, CodexPoolerWeb.Endpoint) do
      {:ok, config} when is_list(config) ->
        case Keyword.fetch(config, :secret_key_base) do
          {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
          _invalid -> invalid_replay_claim("secret_key_base")
        end

      _missing ->
        invalid_replay_claim("secret_key_base")
    end
  end

  defp invalid_replay_claim(param) do
    {:error, Error.invalid_request("native websocket replay claim is invalid", param)}
  end

  defp scrub_request_client_metadata(%{"client_metadata" => client_metadata} = payload)
       when is_map(client_metadata) do
    Map.put(
      payload,
      "client_metadata",
      Map.drop(client_metadata, @excluded_client_metadata_keys)
    )
  end

  defp scrub_request_client_metadata(payload), do: payload

  defp request_claim_hmac_key do
    :crypto.hash(:sha256, secret_key_base() <> <<0>> <> @request_claim_domain)
  end

  defp secret_key_base do
    :codex_pooler
    |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
