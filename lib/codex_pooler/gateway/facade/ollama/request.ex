defmodule CodexPooler.Gateway.Facade.Ollama.Request do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Matrix, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.{RequestOptions, StrictSchema}

  @backend_endpoint "/backend-api/codex/responses"
  @noop_options ~w(
    num_ctx
    num_batch
    num_gpu
    main_gpu
    low_vram
    f16_kv
    use_mmap
    use_mlock
    num_thread
    numa
  )
  @mapped_options ~w(num_predict temperature top_p stop)
  @max_stop_sequences 16

  @type formatting :: %{
          required(:surface) => :chat | :generate,
          required(:stream?) => boolean(),
          required(:think?) => boolean(),
          required(:stops) => [String.t()],
          required(:started_at) => integer()
        }

  @spec normalize_payload(term()) :: {:ok, map()} | {:error, Error.reason()}
  def normalize_payload(payload), do: Validation.normalize_payload(payload)

  @spec reject_unknown_fields(map(), [String.t()]) :: :ok | {:error, Error.reason()}
  def reject_unknown_fields(payload, supported_fields)
      when is_map(payload) and is_list(supported_fields) do
    case payload |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in supported_fields)) do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter(field)}
    end
  end

  @spec coerce(map(), map(), :chat | :generate, map() | keyword()) ::
          {:ok, map()} | {:error, Error.reason()}
  def coerce(payload, canonical, surface, opts)
      when is_map(payload) and is_map(canonical) and surface in [:chat, :generate] do
    with {:ok, canonical, formatting} <- apply_common(payload, canonical, surface),
         {:ok, coerced} <- Responses.coerce(canonical, stream_options(opts, formatting)) do
      request_options =
        if formatting.stream? do
          RequestOptions.put_openai_compatibility(
            coerced.request_options,
            public_ollama_stream: true,
            ollama_surface: surface,
            ollama_formatting: formatting
          )
        else
          coerced.request_options
        end

      {:ok,
       coerced
       |> Map.put(:request_options, request_options)
       |> Map.put(:ollama_formatting, formatting)}
    end
  end

  @spec apply_common(map(), map(), :chat | :generate) ::
          {:ok, map(), formatting()} | {:error, Error.reason()}
  def apply_common(payload, canonical, surface)
      when is_map(payload) and is_map(canonical) and surface in [:chat, :generate] do
    with :ok <- validate_stream(payload),
         {:ok, think?} <- thinking_requested(payload),
         {:ok, text} <- text_format(payload),
         {:ok, generation, stops} <- generation_options(payload) do
      canonical =
        canonical
        |> Map.put("stream", Map.get(payload, "stream", true))
        |> maybe_put("reasoning", if(think?, do: %{"summary" => "detailed"}))
        |> maybe_put("text", text)
        |> Map.merge(generation)

      formatting = %{
        surface: surface,
        stream?: Map.get(payload, "stream", true),
        think?: think?,
        stops: stops,
        started_at: System.monotonic_time()
      }

      {:ok, canonical, formatting}
    end
  end

  @spec image_parts(term(), String.t()) :: {:ok, [map()]} | {:error, Error.reason()}
  def image_parts(nil, _param), do: {:ok, []}

  def image_parts(images, param) when is_list(images) do
    images
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {image, index}, {:ok, parts} ->
      case image_part(image, "#{param}[#{index}]") do
        {:ok, part} -> {:cont, {:ok, [part | parts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  def image_parts(_images, param) do
    {:error, Error.invalid_request("images must be an array of base64 strings", param)}
  end

  @spec backend_endpoint() :: String.t()
  def backend_endpoint, do: @backend_endpoint

  defp validate_stream(%{"stream" => value}) when is_boolean(value), do: :ok

  defp validate_stream(%{"stream" => _value}) do
    {:error, Error.invalid_request("stream must be a boolean", "stream")}
  end

  defp validate_stream(_payload), do: :ok

  defp stream_options(%RequestOptions{} = opts, %{stream?: stream?}) do
    RequestOptions.put_openai_compatibility(opts,
      public_ollama_stream: stream?,
      collect_openai_response_stream: not stream?
    )
  end

  defp stream_options(opts, %{stream?: stream?}) when is_list(opts) do
    opts
    |> Keyword.put(:public_ollama_stream, stream?)
    |> Keyword.put(:collect_openai_response_stream, not stream?)
  end

  defp stream_options(opts, %{stream?: stream?}) when is_map(opts) do
    opts
    |> Map.put(:public_ollama_stream, stream?)
    |> Map.put(:collect_openai_response_stream, not stream?)
  end

  defp stream_options(opts, _formatting), do: opts

  defp thinking_requested(%{"think" => value}) when is_boolean(value), do: {:ok, value}

  defp thinking_requested(%{"think" => value}) when value in ~w(low medium high max),
    do: {:ok, true}

  defp thinking_requested(%{"think" => _value}) do
    {:error,
     Error.invalid_request(
       "think must be a boolean or one of low, medium, high, max",
       "think"
     )}
  end

  defp thinking_requested(_payload), do: {:ok, false}

  defp text_format(%{"format" => "json"}),
    do: {:ok, %{"format" => %{"type" => "json_object"}}}

  defp text_format(%{"format" => schema}) when is_map(schema) and map_size(schema) > 0 do
    format = %{
      "type" => "json_schema",
      "name" => "ollama_response",
      "strict" => false,
      "schema" => schema
    }

    validation_probe = put_in(format, ["strict"], true)

    with :ok <-
           StrictSchema.validate_public_type_vocabulary(%{
             "text" => %{"format" => validation_probe}
           }) do
      {:ok, %{"format" => format}}
    end
  end

  defp text_format(%{"format" => value}) when value in [nil, ""], do: {:ok, nil}

  defp text_format(%{"format" => _value}) do
    {:error, Error.invalid_request("format must be json or a JSON schema object", "format")}
  end

  defp text_format(_payload), do: {:ok, nil}

  defp generation_options(%{"options" => options}) when is_map(options) do
    with :ok <- reject_unknown_options(options),
         :ok <- validate_num_predict(options),
         :ok <- validate_temperature(options),
         :ok <- validate_top_p(options),
         {:ok, stops} <- validate_stops(options),
         {:ok, generation} <- maybe_seed(options) do
      generation =
        generation
        |> maybe_rename(options, "num_predict", "max_output_tokens")
        |> maybe_copy(options, "temperature")
        |> maybe_copy(options, "top_p")

      {:ok, generation, stops}
    end
  end

  defp generation_options(%{"options" => _options}) do
    {:error, Error.invalid_request("options must be an object", "options")}
  end

  defp generation_options(_payload), do: {:ok, %{}, []}

  defp reject_unknown_options(options) do
    supported = @mapped_options ++ @noop_options ++ ["seed"]

    case options |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in supported)) do
      nil -> :ok
      field -> {:error, Error.unsupported_parameter("options." <> field)}
    end
  end

  defp validate_num_predict(%{"num_predict" => value}) when is_integer(value) and value > 0,
    do: :ok

  defp validate_num_predict(%{"num_predict" => _value}) do
    {:error,
     Error.invalid_request(
       "options.num_predict must be a positive integer",
       "options.num_predict"
     )}
  end

  defp validate_num_predict(_options), do: :ok

  defp validate_temperature(%{"temperature" => value})
       when is_number(value) and value >= 0 and value <= 2,
       do: :ok

  defp validate_temperature(%{"temperature" => _value}) do
    {:error,
     Error.invalid_request(
       "options.temperature must be between 0 and 2",
       "options.temperature"
     )}
  end

  defp validate_temperature(_options), do: :ok

  defp validate_top_p(%{"top_p" => value}) when is_number(value) and value >= 0 and value <= 1,
    do: :ok

  defp validate_top_p(%{"top_p" => _value}) do
    {:error, Error.invalid_request("options.top_p must be between 0 and 1", "options.top_p")}
  end

  defp validate_top_p(_options), do: :ok

  defp validate_stops(%{"stop" => stop}) when is_binary(stop) and stop != "",
    do: {:ok, [stop]}

  defp validate_stops(%{"stop" => stops}) when is_list(stops) do
    if stops != [] and length(stops) <= @max_stop_sequences and
         Enum.all?(stops, &(is_binary(&1) and &1 != "")) do
      {:ok, stops}
    else
      {:error,
       Error.invalid_request(
         "options.stop must contain one to sixteen non-empty strings",
         "options.stop"
       )}
    end
  end

  defp validate_stops(%{"stop" => _value}) do
    {:error,
     Error.invalid_request(
       "options.stop must be a non-empty string or string array",
       "options.stop"
     )}
  end

  defp validate_stops(_options), do: {:ok, []}

  defp maybe_seed(%{"seed" => seed}) do
    if "seed" in Matrix.forwarded_fields(:responses) do
      if is_integer(seed) do
        {:ok, %{"seed" => seed}}
      else
        {:error, Error.invalid_request("options.seed must be an integer", "options.seed")}
      end
    else
      {:error, Error.unsupported_parameter("options.seed")}
    end
  end

  defp maybe_seed(_options), do: {:ok, %{}}

  defp image_part(value, param) when is_binary(value) do
    with {:ok, media_type, encoded} <- decode_image(value) do
      {:ok, %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{encoded}"}}
    else
      :error ->
        {:error,
         Error.invalid_request("image must be valid base64 PNG, JPEG, GIF, or WebP", param)}
    end
  end

  defp image_part(_value, param) do
    {:error, Error.invalid_request("image must be a base64 string", param)}
  end

  defp decode_image("data:" <> _rest = data_url) do
    case Regex.run(
           ~r/\Adata:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+\/=]+)\z/,
           data_url
         ) do
      [_full, media_type, encoded] -> validate_encoded_image(media_type, encoded)
      _match -> :error
    end
  end

  defp decode_image(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} ->
        case image_media_type(bytes) do
          nil -> :error
          media_type -> {:ok, media_type, encoded}
        end

      :error ->
        :error
    end
  end

  defp validate_encoded_image(media_type, encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} ->
        if image_media_type(bytes) == media_type,
          do: {:ok, media_type, encoded},
          else: :error

      :error ->
        :error
    end
  end

  defp image_media_type(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>),
    do: "image/png"

  defp image_media_type(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"
  defp image_media_type(<<"GIF87a", _rest::binary>>), do: "image/gif"
  defp image_media_type(<<"GIF89a", _rest::binary>>), do: "image/gif"
  defp image_media_type(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>), do: "image/webp"
  defp image_media_type(_bytes), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_copy(target, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end

  defp maybe_rename(target, source, source_key, target_key) do
    case Map.fetch(source, source_key) do
      {:ok, value} -> Map.put(target, target_key, value)
      :error -> target
    end
  end
end
