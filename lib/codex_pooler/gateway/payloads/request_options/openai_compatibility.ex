defmodule CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization

  defstruct public_openai_responses_stream: false,
            public_openai_chat_stream: false,
            public_openai_completions_stream: false,
            public_ollama_stream: false,
            public_anthropic_stream: false,
            collect_openai_response_stream: false,
            collect_openai_image_stream: false,
            custom_tool_namespaces: %{},
            openai_chat_payload: nil,
            completion_payload: nil,
            ollama_surface: nil,
            ollama_formatting: nil,
            anthropic_formatting: nil,
            source_endpoint: nil,
            translated_endpoint: nil

  @type t :: %__MODULE__{
          public_openai_responses_stream: boolean(),
          public_openai_chat_stream: boolean(),
          public_openai_completions_stream: boolean(),
          public_ollama_stream: boolean(),
          public_anthropic_stream: boolean(),
          collect_openai_response_stream: boolean(),
          collect_openai_image_stream: boolean(),
          custom_tool_namespaces: %{optional(String.t()) => String.t()},
          openai_chat_payload: map() | nil,
          completion_payload: map() | nil,
          ollama_surface: :chat | :generate | nil,
          ollama_formatting: map() | nil,
          anthropic_formatting: map() | nil,
          source_endpoint: String.t() | nil,
          translated_endpoint: String.t() | nil
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      public_openai_responses_stream: Map.get(opts, :public_openai_responses_stream, false),
      public_openai_chat_stream: Map.get(opts, :public_openai_chat_stream, false),
      public_openai_completions_stream: Map.get(opts, :public_openai_completions_stream, false),
      public_ollama_stream: Map.get(opts, :public_ollama_stream, false),
      public_anthropic_stream: Map.get(opts, :public_anthropic_stream, false),
      collect_openai_response_stream: Map.get(opts, :collect_openai_response_stream, false),
      collect_openai_image_stream: Map.get(opts, :collect_openai_image_stream, false),
      custom_tool_namespaces: %{},
      openai_chat_payload: Map.get(opts, :openai_chat_payload),
      completion_payload: Map.get(opts, :openai_completion_payload),
      ollama_surface: Map.get(opts, :ollama_surface),
      ollama_formatting: Map.get(opts, :ollama_formatting),
      anthropic_formatting: Map.get(opts, :anthropic_formatting),
      source_endpoint: Normalization.safe_endpoint(Map.get(opts, :openai_source_endpoint)),
      translated_endpoint: Normalization.safe_endpoint(Map.get(opts, :openai_translated_endpoint))
    }
  end

  @spec mark_origin(t(), String.t(), String.t()) :: t()
  def mark_origin(%__MODULE__{} = compatibility, source_endpoint, translated_endpoint)
      when is_binary(source_endpoint) and is_binary(translated_endpoint) do
    %__MODULE__{
      compatibility
      | source_endpoint: Normalization.safe_endpoint(source_endpoint),
        translated_endpoint: Normalization.safe_endpoint(translated_endpoint)
    }
  end

  @spec translated_responses_surface?(t()) :: boolean()
  def translated_responses_surface?(%__MODULE__{
        source_endpoint: source_endpoint,
        translated_endpoint: "/backend-api/codex/responses"
      }),
      do: not is_nil(source_endpoint)

  def translated_responses_surface?(%__MODULE__{}), do: false

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = compatibility) do
    metadata =
      %{
        "surface" => surface(compatibility),
        "source_endpoint" => compatibility.source_endpoint,
        "translated_endpoint" => compatibility.translated_endpoint
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(metadata) == 0 do
      %{}
    else
      %{"openai_compatibility" => metadata}
    end
  end

  defp surface(%__MODULE__{source_endpoint: endpoint})
       when endpoint in ["/api/chat", "/api/generate"],
       do: "ollama"

  defp surface(%__MODULE__{source_endpoint: endpoint})
       when endpoint in ["/v1/messages", "/v1/messages/count_tokens"],
       do: "anthropic"

  defp surface(%__MODULE__{source_endpoint: endpoint}) when is_binary(endpoint), do: "openai_v1"
  defp surface(_compatibility), do: nil
end
