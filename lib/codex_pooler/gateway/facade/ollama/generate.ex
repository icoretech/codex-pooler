defmodule CodexPooler.Gateway.Facade.Ollama.Generate do
  @moduledoc """
  Translates native Ollama generate requests into canonical Responses work.
  """

  alias CodexPooler.Gateway.Facade.Ollama.Request
  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @supported_fields ~w(model prompt suffix system images format options stream think keep_alive raw)
  @suffix_instruction """
  Complete the gap between the supplied PREFIX and SUFFIX. Return only the text to insert, without quotes, Markdown fences, explanation, or repetition of either boundary.
  """

  @type formatting :: %{
          required(:surface) => :generate,
          required(:stream?) => boolean(),
          required(:think?) => boolean(),
          required(:stops) => [String.t()],
          required(:started_at) => integer(),
          required(:suffix?) => boolean()
        }

  @spec to_responses(term()) ::
          {:ok, map(), formatting()} | {:error, Error.reason()}
  def to_responses(payload) do
    with {:ok, payload} <- Request.normalize_payload(payload),
         :ok <- Request.reject_unknown_fields(payload, @supported_fields),
         {:ok, canonical, suffix?} <- canonical_payload(payload),
         {:ok, canonical, formatting} <- Request.apply_common(payload, canonical, :generate) do
      {:ok, canonical, Map.put(formatting, :suffix?, suffix?)}
    end
  end

  @spec coerce(term(), map() | keyword()) :: {:ok, map()} | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, payload} <- Request.normalize_payload(payload),
         :ok <- Request.reject_unknown_fields(payload, @supported_fields),
         {:ok, canonical, suffix?} <- canonical_payload(payload),
         {:ok, coerced} <- Request.coerce(payload, canonical, :generate, opts) do
      {:ok, Map.update!(coerced, :ollama_formatting, &Map.put(&1, :suffix?, suffix?))}
    end
  end

  defp canonical_payload(payload) do
    with {:ok, prompt} <- prompt(payload),
         {:ok, suffix} <- optional_string(payload, "suffix"),
         {:ok, system} <- optional_string(payload, "system"),
         :ok <- validate_raw(payload),
         {:ok, images} <- Request.image_parts(Map.get(payload, "images"), "images"),
         suffix? = not is_nil(suffix) and suffix != "",
         content = prompt_parts(prompt, suffix) ++ images,
         :ok <- require_generate_content(content),
         instructions = instructions(system, suffix?) do
      canonical =
        %{
          "input" => [
            %{"type" => "message", "role" => "user", "content" => content}
          ]
        }
        |> maybe_put("instructions", instructions)

      {:ok, canonical, suffix?}
    end
  end

  defp prompt(%{"prompt" => prompt}) when is_binary(prompt), do: {:ok, prompt}

  defp prompt(%{"prompt" => _prompt}),
    do: {:error, Error.invalid_request("prompt must be a string", "prompt")}

  defp prompt(_payload), do: {:error, Error.invalid_request("prompt is required", "prompt")}

  defp optional_string(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, Error.invalid_request("#{field} must be a string", field)}
      :error -> {:ok, nil}
    end
  end

  defp validate_raw(%{"raw" => value}) when is_boolean(value), do: :ok

  defp validate_raw(%{"raw" => _value}),
    do: {:error, Error.invalid_request("raw must be a boolean", "raw")}

  defp validate_raw(_payload), do: :ok

  defp prompt_parts(prompt, suffix) when is_binary(suffix) and suffix != "" do
    [
      %{"type" => "input_text", "text" => "PREFIX\n" <> prompt},
      %{"type" => "input_text", "text" => "SUFFIX\n" <> suffix}
    ]
  end

  defp prompt_parts("", _suffix), do: []
  defp prompt_parts(prompt, _suffix), do: [%{"type" => "input_text", "text" => prompt}]

  defp require_generate_content([]),
    do: {:error, Error.invalid_request("prompt or images must contain input", "prompt")}

  defp require_generate_content(_content), do: :ok

  defp instructions(system, suffix?) do
    [clean_string(system), if(suffix?, do: String.trim(@suffix_instruction))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> clean_string()
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
