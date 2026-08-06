defmodule CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules

  @max_hops 32
  @max_entry_bytes 64
  @max_entry_scan_bytes @max_entry_bytes * 2

  defmodule Resolution do
    @moduledoc false

    @enforce_keys [:status, :peer_ip, :client_ip, :source, :reason, :inspected_hops]
    defstruct [:status, :peer_ip, :client_ip, :source, :reason, :inspected_hops]

    @type status :: :ok | :error
    @type source :: :peer | :x_forwarded_for | :x_real_ip

    @type reason ::
            nil
            | :invalid_trusted_proxy_rules
            | :invalid_forwarded_bytes
            | :forwarded_entry_too_long
            | :invalid_forwarded_entry
            | :forwarded_hop_limit_exceeded
            | :forwarded_chain_unresolved

    @type t :: %__MODULE__{
            status: status(),
            peer_ip: :inet.ip_address(),
            client_ip: :inet.ip_address(),
            source: source(),
            reason: reason(),
            inspected_hops: 0..32
          }
  end

  @spec resolve(Plug.Conn.t(), OperationalSettings.t()) :: Resolution.t()
  def resolve(%Plug.Conn{remote_ip: peer_ip} = conn, %OperationalSettings{
        trusted_proxies_compiled: compiled_rules
      }) do
    case compiled_rules do
      {:error, :invalid_rule} ->
        error(peer_ip, :invalid_trusted_proxy_rules, 0)

      {:ok, trusted_rules} ->
        resolve_with_rules(conn, peer_ip, trusted_rules)
    end
  end

  defp resolve_with_rules(conn, peer_ip, trusted_rules) do
    if IPRules.allowed?(peer_ip, trusted_rules) do
      resolve_forwarded(conn, peer_ip, trusted_rules)
    else
      success(peer_ip, peer_ip, :peer, 0)
    end
  end

  defp resolve_forwarded(conn, peer_ip, trusted_rules) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] -> resolve_x_real_ip(conn, peer_ip)
      values -> values |> xff_states() |> resolve_xff(peer_ip, trusted_rules, 0)
    end
  end

  defp resolve_x_real_ip(conn, peer_ip) do
    case Plug.Conn.get_req_header(conn, "x-real-ip") do
      [] ->
        success(peer_ip, peer_ip, :peer, 0)

      [value | _rest] ->
        case read_single_entry(value) do
          {:ok, entry} -> resolve_x_real_ip_entry(entry, peer_ip)
          {:error, reason} -> error(peer_ip, reason, 1)
        end
    end
  end

  defp resolve_x_real_ip_entry(entry, peer_ip) do
    case parse_entry(entry) do
      {:ok, client_ip} -> success(peer_ip, client_ip, :x_real_ip, 1)
      {:error, reason} -> error(peer_ip, reason, 1)
    end
  end

  defp xff_states(values) do
    values
    |> Enum.reverse()
    |> Enum.map(fn value -> {value, byte_size(value) - 1} end)
  end

  defp resolve_xff([], peer_ip, _trusted_rules, inspected_hops) do
    error(peer_ip, :forwarded_chain_unresolved, inspected_hops)
  end

  defp resolve_xff(_states, peer_ip, _trusted_rules, @max_hops) do
    error(peer_ip, :forwarded_hop_limit_exceeded, @max_hops)
  end

  defp resolve_xff(states, peer_ip, trusted_rules, inspected_hops) do
    inspected_hops = inspected_hops + 1

    states
    |> pop_rightmost_entry()
    |> resolve_xff_entry(peer_ip, trusted_rules, inspected_hops)
  end

  defp resolve_xff_entry({:ok, entry, remaining_states}, peer_ip, trusted_rules, inspected_hops) do
    case parse_entry(entry) do
      {:ok, client_ip} ->
        resolve_xff_client(client_ip, remaining_states, peer_ip, trusted_rules, inspected_hops)

      {:error, reason} ->
        error(peer_ip, reason, inspected_hops)
    end
  end

  defp resolve_xff_entry({:error, reason}, peer_ip, _trusted_rules, inspected_hops) do
    error(peer_ip, reason, inspected_hops)
  end

  defp resolve_xff_client(client_ip, remaining_states, peer_ip, trusted_rules, inspected_hops) do
    if IPRules.allowed?(client_ip, trusted_rules) do
      resolve_xff(remaining_states, peer_ip, trusted_rules, inspected_hops)
    else
      success(peer_ip, client_ip, :x_forwarded_for, inspected_hops)
    end
  end

  defp pop_rightmost_entry([{value, end_index} | rest]) do
    scan_entry_from_right({value, end_index, nil, nil, 0, 0, 0}, rest, true)
  end

  defp read_single_entry(value) do
    state = {value, byte_size(value) - 1, nil, nil, 0, 0, 0}

    case scan_entry_from_right(state, [], false) do
      {:ok, entry, []} -> {:ok, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_entry_from_right(
         {value, index, content_start, content_end, _content_bytes, _pending_ows, _scanned_bytes},
         rest,
         _split_on_comma?
       )
       when index < 0 do
    {:ok, slice_bytes(value, content_start, content_end), rest}
  end

  defp scan_entry_from_right(
         {_value, _index, _content_start, _content_end, _content_bytes, _pending_ows,
          @max_entry_scan_bytes},
         _rest,
         _split_on_comma?
       ) do
    {:error, :forwarded_entry_too_long}
  end

  defp scan_entry_from_right({value, index, _, _, _, _, _} = state, rest, split_on_comma?) do
    scan_entry_byte(state, :binary.at(value, index), rest, split_on_comma?)
  end

  defp scan_entry_byte(
         {value, index, content_start, content_end, _content_bytes, _pending_ows, _scanned_bytes},
         44,
         rest,
         true
       ) do
    entry = slice_bytes(value, content_start, content_end)
    {:ok, entry, [{value, index - 1} | rest]}
  end

  defp scan_entry_byte(
         {value, index, content_start, content_end, content_bytes, pending_ows, scanned_bytes},
         byte,
         rest,
         split_on_comma?
       ) do
    cond do
      ows?(byte) ->
        scan_entry_from_right(
          {value, index - 1, content_start, content_end, content_bytes,
           if(is_nil(content_start), do: 0, else: pending_ows + 1), scanned_bytes + 1},
          rest,
          split_on_comma?
        )

      content_bytes + pending_ows + 1 > @max_entry_bytes ->
        {:error, :forwarded_entry_too_long}

      true ->
        scan_entry_from_right(
          {value, index - 1, index, content_end || index, content_bytes + pending_ows + 1, 0,
           scanned_bytes + 1},
          rest,
          split_on_comma?
        )
    end
  end

  defp slice_bytes(_value, nil, _end_index), do: <<>>
  defp slice_bytes(_value, start_index, end_index) when start_index > end_index, do: <<>>

  defp slice_bytes(value, start_index, end_index) do
    binary_part(value, start_index, end_index - start_index + 1)
  end

  defp parse_entry(value) do
    trimmed = trim_ascii_ows(value)

    cond do
      trimmed == <<>> ->
        {:error, :invalid_forwarded_entry}

      byte_size(trimmed) > @max_entry_bytes ->
        {:error, :forwarded_entry_too_long}

      not printable_ascii?(trimmed) ->
        {:error, :invalid_forwarded_bytes}

      true ->
        parse_address_form(trimmed)
    end
  end

  defp trim_ascii_ows(value) do
    start_index = trim_left(value, 0, byte_size(value))
    end_index = trim_right(value, byte_size(value) - 1, start_index)
    slice_bytes(value, start_index, end_index)
  end

  defp trim_left(_value, index, size) when index == size, do: index

  defp trim_left(value, index, size) do
    if ows?(:binary.at(value, index)), do: trim_left(value, index + 1, size), else: index
  end

  defp trim_right(_value, index, start_index) when index < start_index, do: index

  defp trim_right(value, index, start_index) do
    if ows?(:binary.at(value, index)), do: trim_right(value, index - 1, start_index), else: index
  end

  defp ows?(byte), do: byte == ?\s or byte == ?\t

  defp printable_ascii?(value), do: printable_ascii?(value, 0, byte_size(value))
  defp printable_ascii?(_value, index, size) when index == size, do: true

  defp printable_ascii?(value, index, size) do
    byte = :binary.at(value, index)
    byte >= 32 and byte <= 126 and printable_ascii?(value, index + 1, size)
  end

  defp parse_address_form(<<?[, rest::binary>>), do: parse_bracketed_ipv6(rest)

  defp parse_address_form(value) do
    case parse_address(value) do
      {:ok, ip} -> {:ok, ip}
      {:error, :invalid_forwarded_entry} -> parse_ipv4_with_port(value)
    end
  end

  defp parse_bracketed_ipv6(value) do
    case :binary.match(value, "]") do
      {closing_index, 1} ->
        address = binary_part(value, 0, closing_index)
        suffix = binary_part(value, closing_index + 1, byte_size(value) - closing_index - 1)

        with {:ok, ip} when tuple_size(ip) == 8 <- parse_address(address),
             :ok <- parse_optional_port(suffix) do
          {:ok, ip}
        else
          _invalid -> {:error, :invalid_forwarded_entry}
        end

      :nomatch ->
        {:error, :invalid_forwarded_entry}
    end
  end

  defp parse_ipv4_with_port(value) do
    case :binary.match(value, ":") do
      {colon_index, 1} ->
        address = binary_part(value, 0, colon_index)
        port = binary_part(value, colon_index + 1, byte_size(value) - colon_index - 1)

        with {:ok, ip} when tuple_size(ip) == 4 <- parse_address(address),
             :ok <- parse_port(port) do
          {:ok, ip}
        else
          _invalid -> {:error, :invalid_forwarded_entry}
        end

      :nomatch ->
        {:error, :invalid_forwarded_entry}
    end
  end

  defp parse_optional_port(<<>>), do: :ok
  defp parse_optional_port(<<?:, port::binary>>), do: parse_port(port)
  defp parse_optional_port(_suffix), do: {:error, :invalid_forwarded_entry}

  defp parse_port(port) when byte_size(port) in 1..5 do
    case parse_decimal(port, 0, 0) do
      value when value in 1..65_535 -> :ok
      _invalid -> {:error, :invalid_forwarded_entry}
    end
  end

  defp parse_port(_port), do: {:error, :invalid_forwarded_entry}

  defp parse_decimal(value, index, parsed) when index == byte_size(value), do: parsed

  defp parse_decimal(value, index, parsed) do
    case :binary.at(value, index) do
      digit when digit in ?0..?9 -> parse_decimal(value, index + 1, parsed * 10 + digit - ?0)
      _invalid -> :error
    end
  end

  defp parse_address(value) do
    case :inet.parse_strict_address(:binary.bin_to_list(value)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, :invalid_forwarded_entry}
    end
  end

  defp success(peer_ip, client_ip, source, inspected_hops) do
    %Resolution{
      status: :ok,
      peer_ip: peer_ip,
      client_ip: client_ip,
      source: source,
      reason: nil,
      inspected_hops: inspected_hops
    }
  end

  defp error(peer_ip, reason, inspected_hops) do
    %Resolution{
      status: :error,
      peer_ip: peer_ip,
      client_ip: peer_ip,
      source: :peer,
      reason: reason,
      inspected_hops: inspected_hops
    }
  end
end
