defmodule CodexPooler.Dev.I18n.TolgeeClient do
  @moduledoc false

  alias CodexPooler.Dev.I18n.TolgeeCatalogs
  alias Expo.{Message, Messages}

  @type config :: %{url: String.t(), project: pos_integer(), key: String.t()}

  @spec configuration!(map(), boolean()) :: config()
  def configuration!(environment, allow_loopback \\ false) do
    url = required!(environment, "TOLGEE_URL")

    uri =
      case URI.new(url) do
        {:ok, uri} -> uri
        {:error, _} -> raise ArgumentError, "TOLGEE_URL must be a valid origin"
      end

    validate_origin!(uri, allow_loopback)

    project =
      case Integer.parse(required!(environment, "TOLGEE_PROJECT_ID")) do
        {number, ""} when number > 0 -> number
        _ -> raise ArgumentError, "TOLGEE_PROJECT_ID must be a positive integer"
      end

    %{url: String.trim_trailing(url, "/"), project: project, key: required!(environment, "TOLGEE_API_KEY")}
  end

  @spec push!(config(), [TolgeeCatalogs.bundle()]) :: :ok
  def push!(config, bundles) do
    files =
      for bundle <- bundles, {locale, catalog} <- [{"en", bundle.en}, {"zh-CN", import_chinese(bundle)}] do
        name = "#{bundle.domain}-#{locale}.po"
        %{name: name, domain: bundle.domain, locale: locale, bytes: TolgeeCatalogs.encode(catalog)}
      end

    params = %{forceMode: "KEEP", overrideMode: "RECOMMENDED", errorOnUnresolvedConflict: true, convertPlaceholdersToIcu: false, createNewKeys: true, overrideKeyDescriptions: false, removeOtherKeys: false, tagNewKeys: [], storeFilesToFileStorage: false, fileMappings: Enum.map(files, &%{fileName: &1.name, namespace: &1.domain, format: "PO_RUBY", languageTag: &1.locale})}
    multipart = [{"params", {Jason.encode!(params), content_type: "application/json"}} | Enum.map(files, &{"files", {&1.bytes, filename: &1.name, content_type: "text/x-gettext-translation; charset=UTF-8"}})]
    response = request!(config, :post, "single-step-import", form_multipart: multipart)

    case {response.status, Jason.decode(response.body)} do
      {200, {:ok, %{"unresolvedConflicts" => conflicts}}} when conflicts in [nil, []] -> :ok
      {200, _} -> raise ArgumentError, "Tolgee import returned unresolved conflicts or an invalid result"
      _ -> fail_status!(response.status)
    end
  end

  @spec export!(config(), String.t(), String.t(), :reviewed | :all) :: Messages.t()
  def export!(config, domain, locale, state) do
    params = [format: "PO", zip: false, languages: locale, filterNamespace: domain]
    params = if state == :reviewed, do: params ++ [filterState: "REVIEWED"], else: params
    response = request!(config, :get, "export", params: params)

    case response.status do
      200 -> TolgeeCatalogs.parse!(response.body)
      400 -> empty_export!(response.body)
      status -> fail_status!(status)
    end
  end

  defp import_chinese(bundle) do
    keys = TolgeeCatalogs.index(bundle.template)
    messages = bundle.zh |> TolgeeCatalogs.active() |> Enum.filter(&Map.has_key?(keys, Message.key(&1)))
    %{bundle.zh | messages: messages}
  end

  defp request!(config, method, path, options) do
    case Req.request([method: method, url: "#{config.url}/v2/projects/#{config.project}/#{path}", headers: [{"x-api-key", config.key}], decode_body: false, redirect: false, retry: false, receive_timeout: 60_000] ++ options) do
      {:ok, response} -> response
      {:error, _} -> raise ArgumentError, "Tolgee request failed (transport error)"
    end
  end

  defp empty_export!(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => "no_exported_result"}} -> %Messages{messages: []}
      _ -> fail_status!(400)
    end
  end

  defp fail_status!(status), do: raise(ArgumentError, "Tolgee request failed (HTTP #{status})")

  defp validate_origin!(uri, allow_loopback) do
    origin = is_binary(uri.host) and uri.host != "" and uri.userinfo == nil and uri.query == nil and uri.fragment == nil and uri.path in [nil, "", "/"]
    unless secure?(uri, allow_loopback) and origin, do: raise(ArgumentError, "TOLGEE_URL must be an HTTPS origin; HTTP loopback requires --allow-loopback")
  end

  defp secure?(%URI{scheme: "https"}, _), do: true
  defp secure?(%URI{scheme: "http", host: host}, true) when host in ["127.0.0.1", "localhost", "::1"], do: true
  defp secure?(_, _), do: false

  defp required!(environment, name) do
    case Map.get(environment, name) do
      value when is_binary(value) and byte_size(value) > 0 ->
        if String.contains?(value, ["\r", "\n"]), do: raise(ArgumentError, "#{name} must not contain line breaks")
        value

      _ ->
        raise ArgumentError, "#{name} is required"
    end
  end
end
