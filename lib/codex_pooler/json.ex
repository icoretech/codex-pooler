defmodule CodexPooler.JSON.OrderedObject do
  @moduledoc "JSON object entries retaining input order and duplicate keys."
  defstruct values: []

  @type t :: %__MODULE__{values: [{String.t(), term()}]}

  @spec new([{String.t(), term()}]) :: t()
  def new(values) when is_list(values), do: %__MODULE__{values: values}
end

defimpl JSON.Encoder, for: CodexPooler.JSON.OrderedObject do
  def encode(%{values: values}, encoder), do: :json.encode_key_value_list(values, encoder)
end

defmodule CodexPooler.JSON do
  @moduledoc """
  Native JSON encoding and decoding with the application's serialization policies.

  Objects decode with the first duplicate key winning. Ordered decoding retains
  every entry for lossless document compression and pricing validation.
  """

  alias CodexPooler.JSON.OrderedObject

  @type encode_error :: %ArgumentError{} | %ErlangError{} | %Protocol.UndefinedError{}
  @type encode_options :: [pretty: boolean(), escape: :unicode_safe]
  @type decode_options :: [objects: :ordered_objects, strings: :copy]

  @spec decode(iodata(), decode_options()) :: {:ok, term()} | {:error, JSON.decode_error_reason()}
  def decode(input, options \\ []) do
    binary = IO.iodata_to_binary(input)
    options = Keyword.validate!(options, [:objects, :strings])

    decoders =
      [object_finish: object_finish(options[:objects])]
      |> string_decoder(options[:strings])

    case JSON.decode(binary, :ok, decoders) do
      {value, :ok, ""} ->
        {:ok, value}

      {_value, :ok, rest} ->
        {:error, {:invalid_byte, byte_size(binary) - byte_size(rest), :binary.at(rest, 0)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decode!(iodata(), decode_options()) :: term()
  def decode!(input, options \\ []) do
    case decode(input, options) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise JSON.DecodeError,
          offset: elem(reason, 1),
          message: "invalid JSON at byte offset #{elem(reason, 1)}"
    end
  end

  @spec encode(term(), encode_options()) :: {:ok, binary()} | {:error, encode_error()}
  def encode(value, options \\ []) do
    {:ok, encode!(value, options)}
  rescue
    error in [ArgumentError, ErlangError, Protocol.UndefinedError] -> {:error, error}
  end

  @spec encode!(term(), encode_options()) :: binary()
  def encode!(value, options \\ []),
    do: value |> encode_to_iodata!(options) |> IO.iodata_to_binary()

  @spec encode_to_iodata!(term(), encode_options()) :: iodata()
  def encode_to_iodata!(value, options \\ []) do
    options = Keyword.validate!(options, pretty: false, escape: nil)
    encoder = encoder(options[:escape])
    encoded = JSON.encode_to_iodata!(value, encoder)

    case options[:pretty] do
      false ->
        encoded

      true ->
        # Formatting is for operator output. The roundtrip preserves protocol
        # encodings and duplicate object entries without reimplementing JSON.
        document = decode!(encoded, objects: :ordered_objects)
        formatter = fn term, recur, state -> format(term, recur, state, encoder) end

        :json.format(document, formatter, %{max: -1})
        |> IO.iodata_to_binary()
        |> String.trim_trailing("\n")
    end
  end

  defp object_finish(nil),
    do: fn entries, acc -> {Map.new(entries), acc} end

  defp object_finish(:ordered_objects),
    do: fn entries, acc -> {OrderedObject.new(Enum.reverse(entries)), acc} end

  defp string_decoder(decoders, nil), do: decoders
  defp string_decoder(decoders, :copy), do: Keyword.put(decoders, :string, &:binary.copy/1)

  defp encoder(nil), do: &encode_value/2

  defp encoder(:unicode_safe) do
    fn
      value, _recur when is_binary(value) -> :json.encode_binary_escape_all(value)
      value, recur -> encode_value(value, recur)
    end
  end

  defp encode_value(%Decimal{} = value, encoder),
    do: encoder.(Decimal.to_string(value, :normal), encoder)

  defp encode_value(value, encoder), do: JSON.protocol_encode(value, encoder)

  # OTP formats one-property scalar objects inline regardless of its width
  # setting. Keep operator output consistently expanded, including this case.
  defp format(%OrderedObject{values: [{key, value}]}, recur, state, encoder) do
    next = %{state | level: state.level + 1}
    indent = String.duplicate(" ", next.level * state.indent)
    closing_indent = String.duplicate(" ", state.level * state.indent)

    [
      "{\n",
      indent,
      encoder.(key, encoder),
      ": ",
      recur.(value, recur, next),
      "\n",
      closing_indent,
      "}"
    ]
  end

  defp format(%OrderedObject{values: values}, recur, state, _encoder),
    do: :json.format_key_value_list(values, recur, state)

  defp format(value, recur, state, _encoder) when is_list(value),
    do: :json.format_value(value, recur, state)

  defp format(value, _recur, _state, encoder), do: encoder.(value, encoder)
end
