defmodule CodexPooler.Files.SignedUrlTarget do
  @moduledoc false

  alias CodexPooler.Files.UploadUrlPolicy

  @type resolver :: (String.t(), :inet | :inet6 ->
                       {:ok, [:inet.ip_address()]} | {:error, term()})
  @type target :: %{
          required(:url) => String.t(),
          required(:host_header) => String.t(),
          required(:connect_options) => keyword(),
          required(:address) => :inet.ip_address()
        }

  @spec pin(String.t(), keyword()) :: {:ok, target()} | {:error, :invalid_target}
  def pin(url, opts \\ [])

  def pin(url, opts) when is_binary(url) do
    resolver = Keyword.get(opts, :resolver, &default_resolver/2)

    with true <- is_function(resolver, 2),
         :ok <- UploadUrlPolicy.validate(url),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(url),
         {:ok, addresses} <- resolved_addresses(host, resolver),
         true <- addresses != [] and Enum.all?(addresses, &UploadUrlPolicy.public_ip?/1),
         address <- hd(addresses),
         {:ok, pinned_url} <- pinned_url(uri, address) do
      {:ok,
       %{
         url: pinned_url,
         host_header: host_header(uri),
         connect_options: [hostname: host, transport_opts: []],
         address: address
       }}
    else
      _invalid -> {:error, :invalid_target}
    end
  rescue
    _exception in [ArgumentError, URI.Error] -> {:error, :invalid_target}
  end

  def pin(_url, _opts), do: {:error, :invalid_target}

  defp resolved_addresses(host, resolver) do
    case parse_ip(host) do
      {:ok, address} ->
        {:ok, [address]}

      :error ->
        with {:ok, ipv4} <- resolve_family(resolver, host, :inet),
             {:ok, ipv6} <- resolve_family(resolver, host, :inet6),
             addresses <- Enum.uniq(ipv4 ++ ipv6),
             true <- Enum.all?(addresses, &valid_address?/1) do
          {:ok, addresses}
        else
          _invalid -> {:error, :invalid_target}
        end
    end
  end

  defp resolve_family(resolver, host, family) do
    case resolver.(host, family) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      {:error, reason} when reason in [:nxdomain, :eafnosupport] -> {:ok, []}
      _invalid -> {:error, :invalid_target}
    end
  rescue
    _exception -> {:error, :invalid_target}
  catch
    _kind, _reason -> {:error, :invalid_target}
  end

  defp valid_address?(address) when is_tuple(address),
    do: tuple_size(address) in [4, 8]

  defp valid_address?(_address), do: false

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp pinned_url(uri, address) do
    pinned_host = address |> :inet.ntoa() |> to_string()
    {:ok, URI.to_string(%{uri | host: pinned_host})}
  rescue
    _exception -> {:error, :invalid_target}
  end

  defp host_header(%URI{scheme: scheme, host: host, port: port}) do
    if default_port?(scheme, port), do: host, else: host <> ":" <> Integer.to_string(port)
  end

  defp default_port?("https", port), do: port in [nil, 443]
  defp default_port?("http", port), do: port in [nil, 80]
  defp default_port?(_scheme, nil), do: true
  defp default_port?(_scheme, _port), do: false

  defp default_resolver(host, family),
    do: :inet.getaddrs(String.to_charlist(host), family)
end
