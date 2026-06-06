defmodule CodexPooler.Alerts.ChannelEndpoint do
  @moduledoc false

  alias CodexPooler.InstanceSettings.AppSecretCrypto

  @type normalized_endpoint :: %{
          required(:endpoint_scheme) => String.t(),
          required(:endpoint_host) => String.t(),
          required(:endpoint_path_prefix) => String.t(),
          required(:endpoint_fingerprint) => String.t(),
          required(:delivery_endpoint_url) => String.t()
        }

  @spec normalize_url(String.t()) :: {:ok, normalized_endpoint()} | {:error, atom()}
  def normalize_url(value) when is_binary(value) do
    value = String.trim(value)

    with true <- value != "" || {:error, :blank},
         %URI{} = uri <- URI.parse(value),
         {:ok, scheme} <- normalize_scheme(uri.scheme),
         {:ok, host} <- normalize_host(uri.host),
         :ok <- reject_userinfo(uri.userinfo),
         :ok <- reject_fragment(uri.fragment) do
      path = normalize_path(uri.path)
      canonical = canonical_endpoint(scheme, host, uri.port, path, uri.query)

      {:ok,
       %{
         endpoint_scheme: scheme,
         endpoint_host: host,
         endpoint_path_prefix: masked_path_prefix(path),
         endpoint_fingerprint: AppSecretCrypto.safe_fingerprint(canonical),
         delivery_endpoint_url: canonical
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_url(_value), do: {:error, :invalid_url}

  defp normalize_scheme(scheme) when is_binary(scheme) do
    case String.downcase(String.trim(scheme)) do
      "https" -> {:ok, "https"}
      _other -> {:error, :unsupported_scheme}
    end
  end

  defp normalize_scheme(_scheme), do: {:error, :invalid_url}

  defp normalize_host(host) when is_binary(host) do
    case host |> String.trim() |> String.downcase() do
      "" -> {:error, :invalid_url}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_host(_host), do: {:error, :invalid_url}

  defp reject_userinfo(nil), do: :ok
  defp reject_userinfo(""), do: :ok
  defp reject_userinfo(_userinfo), do: {:error, :credentials_not_allowed}

  defp reject_fragment(nil), do: :ok
  defp reject_fragment(""), do: :ok
  defp reject_fragment(_fragment), do: {:error, :fragment_not_allowed}

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(path), do: path

  defp canonical_endpoint("https", host, nil, path, query),
    do: append_query("https://#{host}#{path}", query)

  defp canonical_endpoint("https", host, 443, path, query),
    do: append_query("https://#{host}#{path}", query)

  defp canonical_endpoint("https", host, port, path, query),
    do: append_query("https://#{host}:#{port}#{path}", query)

  defp append_query(url, query) when is_binary(query) and query != "", do: url <> "?" <> query
  defp append_query(url, _query), do: url

  defp masked_path_prefix("/"), do: "/"

  defp masked_path_prefix(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.take(2)
    |> Enum.map(&mask_segment/1)
    |> case do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  defp mask_segment(segment) do
    segment = String.trim(segment)

    cond do
      segment == "" -> "*"
      String.length(segment) <= 4 -> String.duplicate("*", String.length(segment))
      true -> String.slice(segment, 0, 4) <> "..."
    end
  end
end
