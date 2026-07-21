defmodule CodexPooler.Gateway.Websocket.Adapter do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ErrorSanitizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DownstreamSession

  @type socket_state :: map()

  @spec put_runtime(socket_state(), Websocket.websocket_runtime()) :: socket_state()
  def put_runtime(state, runtime), do: DownstreamSession.put_runtime(state, runtime)

  @spec owner?(socket_state()) :: boolean()
  def owner?(state), do: DownstreamSession.owner?(state)

  @spec owner_error?(term()) :: boolean()
  def owner_error?(reason), do: WebsocketOwnerContract.owner_error?(reason)

  @spec close_detail(term()) :: {pos_integer(), String.t()}
  def close_detail(reason), do: DownstreamSession.close_detail(reason)

  @spec accept_downstream_message(term(), socket_state()) ::
          WebsocketOwnerContract.downstream_match_result() | :drop
  def accept_downstream_message(message, state) do
    DownstreamSession.accept_downstream_message(message, state)
  end

  @spec accept_recovered_runtime(term(), socket_state()) :: {:ok, socket_state()} | :drop
  def accept_recovered_runtime(message, state) do
    DownstreamSession.accept_recovered_runtime(message, state)
  end

  @spec handle_monitor_down(socket_state(), pid(), term()) :: DownstreamSession.monitor_result()
  def handle_monitor_down(state, owner_pid, reason) do
    DownstreamSession.handle_monitor_down(state, owner_pid, reason)
  end

  @spec maybe_retarget_before_start(binary(), socket_state()) ::
          {:ok, socket_state()} | {:error, WebsocketOwnerContract.owner_error()}
  def maybe_retarget_before_start(payload, state) do
    DownstreamSession.maybe_retarget_before_start(payload, state)
  end

  @spec retarget_error_payload(term()) :: {:error, term()}
  def retarget_error_payload(reason), do: DownstreamSession.retarget_error_payload(reason)

  @spec response_options(socket_state(), boolean()) :: RequestOptions.t()
  def response_options(state, reuse_upstream_session?) do
    response_options(state, reuse_upstream_session?, nil)
  end

  @spec response_options(socket_state(), boolean(), pid() | nil) :: RequestOptions.t()
  def response_options(state, reuse_upstream_session?, owner_turn_id) do
    if owner?(state) do
      DownstreamSession.response_options(state, owner_turn_id)
    else
      Websocket.websocket_response_options(
        Map.get(state, :opts, %{}),
        Map.get(state, :codex_session),
        Map.get(state, :upstream_websocket_session),
        reuse_upstream_session?
      )
    end
  end

  @spec cleanup_owner_session(socket_state(), term()) :: :ok
  def cleanup_owner_session(state, reason), do: DownstreamSession.cleanup(state, reason)

  @spec downstream_response_chunk(binary()) :: binary()
  def downstream_response_chunk(data) when is_binary(data) do
    StreamProtocol.canonicalize_codex_responses_json_message(data)
  end

  @spec downstream_response_chunk(
          binary(),
          StreamProtocol.public_openai_responses_websocket_state()
        ) ::
          {:push, binary(), StreamProtocol.public_openai_responses_websocket_state()}
          | {:drop, StreamProtocol.public_openai_responses_websocket_state()}
          | {:error, map(), StreamProtocol.public_openai_responses_websocket_state()}
  def downstream_response_chunk(data, turn_state) when is_binary(data) and is_map(turn_state) do
    StreamProtocol.normalize_public_openai_responses_websocket_data(data, turn_state)
  end

  @spec public_responses_turn_state() ::
          StreamProtocol.public_openai_responses_websocket_state()
  def public_responses_turn_state do
    StreamProtocol.public_openai_responses_websocket_state()
  end

  @spec public_responses_stream?(socket_state()) :: boolean()
  def public_responses_stream?(%RequestOptions{
        openai_compatibility: %{public_openai_responses_stream: true}
      }),
      do: true

  def public_responses_stream?(%{
        opts: %RequestOptions{
          openai_compatibility: %{public_openai_responses_stream: true}
        }
      }),
      do: true

  def public_responses_stream?(_state), do: false

  @spec request_row_producing_response_payload?(term()) :: boolean()
  def request_row_producing_response_payload?(payload) when is_binary(payload) do
    WebsocketCodec.request_row_producing_response_payload?(payload)
  end

  def request_row_producing_response_payload?(_payload), do: false

  @spec continuity_ordered_payload?(term()) :: boolean()
  def continuity_ordered_payload?(payload) when is_binary(payload) do
    WebsocketCodec.continuity_ordered_payload?(payload)
  end

  def continuity_ordered_payload?(_payload), do: false

  @spec websocket_error(term()) :: map()
  def websocket_error(%{status: status} = reason) do
    %{
      "type" => "error",
      "status" => status,
      "error" => error_payload(reason)
    }
  end

  def websocket_error(reason) do
    %{
      "type" => "error",
      "status" => 500,
      "error" => error_payload(reason)
    }
  end

  @spec request_id(term()) :: String.t() | nil
  def request_id(%RequestOptions{} = opts), do: opts.request_metadata.request_id
  def request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  def request_id(_opts), do: "none"

  @spec init_failure_metadata(socket_state(), integer()) :: map()
  def init_failure_metadata(state, started_at) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "init",
      elapsed_ms: socket_elapsed_ms(started_at),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  @spec terminate_close_metadata(socket_state()) :: map()
  def terminate_close_metadata(state) do
    opts = Map.get(state, :opts)

    %{
      request_id: request_id(opts),
      endpoint: metadata_endpoint(opts),
      transport: metadata_transport(opts),
      route_class: metadata_route_class(opts),
      phase: "terminate",
      elapsed_ms: socket_elapsed_ms(Map.get(state, :connection_started_at_monotonic_ms)),
      codex_session_id: metadata_codex_session_id(state, opts),
      owner_instance_id: metadata_owner_instance_id(state, opts),
      proxy_instance_id: metadata_proxy_instance_id(opts),
      downstream_epoch: metadata_downstream_epoch(state, opts)
    }
  end

  defp error_payload(%{code: code, message: message} = reason) do
    Map.merge(
      %{
        "message" => message,
        "type" => "invalid_request_error",
        "code" => to_string(code),
        "param" => Map.get(reason, :param)
      },
      Contracts.recovery_error_fields(reason)
    )
  end

  defp error_payload(reason) do
    %{
      "message" => "websocket request failed: #{ErrorSanitizer.safe_reason(reason)}",
      "type" => "invalid_request_error",
      "code" => "websocket_request_failed",
      "param" => nil
    }
  end

  defp metadata_endpoint(%RequestOptions{transport: %{upstream_endpoint: endpoint}})
       when is_binary(endpoint),
       do: endpoint

  defp metadata_endpoint(%{endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(%{upstream_endpoint: endpoint}) when is_binary(endpoint), do: endpoint
  defp metadata_endpoint(_opts), do: nil

  defp metadata_transport(%RequestOptions{transport: %{transport: transport}})
       when is_binary(transport),
       do: transport

  defp metadata_transport(%{transport: transport}) when is_binary(transport), do: transport
  defp metadata_transport(_opts), do: nil

  defp metadata_route_class(%RequestOptions{} = opts), do: RequestOptions.route_class(opts)

  defp metadata_route_class(%{route_class: route_class}) when is_binary(route_class),
    do: route_class

  defp metadata_route_class(_opts), do: nil

  defp metadata_codex_session_id(%{codex_session: %{id: id}}, _opts) when is_binary(id), do: id

  defp metadata_codex_session_id(_state, %RequestOptions{continuity: %{codex_session: %{id: id}}})
       when is_binary(id),
       do: id

  defp metadata_codex_session_id(_state, _opts), do: nil

  defp metadata_owner_instance_id(
         %{codex_session: %{owner_instance_id: owner_instance_id}},
         _opts
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{transport: %{websocket_owner_instance_id: owner_instance_id}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(
         _state,
         %RequestOptions{continuity: %{owner_instance_id: owner_instance_id}}
       )
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, %{owner_instance_id: owner_instance_id})
       when is_binary(owner_instance_id),
       do: owner_instance_id

  defp metadata_owner_instance_id(_state, _opts), do: nil

  defp metadata_proxy_instance_id(%RequestOptions{
         transport: %{websocket_owner_proxy_instance_id: proxy_instance_id}
       })
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(%{websocket_owner_proxy_instance_id: proxy_instance_id})
       when is_binary(proxy_instance_id),
       do: proxy_instance_id

  defp metadata_proxy_instance_id(_opts), do: nil

  defp metadata_downstream_epoch(%{websocket_owner_downstream: %{epoch: epoch}}, _opts)
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(
         _state,
         %RequestOptions{transport: %{websocket_owner_downstream_epoch: epoch}}
       )
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, %{websocket_owner_downstream_epoch: epoch})
       when is_integer(epoch),
       do: Integer.to_string(epoch)

  defp metadata_downstream_epoch(_state, _opts), do: nil

  defp socket_elapsed_ms(started_at) when is_integer(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
  end

  defp socket_elapsed_ms(_started_at), do: nil
end
