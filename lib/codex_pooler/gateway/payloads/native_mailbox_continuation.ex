defmodule CodexPooler.Gateway.Payloads.NativeMailboxContinuation do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounting.ClientRetry.OriginalWitness
  alias CodexPooler.Gateway.Payloads.{NativeTurnContinuation, RequestOptions, WebsocketTurnIdentity}

  @max_mailbox_runs 16
  @max_completed_items 4
  @preemptible_message_phases ["commentary", "partial_answer"]
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"

  # Mailbox delivery can stop the client after a reasoning, commentary or
  # partial-answer item and append new input before its next request. Keep
  # the original turn claim: a separate key would bypass old pods during a
  # rolling deployment. Instead seal the candidate prefix, delivered output
  # and mailbox boundary for the accounting chain to verify against its
  # actual predecessor and successor.
  @spec attach(OriginalWitness.t(), <<_::256>>, map(), RequestOptions.t()) :: OriginalWitness.t()
  def attach(%OriginalWitness{} = witness, semantic_key, payload, options) do
    %{witness | mailbox: candidates(semantic_key, payload, options), mailbox_intent?: mailbox_intent?(payload)}
  end

  # Intent is diagnostic only: an invalid mailbox shape still has no proof.
  defp mailbox_intent?(%{"input" => input}) when is_list(input) and is_integer(length(input)),
    do: Enum.any?(input, &match?(%{"type" => "agent_message"}, &1))

  defp mailbox_intent?(_payload), do: false

  defp candidates(semantic_key, %{"input" => input} = payload, options) when is_list(input) do
    with nil <- Map.get(payload, "previous_response_id"),
         "turn" <- NativeTurnContinuation.request_kind(payload, options),
         %{"agent_name" => agent} when is_binary(agent) and byte_size(agent) in 1..256 <-
           payload |> NativeTurnContinuation.canonical_document(options) |> NativeTurnContinuation.canonical_metadata_map() do
      build_candidates(semantic_key, witness_payloads(payload, options), input, mailbox_runs(input, agent))
    else
      _ineligible -> []
    end
  end

  defp candidates(_semantic_key, _payload, _options), do: []

  # A request whose canonical document carries the fields the released client
  # fills asynchronously also names the request it was before they were
  # filled, so a predecessor (or a historical successor) sent before them
  # still matches (`NativeTurnContinuation.without_async_turn_metadata/1`,
  # findings#314 row 314-2), on either transport.
  defp witness_payloads(payload, _options) do
    case NativeTurnContinuation.without_async_turn_metadata(payload) do
      {:ok, earlier} -> [payload, earlier]
      :none -> [payload]
    end
  end

  defp build_candidates(semantic_key, payloads, input, runs) do
    ranges = Enum.flat_map(runs, &candidate_ranges(input, &1))
    {candidates, _cache} = Enum.reduce(ranges, {[], %{}}, &build_candidate(semantic_key, payloads, input, &1, &2))
    candidates
  end

  defp candidate_ranges(input, {start, finish}) do
    preceding = input |> Enum.take(start) |> Enum.reverse()
    output = preceding |> Enum.take(@max_completed_items) |> Enum.take_while(&preemptible_output?/1)

    if output == [] do
      fulfilled_call_ranges(preceding, start, finish)
    else
      output |> Enum.with_index(1) |> Enum.map(fn {_item, count} -> {start - count, Enum.slice(input, start - count, count), finish} end)
    end
  end

  # Codex drains in-flight tools after a mailbox preemption and before recording
  # the mail. Results are client input; only the matching provider calls and
  # preemptible output participate in the original ordered server-write proof.
  defp fulfilled_call_ranges(preceding, start, finish) do
    {results, remaining} = preceding |> Enum.take(@max_completed_items * 2) |> Enum.split_while(&(tool_result_pair(&1) != nil))

    if results != [] and length(results) <= @max_completed_items and preemptible_output?(List.first(remaining)) do
      ordered_results = Enum.reverse(results)

      remaining
      |> Enum.take(@max_completed_items)
      |> Enum.take_while(&(preemptible_output?(&1) or provider_call_pair(&1) != nil))
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {_item, count} -> fulfilled_call_range(remaining, ordered_results, start, count, finish) end)
    else
      []
    end
  end

  defp fulfilled_call_range(remaining, results, start, count, finish) do
    output = remaining |> Enum.take(count) |> Enum.reverse()
    calls = Enum.filter(output, &(provider_call_pair(&1) != nil))
    if fulfilled_calls?(calls, results), do: [{start - length(results) - count, output, finish}], else: []
  end

  defp fulfilled_calls?(calls, results) do
    pairs = Enum.map(calls, &provider_call_pair/1)
    ids = Enum.map(pairs, &elem(&1, 1))

    pairs != [] and length(ids) == length(Enum.uniq(ids)) and pairs == Enum.map(results, &tool_result_pair/1) and
      Enum.zip(calls, results) |> Enum.all?(fn {call, result} -> Enum.all?(["name", "namespace"], fn key -> not Map.has_key?(result, key) or Map.get(result, key) == Map.get(call, key) end) end)
  end

  defp provider_call_pair(%{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => arguments}) when is_binary(id) and byte_size(id) > 0 and is_binary(name) and byte_size(name) > 0 and is_binary(arguments), do: {"function_call_output", id}
  defp provider_call_pair(%{"type" => "custom_tool_call", "call_id" => id, "name" => name, "input" => input}) when is_binary(id) and byte_size(id) > 0 and is_binary(name) and byte_size(name) > 0 and is_binary(input), do: {"custom_tool_call_output", id}
  defp provider_call_pair(_item), do: nil

  defp tool_result_pair(%{"type" => type, "call_id" => id, "output" => output}) when type in ["function_call_output", "custom_tool_call_output"] and is_binary(id) and byte_size(id) > 0 and (is_binary(output) or (is_list(output) and is_integer(length(output)))), do: {type, id}
  defp tool_result_pair(_item), do: nil

  defp build_candidate(semantic_key, payloads, input, {prefix_count, output, finish}, {candidates, cache}) do
    {prefix, cache} = witnesses_at(semantic_key, payloads, prefix_count, cache)
    {ending, cache} = witnesses_at(semantic_key, payloads, finish, cache)

    case {prefix, ending, output_digests(output)} do
      {%{} = prefix, %{} = ending, {:ok, items}} ->
        candidate = %{prefix: prefix, ending: ending, current?: finish == length(input), items: items, http_progress: ClientRetry.native_http_mailbox_progress_candidates(output)}
        {[candidate | candidates], cache}

      _unproved ->
        {candidates, cache}
    end
  end

  defp mailbox_runs(input, agent) do
    input
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, index}, runs ->
      cond do
        history_boundary?(item) -> []
        incoming?(item, agent) -> extend_run(runs, index)
        true -> runs
      end
    end)
    |> Enum.reverse()
  end

  defp history_boundary?(%{"type" => "message", "role" => "user"}), do: true
  defp history_boundary?(%{"type" => type}), do: type in ["compaction", "compaction_summary", "context_compaction"]
  defp history_boundary?(_item), do: false

  defp extend_run([{start, index} | rest], index), do: [{start, index + 1} | rest]

  # Keep recent recovery boundaries bounded without discarding their complete
  # history from the prefix witness. An omitted historical edge stays fenced.
  defp extend_run(runs, index), do: [{index, index + 1} | Enum.take(runs, @max_mailbox_runs - 1)]

  defp incoming?(%{"type" => "agent_message", "author" => author, "recipient" => agent, "content" => [_first | _rest] = content}, agent)
       when is_binary(author) and byte_size(author) in 1..256 and author != agent,
       do: Enum.all?(content, &mailbox_content?/1)

  defp incoming?(_item, _agent), do: false
  defp mailbox_content?(%{"type" => "input_text", "text" => text}), do: is_binary(text) and byte_size(text) > 0
  defp mailbox_content?(%{"type" => "encrypted_content", "encrypted_content" => value}), do: is_binary(value) and byte_size(value) > 0
  defp mailbox_content?(_part), do: false

  # Output the client can be stopped after: reasoning and the nonterminal assistant phases. Codex treats
  # `partial_answer` like `commentary` here (989c01a41 / 822e58cc3: mailbox preemption and open delivery); only
  # `final_answer` and an unphased message are terminal answers and never qualify.
  defp preemptible_output?(%{"type" => "reasoning"}), do: true
  defp preemptible_output?(%{"type" => "message", "role" => "assistant", "phase" => phase}) when phase in @preemptible_message_phases, do: true
  defp preemptible_output?(_item), do: false

  defp witnesses_at(semantic_key, payloads, count, cache) do
    case Map.fetch(cache, count) do
      {:ok, witnesses} ->
        {witnesses, cache}

      :error ->
        witnesses = prefix_witnesses(semantic_key, Enum.map(payloads, fn payload -> Map.update!(payload, "input", &Enum.take(&1, count)) end))
        {witnesses, Map.put(cache, count, witnesses)}
    end
  end

  # `payloads` share one input: the request, then the request as it was before
  # the client filled its asynchronous turn metadata (`witness_payloads/2`),
  # whose frame digests and trailing-slice digests (an anchored websocket
  # original's witness) join the request's own under the same bound; every
  # variant's items are hashed once.
  defp prefix_witnesses(semantic_key, [payload | earlier]) do
    variants = frame_variants(payload) |> Enum.uniq()
    earlier_variants = earlier |> Enum.flat_map(&frame_variants/1) |> Enum.uniq()

    with {:ok, http} <- WebsocketTurnIdentity.http_resume_input_digest(semantic_key, payload["input"]),
         {:ok, digests} <- replay_claim_digests(semantic_key, variants ++ earlier_variants),
         {:ok, tails} <- WebsocketTurnIdentity.replay_claim_alternates_of_variants(semantic_key, variants ++ earlier_variants) do
      # HTTP tool continuations retain their original unframed replay witness;
      # opening HTTP requests use the reconstructed websocket variants instead.
      # A websocket opener may have been anchored with only its input delta.
      # Its stored tail witness is matched before retained output and mail are
      # appended, using the same bounded full-history proof as an exact resend.
      %{http: http, websocket: Enum.uniq(digests ++ List.flatten(tails))}
    else
      _unproved -> nil
    end
  end

  # The websocket frame (plain and Lite-marked) and the unframed body.
  defp frame_variants(payload) do
    frame = Map.put(payload, "type", "response.create")
    metadata = Map.get(frame, "client_metadata")
    marked = if is_map(metadata) or is_nil(metadata), do: Map.put(frame, "client_metadata", Map.put(metadata || %{}, @lite_marker, "true")), else: frame
    [frame, marked, payload]
  end

  # In variant order: the plain frame's digest stays the first witness.
  defp replay_claim_digests(semantic_key, variants) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, digests} ->
      case WebsocketTurnIdentity.replay_claim_digest(semantic_key, variant) do
        {:ok, digest} -> {:cont, {:ok, [digest | digests]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, digests} -> {:ok, Enum.reverse(digests)}
      {:error, _reason} = error -> error
    end
  end

  defp output_digests(output) do
    Enum.reduce_while(output, {:ok, []}, fn item, {:ok, digests} ->
      case WebsocketTurnIdentity.completed_item_digest(item) do
        {:ok, digest} -> {:cont, {:ok, digests ++ [digest]}}
        :error -> {:halt, :error}
      end
    end)
  end
end
