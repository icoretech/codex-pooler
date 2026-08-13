defmodule CodexPooler.Gateway.Transports.NativeCodexResponseControl do
  @moduledoc false

  defmodule TurnSnapshot do
    @moduledoc false

    @enforce_keys [:models_etag]
    defstruct [:models_etag]

    @type t :: %__MODULE__{models_etag: binary()}
  end

  @type header_name :: String.t()
  @type header_value :: String.t() | number() | boolean()
  @type header :: {header_name(), header_value()}
  @type input_headers :: %{optional(header_name()) => term()} | [term()]
  @type projected_header :: {header_name(), String.t()}
  @type websocket_event :: %{optional(String.t()) => term()}
  @type sanitization_result ::
          :unchanged | {:changed, websocket_event()} | {:error, :invalid_event}
  @type metadata_event :: %{required(String.t()) => String.t() | %{String.t() => String.t()}}

  @max_value_bytes 1_024
  @controls [
    {:string, "openai-model", ["openai-model", "x-openai-model"]},
    {:presence, "x-reasoning-included", ["x-reasoning-included"]},
    {:presence, "x-codex-safety-buffering-enabled", ["x-codex-safety-buffering-enabled"]},
    {:string, "x-codex-safety-buffering-faster-model", ["x-codex-safety-buffering-faster-model"]}
  ]

  @spec http_headers(term()) :: [projected_header()]
  def http_headers(headers) do
    case header_entries(headers) do
      {:ok, entries} -> project_entries(entries)
      :error -> []
    end
  end

  @spec sanitize_websocket_event(term()) :: sanitization_result()
  def sanitize_websocket_event(event) when is_map(event) do
    sanitized =
      event
      |> sanitize_header_field()
      |> sanitize_response_headers()

    if sanitized == event, do: :unchanged, else: {:changed, sanitized}
  end

  def sanitize_websocket_event(_event), do: {:error, :invalid_event}

  @spec pooler_metadata_event(term(), term()) :: metadata_event() | {:error, :invalid_models_etag}
  def pooler_metadata_event(models_etag, provider_headers) do
    if valid_string_value?(models_etag) do
      headers =
        provider_headers
        |> projected_map()
        |> Map.take(["openai-model"])
        |> Map.put("x-models-etag", models_etag)

      %{"type" => "codex.response.metadata", "headers" => headers}
    else
      {:error, :invalid_models_etag}
    end
  end

  defp sanitize_header_field(event) do
    case Map.fetch(event, "headers") do
      {:ok, headers} when is_map(headers) -> Map.put(event, "headers", projected_map(headers))
      {:ok, _invalid_headers} -> Map.delete(event, "headers")
      :error -> event
    end
  end

  defp sanitize_response_headers(%{"response" => response} = event) when is_map(response) do
    case Map.fetch(response, "headers") do
      {:ok, headers} when is_map(headers) ->
        Map.put(event, "response", Map.put(response, "headers", projected_map(headers)))

      {:ok, _invalid_headers} ->
        Map.put(event, "response", Map.delete(response, "headers"))

      :error ->
        event
    end
  end

  defp sanitize_response_headers(event), do: event

  @spec projected_map(term()) :: %{optional(String.t()) => String.t()}
  defp projected_map(headers) do
    headers
    |> http_headers()
    |> Map.new()
  end

  @spec header_entries(term()) :: {:ok, [{String.t(), term()}]} | :error
  defp header_entries(headers) when is_map(headers) do
    entries = Map.to_list(headers)

    if Enum.all?(entries, &valid_header_entry?/1), do: {:ok, entries}, else: :error
  end

  defp header_entries(headers) when is_list(headers) do
    if proper_header_entries?(headers), do: {:ok, headers}, else: :error
  end

  defp header_entries(_headers), do: :error

  defp valid_header_entry?({name, _value}), do: is_binary(name) and String.valid?(name)
  defp valid_header_entry?(_entry), do: false

  defp proper_header_entries?([]), do: true

  defp proper_header_entries?([entry | remaining_entries]) do
    valid_header_entry?(entry) and proper_header_entries?(remaining_entries)
  end

  defp proper_header_entries?(_improper_tail), do: false

  @spec project_entries([{String.t(), term()}]) :: [projected_header()]
  defp project_entries(entries) do
    Enum.flat_map(@controls, fn {kind, output_name, input_names} ->
      case selected_value(entries, input_names, kind) do
        {:ok, value} -> [{output_name, value}]
        :error -> []
      end
    end)
  end

  defp selected_value(entries, input_names, kind) do
    select_from_input_names(entries, input_names, kind)
  end

  defp select_from_input_names(_entries, [], _kind), do: :error

  defp select_from_input_names(entries, [input_name | remaining_names], kind) do
    case selected_input_value(entries, input_name, kind) do
      :missing -> select_from_input_names(entries, remaining_names, kind)
      result -> result
    end
  end

  defp selected_input_value(entries, input_name, kind) do
    case Enum.find(entries, fn {name, _value} -> name == input_name end) do
      {_name, value} -> normalize_value(kind, value) || :error
      nil -> first_valid_case_insensitive_value(entries, input_name, kind)
    end
  end

  defp first_valid_case_insensitive_value(entries, input_name, kind) do
    entries
    |> case_insensitive_candidates(input_name)
    |> Enum.find_value(:missing, fn {_name, value} -> normalize_value(kind, value) end)
  end

  defp case_insensitive_candidates(entries, input_name) do
    entries
    |> Enum.filter(fn {name, _value} ->
      name != input_name and String.downcase(name) == input_name
    end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{name, _value}, index} -> {name, index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp normalize_value(:string, value) do
    if valid_string_value?(value), do: {:ok, value}, else: nil
  end

  defp normalize_value(:presence, value) when is_binary(value) do
    if valid_presence_string?(value), do: {:ok, "true"}, else: nil
  end

  defp normalize_value(:presence, value)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: {:ok, "true"}

  defp normalize_value(:presence, _value), do: nil

  defp valid_string_value?(value) when is_binary(value) do
    byte_size(value) in 1..@max_value_bytes and String.valid?(value) and
      not ascii_control_character?(value)
  end

  defp valid_string_value?(_value), do: false

  defp valid_presence_string?(value) do
    byte_size(value) <= @max_value_bytes and String.valid?(value) and
      not ascii_control_character?(value)
  end

  defp ascii_control_character?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 <= 31 or &1 == 127))
  end
end
