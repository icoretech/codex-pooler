defmodule CodexPooler.Files.UploadUrlPolicy do
  @moduledoc false

  import Bitwise

  @type file_error :: CodexPooler.Files.file_error()

  @raw_control_or_whitespace ~r/[\p{Cc}\p{Zs}\p{Zl}\p{Zp}]/u
  @local_hostname_suffixes ~w(localhost localhost.localdomain)
  @local_hostname_exact_matches ~w(
    broadcasthost
    ip6-allhosts
    ip6-allnodes
    ip6-allrouters
    ip6-localhost
    ip6-localnet
    ip6-loopback
    ip6-mcastprefix
    localhost4
    localhost4.localdomain4
    localhost6
    localhost6.localdomain6
  )

  @spec validate(term()) :: :ok | {:error, file_error()}
  def validate(upload_url) when is_binary(upload_url) do
    trimmed_url = String.trim(upload_url)

    with :ok <- safe_url_characters(upload_url),
         :ok <- exact_nonblank_url(upload_url, trimmed_url),
         uri = URI.parse(trimmed_url),
         :ok <- https_scheme(uri),
         :ok <- reject_userinfo(uri),
         {:ok, host} <- normalized_host(uri.host),
         :ok <- allowed_host(host) do
      :ok
    else
      {:error, %{} = error} -> {:error, error}
    end
  rescue
    _exception in [URI.Error, ArgumentError] -> invalid_response()
  end

  def validate(_upload_url), do: invalid_response()

  @spec safe_url_characters(binary()) :: :ok | {:error, file_error()}
  defp safe_url_characters(upload_url) do
    if raw_control_or_whitespace?(upload_url), do: invalid_response(), else: :ok
  end

  @spec raw_control_or_whitespace?(binary()) :: boolean()
  defp raw_control_or_whitespace?(upload_url),
    do: Regex.match?(@raw_control_or_whitespace, upload_url)

  defp exact_nonblank_url(upload_url, trimmed_url) do
    if trimmed_url != "" and upload_url == trimmed_url do
      :ok
    else
      invalid_response()
    end
  end

  defp https_scheme(%URI{scheme: scheme}) when is_binary(scheme) do
    if String.downcase(scheme) == "https", do: :ok, else: invalid_response()
  end

  defp https_scheme(_uri), do: invalid_response()

  defp reject_userinfo(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "",
    do: invalid_response()

  defp reject_userinfo(_uri), do: :ok

  defp normalized_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    if trimmed_host != "" and host == trimmed_host do
      {:ok, String.downcase(trimmed_host)}
    else
      invalid_response()
    end
  end

  defp normalized_host(_host), do: invalid_response()

  defp allowed_host(host) do
    host = String.trim_trailing(host, ".")

    cond do
      host == "" ->
        invalid_response()

      local_resolving_hostname?(host) ->
        invalid_response()

      true ->
        allowed_host_or_ip(host)
    end
  end

  @spec local_resolving_hostname?(String.t()) :: boolean()
  defp local_resolving_hostname?(host) do
    host in @local_hostname_exact_matches or
      Enum.any?(@local_hostname_suffixes, &hostname_suffix?(host, &1))
  end

  @spec hostname_suffix?(String.t(), String.t()) :: boolean()
  defp hostname_suffix?(host, suffix),
    do: host == suffix or String.ends_with?(host, "." <> suffix)

  defp allowed_host_or_ip(host) do
    case parse_ip(host) do
      {:ok, ip} ->
        if unsafe_ip?(ip), do: invalid_response(), else: :ok

      :error ->
        if valid_hostname?(host), do: :ok, else: invalid_response()
    end
  end

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp valid_hostname?(host) do
    byte_size(host) <= 253 and Regex.match?(~r/\A[a-z0-9.-]+\z/, host) and
      host
      |> String.split(".")
      |> Enum.all?(&valid_hostname_label?/1)
  end

  defp valid_hostname_label?(label) do
    label != "" and byte_size(label) <= 63 and
      not String.starts_with?(label, "-") and not String.ends_with?(label, "-")
  end

  defp unsafe_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4 do
    Enum.any?([&private_ipv4?/1, &reserved_ipv4?/1], & &1.(ip))
  end

  defp unsafe_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    Enum.any?(
      [
        &ipv4_compatible_ipv6?/1,
        &ipv4_mapped_ipv6?/1,
        &nat64_ipv6?/1,
        &private_ipv6?/1,
        &reserved_ipv6?/1
      ],
      & &1.(ip)
    )
  end

  defp unsafe_ip?(_ip), do: true

  defp private_ipv4?({10, _b, _c, _d}), do: true
  defp private_ipv4?({100, b, _c, _d}) when b in 64..127, do: true
  defp private_ipv4?({127, _b, _c, _d}), do: true
  defp private_ipv4?({169, 254, _c, _d}), do: true
  defp private_ipv4?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ipv4?({192, 168, _c, _d}), do: true
  defp private_ipv4?(_ip), do: false

  defp reserved_ipv4?({0, _b, _c, _d}), do: true
  defp reserved_ipv4?({192, 0, 0, _d}), do: true
  defp reserved_ipv4?({192, 0, 2, _d}), do: true
  defp reserved_ipv4?({192, 88, 99, _d}), do: true
  defp reserved_ipv4?({198, b, _c, _d}) when b in 18..19, do: true
  defp reserved_ipv4?({198, 51, 100, _d}), do: true
  defp reserved_ipv4?({203, 0, 113, _d}), do: true
  defp reserved_ipv4?({a, _b, _c, _d}) when a >= 224, do: true
  defp reserved_ipv4?(_ip), do: false

  defp ipv4_compatible_ipv6?({0, 0, 0, 0, 0, 0, _word1, _word2}), do: true
  defp ipv4_compatible_ipv6?(_ip), do: false

  defp ipv4_mapped_ipv6?({0, 0, 0, 0, 0, 65_535, _word1, _word2}), do: true
  defp ipv4_mapped_ipv6?(_ip), do: false

  defp nat64_ipv6?({0x0064, 0xFF9B, 0, 0, 0, 0, _word1, _word2}), do: true
  defp nat64_ipv6?({0x0064, 0xFF9B, 0x0001, _word4, _word5, _word6, _word7, _word8}), do: true
  defp nat64_ipv6?(_ip), do: false

  defp private_ipv6?({first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth}) do
    (first &&& 0xFE00) == 0xFC00 or (first &&& 0xFFC0) == 0xFE80 or
      (first &&& 0xFFC0) == 0xFEC0
  end

  defp reserved_ipv6?({first, second, third, fourth, _fifth, _sixth, _seventh, _eighth}) do
    multicast_ipv6?(first) or discard_ipv6?(first, second, third, fourth) or
      protocol_assignment_ipv6?(first, second, third) or six_to_four_ipv6?(first)
  end

  defp multicast_ipv6?(first), do: (first &&& 0xFF00) == 0xFF00

  defp discard_ipv6?(0x0100, 0, 0, 0), do: true
  defp discard_ipv6?(_first, _second, _third, _fourth), do: false

  defp protocol_assignment_ipv6?(0x2001, 0, _third), do: true
  defp protocol_assignment_ipv6?(0x2001, 0x0002, 0), do: true
  defp protocol_assignment_ipv6?(0x2001, 0x0DB8, _third), do: true

  defp protocol_assignment_ipv6?(0x2001, second, _third),
    do: (second &&& 0xFFF0) == 0x0010

  defp protocol_assignment_ipv6?(_first, _second, _third), do: false

  defp six_to_four_ipv6?(0x2002), do: true
  defp six_to_four_ipv6?(_first), do: false

  defp invalid_response do
    {:error,
     %{
       status: 502,
       code: :upstream_file_bridge_invalid_response,
       message: "upstream file create returned an invalid upload_url",
       param: nil
     }}
  end
end
