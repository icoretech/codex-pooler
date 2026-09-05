defmodule CodexPooler.Gateway.OpenAICompatibility.Images do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @supported_models ~w(gpt-image-1 gpt-image-1.5 gpt-image-1-mini gpt-image-2)
  @sizes ~w(auto 1024x1024 1024x1536 1536x1024)
  @qualities ~w(auto low medium high)
  @backgrounds ~w(auto transparent opaque)
  @input_fidelities ~w(low high)

  @spec validate_generation(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate_generation(payload) do
    with {:ok, %{image_payload: image_payload, response_payload: response_payload}} <-
           prepare_generation(payload),
         {:ok, _response_payload} <- Responses.validate(response_payload) do
      {:ok, image_payload}
    end
  end

  @spec coerce_generation(term(), map() | keyword()) ::
          {:ok,
           %{
             endpoint: String.t(),
             payload: map(),
             request_options: RequestOptions.t(),
             image_payload: map()
           }}
          | {:error, Error.reason()}
  def coerce_generation(payload, opts \\ %{}) do
    with {:ok, %{image_payload: image_payload, response_payload: response_payload}} <-
           prepare_generation(payload),
         {:ok, response} <- Responses.coerce(response_payload, opts) do
      {:ok, Map.put(response, :image_payload, image_payload)}
    end
  end

  @spec validate_edit(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate_edit(payload) do
    with {:ok, %{image_payload: image_payload, response_payload: response_payload}} <-
           prepare_edit(payload),
         {:ok, _response_payload} <- Responses.validate(response_payload) do
      {:ok, image_payload}
    end
  end

  @spec coerce_edit(term(), map() | keyword()) ::
          {:ok,
           %{
             endpoint: String.t(),
             payload: map(),
             request_options: RequestOptions.t(),
             image_payload: map()
           }}
          | {:error, Error.reason()}
  def coerce_edit(payload, opts \\ %{}) do
    with {:ok,
          %{
            image_payload: image_payload,
            response_payload: response_payload,
            images: images,
            mask: mask
          }} <-
           prepare_edit(payload),
         {:ok, response} <- Responses.coerce(response_payload, opts) do
      response_payload = put_edit_images(response.payload, image_payload["prompt"], images, mask)

      {:ok,
       response |> Map.put(:payload, response_payload) |> Map.put(:image_payload, image_payload)}
    end
  end

  @spec image_response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def image_response_from_sse(body) when is_binary(body) do
    events = decoded_sse_events(body)

    with {:ok, items} <- image_items(events),
         :ok <- reject_failed_items(items),
         data when data != [] <- image_data(items) do
      {:ok,
       %{
         "created" => DateTime.utc_now() |> DateTime.to_unix(),
         "data" => data
       }
       |> maybe_put_usage(events)}
    else
      [] ->
        {:error,
         Error.reason(
           502,
           "image_generation_failed",
           "upstream image response contained no image data"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_generation(payload) do
    with {:ok, payload} <- normalize_image_payload(payload),
         :ok <- require_prompt(payload),
         :ok <- validate_generation_only(payload),
         {:ok, response_payload} <- response_payload(payload) do
      {:ok, %{image_payload: payload, response_payload: response_payload}}
    end
  end

  defp prepare_edit(payload) do
    with {:ok, payload} <- normalize_image_payload(payload),
         :ok <- require_prompt(payload),
         {:ok, images} <- image_parts(payload),
         {:ok, mask} <- optional_image_part(payload, "mask"),
         {:ok, response_payload} <- response_payload(payload) do
      {:ok,
       %{
         image_payload: payload,
         response_payload: response_payload,
         images: images,
         mask: mask
       }}
    end
  end

  defp normalize_image_payload(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :images),
         :ok <- validate_model(payload),
         :ok <- validate_one_of(payload, "size", @sizes),
         :ok <- validate_one_of(payload, "quality", @qualities),
         :ok <- validate_one_of(payload, "background", @backgrounds),
         :ok <- validate_one_of(payload, "input_fidelity", @input_fidelities),
         :ok <- validate_n(payload) do
      {:ok, payload}
    end
  end

  defp validate_generation_only(%{"image" => _image}),
    do: {:error, Error.invalid_request("image is only supported for image edits", "image")}

  defp validate_generation_only(%{"image[]" => _image}),
    do: {:error, Error.invalid_request("image is only supported for image edits", "image")}

  defp validate_generation_only(_payload), do: :ok

  defp validate_model(%{"model" => model}) when model in @supported_models, do: :ok

  defp validate_model(%{"model" => _model}),
    do: {:error, Error.invalid_model("image model is not supported")}

  defp validate_model(_payload), do: {:error, Error.invalid_request("model is required", "model")}

  defp require_prompt(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "", do: :ok

  defp require_prompt(_payload),
    do: {:error, Error.invalid_request("prompt is required", "prompt")}

  defp validate_one_of(payload, key, allowed) do
    case Map.fetch(payload, key) do
      {:ok, value} ->
        if value in allowed do
          :ok
        else
          {:error, Error.invalid_request("#{key} is not supported", key)}
        end

      :error ->
        :ok
    end
  end

  defp validate_n(%{"n" => 1}), do: :ok
  defp validate_n(%{"n" => n}) when is_binary(n), do: validate_n(%{"n" => parse_integer(n)})
  defp validate_n(%{"n" => nil}), do: :ok
  defp validate_n(%{"n" => _n}), do: {:error, Error.invalid_request("n must be 1", "n")}
  defp validate_n(_payload), do: :ok

  defp image_parts(payload) do
    images =
      payload
      |> Map.get("image", Map.get(payload, "image[]"))
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    if images == [] do
      {:error, Error.invalid_request("image is required", "image")}
    else
      collect_image_parts(images)
    end
  end

  defp collect_image_parts(images) do
    images
    |> Enum.reduce_while({:ok, []}, fn image, {:ok, acc} ->
      case input_image_part(image, "image") do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_image_part(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value -> input_image_part(value, key)
    end
  end

  defp input_image_part(value, param) do
    with {:ok, metadata} <- Validation.upload_metadata(value),
         {:ok, bytes} <- read_upload_bytes(metadata, param) do
      {:ok,
       %{
         "type" => "input_image",
         "image_url" => "data:#{metadata["content_type"]};base64,#{Base.encode64(bytes)}"
       }}
    end
  end

  defp read_upload_bytes(%{"path" => path}, param) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, Error.invalid_request("image upload is not readable", param)}
    end
  end

  defp read_upload_bytes(_metadata, param),
    do: {:error, Error.invalid_request("image upload is not readable", param)}

  defp response_payload(payload) do
    tool = %{
      "type" => "image_generation",
      "model" => payload["model"],
      "size" => Map.get(payload, "size", "auto"),
      "quality" => Map.get(payload, "quality", "auto")
    }

    tool =
      tool
      |> maybe_put(payload, "background")
      |> maybe_put(payload, "input_fidelity")

    {:ok,
     %{
       "model" => payload["model"],
       "input" => payload["prompt"],
       "tools" => [tool],
       "store" => false,
       "stream" => true
     }}
  end

  defp put_edit_images(response_payload, prompt, images, nil) do
    Map.put(response_payload, "input", [message_input(prompt, images)])
  end

  defp put_edit_images(response_payload, prompt, images, mask) do
    prompt =
      prompt <>
        "\n\n(The final attached image is a transparent mask: only modify the regions where the mask is non-transparent.)"

    Map.put(response_payload, "input", [message_input(prompt, images ++ [mask])])
  end

  defp message_input(prompt, images) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => prompt} | images]
    }
  end

  defp decoded_sse_events(body) do
    body
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp image_items(events) do
    items =
      events
      |> Enum.flat_map(fn
        %{
          "type" => "response.output_item.done",
          "item" => %{"type" => "image_generation_call"} = item
        } ->
          [item]

        %{"response" => %{"output" => output}} when is_list(output) ->
          Enum.filter(output, &image_item?/1)

        %{"output" => output} when is_list(output) ->
          Enum.filter(output, &image_item?/1)

        _event ->
          []
      end)

    if items == [],
      do:
        {:error,
         Error.reason(
           502,
           "image_generation_failed",
           "upstream response did not include image output"
         )},
      else: {:ok, items}
  end

  defp image_item?(%{"type" => "image_generation_call"}), do: true
  defp image_item?(_item), do: false

  defp reject_failed_items(items) do
    Enum.find(items, &(Map.get(&1, "status") == "failed"))
    |> case do
      nil ->
        :ok

      %{"error" => %{} = error} ->
        {:error, image_item_error(error)}

      _item ->
        {:error, Error.reason(502, "image_generation_failed", "upstream image generation failed")}
    end
  end

  defp image_item_error(error) do
    code = Map.get(error, "code") || "image_generation_failed"
    message = Map.get(error, "message") || "upstream image generation failed"
    status = if Map.get(error, "type") == "invalid_request_error", do: 400, else: 502
    Error.reason(status, code, message, Map.get(error, "param"))
  end

  defp image_data(items) do
    items
    |> Enum.flat_map(fn item ->
      case Map.get(item, "result") do
        result when is_binary(result) and result != "" -> [image_data_item(result, item)]
        _result -> []
      end
    end)
  end

  defp image_data_item(result, item) do
    %{"b64_json" => result}
    |> maybe_put(item, "revised_prompt")
  end

  defp maybe_put_usage(response, events) do
    case image_usage(events) do
      nil -> response
      usage -> Map.put(response, "usage", usage)
    end
  end

  defp image_usage(events) do
    events
    |> Enum.find_value(fn
      %{"response" => %{"tool_usage" => %{"image_gen" => usage}}} when is_map(usage) -> usage
      %{"tool_usage" => %{"image_gen" => usage}} when is_map(usage) -> usage
      _event -> nil
    end)
    |> normalize_usage()
  end

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) do
    input = integer_value(usage["input_tokens"])
    output = integer_value(usage["output_tokens"])

    total =
      integer_value(usage["total_tokens"]) ||
        if(is_integer(input) and is_integer(output), do: input + output)

    %{}
    |> maybe_put_integer("input_tokens", input)
    |> maybe_put_integer("output_tokens", output)
    |> maybe_put_integer("total_tokens", total)
    |> maybe_put_map("input_tokens_details", usage["input_tokens_details"])
    |> maybe_put_map("output_tokens_details", usage["output_tokens_details"])
    |> case do
      empty when empty == %{} -> nil
      normalized -> normalized
    end
  end

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map(map, key, value) when is_map(value), do: Map.put(map, key, value)
  defp maybe_put_map(map, _key, _value), do: map

  defp integer_value(value) when is_integer(value) and not is_boolean(value), do: value
  defp integer_value(_value), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> :invalid
    end
  end

  defp maybe_put(acc, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end
end
