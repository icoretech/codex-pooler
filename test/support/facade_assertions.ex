defmodule CodexPooler.FacadeAssertions do
  @moduledoc false

  import ExUnit.Assertions

  @public_model "gemma3"

  @sentinels %{
    target_model: "gpt-5.6-sol",
    provider: "facade-provider-private-sentinel",
    account: "facade-account-private-sentinel",
    assignment: "facade-assignment-private-sentinel",
    endpoint: "upstream.facade-private.invalid",
    request_id: "facade-provider-request-id-sentinel",
    credential: "facade-upstream-credential-sentinel",
    cache: "facade-raw-cache-key-sentinel"
  }

  @forbidden_header_prefixes [
    "openai-",
    "x-openai-",
    "x-provider-",
    "x-account-",
    "x-assignment-",
    "x-upstream-"
  ]

  @doc "Returns distinctive values shared by facade transport leakage tests."
  def facade_sentinels, do: @sentinels

  @doc "Asserts that a decoded public JSON value contains no private facade identity."
  def assert_cloaked_json(value, opts \\ []) do
    value
    |> redact_allowed_content(opts)
    |> encoded()
    |> assert_no_sentinels(opts)

    assert_public_model_fields(value)
    value
  end

  @doc "Asserts that public response headers contain no private routing metadata."
  def assert_cloaked_headers(headers, opts \\ []) do
    normalized = normalize_headers(headers)

    Enum.each(normalized, fn {name, _value} ->
      refute Enum.any?(@forbidden_header_prefixes, &String.starts_with?(name, &1)),
             "private facade response header escaped: #{inspect(name)}"
    end)

    normalized
    |> Enum.map_join("\n", fn {name, value} -> name <> ":" <> value end)
    |> assert_no_sentinels(opts)

    headers
  end

  @doc "Asserts every complete Ollama NDJSON object is cloaked."
  def assert_cloaked_ndjson(body, opts \\ []) when is_binary(body) do
    lines = String.split(body, "\n", trim: true)
    assert lines != [], "expected at least one NDJSON object"

    Enum.each(lines, fn line ->
      assert {:ok, decoded} = Jason.decode(line), "invalid NDJSON line: #{inspect(line)}"
      assert is_map(decoded), "NDJSON line must decode to an object"
      assert_cloaked_json(decoded, opts)
    end)

    assert_no_sentinels(redact_allowed_binary(body, opts), opts)
    body
  end

  @doc "Asserts every JSON data field in an SSE stream is cloaked."
  def assert_cloaked_sse(body, opts \\ []) when is_binary(body) do
    data_values =
      body
      |> String.split(~r/\r?\n\r?\n/, trim: true)
      |> Enum.flat_map(&sse_data_values/1)

    assert data_values != [], "expected at least one SSE data field"

    Enum.each(data_values, fn
      "[DONE]" ->
        :ok

      data ->
        assert {:ok, decoded} = Jason.decode(data), "invalid SSE data JSON: #{inspect(data)}"
        assert is_map(decoded), "SSE data must decode to an object"
        assert_cloaked_json(decoded, opts)
    end)

    assert_no_sentinels(redact_allowed_binary(body, opts), opts)
    body
  end

  @doc "Asserts JSON websocket text frames are cloaked."
  def assert_cloaked_websocket(frames, opts \\ []) when is_list(frames) do
    assert frames != [], "expected at least one websocket frame"

    Enum.each(frames, fn frame ->
      payload = websocket_payload(frame)
      assert {:ok, decoded} = Jason.decode(payload), "invalid websocket JSON frame"
      assert is_map(decoded), "websocket frame must decode to an object"
      assert_cloaked_json(decoded, opts)
    end)

    frames
  end

  defp assert_no_sentinels(serialized, opts) do
    ignored = opts |> Keyword.get(:ignore, []) |> MapSet.new()

    Enum.each(@sentinels, fn {kind, sentinel} ->
      unless MapSet.member?(ignored, kind) do
        refute String.contains?(serialized, sentinel),
               "private facade #{kind} escaped into public transport"
      end
    end)

    serialized
  end

  # Public model fields live only at documented envelope positions. We do not
  # traverse arbitrary content or tool arguments because a user can
  # legitimately own a field named `model` there.
  defp assert_public_model_fields(values) when is_list(values) do
    Enum.each(values, &assert_public_model_fields/1)
  end

  defp assert_public_model_fields(%{} = envelope) do
    assert_present_public_model(envelope)

    case Map.get(envelope, "response") do
      %{} = response -> assert_present_public_model(response)
      _response -> :ok
    end

    case Map.get(envelope, "output") do
      output when is_list(output) -> Enum.each(output, &assert_output_model/1)
      _output -> :ok
    end
  end

  defp assert_public_model_fields(_value), do: :ok

  defp assert_output_model(%{} = item), do: assert_present_public_model(item)
  defp assert_output_model(_item), do: :ok

  defp assert_present_public_model(%{"model" => model}) do
    assert model == @public_model,
           "public model field must be #{@public_model}, got: #{inspect(model)}"
  end

  defp assert_present_public_model(_map), do: :ok

  defp normalize_headers(%Plug.Conn{} = conn), do: normalize_headers(conn.resp_headers)

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp encoded(value) when is_binary(value), do: value
  defp encoded(value), do: Jason.encode!(value)

  defp redact_allowed_content(value, opts) do
    allowed = opts |> Keyword.get(:allow_content, []) |> List.wrap() |> MapSet.new()
    redact_exact_values(value, allowed)
  end

  defp redact_exact_values(value, allowed) when is_binary(value) do
    if MapSet.member?(allowed, value), do: "<allowed-content>", else: value
  end

  defp redact_exact_values(values, allowed) when is_list(values) do
    Enum.map(values, &redact_exact_values(&1, allowed))
  end

  defp redact_exact_values(%{} = value, allowed) do
    Map.new(value, fn {key, nested} -> {key, redact_exact_values(nested, allowed)} end)
  end

  defp redact_exact_values(value, _allowed), do: value

  defp redact_allowed_binary(body, opts) do
    Enum.reduce(Keyword.get(opts, :allow_content, []) |> List.wrap(), body, fn allowed, body ->
      body
      |> String.replace(allowed, "<allowed-content>")
      |> String.replace(Jason.encode!(allowed), Jason.encode!("<allowed-content>"))
    end)
  end

  defp sse_data_values(block) do
    block
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn
      "data: " <> data -> [data]
      "data:" <> data -> [data]
      _line -> []
    end)
  end

  defp websocket_payload({:text, payload}) when is_binary(payload), do: payload
  defp websocket_payload(%{opcode: :text, payload: payload}) when is_binary(payload), do: payload
  defp websocket_payload(payload) when is_binary(payload), do: payload
end
