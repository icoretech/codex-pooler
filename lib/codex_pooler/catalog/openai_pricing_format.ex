defmodule CodexPooler.Catalog.OpenAIPricingFormat do
  @moduledoc false

  alias CodexPooler.ServiceTier

  @root_fields ~w(generated_at models models_count source source_url tools tools_count)
  @model_fields ~w(categories category model prices pricing_type pricing_types timestamp)
  @tool_fields ~w(details price pricing tool)
  @snapshot_buckets ~w(default short_context long_context)
  @price_fields ~w(input cached_input cache_write output reasoning)
  @pricing_type "per_1m_tokens"

  defmodule Row do
    @moduledoc false
    @type t :: %__MODULE__{
            model_identifier: String.t(),
            service_tier: String.t(),
            price_bucket: String.t(),
            pricing_type: String.t(),
            category: String.t(),
            categories: [String.t()],
            availability: String.t(),
            input: Decimal.t() | nil,
            cached_input: Decimal.t() | nil,
            cache_write: Decimal.t() | nil,
            output: Decimal.t() | nil,
            reasoning: Decimal.t() | nil,
            request_base: Decimal.t() | nil,
            reasoning_price_source: String.t() | nil
          }
    defstruct [
      :model_identifier,
      :service_tier,
      :price_bucket,
      :pricing_type,
      :category,
      :availability,
      :input,
      :cached_input,
      :cache_write,
      :output,
      :reasoning,
      :request_base,
      :reasoning_price_source,
      categories: []
    ]
  end

  defmodule Result do
    @moduledoc false
    @type issue :: %{code: atom(), message: String.t(), path: String.t()}
    @type t :: %__MODULE__{
            compatible?: boolean(),
            generated_at: DateTime.t() | nil,
            generated_at_raw: String.t() | nil,
            rows: [Row.t()],
            errors: [issue()],
            warnings: [issue()],
            summary: map(),
            coverage: map()
          }
    defstruct compatible?: false,
              generated_at: nil,
              generated_at_raw: nil,
              rows: [],
              errors: [],
              warnings: [],
              summary: %{},
              coverage: %{}
  end

  @type decode_error :: :invalid_json

  @spec decode(binary()) :: {:ok, map()} | {:error, decode_error()}
  def decode(raw) when is_binary(raw) do
    with {:ok, value} <- Jason.decode(raw, objects: :ordered_objects),
         {:ok, payload} <- ordered_to_maps(value) do
      {:ok, payload}
    else
      _error -> {:error, :invalid_json}
    end
  end

  @spec classify(term()) :: Result.t()
  def classify(payload) do
    state = empty_state()

    with {:ok, root} <- exact_object(payload, @root_fields, "$", state),
         {:ok, generated_at, state} <- validate_root(root, state),
         {:ok, state} <- validate_tools(root["tools"], state),
         {:ok, state} <- validate_models(root["models"], generated_at, state) do
      finalize(state, generated_at)
    else
      {:error, state} -> finalize(state, nil)
    end
  end

  defp validate_root(root, state) do
    state =
      state
      |> validate_nonblank(root["source"], "source")
      |> validate_nonblank(root["source_url"], "source_url")
      |> validate_count(root["models_count"], root["models"], "models_count")
      |> validate_count(root["tools_count"], root["tools"], "tools_count")
      |> validate_nonempty_map(root["models"], "models")
      |> validate_nonempty_map(root["tools"], "tools")

    case parse_timestamp(root["generated_at"]) do
      {:ok, generated_at} when state.errors == [] ->
        {:ok, generated_at, state}

      {:ok, _generated_at} ->
        {:error, state}

      :error ->
        {:error,
         add_error(
           state,
           :invalid_root,
           "generated_at must be an ISO-8601 datetime",
           "generated_at"
         )}
    end
  end

  defp validate_tools(tools, state) when is_map(tools) and map_size(tools) > 0 do
    state =
      tools
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(state, fn {key, tool}, acc -> validate_tool(acc, key, tool) end)

    if state.errors == [], do: {:ok, state}, else: {:error, state}
  end

  defp validate_tools(_tools, state), do: {:error, state}

  defp validate_tool(state, key, tool) do
    path = "tools.#{key}"
    state = validate_trimmed_key(state, key, "tools")

    case exact_object(tool, @tool_fields, path, state) do
      {:ok, tool} ->
        state
        |> validate_trimmed_nonblank(tool["tool"], path <> ".tool")
        |> validate_trimmed_nonblank(tool["details"], path <> ".details")
        |> validate_trimmed_nonblank(tool["pricing"], path <> ".pricing")
        |> validate_number(tool["price"], path <> ".price")

      {:error, state} ->
        state
    end
  end

  defp validate_models(models, generated_at, state)
       when is_map(models) and map_size(models) > 0 do
    {state, _identities} =
      models
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({state, MapSet.new()}, fn {key, model}, {acc, identities} ->
        validate_model(acc, identities, key, model, generated_at)
      end)

    state = coalesce_alias_rows(state)
    if state.errors == [], do: {:ok, state}, else: {:error, state}
  end

  defp validate_models(_models, _generated_at, state), do: {:error, state}

  defp validate_model(state, identities, key, model, generated_at) do
    path = "models.#{key}"

    with true <- is_binary(key),
         {:ok, model} <- exact_object(model, @model_fields, path, state) do
      normalized_key = normalize_identity(key)
      normalized_model = normalize_identity(model["model"])

      state =
        state
        |> validate_model_scalars(model, path)
        |> validate_string_list(model["categories"], path <> ".categories")
        |> validate_string_list(model["pricing_types"], path <> ".pricing_types")
        |> validate_nonempty_map(model["prices"], path <> ".prices")
        |> validate_model_identity(normalized_key, normalized_model, path)
        |> validate_model_timestamp(model["timestamp"], generated_at, path)
        |> validate_pricing_types(model["pricing_type"], model["pricing_types"], path)

      cond do
        is_nil(normalized_model) ->
          {state, identities}

        MapSet.member?(identities, normalized_model) ->
          {add_error(
             state,
             :normalized_model_collision,
             "model identities collide after normalization",
             path
           ), identities}

        state.errors != [] ->
          {state, MapSet.put(identities, normalized_model)}

        true ->
          state = classify_model(state, normalized_model, model, path)
          {state, MapSet.put(identities, normalized_model)}
      end
    else
      false ->
        {add_error(state, :invalid_model_name, "model names must be strings", "models"),
         identities}

      {:error, state} ->
        {state, identities}
    end
  end

  defp validate_model_scalars(state, model, path) do
    Enum.reduce(~w(model category pricing_type timestamp), state, fn field, acc ->
      validate_trimmed_nonblank(acc, model[field], path <> ".#{field}")
    end)
  end

  defp classify_model(state, identifier, model, path) do
    case model["pricing_type"] do
      @pricing_type ->
        classify_token_prices(state, identifier, model, path)

      type when type in ["mixed", "per_minute", "per_second"] ->
        classify_unsupported_prices(state, model, path)

      _type ->
        add_error(
          state,
          :unsupported_pricing_type_shape,
          "pricing_type is not supported",
          path <> ".pricing_type"
        )
    end
  end

  defp classify_token_prices(state, identifier, model, path) do
    prices = model["prices"]

    prices
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, fn {raw_tier, buckets}, acc ->
      classify_token_tier(acc, identifier, model, raw_tier, buckets, path)
    end)
  end

  defp classify_token_tier(state, identifier, model, raw_tier, buckets, path) do
    tier_path = path <> ".prices.#{raw_tier}"
    state = validate_pricing_key(state, raw_tier, path <> ".prices")

    if is_map(buckets) and map_size(buckets) > 0 and state.errors == [] do
      tier = ServiceTier.canonicalize(raw_tier)

      buckets
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(state, fn {bucket, values}, acc ->
        classify_token_bucket(acc, identifier, model, raw_tier, tier, bucket, values, tier_path)
      end)
    else
      add_error(state, :invalid_tier_shape, "tier prices must be a non-empty map", tier_path)
    end
  end

  defp classify_token_bucket(state, identifier, model, raw_tier, tier, bucket, values, tier_path) do
    path = tier_path <> ".#{bucket}"
    state = validate_pricing_key(state, bucket, tier_path)

    cond do
      bucket in @snapshot_buckets ->
        classify_snapshot_bucket(state, identifier, model, raw_tier, tier, bucket, values, path)

      descriptor_valid?(bucket, values) ->
        state
        |> increment(:skipped_price_buckets)
        |> add_warning(:unsupported_price_bucket, "complete non-snapshot bucket is skipped", path)

      true ->
        add_error(
          state,
          :invalid_bucket_descriptor,
          "bucket does not match a supported descriptor",
          path
        )
    end
  end

  defp classify_snapshot_bucket(state, identifier, model, raw_tier, tier, bucket, values, path) do
    cond do
      values == %{"available" => false} ->
        row = row(identifier, model, raw_tier, tier, bucket, "unavailable", %{})

        state
        |> add_row(row)
        |> increment(:importable_rows)
        |> increment(:unavailable_rows)
        |> increment_bucket(bucket)

      raw_tier == "standard" and bucket == "default" and exact_numeric_keys?(values, ["input"]) ->
        state
        |> increment(:skipped_price_buckets)
        |> add_warning(
          :incomplete_price_bucket,
          "supported bucket is incomplete and skipped",
          path
        )

      priced_bucket?(values) ->
        row = row(identifier, model, raw_tier, tier, bucket, "priced", values)

        state
        |> add_row(row)
        |> increment(:importable_rows)
        |> increment(:priced_rows)
        |> increment_bucket(bucket)

      true ->
        add_error(
          state,
          :invalid_snapshot_bucket,
          "snapshot bucket has an incompatible shape",
          path
        )
    end
  end

  defp classify_unsupported_prices(state, model, path) do
    valid? = unsupported_prices_valid?(model["pricing_type"], model["prices"])

    if valid? do
      state
      |> increment(:skipped_models)
      |> add_warning(
        :unsupported_pricing_type,
        "validated pricing type is skipped",
        path <> ".pricing_type"
      )
    else
      add_error(
        state,
        :unsupported_pricing_type_shape,
        "pricing type descriptor is incompatible",
        path <> ".prices"
      )
    end
  end

  defp unsupported_prices_valid?("mixed", %{"standard" => buckets} = prices)
       when map_size(prices) == 1 and map_size(buckets) > 0 do
    Enum.all?(buckets, fn
      {"audio", values} -> exact_numeric_keys?(values, ["output"])
      {"live_transcription", values} -> exact_numeric_keys?(values, ["estimated_cost"])
      _other -> false
    end)
  end

  defp unsupported_prices_valid?("per_minute", %{"standard" => buckets} = prices)
       when map_size(prices) == 1 and map_size(buckets) > 0 do
    Enum.all?(buckets, fn
      {"transcription", values} ->
        exact_numeric_keys?(values, ["estimated_cost"]) or
          exact_numeric_keys?(values, ~w(estimated_cost input output))

      {"transcription_+_diarization", values} ->
        exact_numeric_keys?(values, ~w(estimated_cost input output))

      _other ->
        false
    end)
  end

  defp unsupported_prices_valid?("per_second", prices)
       when is_map(prices) and map_size(prices) > 0 do
    Enum.all?(prices, fn {tier, buckets} ->
      tier in ["batch", "standard"] and is_map(buckets) and map_size(buckets) > 0 and
        Enum.all?(buckets, &video_bucket_valid?/1)
    end)
  end

  defp unsupported_prices_valid?(_type, _prices), do: false

  defp video_bucket_valid?({bucket, values}) do
    resolutions = %{
      "720p" => {"1280x720", "720x1280"},
      "1024p" => {"1792x1024", "1024x1792"},
      "1080p" => {"1920x1080", "1080x1920"}
    }

    case {Map.get(resolutions, bucket), values} do
      {{landscape, portrait},
       %{
         "landscape" => actual_landscape,
         "portrait" => actual_portrait,
         "price_per_second" => price
       }} ->
        actual_landscape == landscape and actual_portrait == portrait and
          finite_nonnegative_number?(price)

      _other ->
        false
    end
  end

  defp descriptor_valid?("audio", values),
    do: numeric_key_set?(values, [~w(cached_input input output), ~w(input output), ~w(output)])

  defp descriptor_valid?("image", values),
    do: numeric_key_set?(values, [~w(cached_input input), ~w(cached_input input output)])

  defp descriptor_valid?("inference", values) do
    cond do
      exact_numeric_keys?(values, ~w(cached_input input output training)) ->
        true

      exact_numeric_keys?(values, ~w(input output training)) ->
        true

      exact_keys?(values, ~w(cached_input input output training training_unit)) ->
        values["training_unit"] == "hour" and
          Enum.all?(
            ~w(cached_input input output training),
            &finite_nonnegative_number?(values[&1])
          )

      true ->
        false
    end
  end

  defp descriptor_valid?("inference_with_data_sharing", values) do
    exact_keys?(values, ~w(cached_input input output training training_unit)) and
      values["training_unit"] == "hour" and
      Enum.all?(~w(cached_input input output training), &finite_nonnegative_number?(values[&1]))
  end

  defp descriptor_valid?("text", values),
    do:
      numeric_key_set?(values, [
        ~w(cached_input input),
        ~w(cached_input input output),
        ~w(input),
        ~w(input output)
      ])

  defp descriptor_valid?(_bucket, _values), do: false

  defp priced_bucket?(values) when is_map(values) do
    keys = Map.keys(values)
    allowed = ["available" | @price_fields]

    Enum.all?(keys, &(&1 in allowed)) and Map.has_key?(values, "input") and
      Map.has_key?(values, "output") and Map.get(values, "available", true) == true and
      Enum.all?(Map.take(values, @price_fields), fn {_key, value} ->
        finite_nonnegative_number?(value)
      end)
  end

  defp priced_bucket?(_values), do: false

  defp row(identifier, model, raw_tier, tier, bucket, availability, values) do
    output = decimal(values["output"])
    reasoning = decimal(values["reasoning"]) || output

    %Row{
      model_identifier: identifier,
      service_tier: tier,
      price_bucket: bucket,
      pricing_type: @pricing_type,
      category: String.trim(model["category"]),
      categories: Enum.map(model["categories"], &String.trim/1),
      availability: availability,
      input: decimal(values["input"]),
      cached_input:
        decimal(values["cached_input"]) || if(availability == "priced", do: Decimal.new(0)),
      cache_write: decimal(values["cache_write"]),
      output: output,
      reasoning: reasoning,
      request_base: if(availability == "priced", do: Decimal.new(0)),
      reasoning_price_source:
        if(availability == "priced",
          do:
            if(Map.has_key?(values, "reasoning"),
              do: "default.reasoning",
              else: "output_fallback"
            )
        )
    }
    |> Map.put(:raw_service_tier, raw_tier)
  end

  defp coalesce_alias_rows(state) do
    state.rows
    |> Enum.group_by(& &1.model_identifier)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{state | rows: []}, fn {_identifier, rows}, acc ->
      coalesce_model_rows(acc, rows)
    end)
  end

  defp coalesce_model_rows(state, rows) do
    rows_by_tier = Enum.group_by(rows, & &1.service_tier)

    Enum.reduce(rows_by_tier, state, fn {_tier, tier_rows}, acc ->
      case Enum.group_by(tier_rows, & &1.raw_service_tier) do
        %{"fast" => fast_rows, "priority" => priority_rows} = aliases
        when map_size(aliases) == 2 ->
          coalesce_alias_tiers(acc, fast_rows, priority_rows)

        _non_alias ->
          coalesce_identity_rows(acc, tier_rows)
      end
    end)
  end

  defp coalesce_identity_rows(state, rows) do
    rows
    |> Enum.group_by(&row_identity/1)
    |> Enum.reduce(state, fn {_identity, identity_rows}, acc ->
      coalesce_rows(acc, identity_rows)
    end)
  end

  defp coalesce_alias_tiers(state, fast_rows, priority_rows) do
    fast = semantic_tier(fast_rows)
    priority = semantic_tier(priority_rows)

    if fast == priority do
      Enum.reduce(fast_rows, state, fn row, acc ->
        %{acc | rows: [Map.delete(row, :raw_service_tier) | acc.rows]}
      end)
    else
      add_error(
        state,
        :conflicting_service_tier_alias,
        "fast and priority pricing aliases conflict",
        row_path(hd(fast_rows))
      )
    end
  end

  defp semantic_tier(rows) do
    rows
    |> Map.new(fn row -> {row.price_bucket, semantic_row(row)} end)
  end

  defp coalesce_rows(state, [row]),
    do: %{state | rows: [Map.delete(row, :raw_service_tier) | state.rows]}

  defp coalesce_rows(state, rows) do
    raw_tiers = rows |> Enum.map(& &1.raw_service_tier) |> Enum.sort()
    semantic_rows = Enum.map(rows, &(&1 |> Map.delete(:raw_service_tier) |> semantic_row()))

    if raw_tiers == ["fast", "priority"] and Enum.uniq(semantic_rows) |> length() == 1 do
      %{state | rows: [rows |> hd() |> Map.delete(:raw_service_tier) | state.rows]}
    else
      add_error(
        state,
        :conflicting_service_tier_alias,
        "fast and priority pricing aliases conflict",
        row_path(hd(rows))
      )
    end
  end

  @spec semantic_row(Row.t() | map()) :: map()
  def semantic_row(row) do
    row
    |> Map.take([
      :model_identifier,
      :service_tier,
      :price_bucket,
      :pricing_type,
      :category,
      :categories,
      :availability,
      :input,
      :cached_input,
      :cache_write,
      :output,
      :reasoning,
      :request_base,
      :reasoning_price_source
    ])
    |> Map.update!(:input, &normalize_decimal/1)
    |> Map.update!(:cached_input, &normalize_decimal/1)
    |> Map.update!(:cache_write, &normalize_decimal/1)
    |> Map.update!(:output, &normalize_decimal/1)
    |> Map.update!(:reasoning, &normalize_decimal/1)
    |> Map.update!(:request_base, &normalize_decimal/1)
  end

  defp row_identity(row), do: {row.model_identifier, row.service_tier, row.price_bucket}

  defp row_path(row),
    do: "models.#{row.model_identifier}.prices.#{row.service_tier}.#{row.price_bucket}"

  defp exact_object(value, fields, path, state) when is_map(value) do
    actual = Map.keys(value) |> Enum.sort()
    expected = Enum.sort(fields)

    if actual == expected do
      {:ok, value}
    else
      {:error,
       add_error(
         state,
         :invalid_object_shape,
         "object keys must match the catalog contract",
         path
       )}
    end
  end

  defp exact_object(_value, _fields, path, state),
    do: {:error, add_error(state, :invalid_object_shape, "value must be an object", path)}

  defp ordered_to_maps(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      Enum.reduce_while(values, {:ok, %{}}, &convert_ordered_entry/2)
    else
      {:error, :duplicate_key}
    end
  end

  defp ordered_to_maps(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case ordered_to_maps(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp ordered_to_maps(value), do: {:ok, value}

  defp convert_ordered_entry({key, value}, {:ok, acc}) do
    case ordered_to_maps(value) do
      {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
      error -> {:halt, error}
    end
  end

  defp validate_model_identity(state, normalized_key, normalized_model, path) do
    if not is_nil(normalized_key) and normalized_key == normalized_model do
      state
    else
      add_error(
        state,
        :model_identity_mismatch,
        "model key and model value must match after normalization",
        path <> ".model"
      )
    end
  end

  defp validate_model_timestamp(state, timestamp, generated_at, path) do
    case parse_timestamp(timestamp) do
      {:ok, timestamp} ->
        if DateTime.compare(timestamp, generated_at) == :eq,
          do: state,
          else:
            add_error(
              state,
              :timestamp_mismatch,
              "model timestamp must equal generated_at",
              path <> ".timestamp"
            )

      :error ->
        add_error(
          state,
          :invalid_timestamp,
          "timestamp must be an ISO-8601 datetime",
          path <> ".timestamp"
        )
    end
  end

  defp validate_pricing_types(state, "mixed", ["per_1m_tokens", "per_minute"], _path), do: state
  defp validate_pricing_types(state, type, [type], _path) when is_binary(type), do: state

  defp validate_pricing_types(state, _type, _types, path),
    do:
      add_error(
        state,
        :pricing_types_mismatch,
        "pricing_types do not match pricing_type",
        path <> ".pricing_types"
      )

  defp validate_string_list(state, values, path) when is_list(values) and values != [] do
    normalized = Enum.map(values, &if(is_binary(&1), do: String.trim(&1), else: nil))

    if Enum.all?(values, &(is_binary(&1) and &1 == String.trim(&1) and &1 != "")) and
         length(normalized) == MapSet.size(MapSet.new(normalized)) do
      state
    else
      add_error(
        state,
        :invalid_string_list,
        "list must contain unique nonblank trimmed strings",
        path
      )
    end
  end

  defp validate_string_list(state, _values, path),
    do: add_error(state, :invalid_string_list, "list must be non-empty", path)

  defp validate_count(state, count, values, path)
       when is_integer(count) and count >= 0 and is_map(values) do
    if count == map_size(values),
      do: state,
      else: add_error(state, :count_mismatch, "count does not match object size", path)
  end

  defp validate_count(state, _count, _values, path),
    do: add_error(state, :invalid_count, "count must be a nonnegative integer", path)

  defp validate_nonempty_map(state, value, _path) when is_map(value) and map_size(value) > 0,
    do: state

  defp validate_nonempty_map(state, _value, path),
    do: add_error(state, :invalid_map, "value must be a non-empty map", path)

  defp validate_nonblank(state, value, path) when is_binary(value) do
    if String.trim(value) == "",
      do: add_error(state, :invalid_string, "value must be a nonblank string", path),
      else: state
  end

  defp validate_nonblank(state, _value, path),
    do: add_error(state, :invalid_string, "value must be a nonblank string", path)

  defp validate_trimmed_nonblank(state, value, path) when is_binary(value) do
    if value != "" and value == String.trim(value),
      do: state,
      else: add_error(state, :invalid_string, "value must be a nonblank trimmed string", path)
  end

  defp validate_trimmed_nonblank(state, _value, path),
    do: add_error(state, :invalid_string, "value must be a nonblank trimmed string", path)

  defp validate_trimmed_key(state, key, path) when is_binary(key) do
    if key != "" and key == String.trim(key),
      do: state,
      else: add_error(state, :invalid_key, "keys must be nonblank trimmed strings", path)
  end

  defp validate_trimmed_key(state, _key, path),
    do: add_error(state, :invalid_key, "keys must be nonblank trimmed strings", path)

  defp validate_pricing_key(state, key, path) when is_binary(key) do
    if key != "" and key == String.trim(key) and key == String.downcase(key),
      do: state,
      else:
        add_error(
          state,
          :invalid_pricing_key,
          "pricing keys must be trimmed lowercase strings",
          path
        )
  end

  defp validate_pricing_key(state, _key, path),
    do:
      add_error(
        state,
        :invalid_pricing_key,
        "pricing keys must be trimmed lowercase strings",
        path
      )

  defp validate_number(state, value, path) do
    if finite_nonnegative_number?(value),
      do: state,
      else: add_error(state, :invalid_number, "value must be a finite nonnegative number", path)
  end

  defp exact_numeric_keys?(values, keys),
    do: exact_keys?(values, keys) and Enum.all?(keys, &finite_nonnegative_number?(values[&1]))

  defp numeric_key_set?(values, key_sets),
    do: Enum.any?(key_sets, &exact_numeric_keys?(values, &1))

  defp exact_keys?(values, keys) when is_map(values),
    do: Enum.sort(Map.keys(values)) == Enum.sort(keys)

  defp exact_keys?(_values, _keys), do: false

  defp finite_nonnegative_number?(value) when is_integer(value), do: value >= 0

  defp finite_nonnegative_number?(value) when is_float(value) do
    encoded = value |> :erlang.float_to_binary([:compact]) |> String.downcase()
    value >= 0 and encoded not in ["inf", "+inf", "nan"]
  end

  defp finite_nonnegative_number?(_value), do: false

  defp decimal(nil), do: nil
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp normalize_decimal(nil), do: nil
  defp normalize_decimal(%Decimal{} = value), do: Decimal.normalize(value)

  defp normalize_identity(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identity(_value), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, usec_precision(datetime)}
      _error -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp empty_state do
    %{
      errors: [],
      warnings: [],
      rows: [],
      summary: %{
        importable_rows: 0,
        priced_rows: 0,
        unavailable_rows: 0,
        skipped_models: 0,
        skipped_price_buckets: 0
      },
      buckets: Map.new(@snapshot_buckets, &{&1, 0})
    }
  end

  defp finalize(state, generated_at) do
    errors = sort_issues(state.errors)
    warnings = sort_issues(state.warnings)

    %Result{
      compatible?: errors == [],
      generated_at: generated_at,
      generated_at_raw: if(generated_at, do: DateTime.to_iso8601(generated_at)),
      rows: Enum.sort_by(state.rows, &row_identity/1),
      errors: errors,
      warnings: warnings,
      summary: state.summary,
      coverage: %{
        supported_price_buckets: @snapshot_buckets,
        imported_price_buckets: state.buckets
      }
    }
  end

  defp add_row(state, row), do: %{state | rows: [row | state.rows]}
  defp increment(state, key), do: update_in(state, [:summary, key], &(&1 + 1))
  defp increment_bucket(state, bucket), do: update_in(state, [:buckets, bucket], &(&1 + 1))

  defp add_error(state, code, message, path),
    do: update_in(state.errors, &[%{code: code, message: message, path: path} | &1])

  defp add_warning(state, code, message, path),
    do: update_in(state.warnings, &[%{code: code, message: message, path: path} | &1])

  defp sort_issues(issues), do: Enum.sort_by(issues, &{&1.path, &1.code, &1.message})

  defp usec_precision(%DateTime{microsecond: {microsecond, _precision}} = timestamp),
    do: %DateTime{timestamp | microsecond: {microsecond, 6}}
end
