defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodec do
  @moduledoc """
  Conversion helpers for Codex public websocket frames and upstream stream data.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.ToolResultShape
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.RouteClass

  @failed_stream_buffer <<0, "codex-pooler-websocket-stream-failed", 0>>

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
    case public_websocket_messages(messages) do
      {:ok, frames} ->
        Enum.each(frames, push_frame)
        :ok

      {:error, frame} ->
        push_frame.(frame)
        websocket_stream_error()
    end
  end

  def deliver_result(%{raw_body: body}, push_frame) do
    deliver_projected_json(body, push_frame)
  end

  def deliver_result(%{body: body}, push_frame) do
    deliver_projected_json(Jason.encode!(body), push_frame)
  end

  defp deliver_projected_json(body, push_frame) do
    case PublicProjection.json_message_result(body) do
      {:ok, frame, _projected} ->
        push_frame.(frame)
        :ok

      {:error, frame} ->
        push_frame.(frame)

        {:error,
         %{status: 502, code: "websocket_stream_error", message: "websocket stream failed"}}
    end
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
    websocket_stream_error()
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
      push_frame = namespace_restoring_writer(push_frame, coerced.request_options)

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

  defp namespace_restoring_writer(
         push_frame,
         %RequestOptions{openai_compatibility: %{custom_tool_namespaces: namespaces}}
       )
       when is_function(push_frame, 1) and map_size(namespaces) > 0 do
    fn data ->
      data
      |> restore_custom_tool_call_namespaces(namespaces)
      |> PublicProjection.json_message()
      |> push_frame.()
    end
  end

  defp namespace_restoring_writer(push_frame, %RequestOptions{}) do
    fn data -> data |> PublicProjection.json_message() |> push_frame.() end
  end

  defp restore_custom_tool_call_namespaces(data, namespaces) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        restored = Responses.restore_custom_tool_call_namespaces(decoded, namespaces)
        if restored === decoded, do: data, else: Jason.encode!(restored)

      _invalid ->
        data
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

  def stream_messages(_request_id, _data, @failed_stream_buffer),
    do: {[], @failed_stream_buffer}

  def stream_messages(request_id, data, buffer)
      when is_binary(request_id) and is_binary(data) and is_binary(buffer) do
    {blocks, next_buffer} =
      StreamProtocol.complete_sse_blocks(buffer, data, bounded?: false)

    if StreamProtocol.oversized_incomplete_sse_block?(next_buffer) do
      BufferTelemetry.record_oversized_incomplete(
        "websocket_sse",
        byte_size(next_buffer),
        StreamProtocol.max_incomplete_sse_block_bytes()
      )

      fail_stream()
    else
      project_stream_messages(blocks, buffer, data, next_buffer)
    end
  end

  def stream_messages(_request_id, _data, _buffer), do: {[], ""}

  @doc false
  @spec failed_stream_buffer?(term()) :: boolean()
  def failed_stream_buffer?(@failed_stream_buffer), do: true
  def failed_stream_buffer?(_buffer), do: false

  defp messages_from_sse_blocks(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, messages} ->
      case sse_block_message(block) do
        {:ok, nil} -> {:cont, {:ok, messages}}
        {:ok, message} -> {:cont, {:ok, [message | messages]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      :error -> :error
    end
  end

  defp sse_block_message(block) do
    case StreamProtocol.sse_field(block, "data") do
      nil -> if comment_sse_block?(block), do: {:ok, nil}, else: :error
      "[DONE]" -> {:ok, nil}
      data -> canonical_sse_data_message(data)
    end
  end

  defp comment_sse_block?(block) do
    block
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> case do
      [] -> false
      lines -> Enum.all?(lines, &String.starts_with?(String.trim_leading(&1), ":"))
    end
  end

  defp canonical_sse_data_message(data) do
    canonical_json_message(data)
  end

  defp direct_json_message(data) do
    canonical_json_message(data)
  end

  defp canonical_json_message(data) do
    with {:ok, %{} = decoded} <- Jason.decode(data),
         {canonical, _decoded} =
           StreamProtocol.canonicalize_codex_responses_json_message(data, decoded),
         {:ok, projected, _decoded} <- PublicProjection.json_message_result(canonical) do
      {:ok, projected}
    else
      _invalid -> :error
    end
  end

  defp project_stream_messages([], "", data, next_buffer) do
    cond do
      next_buffer != data ->
        {[], next_buffer}

      incomplete_sse_prefix?(data) ->
        {[], next_buffer}

      true ->
        case direct_json_message(data) do
          {:ok, message} -> {[message], ""}
          :error -> fail_stream()
        end
    end
  end

  defp project_stream_messages([], _buffer, _data, next_buffer), do: {[], next_buffer}

  defp project_stream_messages(blocks, _buffer, _data, next_buffer) do
    case messages_from_sse_blocks(blocks) do
      {:ok, messages} -> {messages, next_buffer}
      :error -> fail_stream()
    end
  end

  defp incomplete_sse_prefix?(data) do
    trimmed = String.trim_leading(data)

    String.starts_with?(trimmed, ["data:", "event:", "id:", "retry:", ":"])
  end

  defp fail_stream, do: {[local_failure_frame()], @failed_stream_buffer}

  defp local_failure_frame do
    {:error, frame} = PublicProjection.json_message_result("")
    frame
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

  defp coerce_response_payload(
         _payload,
         %RequestOptions{openai_compatibility: %{public_openai_responses_stream: true}}
       ) do
    {:error,
     %{
       status: 400,
       code: "invalid_request",
       message: "unsupported websocket message type",
       param: "type"
     }}
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
    case request_options.continuity do
      %{resolved_turn_state_assignment_id: assignment_id} when is_binary(assignment_id) ->
        request_options

      _unresolved ->
        case PayloadNormalizer.backend_client_metadata_turn_state(payload) do
          nil ->
            request_options

          turn_state ->
            RequestOptions.put_continuity(request_options, accepted_turn_state: turn_state)
        end
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

  defp public_websocket_messages(messages) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, frames} ->
      case public_websocket_message(message) do
        {:ok, frame} -> {:cont, {:ok, [frame | frames]}}
        {:error, frame} -> {:halt, {:error, frame}}
      end
    end)
    |> case do
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      {:error, frame} -> {:error, frame}
    end
  end

  defp public_websocket_messages(_messages), do: {:error, local_failure_frame()}

  defp public_websocket_message(%{} = message) do
    case PublicProjection.gateway_body_result(message) do
      {:ok, projected} -> {:ok, Jason.encode!(projected)}
      :error -> {:error, local_failure_frame()}
    end
  end

  defp public_websocket_message(message) when is_binary(message) do
    case PublicProjection.json_message_result(message) do
      {:ok, frame, _projected} -> {:ok, frame}
      {:error, frame} -> {:error, frame}
    end
  end

  defp public_websocket_message(_message), do: {:error, local_failure_frame()}

  defp websocket_stream_error do
    {:error,
     %{
       status: 502,
       code: "websocket_stream_error",
       message: "websocket stream failed"
     }}
  end
end
