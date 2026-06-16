defmodule CodexPooler.Catalog.OpenAIPricingImporter do
  @moduledoc false

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  @source "openai-json-pricing"
  @pricing_type "per_1m_tokens"
  @supported_price_buckets ~w(default short_context long_context)
  @unavailable "unavailable"
  @currency_code "USD"
  @billing_unit "token"

  @type importer_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type import_result :: %{
          required(:inserted) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          required(:source) => String.t(),
          required(:price_version) => String.t()
        }

  @spec import_file(term()) :: {:ok, import_result()} | {:error, importer_error()}
  def import_file(path) when is_binary(path) do
    with {:ok, payload} <- decode_file(path) do
      import_payload(payload, path)
    end
  end

  def import_file(_path), do: {:error, importer_error(:invalid_path, "path must be a string")}

  @spec import_url(term()) :: {:ok, import_result()} | {:error, importer_error()}
  def import_url(url) when is_binary(url) do
    with {:ok, payload} <- fetch_url(url) do
      import_payload(payload, url)
    end
  end

  def import_url(_url), do: {:error, importer_error(:invalid_url, "url must be a string")}

  defp import_payload(payload, source_url) do
    with {:ok, generated_at, generated_at_raw, models} <- validate_payload(payload),
         {:ok, rows, skipped} <- build_rows(models, generated_at, generated_at_raw, source_url) do
      replace_rows(generated_at_raw, rows, skipped)
    end
  end

  defp decode_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, payload} <- Jason.decode(raw) do
      {:ok, payload}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, importer_error(:invalid_json, Exception.message(error))}

      {:error, reason} ->
        {:error, importer_error(:file_read_failed, format_file_error(reason))}
    end
  end

  defp fetch_url(url) do
    case Req.get(url, decode_body: false, receive_timeout: :timer.seconds(30), retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        decode_json_body(body)

      {:ok, %{status: status}} ->
        {:error, importer_error(:http_error, "pricing catalog returned HTTP #{status}")}

      {:error, %Req.TransportError{} = error} ->
        {:error, importer_error(:http_transport_failed, Exception.message(error))}
    end
  end

  defp decode_json_body(body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, importer_error(:invalid_json, Exception.message(error))}
    end
  end

  defp format_file_error(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  defp validate_payload(%{"generated_at" => generated_at_raw, "models" => models})
       when is_binary(generated_at_raw) and is_map(models) do
    case DateTime.from_iso8601(generated_at_raw) do
      {:ok, generated_at, _offset} ->
        {:ok, usec_precision(generated_at), generated_at_raw, models}

      {:error, _reason} ->
        {:error,
         importer_error(:invalid_generated_at, "generated_at must be an ISO-8601 datetime")}
    end
  end

  defp validate_payload(_payload) do
    {:error,
     importer_error(
       :invalid_payload,
       "payload must contain generated_at and models map"
     )}
  end

  defp build_rows(models, generated_at, generated_at_raw, path) do
    now = now()

    Enum.reduce_while(models, {:ok, [], 0}, fn {model_name, model_payload},
                                               {:ok, rows, skipped} ->
      case build_model_rows(model_name, model_payload, generated_at, generated_at_raw, path, now) do
        {:ok, model_rows, model_skipped} ->
          {:cont, {:ok, rows ++ model_rows, skipped + model_skipped}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_model_rows(model_name, model_payload, generated_at, generated_at_raw, path, now)
       when is_binary(model_name) and is_map(model_payload) do
    pricing_type = Map.get(model_payload, "pricing_type")

    if pricing_type == @pricing_type do
      with {:ok, prices} <- fetch_prices(model_payload, model_name),
           {:ok, model_identifier} <- model_identifier(model_name, model_payload) do
        build_service_tier_rows(
          model_identifier,
          model_payload,
          prices,
          generated_at,
          generated_at_raw,
          path,
          now
        )
      end
    else
      {:ok, [], 1}
    end
  end

  defp build_model_rows(model_name, _model_payload, _generated_at, _generated_at_raw, _path, _now)
       when is_binary(model_name) do
    {:error, importer_error(:invalid_model_payload, "model #{model_name} payload must be a map")}
  end

  defp fetch_prices(%{"prices" => prices}, _model_name) when is_map(prices), do: {:ok, prices}

  defp fetch_prices(_model_payload, model_name) do
    {:error, importer_error(:invalid_model_payload, "model #{model_name} prices must be a map")}
  end

  defp model_identifier(_model_name, %{"model" => model}) when is_binary(model) and model != "",
    do: {:ok, model}

  defp model_identifier(model_name, _model_payload), do: {:ok, model_name}

  defp build_service_tier_rows(
         model_identifier,
         model_payload,
         prices,
         generated_at,
         generated_at_raw,
         path,
         now
       ) do
    Enum.reduce_while(prices, {:ok, [], 0}, fn {service_tier, tier_prices},
                                               {:ok, rows, skipped} ->
      case build_tier_row(
             model_identifier,
             model_payload,
             service_tier,
             tier_prices,
             generated_at,
             generated_at_raw,
             path,
             now
           ) do
        {:ok, tier_rows, tier_skipped} ->
          {:cont, {:ok, rows ++ tier_rows, skipped + tier_skipped}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows, skipped} -> {:ok, rows, skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_tier_row(
         model_identifier,
         model_payload,
         service_tier,
         tier_prices,
         generated_at,
         generated_at_raw,
         path,
         now
       )
       when is_binary(service_tier) and is_map(tier_prices) do
    row_context = %{
      generated_at: generated_at,
      generated_at_raw: generated_at_raw,
      model_identifier: model_identifier,
      model_payload: model_payload,
      now: now,
      path: path,
      service_tier: service_tier
    }

    tier_prices
    |> Map.take(@supported_price_buckets)
    |> Enum.reduce_while({:ok, [], 0}, fn {price_bucket, prices}, {:ok, rows, skipped} ->
      case build_bucket_row(row_context, price_bucket, prices) do
        {:ok, nil} -> {:cont, {:ok, rows, skipped + 1}}
        {:ok, row} -> {:cont, {:ok, [row | rows], skipped}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, [], skipped} -> {:ok, [], skipped + 1}
      {:ok, rows, skipped} -> {:ok, Enum.reverse(rows), skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_tier_row(
         model_identifier,
         _model_payload,
         service_tier,
         _tier_prices,
         _generated_at,
         _generated_at_raw,
         _path,
         _now
       )
       when is_binary(service_tier) do
    {:error,
     importer_error(
       :invalid_price_row,
       "model #{model_identifier} tier #{service_tier} prices must be a map"
     )}
  end

  defp build_bucket_row(%{} = row_context, price_bucket, prices) when is_map(prices) do
    case build_snapshot_row(row_context, price_bucket, prices) do
      {:ok, :skip} -> {:ok, nil}
      other -> other
    end
  end

  defp build_bucket_row(
         %{model_identifier: model_identifier, service_tier: service_tier},
         price_bucket,
         _prices
       ) do
    {:error,
     importer_error(
       :invalid_price_row,
       "model #{model_identifier} tier #{service_tier} #{price_bucket} pricing must be a map"
     )}
  end

  defp build_snapshot_row(
         %{
           generated_at: generated_at,
           generated_at_raw: generated_at_raw,
           model_identifier: model_identifier,
           model_payload: model_payload,
           now: now,
           path: path,
           service_tier: service_tier
         },
         price_bucket,
         default_prices
       ) do
    cond do
      unavailable_price_bucket?(default_prices) ->
        {:ok,
         %{
           model_identifier: model_identifier,
           price_version: generated_at_raw,
           currency_code: @currency_code,
           billing_unit: @billing_unit,
           input_token_micros: nil,
           cached_input_token_micros: nil,
           output_token_micros: nil,
           reasoning_token_micros: nil,
           request_base_micros: nil,
           effective_at: generated_at,
           source_url: path,
           captured_at: now,
           config:
             snapshot_config(model_payload, generated_at_raw, path, service_tier, price_bucket, %{
               "availability" => @unavailable
             })
         }}

      Map.has_key?(default_prices, "input") and Map.has_key?(default_prices, "output") ->
        with {:ok, input} <-
               required_decimal(default_prices, "input", model_identifier, service_tier),
             {:ok, output} <-
               required_decimal(default_prices, "output", model_identifier, service_tier),
             {:ok, cached_input} <-
               optional_decimal(default_prices, "cached_input", Decimal.new(0)),
             {:ok, reasoning, reasoning_source} <- reasoning_price(default_prices, output) do
          {:ok,
           %{
             model_identifier: model_identifier,
             price_version: generated_at_raw,
             currency_code: @currency_code,
             billing_unit: @billing_unit,
             input_token_micros: usd_per_1m_to_token_micros(input),
             cached_input_token_micros: usd_per_1m_to_token_micros(cached_input),
             output_token_micros: usd_per_1m_to_token_micros(output),
             reasoning_token_micros: usd_per_1m_to_token_micros(reasoning),
             request_base_micros: Decimal.new(0),
             effective_at: generated_at,
             source_url: path,
             captured_at: now,
             config:
               snapshot_config(
                 model_payload,
                 generated_at_raw,
                 path,
                 service_tier,
                 price_bucket,
                 %{
                   "availability" => "priced",
                   "reasoning_price_source" => reasoning_source
                 }
               )
           }}
        end

      true ->
        {:ok, :skip}
    end
  end

  defp unavailable_price_bucket?(prices), do: Map.get(prices, "available") == false

  defp snapshot_config(model_payload, generated_at_raw, path, service_tier, price_bucket, extra) do
    Map.merge(
      %{
        "source" => @source,
        "source_generated_at" => generated_at_raw,
        "source_path" => path,
        "service_tier" => service_tier,
        "price_bucket" => price_bucket,
        "pricing_type" => @pricing_type,
        "category" => string_or_nil(Map.get(model_payload, "category")),
        "categories" => string_list_or_empty(Map.get(model_payload, "categories"))
      },
      extra
    )
  end

  defp required_decimal(map, key, model_identifier, service_tier) do
    with {:ok, value} <- optional_decimal(map, key, nil),
         false <- is_nil(value) do
      {:ok, value}
    else
      true ->
        {:error,
         importer_error(
           :invalid_price_row,
           "model #{model_identifier} tier #{service_tier} default.#{key} must be present"
         )}

      {:error, _reason} ->
        {:error,
         importer_error(
           :invalid_price_row,
           "model #{model_identifier} tier #{service_tier} default.#{key} must be numeric"
         )}
    end
  end

  defp optional_decimal(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      value -> parse_decimal_value(value)
    end
  end

  defp parse_decimal_value(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp parse_decimal_value(value) when is_float(value) do
    value
    |> Float.to_string()
    |> parse_decimal_string()
  end

  defp parse_decimal_value(%Decimal{} = value), do: {:ok, value}

  defp parse_decimal_value(value) when is_binary(value), do: parse_decimal_string(value)
  defp parse_decimal_value(_invalid), do: {:error, :invalid_decimal}

  defp parse_decimal_string(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _invalid -> {:error, :invalid_decimal}
    end
  end

  defp reasoning_price(default_prices, output) do
    case optional_decimal(default_prices, "reasoning", nil) do
      {:ok, %Decimal{} = reasoning} ->
        {:ok, reasoning, "default.reasoning"}

      {:ok, nil} ->
        {:ok, output, "output_fallback"}

      {:error, _reason} ->
        {:error, importer_error(:invalid_price_row, "default.reasoning must be numeric")}
    end
  end

  defp replace_rows(price_version, rows, skipped) do
    Repo.transaction(fn ->
      inserted_count = insert_rows(rows)

      %{inserted: inserted_count, skipped: skipped, total: inserted_count + skipped}
    end)
    |> case do
      {:ok, stats} ->
        {:ok,
         Map.merge(stats, %{
           source: @source,
           price_version: price_version
         })}

      {:error, reason} ->
        {:error, importer_error(:import_failed, Exception.message(reason))}
    end
  end

  defp insert_rows([]), do: 0

  defp insert_rows(rows) do
    {count, _rows} = Repo.insert_all(PricingSnapshot, rows, on_conflict: :nothing)
    count
  end

  defp usd_per_1m_to_token_micros(%Decimal{} = usd_per_1m), do: usd_per_1m

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp string_list_or_empty(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
  end

  defp string_list_or_empty(_values), do: []

  defp importer_error(code, message), do: %{code: code, message: message}

  defp usec_precision(%DateTime{microsecond: {microsecond, _precision}} = timestamp),
    do: %DateTime{timestamp | microsecond: {microsecond, 6}}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
