defmodule CodexPooler.Gateway.Transports.BoundedResponseBody do
  @moduledoc false

  @default_max_bytes 8 * 1024 * 1024
  @state_key :codex_pooler_bounded_response_body_state
  @exceeded_key :codex_pooler_response_body_limit_exceeded

  @type collector ::
          ({:data, binary()}, {Req.Request.t(), Req.Response.t()} ->
             {:cont | :halt, {Req.Request.t(), Req.Response.t()}})
  @type metadata :: %{
          required(String.t()) => boolean() | non_neg_integer()
        }

  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @spec collector(pos_integer()) :: collector()
  def collector(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, data}, {request, %Req.Response{} = response} when is_binary(data) ->
      response = collect_data(response, data, max_bytes)
      flow = if exceeded?(response), do: :halt, else: :cont

      {flow, {request, response}}
    end
  end

  @spec finalize(Req.Response.t()) :: Req.Response.t()
  def finalize(%Req.Response{} = response) do
    cond do
      exceeded?(response) ->
        response
        |> Map.replace!(:body, "")
        |> clear_state()

      state = Req.Response.get_private(response, @state_key) ->
        response
        |> Map.replace!(:body, materialize_chunks(state))
        |> clear_state()

      true ->
        response
    end
  end

  @spec exceeded?(Req.Response.t()) :: boolean()
  def exceeded?(%Req.Response{} = response),
    do: is_map(Req.Response.get_private(response, @exceeded_key))

  @spec metadata(Req.Response.t()) :: metadata()
  def metadata(%Req.Response{} = response) do
    case Req.Response.get_private(response, @exceeded_key) do
      %{limit: limit, seen_bytes: seen_bytes} = metadata ->
        %{
          "response_body_limit_exceeded" => true,
          "response_body_limit_bytes" => limit,
          "response_body_seen_bytes" => seen_bytes
        }
        |> maybe_put_content_length(Map.get(metadata, :content_length))

      _metadata ->
        %{}
    end
  end

  defp collect_data(%Req.Response{} = response, data, max_bytes) do
    state = response_state(response, max_bytes)
    {state, content_length} = maybe_parse_content_length(response, state)

    cond do
      is_integer(content_length) and content_length > max_bytes ->
        mark_exceeded(response, max_bytes, byte_size(data), content_length)

      state.seen_bytes + byte_size(data) > max_bytes ->
        mark_exceeded(response, max_bytes, state.seen_bytes + byte_size(data), content_length)

      true ->
        state = %{
          state
          | chunks: [data | state.chunks],
            seen_bytes: state.seen_bytes + byte_size(data)
        }

        Req.Response.put_private(response, @state_key, state)
    end
  end

  defp response_state(%Req.Response{} = response, max_bytes) do
    Req.Response.get_private(response, @state_key, %{
      chunks: [],
      content_length: nil,
      content_length_checked?: false,
      limit: max_bytes,
      seen_bytes: 0
    })
  end

  defp maybe_parse_content_length(response, %{content_length_checked?: false} = state) do
    content_length =
      response
      |> Req.Response.get_header("content-length")
      |> List.first()
      |> parse_content_length()

    state = %{state | content_length: content_length, content_length_checked?: true}
    {state, content_length}
  end

  defp maybe_parse_content_length(_response, state), do: {state, state.content_length}

  defp parse_content_length(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {length, ""} when length >= 0 -> length
      _value -> nil
    end
  end

  defp parse_content_length(_value), do: nil

  defp mark_exceeded(response, limit, seen_bytes, content_length) do
    response
    |> Req.Response.put_private(@exceeded_key, %{
      content_length: content_length,
      limit: limit,
      seen_bytes: seen_bytes
    })
    |> clear_state()
    |> Map.replace!(:body, "")
  end

  defp materialize_chunks(%{chunks: chunks}),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp clear_state(%Req.Response{} = response),
    do: %{response | private: Map.delete(response.private, @state_key)}

  defp maybe_put_content_length(metadata, content_length) when is_integer(content_length),
    do: Map.put(metadata, "response_body_content_length", content_length)

  defp maybe_put_content_length(metadata, _content_length), do: metadata
end
