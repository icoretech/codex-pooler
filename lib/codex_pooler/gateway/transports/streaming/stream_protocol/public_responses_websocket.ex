defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesWebsocket do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Runtime.Finalization.ProviderUsageLimit
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence
  alias CodexPooler.Gateway.Websocket.Adapter

  @type state :: %{
          required(:max_seen) => integer() | nil,
          required(:terminal_latched?) => boolean(),
          required(:overflow_latched?) => boolean(),
          optional(:stream_id) => String.t(),
          optional(:custom_tool_namespaces) => map()
        }
  @type result ::
          {:push, binary(), state()}
          | {:drop, state()}
          | {:error, map(), state()}

  @spec new_state() :: state()
  @spec new_state(String.t() | nil) :: state()
  def new_state(stream_id \\ nil)

  def new_state(nil), do: PublicResponsesSequence.new_state()

  def new_state(stream_id) when is_binary(stream_id) do
    PublicResponsesSequence.new_state()
    |> Map.put(:stream_id, stream_id)
  end

  @spec normalize(binary(), state()) :: result()
  def normalize(data, state) when is_binary(data) do
    stream_id = Map.get(state, :stream_id)

    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = source_decoded} ->
        cond do
          PublicResponses.provider_rejection_frame?(source_decoded) -> provider_rejection(source_decoded, state, stream_id)
          PublicResponses.provider_usage_limit_frame?(source_decoded) -> provider_usage_limit(source_decoded, state, stream_id)
          match?({:withheld, _seconds}, ProviderUsageLimit.withheld(source_decoded)) -> withheld_usage_limit(source_decoded, state, stream_id)
          true -> normalize_decoded(data, source_decoded, state, stream_id)
        end

      _invalid ->
        {:drop, state}
    end
  end

  defp normalize_decoded(data, source_decoded, state, stream_id) do
    {_data, decoded} = PublicResponses.normalize_json_message(data, source_decoded)
    decoded = PublicResponses.drop_provider_event_headers(decoded)
    event_type = string_value(decoded, "type")

    case public_event(event_type, decoded, state) do
      {:emit, type, normalized, state} ->
        normalized =
          type
          |> PublicResponses.normalize_terminal_errors(normalized)
          |> Responses.restore_custom_tool_call_namespaces(Map.get(state, :custom_tool_namespaces, %{}))
          |> maybe_put_stream_id(stream_id)

        {:push, CodexPooler.JSON.encode!(normalized), state}

      {:drop, state} ->
        {:drop, state}

      {:overflow, _failed, state} ->
        {:error, sequence_exhausted(), state}
    end
  end

  # A provider refusal sent as the upstream websocket's wrapped error frame
  # (4xx, 429 and the Codex websocket-retry codes excluded) reaches the public
  # client as the OpenAI websocket mode's `error` event with the status and
  # error object `/v1/responses` answers over HTTP, instead of a masked
  # `response.failed` `server_error` an SDK would retry (findings#254 row
  # 254-15). The owner passes the frame through unmasked for this
  # (`PublicResponses.normalize_owner_json_message/2`).
  defp provider_rejection(%{"error" => error} = source_decoded, state, stream_id) do
    status = Map.get(source_decoded, "status", Map.get(source_decoded, "status_code"))
    event = PublicResponse.provider_rejection_websocket_event(status, error)

    case PublicResponsesSequence.assign("error", event, state, :websocket) do
      {:emit, _type, event, state} -> {:push, CodexPooler.JSON.encode!(maybe_put_stream_id(event, stream_id)), state}
      {:drop, state} -> {:drop, state}
      {:overflow, _failed, state} -> {:error, sequence_exhausted(), state}
    end
  end

  # A provider usage limit sent as the wrapped `429` frame, with a reset still
  # ahead, reaches the public client as the terminal usage-limit event every
  # other surface sends (findings#206 row 206-546): `usage_limit_reached`, the
  # Pooler's code and message, the reset fields and `headers.retry-after`,
  # never the provider's message or plan. It used to be the masked
  # `response.failed` `rate_limit_error`, which an SDK retries.
  defp provider_usage_limit(source_decoded, state, stream_id) do
    {:ok, error} = ProviderUsageLimit.frame_error(source_decoded)

    case PublicResponsesSequence.assign("error", Adapter.websocket_error(error), state, :websocket) do
      {:emit, _type, event, state} -> {:push, CodexPooler.JSON.encode!(maybe_put_stream_id(event, stream_id)), state}
      {:drop, state} -> {:drop, state}
      {:overflow, _failed, state} -> {:error, sequence_exhausted(), state}
    end
  end

  # A provider usage limit whose Pool advice was withheld (another candidate's
  # return is not known) reaches the public client as the error event of the
  # `/v1` HTTP answer to the same refusal: status `429`, the redacted
  # `rate_limit_error`, and `headers.retry-after` when an open circuit of
  # another candidate bounds the wait (findings#206 row 206-593). It used to be
  # a masked `response.failed` with no retry advice.
  defp withheld_usage_limit(source_decoded, state, stream_id) do
    {:withheld, seconds} = ProviderUsageLimit.withheld(source_decoded)
    error = PublicResponse.normalize_error(%{"code" => "upstream_rate_limited"}, status: 429)
    event = %{"type" => "error", "status" => 429, "error" => error}
    event = if seconds, do: Map.put(event, "headers", %{"retry-after" => Integer.to_string(seconds)}), else: event

    case PublicResponsesSequence.assign("error", event, state, :websocket) do
      {:emit, _type, event, state} -> {:push, CodexPooler.JSON.encode!(maybe_put_stream_id(event, stream_id)), state}
      {:drop, state} -> {:drop, state}
      {:overflow, _failed, state} -> {:error, sequence_exhausted(), state}
    end
  end

  # Only the public Responses vocabulary reaches a public websocket client, as
  # on the public SSE relay: `response.*` (unknown ones included), the `error`
  # terminal and `keepalive`. Backend-internal types (`codex.*` controls, the
  # upstream websocket's `responsesapi.websocket_timing`) and typeless
  # non-terminal frames are dropped before they take a sequence number
  # (findings#254 row 254-14).
  defp public_event(event_type, decoded, state) do
    case PublicResponsesSequence.public_shape(event_type, decoded) do
      {:ok, type, public_decoded} ->
        if public_websocket_event?(type),
          do: PublicResponsesSequence.assign(type, public_decoded, state, :websocket),
          else: {:drop, state}

      :drop ->
        {:drop, state}
    end
  end

  defp public_websocket_event?("error"), do: true
  defp public_websocket_event?(type), do: PublicResponses.public_stream_event?(type)

  defp sequence_exhausted do
    %{
      status: 500,
      code: :websocket_sequence_exhausted,
      message: "websocket response sequence exhausted",
      param: nil
    }
  end

  defp maybe_put_stream_id(event, stream_id) when is_binary(stream_id) do
    Map.put(event, "stream_id", stream_id)
  end

  defp maybe_put_stream_id(event, _stream_id), do: event

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
