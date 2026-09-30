defmodule CodexPooler.Gateway.Payloads.NativeMailboxContinuation do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounting.ClientRetry.OriginalWitness
  alias CodexPooler.Gateway.Payloads.{NativeTurnContinuation, RequestOptions, WebsocketTurnIdentity}

  @max_mailbox_runs 16
  @max_completed_items 4
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"

  # Mailbox delivery can stop the client after a reasoning/commentary item and
  # append new input before its next request. Keep the original resume claim:
  # a separate key would bypass old pods during a rolling deployment. Instead
  # seal the candidate prefix, delivered output and mailbox boundary for the
  # accounting chain to verify against its actual predecessor and successor.
  #
  # The same cut happens inside an ordinary turn: the opener streams a
  # commentary or reasoning item, mailbox input arrives, and the client resends
  # the turn under its bare `codex-turn:` claim with that item and the mail
  # appended. Only the opener shares its claim with such a resend; a tool
  # continuation is named by its whole payload, so its grown resend never meets
  # its predecessor. Mail addressed before the latest user message belongs to
  # an earlier turn and is never a candidate boundary.
  @spec attach(OriginalWitness.t(), <<_::256>>, map(), RequestOptions.t()) :: OriginalWitness.t()
  def attach(%OriginalWitness{} = witness, semantic_key, payload, options) do
    %{witness | mailbox: candidates(semantic_key, payload, options)}
  end

  defp candidates(semantic_key, %{"input" => input} = payload, options) when is_list(input) do
    with nil <- Map.get(payload, "previous_response_id"),
         "turn" <- NativeTurnContinuation.request_kind(payload, options),
         true <- mailbox_role?(NativeTurnContinuation.turn_role(payload)),
         %{"agent_name" => agent} when is_binary(agent) and byte_size(agent) in 1..256 <-
           payload |> NativeTurnContinuation.canonical_document(options) |> NativeTurnContinuation.canonical_metadata_map(),
         runs when length(runs) <= @max_mailbox_runs <- mailbox_runs(input, agent) do
      build_candidates(semantic_key, payload, input, runs)
    else
      _ineligible -> []
    end
  end

  defp candidates(_semantic_key, _payload, _options), do: []

  defp mailbox_role?({:post_compaction_resume, _anchor}), do: true
  defp mailbox_role?(:opening), do: true
  defp mailbox_role?(_role), do: false

  defp build_candidates(semantic_key, payload, input, runs) do
    ranges = Enum.flat_map(runs, &candidate_ranges(input, &1))
    {candidates, _cache} = Enum.reduce(ranges, {[], %{}}, &build_candidate(semantic_key, payload, input, &1, &2))
    candidates
  end

  defp candidate_ranges(input, {start, finish}) do
    input
    |> Enum.take(start)
    |> Enum.reverse()
    |> Enum.take(@max_completed_items)
    |> Enum.take_while(&preemptible_output?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {_item, count} -> {start - count, count, finish} end)
  end

  defp build_candidate(semantic_key, payload, input, {prefix_count, count, finish}, {candidates, cache}) do
    output = Enum.slice(input, prefix_count, count)
    {prefix, cache} = witnesses_at(semantic_key, payload, prefix_count, cache)
    {ending, cache} = witnesses_at(semantic_key, payload, finish, cache)

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
        compaction?(item) or user_message?(item) -> []
        incoming?(item, agent) -> extend_run(runs, index)
        true -> runs
      end
    end)
    |> Enum.reverse()
  end

  defp compaction?(%{"type" => type}), do: type in ["compaction", "compaction_summary", "context_compaction"]
  defp compaction?(_item), do: false

  defp user_message?(%{"role" => "user"} = item), do: Map.get(item, "type", "message") == "message"
  defp user_message?(_item), do: false

  defp extend_run([{start, index} | rest], index), do: [{start, index + 1} | rest]
  defp extend_run(runs, index), do: [{index, index + 1} | runs]

  defp incoming?(%{"type" => "agent_message", "author" => author, "recipient" => agent, "content" => [_first | _rest] = content}, agent)
       when is_binary(author) and byte_size(author) in 1..256 and author != agent,
       do: Enum.all?(content, &mailbox_content?/1)

  defp incoming?(_item, _agent), do: false
  defp mailbox_content?(%{"type" => "input_text", "text" => text}), do: is_binary(text) and byte_size(text) > 0
  defp mailbox_content?(%{"type" => "encrypted_content", "encrypted_content" => value}), do: is_binary(value) and byte_size(value) > 0
  defp mailbox_content?(_part), do: false

  defp preemptible_output?(%{"type" => "reasoning"}), do: true
  defp preemptible_output?(%{"type" => "message", "role" => "assistant", "phase" => "commentary"}), do: true
  defp preemptible_output?(_item), do: false

  defp witnesses_at(semantic_key, payload, count, cache) do
    case Map.fetch(cache, count) do
      {:ok, witnesses} ->
        {witnesses, cache}

      :error ->
        witnesses = prefix_witnesses(semantic_key, Map.update!(payload, "input", &Enum.take(&1, count)))
        {witnesses, Map.put(cache, count, witnesses)}
    end
  end

  defp prefix_witnesses(semantic_key, payload) do
    frame = Map.put(payload, "type", "response.create")
    metadata = Map.get(frame, "client_metadata")
    marked = if is_map(metadata) or is_nil(metadata), do: Map.put(frame, "client_metadata", Map.put(metadata || %{}, @lite_marker, "true")), else: frame

    with {:ok, http} <- WebsocketTurnIdentity.http_resume_input_digest(semantic_key, payload["input"]),
         {:ok, plain} <- WebsocketTurnIdentity.replay_claim_digest(semantic_key, frame),
         {:ok, lite} <- WebsocketTurnIdentity.replay_claim_digest(semantic_key, marked) do
      %{http: http, websocket: Enum.uniq([plain, lite])}
    else
      _unproved -> nil
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
