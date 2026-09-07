defmodule CodexPooler.Gateway.Runtime.Streaming.UsageEnvelope do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Streaming.{UsageJsonToken, UsageProjection}

  @context_bytes 80
  @encoded_context_bytes @context_bytes * 6 + 2

  @type frame :: %{
          kind: :object | :array,
          phase: :first | :key | :colon | :value | :next,
          path: [binary() | nil],
          key: binary() | nil,
          seen: [binary()]
        }
  @type t :: %__MODULE__{
          lexer: UsageJsonToken.t(),
          stack: [frame()],
          key: binary() | nil,
          capture: binary() | nil,
          projection: UsageProjection.t() | nil,
          usage: map() | nil,
          usage_owner: :root | :response | nil,
          root_tier: binary() | nil,
          response_tier: binary() | nil,
          root_type: binary() | nil,
          response_type: binary() | nil,
          tier: binary() | nil,
          type: binary() | nil,
          error: :malformed | :limit | :null | nil,
          usage_error: :malformed | :limit | :null | nil,
          done?: boolean(),
          started?: boolean(),
          marker_seen?: boolean()
        }
  defstruct lexer: :idle,
            stack: [],
            key: "",
            capture: nil,
            projection: nil,
            usage: nil,
            usage_owner: nil,
            root_tier: nil,
            response_tier: nil,
            root_type: nil,
            response_type: nil,
            tier: nil,
            type: nil,
            error: nil,
            usage_error: nil,
            done?: false,
            started?: false,
            marker_seen?: false

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: t()
  def feed(state, ""), do: state
  def feed(%{error: error} = state, _data) when error != nil, do: state

  def feed(state, <<byte, rest::binary>> = data) do
    case UsageJsonToken.step(state.lexer, byte) do
      :error -> fail(state, :malformed)
      {:again, token} -> state |> Map.put(:lexer, :idle) |> advance(token) |> feed(data)
      result -> consume(state, byte, rest, result)
    end
  end

  defp consume(state, byte, rest, result) do
    state = start_capture(state, byte)
    state = capture(state, byte)

    case result do
      {:more, lexer} -> feed(%{state | lexer: lexer}, rest)
      {:done, token} -> state |> Map.put(:lexer, :idle) |> advance(token) |> feed(rest)
    end
  end

  defp start_capture(%{lexer: :idle} = state, byte) when byte not in [32, 9, 10, 13] do
    case value_path(state) do
      ["response"] ->
        reset_response(state)

      ["response", "usage"] when state.usage_owner == :root ->
        state

      path when path in [["usage"], ["response", "usage"]] ->
        owner = if path == ["usage"], do: :root, else: :response
        tier = if owner == :root, do: state.root_tier, else: state.response_tier
        state = %{state | usage_owner: owner, tier: tier, usage: nil, usage_error: nil}

        if byte == ?{,
          do: %{state | projection: UsageProjection.new(16_384), marker_seen?: true},
          else: %{state | capture: "", marker_seen?: true}

      path
      when path in [
             ["type"],
             ["response", "type"],
             ["service_tier"],
             ["response", "service_tier"]
           ] ->
        %{state | capture: ""}

      _other ->
        state
    end
  end

  defp start_capture(state, _byte), do: state

  defp reset_response(%{usage_owner: :response} = state),
    do: %{
      state
      | usage: nil,
        usage_owner: nil,
        tier: nil,
        response_tier: nil,
        response_type: nil,
        type: state.root_type
    }

  defp reset_response(state),
    do: %{state | response_tier: nil, response_type: nil, type: state.root_type}

  defp capture(state, byte) do
    key = capture_key(state, byte)
    captured = append_bounded(state.capture, byte, @encoded_context_bytes)
    state = %{state | key: key, capture: captured}

    case state.projection do
      nil -> state
      projection -> project(state, UsageProjection.feed(projection, <<byte>>))
    end
  end

  defp project(state, {:cont, projection}), do: %{state | projection: projection}

  defp project(state, {:error, error, _rest}),
    do: %{state | usage_error: error, projection: nil, usage: nil}

  defp project(state, {:done, json, _rest}) do
    case CodexPooler.JSON.decode(json) do
      {:ok, usage} -> %{state | projection: nil, usage: usage}
      _invalid -> fail(state, :malformed)
    end
  end

  defp advance(%{error: error} = state, _token) when error != nil, do: state

  defp advance(%{started?: false} = state, :object_start),
    do: push(%{state | started?: true}, :object, [])

  defp advance(%{stack: [frame | tail]} = state, :string)
       when frame.kind == :object and frame.phase in [:first, :key] do
    key =
      case state.key && CodexPooler.JSON.decode(state.key) do
        {:ok, key} -> key
        _other -> nil
      end

    frame = tracked_key(frame, key)
    %{state | stack: [%{frame | phase: :colon} | tail], key: ""}
  end

  defp advance(%{stack: [%{phase: :colon} = frame | tail]} = state, :colon),
    do: %{state | stack: [%{frame | phase: :value} | tail]}

  defp advance(%{stack: [%{phase: :next} = frame | tail]} = state, :comma) do
    phase = if frame.kind == :object, do: :key, else: :value
    %{state | stack: [%{frame | phase: phase, key: nil} | tail], key: ""}
  end

  defp advance(%{stack: [frame | tail]} = state, token)
       when frame.phase in [:first, :next] and
              ((frame.kind == :object and token == :object_end) or
                 (frame.kind == :array and token == :array_end)),
       do: finish(%{state | stack: tail})

  defp advance(state, token) do
    case value_path(state) do
      nil -> fail(state, :malformed)
      path -> value(state, token, path)
    end
  end

  defp value(state, :object_start, path), do: push(state, :object, path)

  defp value(%{usage_owner: :root} = state, :array_start, ["response", "usage"]),
    do: push(state, :array, [nil])

  defp value(state, :array_start, path) when path in [["usage"], ["response", "usage"]],
    do: push(%{state | usage_error: :malformed, usage: nil}, :array, path)

  defp value(state, :array_start, path), do: push(state, :array, path)

  defp value(%{usage_owner: :root} = state, token, ["response", "usage"])
       when token in [:scalar, :string], do: finish(state)

  defp value(state, token, path) when token in [:scalar, :string] do
    if path in [["usage"], ["response", "usage"]] do
      error = if state.capture == "null", do: :null, else: :malformed
      finish(%{state | usage_error: error, usage: nil, capture: nil})
    else
      state = store_context(state, path)
      finish(%{state | capture: nil})
    end
  end

  defp value(state, _token, _path), do: fail(state, :malformed)

  defp push(state, kind, path) do
    if length(state.stack) < 64 do
      path = if path in [[], ["response"]], do: path, else: [nil]
      frame = %{kind: kind, phase: :first, path: path, key: nil, seen: []}
      %{state | stack: [frame | state.stack], key: ""}
    else
      fail(state, :malformed)
    end
  end

  defp finish(%{stack: []} = state), do: %{state | done?: true}

  defp finish(%{stack: [frame | tail]} = state),
    do: %{state | stack: [%{frame | phase: :next} | tail]}

  defp value_path(%{stack: [%{phase: :value, kind: :object} = frame]}),
    do: frame.path ++ [frame.key]

  defp value_path(%{stack: [%{phase: :value, kind: :object} = frame | _tail]}),
    do: frame.path ++ [frame.key]

  defp value_path(%{stack: [%{kind: :array, phase: phase} = frame | _tail]})
       when phase in [:first, :value], do: frame.path ++ [nil]

  defp value_path(_state), do: nil

  defp tracked_key(frame, key) when key in ["usage", "response", "type", "service_tier"] do
    if frame.path in [[], ["response"]] do
      if key in frame.seen,
        do: %{frame | key: nil},
        else: %{frame | key: key, seen: [key | frame.seen]}
    else
      %{frame | key: key}
    end
  end

  defp tracked_key(frame, key), do: %{frame | key: key}

  defp key_phase?(%{stack: [%{kind: :object, phase: phase} | _tail]})
       when phase in [:first, :key], do: true

  defp key_phase?(_state), do: false

  defp capture_key(state, byte) do
    if key_phase?(state) and (state.lexer != :idle or byte == ?"),
      do: append_bounded(state.key, byte, 80),
      else: state.key
  end

  defp store_context(state, path) do
    value =
      case state.capture && CodexPooler.JSON.decode(state.capture) do
        {:ok, value} when is_binary(value) and byte_size(value) <= @context_bytes -> value
        _other -> nil
      end

    put_context(state, path, value)
  end

  defp put_context(state, ["type"], value),
    do: %{state | type: value || state.response_type, root_type: value}

  defp put_context(state, ["response", "type"], value),
    do: %{state | type: state.root_type || value, response_type: value}

  defp put_context(state, ["service_tier"], value),
    do: %{state | root_tier: tier(value), tier: owned_tier(state, :root, tier(value))}

  defp put_context(state, ["response", "service_tier"], value),
    do: %{state | response_tier: tier(value), tier: owned_tier(state, :response, tier(value))}

  defp put_context(state, _path, _value), do: state

  defp owned_tier(%{usage_owner: owner}, owner, value), do: value
  defp owned_tier(state, _owner, _value), do: state.tier

  defp tier(value) when value in ~w(auto default flex priority scale ultrafast), do: value
  defp tier(_value), do: nil

  defp append_bounded(nil, _byte, _limit), do: nil
  defp append_bounded(value, byte, limit) when byte_size(value) < limit, do: value <> <<byte>>
  defp append_bounded(_value, _byte, _limit), do: nil

  defp fail(state, error),
    do: %{state | error: error, projection: nil, capture: nil, key: nil, usage: nil}
end
