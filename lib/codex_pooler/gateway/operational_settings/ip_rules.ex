defmodule CodexPooler.Gateway.OperationalSettings.IPRules do
  @moduledoc false

  import Bitwise

  defmodule Rule do
    @moduledoc false

    @enforce_keys [:network, :prefix]
    defstruct [:network, :prefix]

    @type t :: %__MODULE__{
            network: :inet.ip_address(),
            prefix: non_neg_integer()
          }
  end

  @type compiled :: {:ok, [Rule.t()]} | {:error, :invalid_rule}

  @spec compile(term()) :: compiled()
  def compile(rules) when is_list(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, compiled} ->
      case compile_rule(rule) do
        {:ok, compiled_rule} -> {:cont, {:ok, [compiled_rule | compiled]}}
        {:error, :invalid_rule} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      {:error, :invalid_rule} = error -> error
    end
  end

  def compile(_rules), do: {:error, :invalid_rule}

  @spec parse_candidate(term()) :: {:ok, :inet.ip_address()} | {:error, :invalid_address}
  def parse_candidate(value) when is_binary(value) do
    case parse_address(value) do
      {:ok, ip, _mapped?} -> {:ok, ip}
      :error -> {:error, :invalid_address}
    end
  end

  def parse_candidate(_value), do: {:error, :invalid_address}

  @spec allowed?(:inet.ip_address(), [Rule.t()]) :: boolean()
  def allowed?(ip, rules) when is_tuple(ip) and is_list(rules) do
    case normalize_ip(ip) do
      {:ok, normalized_ip, _mapped?} ->
        Enum.any?(rules, fn %Rule{} = rule -> matches?(normalized_ip, rule) end)

      :error ->
        false
    end
  end

  defp compile_rule(rule) when is_binary(rule) do
    case :binary.split(trim_ascii_ows(rule), "/", [:global]) do
      [address] -> compile_exact_rule(address)
      [address, prefix] -> compile_cidr_rule(address, prefix)
      _invalid -> {:error, :invalid_rule}
    end
  end

  defp compile_rule(_rule), do: {:error, :invalid_rule}

  defp compile_exact_rule(address) do
    case parse_address(address) do
      {:ok, ip, _mapped?} -> {:ok, %Rule{network: ip, prefix: total_bits(ip)}}
      :error -> {:error, :invalid_rule}
    end
  end

  defp compile_cidr_rule(address, prefix) do
    with {:ok, ip, mapped?} <- parse_address(address),
         {:ok, prefix} <- parse_prefix(prefix, original_total_bits(ip, mapped?)),
         {:ok, prefix} <- normalize_prefix(prefix, mapped?) do
      {:ok, %Rule{network: mask_network(ip, prefix), prefix: prefix}}
    else
      :error -> {:error, :invalid_rule}
    end
  end

  defp parse_address(value) do
    with {:ok, parsed} <- :inet.parse_strict_address(:binary.bin_to_list(trim_ascii_ows(value))),
         {:ok, ip, mapped?} <- normalize_ip(parsed) do
      {:ok, ip, mapped?}
    else
      _invalid -> :error
    end
  end

  defp normalize_ip({first, second, third, fourth} = ip)
       when first in 0..255 and second in 0..255 and third in 0..255 and fourth in 0..255,
       do: {:ok, ip, false}

  defp normalize_ip({0, 0, 0, 0, 0, 65_535, high, low})
       when high in 0..65_535 and low in 0..65_535 do
    {:ok, {high >>> 8, band(high, 255), low >>> 8, band(low, 255)}, true}
  end

  defp normalize_ip(ip) when tuple_size(ip) == 8 do
    if valid_ipv6?(ip), do: {:ok, ip, false}, else: :error
  end

  defp normalize_ip(_ip), do: :error

  defp valid_ipv6?(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.all?(&(&1 in 0..65_535))
  end

  defp parse_prefix(value, max_prefix) do
    value
    |> trim_ascii_ows()
    |> parse_canonical_decimal(max_prefix)
  end

  defp parse_canonical_decimal("0", _max_prefix), do: {:ok, 0}

  defp parse_canonical_decimal(<<first, rest::binary>>, max_prefix) when first in ?1..?9 do
    parse_decimal_digits(rest, first - ?0, max_prefix)
  end

  defp parse_canonical_decimal(_value, _max_prefix), do: :error

  defp parse_decimal_digits(<<>>, prefix, _max_prefix), do: {:ok, prefix}

  defp parse_decimal_digits(<<digit, rest::binary>>, prefix, max_prefix) when digit in ?0..?9 do
    prefix = prefix * 10 + digit - ?0

    if prefix <= max_prefix,
      do: parse_decimal_digits(rest, prefix, max_prefix),
      else: :error
  end

  defp parse_decimal_digits(_value, _prefix, _max_prefix), do: :error

  defp original_total_bits(_ip, true), do: 128
  defp original_total_bits(ip, false), do: total_bits(ip)

  defp normalize_prefix(prefix, true) when prefix in 96..128, do: {:ok, prefix - 96}
  defp normalize_prefix(_prefix, true), do: :error
  defp normalize_prefix(prefix, false), do: {:ok, prefix}

  defp trim_ascii_ows(value) do
    value
    |> trim_ascii_ows_left()
    |> trim_ascii_ows_right()
  end

  defp trim_ascii_ows_left(<<?\s, rest::binary>>), do: trim_ascii_ows_left(rest)
  defp trim_ascii_ows_left(<<?\t, rest::binary>>), do: trim_ascii_ows_left(rest)
  defp trim_ascii_ows_left(value), do: value

  defp trim_ascii_ows_right(value) when byte_size(value) == 0, do: value

  defp trim_ascii_ows_right(value) do
    case :binary.last(value) do
      ?\s -> value |> binary_part(0, byte_size(value) - 1) |> trim_ascii_ows_right()
      ?\t -> value |> binary_part(0, byte_size(value) - 1) |> trim_ascii_ows_right()
      _byte -> value
    end
  end

  defp matches?(ip, %Rule{network: network, prefix: prefix})
       when tuple_size(ip) == tuple_size(network) do
    mask = mask(total_bits(ip), prefix)
    band(to_integer(ip), mask) == band(to_integer(network), mask)
  end

  defp matches?(_ip, %Rule{}), do: false

  defp mask_network(ip, prefix) do
    segment_bits = segment_bits(ip)
    masked = band(to_integer(ip), mask(total_bits(ip), prefix))

    0..(tuple_size(ip) - 1)
    |> Enum.reverse()
    |> Enum.map(&band(masked >>> (&1 * segment_bits), (1 <<< segment_bits) - 1))
    |> List.to_tuple()
  end

  defp to_integer(ip) do
    segment_bits = segment_bits(ip)

    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, value -> (value <<< segment_bits) + segment end)
  end

  defp total_bits(ip), do: tuple_size(ip) * segment_bits(ip)
  defp segment_bits(ip) when tuple_size(ip) == 4, do: 8
  defp segment_bits(ip) when tuple_size(ip) == 8, do: 16

  defp mask(_total_bits, 0), do: 0
  defp mask(total_bits, prefix), do: ((1 <<< prefix) - 1) <<< (total_bits - prefix)
end
