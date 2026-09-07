defmodule CodexPooler.Gateway.Runtime.Streaming.UsageProjection do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Streaming.UsageJsonToken

  @max_depth 64
  @type frame ::
          :object_first
          | :object_key
          | :object_colon
          | :object_value
          | :object_next
          | :array_first
          | :array_value
          | :array_next
  @type t :: %__MODULE__{
          lexer: UsageJsonToken.t(),
          stack: [frame()],
          buffer: binary(),
          limit: pos_integer(),
          skip?: boolean(),
          attribution?: boolean(),
          key: binary() | nil,
          started?: boolean()
        }
  defstruct lexer: :idle,
            stack: [],
            buffer: "",
            limit: 16_384,
            skip?: false,
            attribution?: false,
            key: "",
            started?: false

  @spec new(pos_integer()) :: t()
  def new(limit), do: %__MODULE__{limit: limit}

  @spec feed(t(), binary()) ::
          {:cont, t()} | {:done, binary(), binary()} | {:error, :malformed | :limit, binary()}
  def feed(state, ""), do: {:cont, state}

  def feed(state, <<byte, rest::binary>> = input) do
    case UsageJsonToken.step(state.lexer, byte) do
      :error -> {:error, :malformed, input}
      {:again, token} -> transition(%{state | lexer: :idle}, token, input)
      result -> consume(state, byte, rest, result)
    end
  end

  defp consume(state, byte, rest, result) do
    state = retain(state, byte)

    if byte_size(state.buffer) > state.limit do
      {:error, :limit, rest}
    else
      case result do
        {:more, lexer} -> feed(%{state | lexer: lexer}, rest)
        {:done, token} -> transition(%{state | lexer: :idle}, token, rest)
      end
    end
  end

  defp retain(state, byte) do
    buffer = if state.skip?, do: state.buffer, else: state.buffer <> <<byte>>

    key =
      if state.stack in [[:object_first], [:object_key]] and state.key != nil and
           (state.lexer != :idle or byte == ?") do
        if byte_size(state.key) < 80, do: state.key <> <<byte>>, else: nil
      else
        state.key
      end

    %{state | buffer: buffer, key: key}
  end

  defp transition(state, token, rest) do
    case advance(state, token) do
      :error -> {:error, :malformed, rest}
      %{stack: [], started?: true} = state -> {:done, state.buffer, rest}
      state -> feed(state, rest)
    end
  end

  defp advance(%{started?: false} = state, :object_start),
    do: %{state | started?: true, stack: [:object_first], key: ""}

  defp advance(%{stack: [frame | tail]} = state, :string)
       when frame in [:object_first, :object_key] do
    attribution? = tail == [] and attribution_key?(state.key)
    %{state | stack: [:object_colon | tail], attribution?: attribution?, key: ""}
  end

  defp advance(%{stack: [:object_colon | tail]} = state, :colon) do
    skip? = state.skip? or (tail == [] and state.attribution?)
    buffer = if skip? and not state.skip?, do: state.buffer <> "null", else: state.buffer
    %{state | stack: [:object_value | tail], skip?: skip?, buffer: buffer}
  end

  defp advance(%{stack: [frame | tail]} = state, :object_end)
       when frame in [:object_first, :object_next], do: finish(%{state | stack: tail})

  defp advance(%{stack: [frame | tail]} = state, :array_end)
       when frame in [:array_first, :array_next], do: finish(%{state | stack: tail})

  defp advance(%{stack: [:object_next | tail]} = state, :comma),
    do: %{state | stack: [:object_key | tail], key: ""}

  defp advance(%{stack: [:array_next | tail]} = state, :comma),
    do: %{state | stack: [:array_value | tail]}

  defp advance(%{stack: [frame | _]} = state, token)
       when frame in [:object_value, :array_first, :array_value], do: value(state, token)

  defp advance(_state, _token), do: :error

  defp value(state, token) when token in [:scalar, :string], do: finish(state)

  defp value(state, token) when token in [:object_start, :array_start] do
    if length(state.stack) < @max_depth do
      frame = if token == :object_start, do: :object_first, else: :array_first
      %{state | stack: [frame | state.stack]}
    else
      :error
    end
  end

  defp value(_state, _token), do: :error

  defp finish(%{stack: []} = state), do: state

  defp finish(%{stack: [frame | tail]} = state) do
    next = if frame == :object_value, do: :object_next, else: :array_next
    skip? = state.skip? and tail != []
    %{state | stack: [next | tail], skip?: skip?}
  end

  defp attribution_key?(nil), do: false
  defp attribution_key?(key), do: CodexPooler.JSON.decode(key) == {:ok, "attribution"}
end
