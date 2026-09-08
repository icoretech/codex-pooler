defmodule CodexPooler.Gateway.OpenAICompatibility.Images do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @image_25_models ~w(gpt-image-2.5-flare gpt-image-2.5-sunburst gpt-image-2.5-flare-2026-09-08 gpt-image-2.5-sunburst-2026-09-08)
  @native_models ["gpt-image-2" | @image_25_models]
  @supported_models ~w(gpt-image-1 gpt-image-1.5 gpt-image-1-mini) ++ @native_models
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
  def coerce_generation(payload, opts \\ %{})

  def coerce_generation(%{"model" => model} = payload, opts)
      when model in @native_models and not is_map_key(payload, "input_fidelity") and
             not is_map_key(payload, "mask") do
    with {:ok, payload} <- normalize_image_payload(payload),
         :ok <- require_prompt(payload),
         :ok <- validate_generation_only(payload) do
      native_response(payload, "generations", opts)
    end
  end

  def coerce_generation(payload, opts) do
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
  def coerce_edit(payload, opts \\ %{})

  def coerce_edit(%{"model" => model} = payload, opts)
      when model in @native_models and not is_map_key(payload, "input_fidelity") and
             not is_map_key(payload, "mask") do
    with {:ok, %{image_payload: image_payload, images: images}} <- prepare_edit(payload),
         {:ok, response} <- native_response(image_payload, "edits", opts) do
      images = Enum.map(images, &Map.take(&1, ["image_url"]))
      {:ok, %{response | payload: Map.put(response.payload, "images", images)}}
    end
  end

  def coerce_edit(payload, opts) do
    with {:ok, %{image_payload: image_payload, response_payload: response_payload}} <-
           prepare_edit(payload),
         {:ok, response} <- Responses.coerce(response_payload, opts) do
      {:ok, Map.put(response, :image_payload, image_payload)}
    end
  end

  defp native_response(payload, operation, opts) do
    endpoint = "/backend-api/codex/images/" <> operation
    native = payload |> Map.take(~w(model prompt background quality size)) |> Map.put("n", 1)

    options =
      opts
      |> Map.new()
      |> Map.merge(%{
        upstream_endpoint: endpoint,
        native_image_request?: true,
        collect_openai_image_stream: false
      })
      |> RequestOptions.build(endpoint, native)

    {:ok,
     %{endpoint: endpoint, payload: native, image_payload: payload, request_options: options}}
  end

  @spec image_response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def image_response_from_sse(body) when is_binary(body) do
    events = decoded_sse_events(body)

    with :ok <- reject_failed_events(events),
         {:ok, items} <- image_items(events),
         :ok <- reject_failed_items(items),
         :ok <- require_completed_event(events),
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
      response_payload = put_edit_images(response_payload, payload["prompt"], images, mask)

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
         :ok <- validate_size(payload),
         :ok <- validate_quality(payload),
         :ok <- validate_one_of(payload, "background", @backgrounds),
         :ok <- validate_input_fidelity(payload),
         :ok <- validate_n(payload),
         :ok <- validate_one_of(payload, "response_format", ["b64_json"]) do
      discard_user_identifier(payload)
    end
  end

  defp validate_quality(%{"model" => model} = payload) when model in @image_25_models,
    do: validate_one_of(payload, "quality", @qualities ++ ~w(xhigh max))

  defp validate_quality(payload), do: validate_one_of(payload, "quality", @qualities)

  defp validate_size(%{"model" => model, "size" => size})
       when model in @image_25_models and is_binary(size) and size != "auto" do
    if valid_dimensions?(size),
      do: :ok,
      else: {:error, Error.invalid_request("size is not supported", "size")}
  end

  defp validate_size(payload), do: validate_one_of(payload, "size", @sizes)

  defp valid_dimensions?(size) when byte_size(size) <= 9 do
    case Regex.run(~r/\A([1-9][0-9]{0,3})x([1-9][0-9]{0,3})\z/, size) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)
        valid_edges?(width, height) and (width * height) in 655_360..8_294_400

      _ ->
        false
    end
  end

  defp valid_dimensions?(_size), do: false

  defp valid_edges?(width, height),
    do:
      max(width, height) <= 3840 and rem(width, 16) == 0 and rem(height, 16) == 0 and
        max(width, height) <= 3 * min(width, height)

  defp validate_input_fidelity(%{"model" => model, "input_fidelity" => _})
       when model in @native_models or model == "gpt-image-1-mini" do
    {:error,
     Error.invalid_request("input_fidelity is not supported for #{model}", "input_fidelity")}
  end

  defp validate_input_fidelity(payload),
    do: validate_one_of(payload, "input_fidelity", @input_fidelities)

  defp validate_generation_only(%{"image" => _image}),
    do: {:error, Error.invalid_request("image is only supported for image edits", "image")}

  defp validate_generation_only(%{"image[]" => _image}),
    do: {:error, Error.invalid_request("image is only supported for image edits", "image")}

  defp validate_generation_only(%{"mask" => _}),
    do: {:error, Error.invalid_request("mask is only supported for image edits", "mask")}

  defp validate_generation_only(%{"input_fidelity" => _}),
    do:
      {:error,
       Error.invalid_request("input_fidelity is only supported for image edits", "input_fidelity")}

  defp validate_generation_only(_payload), do: :ok

  defp discard_user_identifier(%{"user" => user} = payload) when is_binary(user) or is_nil(user),
    do: {:ok, Map.delete(payload, "user")}

  defp discard_user_identifier(%{"user" => _}),
    do: {:error, Error.invalid_request("user must be a string or null", "user")}

  defp discard_user_identifier(payload), do: {:ok, payload}

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
    response_payload
    |> Map.put("input", [message_input(prompt, images)])
    |> Map.update!("tools", fn [tool] ->
      [Map.put(tool, "input_image_mask", Map.take(mask, ["image_url"]))]
    end)
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

  defp require_completed_event(events) do
    if Enum.any?(events, &(Map.get(&1, "type") == "response.completed")) do
      :ok
    else
      {:error,
       Error.reason(
         502,
         "image_generation_failed",
         "upstream image response ended before completion"
       )}
    end
  end

  defp reject_failed_events(events) do
    if Enum.any?(
         events,
         &(Map.get(&1, "type") in ["response.failed", "response.incomplete", "error"])
       ) do
      {:error, Error.reason(502, "image_generation_failed", "upstream image generation failed")}
    else
      :ok
    end
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

        %{"type" => type, "response" => %{"output" => output}}
        when type in ["response.completed", "response.failed", "response.incomplete"] and
               is_list(output) ->
          Enum.filter(output, &image_item?/1)

        %{"type" => type, "output" => output}
        when type in ["response.completed", "response.failed", "response.incomplete"] and
               is_list(output) ->
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
    status = if Map.get(error, "type") == "invalid_request_error", do: 400, else: 502
    Error.reason(status, "image_generation_failed", "upstream image generation failed")
  end

  defp image_data(items) do
    items
    |> Enum.reverse()
    |> Enum.uniq_by(&(Map.get(&1, "id") || &1))
    |> Enum.reverse()
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
