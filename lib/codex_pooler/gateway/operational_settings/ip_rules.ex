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

  @spec allowed?(:inet.ip_address(), [Rule.t()]) :: boolean()
  def allowed?(ip, rules) when is_tuple(ip) and is_list(rules) do
    Enum.any?(rules, fn %Rule{} = rule -> matches?(ip, rule) end)
  end

  defp compile_rule(rule) when is_binary(rule) do
    case String.split(rule, "/", parts: 2) do
      [address] ->
        with {:ok, ip} <- parse_ip(address) do
          {:ok, %Rule{network: ip, prefix: total_bits(ip)}}
        else
          {:error, _reason} -> {:error, :invalid_rule}
        end

      [address, prefix] ->
        with {:ok, ip} <- parse_ip(address),
             {prefix, ""} <- Integer.parse(prefix),
             true <- valid_prefix?(ip, prefix) do
          {:ok, %Rule{network: ip, prefix: prefix}}
        else
          _invalid -> {:error, :invalid_rule}
        end
    end
  end

  defp compile_rule(_rule), do: {:error, :invalid_rule}

  defp parse_ip(value) do
    value
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp valid_prefix?(ip, prefix), do: prefix >= 0 and prefix <= total_bits(ip)

  defp matches?(ip, %Rule{network: network, prefix: prefix})
       when tuple_size(ip) == tuple_size(network) do
    mask = mask(total_bits(ip), prefix)
    band(to_integer(ip), mask) == band(to_integer(network), mask)
  end

  defp matches?(_ip, %Rule{}), do: false

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
