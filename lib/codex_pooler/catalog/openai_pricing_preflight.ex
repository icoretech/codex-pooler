defmodule CodexPooler.Catalog.OpenAIPricingPreflight do
  @moduledoc """
  Pure, fail-closed compatibility check for `openai-json-pricing` candidates.

  It mirrors the rows the current importer can represent, but performs no Repo,
  application, or network work. Any source price dimension that would be
  silently discarded is reported as an error.
  """

  @pricing_type "per_1m_tokens"
  @supported_price_buckets ~w(default short_context long_context)
  @supported_price_fields ~w(available input cached_input output reasoning)
  @known_model_fields ~w(model pricing_type pricing_types category categories prices timestamp)

  @type issue :: %{code: atom(), message: String.t(), path: String.t()}
  @type result :: %{
          compatible?: boolean(),
          errors: [issue()],
          warnings: [issue()],
          summary: map(),
          coverage: map()
        }

  @spec validate_file(term()) :: result()
  def validate_file(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, payload} <- Jason.decode(raw) do
      validate_payload(payload)
    else
      {:error, %Jason.DecodeError{} = error} ->
        result_with_error(:invalid_json, Exception.message(error), "$")

      {:error, reason} ->
        result_with_error(:file_read_failed, format_file_error(reason), path)
    end
  end

  def validate_file(_path), do: result_with_error(:invalid_path, "path must be a string", "$")

  @spec validate_payload(term()) :: result()
  def validate_payload(%{"generated_at" => generated_at, "models" => models})
      when is_binary(generated_at) and is_map(models) do
    state = empty_state()
    state = validate_generated_at(state, generated_at)

    state =
      Enum.reduce(models, state, fn {model_name, model}, acc ->
        validate_model(acc, model_name, model)
      end)

    finalize(state)
  end

  def validate_payload(_payload) do
    result_with_error(:invalid_payload, "payload must contain generated_at and models map", "$")
  end

  defp validate_generated_at(state, generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, _datetime, _offset} ->
        state

      {:error, _reason} ->
        add_error(
          state,
          :invalid_generated_at,
          "generated_at must be an ISO-8601 datetime",
          "generated_at"
        )
    end
  end

  defp validate_model(state, model_name, model) when is_binary(model_name) and is_map(model) do
    path = "models.#{model_name}"
    state = validate_unknown_model_fields(state, model, path)

    if Map.get(model, "pricing_type") == @pricing_type do
      validate_prices(state, model_name, Map.get(model, "prices"), path)
    else
      state
      |> increment(:skipped_models)
      |> add_warning(
        :unsupported_pricing_type,
        "pricing_type is not #{@pricing_type}; importer skips this model",
        path <> ".pricing_type"
      )
    end
  end

  defp validate_model(state, model_name, _model) when is_binary(model_name) do
    add_error(
      state,
      :invalid_model_payload,
      "model #{model_name} payload must be a map",
      "models.#{model_name}"
    )
  end

  defp validate_model(state, _model_name, _model) do
    add_error(state, :invalid_model_name, "model names must be strings", "models")
  end

  defp validate_unknown_model_fields(state, model, path) do
    model
    |> Map.keys()
    |> Enum.reject(&(&1 in @known_model_fields))
    |> Enum.reduce(state, fn field, acc ->
      add_error(
        acc,
        :unknown_model_field,
        "field is not represented by the importer",
        path <> ".#{field}"
      )
    end)
  end

  defp validate_prices(state, model_name, prices, path) when is_map(prices) do
    Enum.reduce(prices, state, fn {service_tier, tier_prices}, acc ->
      validate_tier(acc, model_name, service_tier, tier_prices, path)
    end)
  end

  defp validate_prices(state, model_name, _prices, path) do
    add_error(
      state,
      :invalid_model_payload,
      "model #{model_name} prices must be a map",
      path <> ".prices"
    )
  end

  defp validate_tier(state, model_name, service_tier, tier_prices, path)
       when is_binary(service_tier) and is_map(tier_prices) do
    tier_path = path <> ".prices.#{service_tier}"

    Enum.reduce(tier_prices, state, fn {bucket, bucket_prices}, acc ->
      if bucket in @supported_price_buckets do
        validate_bucket(acc, model_name, service_tier, bucket, bucket_prices, tier_path)
      else
        acc
        |> increment(:skipped_price_buckets)
        |> add_error(
          :unknown_price_bucket,
          "bucket is not represented by the importer",
          tier_path <> ".#{bucket}"
        )
      end
    end)
  end

  defp validate_tier(state, model_name, service_tier, _tier_prices, path)
       when is_binary(service_tier) do
    add_error(
      state,
      :invalid_price_row,
      "model #{model_name} tier #{service_tier} prices must be a map",
      path <> ".prices.#{service_tier}"
    )
  end

  defp validate_tier(state, _model_name, _service_tier, _tier_prices, path) do
    add_error(
      state,
      :invalid_service_tier,
      "service tier names must be strings",
      path <> ".prices"
    )
  end

  defp validate_bucket(state, model_name, service_tier, bucket, prices, tier_path)
       when is_map(prices) do
    bucket_path = tier_path <> ".#{bucket}"
    state = validate_unknown_price_fields(state, prices, bucket_path)

    cond do
      Map.get(prices, "available") == false ->
        state
        |> increment(:importable_rows)
        |> increment(:unavailable_rows)
        |> increment_bucket(bucket)

      Map.has_key?(prices, "input") and Map.has_key?(prices, "output") ->
        state
        |> validate_decimal(prices, "input", bucket_path)
        |> validate_decimal(prices, "output", bucket_path)
        |> validate_optional_decimal(prices, "cached_input", bucket_path)
        |> validate_optional_decimal(prices, "reasoning", bucket_path)
        |> increment(:importable_rows)
        |> increment(:priced_rows)
        |> increment_bucket(bucket)

      true ->
        state
        |> increment(:skipped_price_buckets)
        |> add_warning(
          :incomplete_price_bucket,
          "model #{model_name} tier #{service_tier} bucket is skipped because input and output are required",
          bucket_path
        )
    end
  end

  defp validate_bucket(state, model_name, service_tier, bucket, _prices, tier_path) do
    add_error(
      state,
      :invalid_price_row,
      "model #{model_name} tier #{service_tier} #{bucket} pricing must be a map",
      tier_path <> ".#{bucket}"
    )
  end

  defp validate_unknown_price_fields(state, prices, path) do
    prices
    |> Map.keys()
    |> Enum.reject(&(&1 in @supported_price_fields))
    |> Enum.reduce(state, fn field, acc ->
      add_error(
        acc,
        :unknown_price_field,
        "field is not represented by pricing snapshots",
        path <> ".#{field}"
      )
    end)
  end

  defp validate_optional_decimal(state, prices, key, path) do
    if Map.has_key?(prices, key), do: validate_decimal(state, prices, key, path), else: state
  end

  defp validate_decimal(state, prices, key, path) do
    case decimal(prices[key]) do
      :ok ->
        state

      :error ->
        add_error(state, :invalid_price_value, "#{key} must be numeric", path <> ".#{key}")
    end
  end

  defp decimal(value) when is_integer(value) or is_float(value), do: :ok

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {_decimal, ""} -> :ok
      _ -> :error
    end
  end

  defp decimal(_value), do: :error

  defp empty_state do
    %{
      errors: [],
      warnings: [],
      summary: %{
        importable_rows: 0,
        priced_rows: 0,
        unavailable_rows: 0,
        skipped_models: 0,
        skipped_price_buckets: 0
      },
      buckets: Map.new(@supported_price_buckets, &{&1, 0})
    }
  end

  defp result_with_error(code, message, path),
    do: empty_state() |> add_error(code, message, path) |> finalize()

  defp finalize(state) do
    %{
      compatible?: state.errors == [],
      errors: Enum.reverse(state.errors),
      warnings: Enum.reverse(state.warnings),
      summary: state.summary,
      coverage: %{
        supported_price_buckets: @supported_price_buckets,
        imported_price_buckets: state.buckets
      }
    }
  end

  defp increment(state, key), do: update_in(state, [:summary, key], &(&1 + 1))
  defp increment_bucket(state, bucket), do: update_in(state, [:buckets, bucket], &(&1 + 1))

  defp add_error(state, code, message, path),
    do: update_in(state.errors, &[issue(code, message, path) | &1])

  defp add_warning(state, code, message, path),
    do: update_in(state.warnings, &[issue(code, message, path) | &1])

  defp issue(code, message, path), do: %{code: code, message: message, path: path}

  defp format_file_error(reason),
    do: reason |> :file.format_error() |> to_string()
end
