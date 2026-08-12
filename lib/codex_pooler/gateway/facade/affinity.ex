defmodule CodexPooler.Gateway.Facade.Affinity do
  @moduledoc """
  Authenticates facade cache and session affinity identifiers.

  Client values are converted to Pool/API-key scoped digests before they can
  influence routing, persistence, or an upstream request. Existing Codex,
  previous-response, websocket, and file continuity fields are left alone.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @ollama_session_source "x-ollama-session-id"
  @prompt_cache_breakpoint "prompt_cache_breakpoint"

  @spec scope(map(), map(), RequestOptions.t()) :: {map(), RequestOptions.t()}
  def scope(
        %{pool: %{id: pool_id}, api_key: %{id: api_key_id}},
        payload,
        %RequestOptions{persona: %Persona{} = persona} = options
      )
      when is_map(payload) and is_binary(pool_id) and is_binary(api_key_id) do
    auth_scope = %{pool_id: pool_id, api_key_id: api_key_id}
    target = options.routing.effective_model || persona.effective_model

    {payload, options} = scope_prompt_cache(auth_scope, target, payload, options)
    options = scope_ollama_session(auth_scope, target, options)

    endpoint = options.transport.upstream_endpoint || ""
    {payload, RequestOptions.for_payload(options, endpoint, payload)}
  end

  def scope(_auth, payload, %RequestOptions{persona: nil} = options), do: {payload, options}

  defp scope_prompt_cache(auth_scope, target, payload, options) do
    case prompt_cache_identity(payload, options) do
      {:ok, source, raw_value} ->
        digest = namespace(auth_scope, source <> "/" <> target, raw_value)
        payload = Map.put(payload, "prompt_cache_key", digest)

        options =
          if prompt_cache_routing_allowed?(options) do
            RequestOptions.put_routing(options, prompt_cache_key: digest)
          else
            RequestOptions.put_routing(options, prompt_cache_key: nil)
          end

        {payload, options}

      :none ->
        {Map.delete(payload, "prompt_cache_key"),
         RequestOptions.put_routing(options, prompt_cache_key: nil)}
    end
  end

  defp prompt_cache_identity(payload, options) do
    case Map.get(payload, "prompt_cache_key") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> anthropic_cache_identity(payload, options)
          value -> {:ok, "prompt-cache/client", value}
        end

      nil ->
        anthropic_cache_identity(payload, options)

      _invalid ->
        :none
    end
  end

  defp anthropic_cache_identity(
         %{"prompt_cache_options" => %{"mode" => mode}} = payload,
         %RequestOptions{persona: %Persona{protocol: :anthropic_messages}}
       )
       when mode in ["explicit", "implicit"] do
    {:ok, "prompt-cache/anthropic/#{mode}", cache_material_digest(payload, mode)}
  end

  defp anthropic_cache_identity(_payload, _options), do: :none

  defp prompt_cache_routing_allowed?(%RequestOptions{
         transport: %{route_class: "proxy_websocket"}
       }),
       do: false

  defp prompt_cache_routing_allowed?(%RequestOptions{}), do: true

  defp scope_ollama_session(
         auth_scope,
         target,
         %RequestOptions{
           continuity: %{
             session_header_source: @ollama_session_source,
             session_header: raw_value
           }
         } = options
       )
       when is_binary(raw_value) do
    case String.trim(raw_value) do
      "" ->
        RequestOptions.put_continuity(options, session_header: nil)

      raw_value ->
        digest = namespace(auth_scope, "session/#{@ollama_session_source}/#{target}", raw_value)
        RequestOptions.put_continuity(options, session_header: digest)
    end
  end

  defp scope_ollama_session(_auth_scope, _target, %RequestOptions{} = options), do: options

  defp namespace(%{pool_id: pool_id, api_key_id: api_key_id}, source, raw_value) do
    :crypto.hash(
      :sha256,
      Enum.join([pool_id, api_key_id, source, raw_value], <<0>>)
    )
    |> Base.url_encode64(padding: false)
    |> then(&("facade:" <> &1))
  end

  defp cache_material_digest(payload, mode) do
    context = :crypto.hash_init(:sha256)

    {context, last_breakpoint} =
      ["instructions", "tools", "input"]
      |> Enum.reduce({context, nil}, fn key, {context, last_breakpoint} ->
        case Map.fetch(payload, key) do
          {:ok, value} ->
            context = hash_token(context, {:section, key})
            walk_cache_material(value, [key], context, last_breakpoint)

          :error ->
            {context, last_breakpoint}
        end
      end)

    case {mode, last_breakpoint} do
      {"explicit", digest} when is_binary(digest) -> digest
      {_mode, _last_breakpoint} -> :crypto.hash_final(context)
    end
  end

  defp walk_cache_material(value, path, context, last_breakpoint) when is_map(value) do
    context = hash_token(context, {:map_start, path})

    {context, last_breakpoint} =
      value
      |> Map.keys()
      |> Enum.reject(&cache_breakpoint_key?/1)
      |> Enum.sort()
      |> Enum.reduce({context, last_breakpoint}, fn key, {context, last_breakpoint} ->
        context = hash_token(context, {:map_key, path, key})
        walk_cache_material(Map.fetch!(value, key), [key | path], context, last_breakpoint)
      end)

    context = hash_token(context, {:map_end, path})

    if cache_breakpoint?(value) do
      context = hash_token(context, {:cache_breakpoint, path})
      {context, :crypto.hash_final(context)}
    else
      {context, last_breakpoint}
    end
  end

  defp walk_cache_material(value, path, context, last_breakpoint) when is_list(value) do
    context = hash_token(context, {:list_start, path, length(value)})

    {context, last_breakpoint} =
      value
      |> Enum.with_index()
      |> Enum.reduce({context, last_breakpoint}, fn {item, index}, {context, last_breakpoint} ->
        walk_cache_material(item, [index | path], context, last_breakpoint)
      end)

    {hash_token(context, {:list_end, path}), last_breakpoint}
  end

  defp walk_cache_material(value, path, context, last_breakpoint) do
    {hash_token(context, {:value, path, value}), last_breakpoint}
  end

  defp cache_breakpoint?(value) do
    Map.has_key?(value, @prompt_cache_breakpoint) or
      Map.has_key?(value, :prompt_cache_breakpoint)
  end

  defp cache_breakpoint_key?(@prompt_cache_breakpoint), do: true
  defp cache_breakpoint_key?(:prompt_cache_breakpoint), do: true
  defp cache_breakpoint_key?(_key), do: false

  defp hash_token(context, token) do
    :crypto.hash_update(context, :erlang.term_to_binary(token, [:deterministic]))
  end
end
