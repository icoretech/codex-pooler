defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodec do
  @moduledoc """
  Conversion helpers for Codex public websocket frames and upstream stream data.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.RouteClass

  @type decode_error :: :invalid_json | :not_object
  @type gateway_error :: Contracts.gateway_error()
  @type deliver_result :: :ok | {:error, gateway_error()}
  @type coerced_request :: %{
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:request_options) => RequestOptions.t()
        }

  @spec decode_payload(binary()) :: {:ok, map()} | {:error, decode_error()}
  def decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, :not_object}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  @spec deliver_result(map(), (binary() -> any())) :: deliver_result()
  def deliver_result(%{websocket_stream: stream}, _push_frame) do
    stream.()
    |> normalize_websocket_stream_result()
  end

  def deliver_result(%{websocket_messages: messages}, push_frame) do
    Enum.each(messages, fn message -> push_frame.(Jason.encode!(message)) end)
    :ok
  end

  def deliver_result(%{raw_body: body}, push_frame) do
    push_frame.(body)
    :ok
  end

  def deliver_result(%{body: body}, push_frame) do
    push_frame.(Jason.encode!(body))
    :ok
  end

  defp normalize_websocket_stream_result(:ok), do: :ok
  defp normalize_websocket_stream_result({:ok, _result}), do: :ok

  defp normalize_websocket_stream_result(
         {:error, %{status: status, code: code, message: message}} = error
       )
       when is_integer(status) and status > 0 and (is_binary(code) or is_atom(code)) and
              is_binary(message),
       do: error

  defp normalize_websocket_stream_result(_result) do
    {:error,
     %{
       status: 502,
       code: "websocket_stream_error",
       message: "websocket stream failed"
     }}
  end

  @spec warmup_result() :: map()
  def warmup_result do
    response = %{"id" => "", "usage" => nil, "end_turn" => true}

    %{
      websocket_messages: [
        %{"type" => "response.created", "response" => response},
        %{"type" => "response.completed", "response" => response}
      ]
    }
  end

  @spec ack_result() :: map()
  def ack_result, do: %{websocket_messages: []}

  @spec coerce_request(map(), RequestOptions.t(), (binary() -> any())) ::
          {:ok, coerced_request()} | {:error, gateway_error()}
  def coerce_request(payload, %RequestOptions{} = opts, push_frame)
      when is_map(payload) and is_function(push_frame, 1) do
    with {:ok, coerced} <- coerce_response_payload(payload, opts) do
      request_options =
        coerced.request_options
        |> RequestOptions.for_payload(coerced.endpoint, coerced.payload)
        |> RequestOptions.put_transport(
          transport: "websocket",
          upstream_endpoint: coerced.endpoint,
          route_class: RouteClass.proxy_websocket(),
          websocket_writer: push_frame
        )
        |> maybe_put_backend_turn_state(coerced.endpoint, coerced.payload)
        |> RequestOptions.put_continuity(
          codex_turn_id: SessionContinuity.websocket_turn_id(coerced.payload)
        )

      {:ok, %{coerced | request_options: request_options}}
    end
  end

  @spec response_processed_payload?(map()) :: boolean()
  def response_processed_payload?(%{"type" => "response.processed"}), do: true
  def response_processed_payload?(_payload), do: false

  @spec warmup_payload?(map()) :: boolean()
  def warmup_payload?(%{"generate" => false}), do: true
  def warmup_payload?(_payload), do: false

  @spec request_row_producing_response_payload?(term()) :: boolean()
  def request_row_producing_response_payload?(payload) when is_binary(payload) do
    case decode_payload(payload) do
      {:ok, decoded} -> request_row_producing_response_payload(decoded)
      {:error, _reason} -> false
    end
  end

  def request_row_producing_response_payload?(_payload), do: false

  @spec continuity_ordered_payload?(term()) :: boolean()
  def continuity_ordered_payload?(payload) when is_binary(payload) do
    case decode_payload(payload) do
      {:ok, decoded} -> continuity_ordered_payload(decoded)
      {:error, _reason} -> false
    end
  end

  def continuity_ordered_payload?(_payload), do: false

  @spec stream_messages(Ecto.UUID.t() | %{optional(:id) => Ecto.UUID.t()}, term()) :: [binary()]
  def stream_messages(request, data) do
    {messages, _buffer} = stream_messages(request, data, "")
    messages
  end

  @spec stream_messages(Ecto.UUID.t() | %{optional(:id) => Ecto.UUID.t()}, term(), binary()) ::
          {[binary()], binary()}
  def stream_messages(%{id: request_id}, data, buffer),
    do: stream_messages(request_id, data, buffer)

  def stream_messages(request_id, data, buffer)
      when is_binary(request_id) and is_binary(data) and is_binary(buffer) do
    buffered_data = buffer <> data
    {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: true)

    if oversized_incomplete_sse_prefix?(blocks, buffer, buffered_data) do
      BufferTelemetry.record_oversized_incomplete(
        "websocket_sse",
        byte_size(buffered_data),
        StreamProtocol.max_incomplete_sse_block_bytes()
      )
    end

    messages =
      case messages_from_sse_blocks(blocks) do
        [] -> direct_json_message(data)
        messages -> messages
      end

    {messages, buffer}
  end

  def stream_messages(_request_id, _data, _buffer), do: {[], ""}

  defp oversized_incomplete_sse_prefix?([], "", data),
    do: StreamProtocol.oversized_incomplete_sse_block?(data)

  defp oversized_incomplete_sse_prefix?(_blocks, _buffer, _data), do: false

  defp messages_from_sse_blocks(blocks) do
    blocks
    |> Enum.map(&StreamProtocol.normalize_codex_responses_sse_block/1)
    |> Enum.map(&IO.iodata_to_binary/1)
    |> Enum.map(&StreamProtocol.sse_field(&1, "data"))
    |> Enum.reject(&(&1 in [nil, "[DONE]"]))
    |> Enum.filter(&StreamProtocol.valid_json?/1)
  end

  defp direct_json_message(data) do
    data = StreamProtocol.canonicalize_codex_responses_json_message(data)

    if StreamProtocol.valid_json?(data), do: [data], else: []
  end

  defp coerce_response_payload(
         %{"type" => "response.create"} = payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}} = opts
       ) do
    payload
    |> Map.drop(["type", "generate"])
    |> Responses.coerce(opts)
    |> case do
      {:ok, coerced} -> {:ok, %{coerced | payload: Map.put(coerced.payload, "generate", true)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coerce_response_payload(payload, opts) do
    {:ok, %{endpoint: "/backend-api/codex/responses", payload: payload, request_options: opts}}
  end

  defp maybe_put_backend_turn_state(
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}} =
           request_options,
         _endpoint,
         _payload
       ) do
    request_options
  end

  defp maybe_put_backend_turn_state(
         %RequestOptions{} = request_options,
         "/backend-api/codex/responses",
         payload
       ) do
    case PayloadNormalizer.backend_client_metadata_turn_state(payload) do
      nil ->
        request_options

      turn_state ->
        RequestOptions.put_continuity(request_options, accepted_turn_state: turn_state)
    end
  end

  defp maybe_put_backend_turn_state(%RequestOptions{} = request_options, _endpoint, _payload),
    do: request_options

  defp request_row_producing_response_payload(%{"type" => "response.processed"}), do: true
  defp request_row_producing_response_payload(%{"generate" => false}), do: false
  defp request_row_producing_response_payload(%{"type" => "response.create"}), do: true

  defp request_row_producing_response_payload(%{"model" => model}) when is_binary(model),
    do: String.trim(model) != ""

  defp request_row_producing_response_payload(_payload), do: false

  defp continuity_ordered_payload(%{"type" => "response.processed"}), do: true

  defp continuity_ordered_payload(
         %{"type" => "response.create", "previous_response_id" => previous_response_id} =
           payload
       )
       when is_binary(previous_response_id) do
    payload
    |> Map.get("input")
    |> ToolResultShape.items()
    |> Enum.any?()
  end

  defp continuity_ordered_payload(_payload), do: false
end
