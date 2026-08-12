defmodule CodexPooler.Gateway.Facade.PublicProjection do
  @moduledoc """
  Projects gateway-owned response metadata into the public facade identity.

  Projection is deliberately limited to documented response envelopes. User
  and assistant content, tool arguments, filenames, and arbitrary nested data
  are never searched or rewritten.
  """

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Error
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @internal_envelope_keys [
    "provider",
    "provider_id",
    "account",
    "account_id",
    "assignment",
    "assignment_id",
    "upstream",
    "upstream_model",
    "upstream_model_id",
    "effective_model",
    "selected_model",
    "selected_assignment",
    "upstream_endpoint",
    "request_id",
    "system_fingerprint"
  ]

  @response_event_prefix "response."

  @spec openai_response(map()) :: map()
  def openai_response(%{} = response) do
    response
    |> drop_internal_envelope_fields()
    |> project_present_model()
    |> update_list("output", &identity_item/1)
    |> project_response_error()
  end

  @spec identity_item(map()) :: map()
  def identity_item(%{} = item) do
    item = drop_internal_envelope_fields(item)

    if Map.has_key?(item, "model") do
      Map.put(item, "model", Facade.public_model())
    else
      item
    end
  end

  @spec responses_event(map()) :: map()
  def responses_event(%{} = event) do
    event
    |> drop_internal_envelope_fields()
    |> project_present_model()
    |> update_map("response", &openai_response/1)
    |> update_map("item", &identity_item/1)
    |> project_event_error()
  end

  @spec chat_completion(map()) :: map()
  def chat_completion(%{} = completion) do
    completion
    |> drop_internal_envelope_fields()
    |> Map.put("model", Facade.public_model())
    |> project_event_error()
  end

  @spec gateway_body(map()) :: map()
  def gateway_body(%{"object" => object} = body)
      when object in ["chat.completion", "chat.completion.chunk"] do
    chat_completion(body)
  end

  def gateway_body(%{"object" => "response"} = body), do: openai_response(body)

  def gateway_body(%{"type" => type} = body) when is_binary(type) do
    if String.starts_with?(type, @response_event_prefix) or type == "error" do
      responses_event(body)
    else
      project_known_root(body)
    end
  end

  def gateway_body(%{"response" => %{} = _response} = body), do: responses_event(body)
  def gateway_body(%{} = body), do: project_known_root(body)

  @spec error_body(Error.protocol(), pos_integer(), map()) :: map()
  def error_body(protocol, status, %{} = error), do: Error.body(protocol, status, error)

  @spec json_message(binary()) :: binary()
  def json_message(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        projected = gateway_body(decoded)
        if projected === decoded, do: data, else: Jason.encode!(projected)

      _invalid ->
        data
    end
  end

  @spec json_message(binary(), map()) :: {binary(), map()}
  def json_message(data, %{} = decoded) when is_binary(data) do
    projected = gateway_body(decoded)
    encoded = if projected === decoded, do: data, else: Jason.encode!(projected)
    {encoded, projected}
  end

  @spec sse_block(iodata()) :: iodata()
  def sse_block(block) do
    block = IO.iodata_to_binary(block)

    case SSEParser.sse_field(block, "data") do
      nil ->
        block

      "[DONE]" ->
        block

      data ->
        case Jason.decode(data) do
          {:ok, %{} = decoded} ->
            projected = responses_event(decoded)

            if projected === decoded do
              block
            else
              replace_sse_data(block, Jason.encode!(projected))
            end

          _invalid ->
            block
        end
    end
  end

  defp project_known_root(body) do
    body = drop_internal_envelope_fields(body)

    if Map.has_key?(body, "model") do
      Map.put(body, "model", Facade.public_model())
    else
      body
    end
  end

  defp project_present_model(event) do
    if Map.has_key?(event, "model") do
      Map.put(event, "model", Facade.public_model())
    else
      event
    end
  end

  defp project_response_error(%{"error" => %{} = error} = response) do
    Map.put(response, "error", public_error(error))
  end

  defp project_response_error(response), do: response

  defp project_event_error(%{"error" => %{} = error} = event) do
    public_error = public_error(error, integer_field(event, "status") || 502)

    event
    |> Map.put("error", public_error)
    |> project_top_level_error_fields(public_error)
  end

  defp project_event_error(event), do: event

  defp public_error(error), do: public_error(error, integer_field(error, "status") || 502)

  defp public_error(error, status) do
    public_error = Error.body(:openai, status, atomize_known_error(error))["error"]

    if Map.has_key?(error, "param") or Map.has_key?(error, :param) do
      public_error
    else
      Map.delete(public_error, "param")
    end
  end

  defp project_top_level_error_fields(event, public_error) do
    event
    |> replace_present("code", Map.get(public_error, "code"))
    |> replace_present("message", Map.get(public_error, "message"))
    |> replace_present("param", nil)
  end

  defp replace_present(map, key, value) do
    if Map.has_key?(map, key), do: Map.put(map, key, value), else: map
  end

  defp atomize_known_error(error) do
    %{
      code: Map.get(error, "code") || Map.get(error, :code),
      message: Map.get(error, "message") || Map.get(error, :message),
      param: Map.get(error, "param") || Map.get(error, :param)
    }
  end

  defp integer_field(map, key) do
    atom_value = if key == "status", do: Map.get(map, :status), else: nil

    case Map.get(map, key) || atom_value do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp drop_internal_envelope_fields(map), do: Map.drop(map, @internal_envelope_keys)

  defp update_map(map, key, fun) do
    case Map.get(map, key) do
      %{} = nested -> Map.put(map, key, fun.(nested))
      _nested -> map
    end
  end

  defp update_list(map, key, fun) do
    case Map.get(map, key) do
      list when is_list(list) -> Map.put(map, key, Enum.map(list, &map_item(&1, fun)))
      _list -> map
    end
  end

  defp map_item(%{} = item, fun), do: fun.(item)
  defp map_item(item, _fun), do: item

  defp replace_sse_data(block, projected_data) do
    newline = if String.contains?(block, "\r\n"), do: "\r\n", else: "\n"
    trailing_separator? = String.ends_with?(block, newline <> newline)

    lines =
      block
      |> String.split(newline, trim: false)
      |> Enum.reject(&(&1 == ""))

    {lines, _replaced?} =
      Enum.map_reduce(lines, false, fn
        "data:" <> _rest = line, false ->
          replacement = if String.starts_with?(line, "data: "), do: "data: ", else: "data:"
          {replacement <> projected_data, true}

        line, replaced? ->
          {line, replaced?}
      end)

    suffix = if trailing_separator?, do: newline <> newline, else: ""
    Enum.join(lines, newline) <> suffix
  end
end
