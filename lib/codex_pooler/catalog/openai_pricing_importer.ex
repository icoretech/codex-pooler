defmodule CodexPooler.Catalog.OpenAIPricingImporter do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.{OpenAIPricingFormat, PricingSnapshot}
  alias CodexPooler.Repo

  @source "openai-json-pricing"
  @revision "2"
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
    with {:ok, raw} <- File.read(path),
         {:ok, payload} <- decode(raw),
         {:ok, classified} <- classify(payload) do
      persist(classified, path)
    else
      {:error, reason} when is_atom(reason) -> {:error, file_error(reason)}
      {:error, %{code: _code, message: _message} = error} -> {:error, error}
    end
  end

  def import_file(_path), do: {:error, error(:invalid_path, "path must be a string")}

  @spec import_url(term()) :: {:ok, import_result()} | {:error, importer_error()}
  def import_url(url) when is_binary(url) do
    with {:ok, raw} <- fetch(url),
         {:ok, payload} <- decode(raw),
         {:ok, classified} <- classify(payload) do
      persist(classified, url)
    end
  end

  def import_url(_url), do: {:error, error(:invalid_url, "url must be a string")}

  defp fetch(url) do
    case Req.get(url, decode_body: false, receive_timeout: :timer.seconds(30), retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, error(:http_error, "pricing catalog returned HTTP #{status}")}

      {:error, %Req.TransportError{}} ->
        {:error, error(:http_transport_failed, "pricing catalog transport failed")}
    end
  end

  defp decode(raw) do
    case OpenAIPricingFormat.decode(raw) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, :invalid_json} ->
        {:error, error(:invalid_json, "pricing catalog is not valid JSON")}
    end
  end

  defp classify(payload) do
    case OpenAIPricingFormat.classify(payload) do
      %{compatible?: true} = result ->
        {:ok, %{result | generated_at_raw: payload["generated_at"]}}

      %{errors: errors} ->
        code =
          if Enum.any?(errors, &(&1.code == :conflicting_service_tier_alias)),
            do: :conflicting_service_tier_alias,
            else: :incompatible_pricing_catalog

        {:error, error(code, error_message(code))}
    end
  end

  defp persist(classified, source_url) do
    price_version = "#{classified.generated_at_raw}:importer-format-2"
    captured_at = now()

    rows =
      Enum.map(classified.rows, fn row ->
        row_attrs(
          row,
          classified.generated_at,
          classified.generated_at_raw,
          price_version,
          source_url,
          captured_at
        )
      end)

    Repo.transaction(fn -> insert_rows(rows) end)
    |> case do
      {:ok, inserted} ->
        skipped = classified.summary.skipped_models + classified.summary.skipped_price_buckets

        {:ok,
         %{
           inserted: inserted,
           skipped: skipped,
           total: inserted + skipped,
           source: @source,
           price_version: price_version
         }}

      {:error, %{code: _code, message: _message} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, error(:concurrent_pricing_conflict, error_message(:concurrent_pricing_conflict))}
    end
  end

  defp insert_rows(rows) do
    Enum.reduce(rows, 0, fn attrs, inserted ->
      case Repo.insert(PricingSnapshot.insert_changeset(attrs), mode: :savepoint) do
        {:ok, _snapshot} ->
          inserted + 1

        {:error, changeset} ->
          resolve_unique_conflict(changeset, attrs, inserted)
      end
    end)
  end

  defp resolve_unique_conflict(changeset, attrs, inserted) do
    if named_unique_conflict?(changeset) do
      case reload_identity(attrs) do
        [snapshot] ->
          if semantic_equal?(persisted_semantics(snapshot), attrs_semantics(attrs)),
            do: inserted,
            else: rollback_conflict()

        _rows ->
          rollback_conflict()
      end
    else
      rollback_conflict()
    end
  end

  defp reload_identity(attrs) do
    model_identifier = String.downcase(attrs.model_identifier)
    price_version = attrs.price_version
    service_tier = attrs.config["service_tier"]
    price_bucket = attrs.config["price_bucket"]

    Repo.all(
      from snapshot in PricingSnapshot,
        where:
          fragment("lower(?)", snapshot.model_identifier) == ^model_identifier and
            snapshot.price_version == ^price_version and
            fragment("COALESCE(?->>'service_tier', '')", snapshot.config) == ^service_tier and
            fragment("COALESCE(?->>'price_bucket', '')", snapshot.config) == ^price_bucket and
            fragment("COALESCE(?->>'importer_format_revision', '')", snapshot.config) ==
              ^@revision
    )
  end

  defp named_unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          to_string(metadata[:constraint_name]) == "pricing_snapshots_version_uq"

      _error ->
        false
    end)
  end

  defp row_attrs(row, effective_at, generated_at_raw, price_version, source_url, captured_at) do
    %{
      model_identifier: row.model_identifier,
      price_version: price_version,
      currency_code: @currency_code,
      billing_unit: @billing_unit,
      input_token_micros: row.input,
      cached_input_token_micros: row.cached_input,
      cache_write_token_micros: row.cache_write,
      output_token_micros: row.output,
      reasoning_token_micros: row.reasoning,
      request_base_micros: row.request_base,
      effective_at: effective_at,
      source_url: source_url,
      captured_at: captured_at,
      config: %{
        "source" => @source,
        "importer_format_revision" => @revision,
        "source_generated_at" => generated_at_raw,
        "source_path" => source_url,
        "service_tier" => row.service_tier,
        "price_bucket" => row.price_bucket,
        "pricing_type" => row.pricing_type,
        "category" => row.category,
        "categories" => row.categories,
        "availability" => row.availability,
        "reasoning_price_source" => row.reasoning_price_source
      }
    }
  end

  defp persisted_semantics(snapshot) do
    %{
      model_identifier: String.downcase(snapshot.model_identifier),
      price_version: snapshot.price_version,
      revision: snapshot.config["importer_format_revision"],
      service_tier: snapshot.config["service_tier"],
      price_bucket: snapshot.config["price_bucket"],
      currency_code: snapshot.currency_code,
      billing_unit: snapshot.billing_unit,
      availability: snapshot.config["availability"],
      input: snapshot.input_token_micros,
      cached_input: snapshot.cached_input_token_micros,
      cache_write: snapshot.cache_write_token_micros,
      output: snapshot.output_token_micros,
      reasoning: snapshot.reasoning_token_micros,
      request_base: snapshot.request_base_micros,
      effective_at: snapshot.effective_at,
      pricing_type: snapshot.config["pricing_type"],
      category: snapshot.config["category"],
      categories: snapshot.config["categories"],
      reasoning_price_source: snapshot.config["reasoning_price_source"]
    }
  end

  defp attrs_semantics(attrs) do
    %{
      model_identifier: String.downcase(attrs.model_identifier),
      price_version: attrs.price_version,
      revision: attrs.config["importer_format_revision"],
      service_tier: attrs.config["service_tier"],
      price_bucket: attrs.config["price_bucket"],
      currency_code: attrs.currency_code,
      billing_unit: attrs.billing_unit,
      availability: attrs.config["availability"],
      input: attrs.input_token_micros,
      cached_input: attrs.cached_input_token_micros,
      cache_write: attrs.cache_write_token_micros,
      output: attrs.output_token_micros,
      reasoning: attrs.reasoning_token_micros,
      request_base: attrs.request_base_micros,
      effective_at: attrs.effective_at,
      pricing_type: attrs.config["pricing_type"],
      category: attrs.config["category"],
      categories: attrs.config["categories"],
      reasoning_price_source: attrs.config["reasoning_price_source"]
    }
  end

  defp semantic_equal?(left, right) do
    decimal_fields = ~w(input cached_input cache_write output reasoning request_base)a

    Enum.all?(Map.keys(left), fn key ->
      if key in decimal_fields do
        decimal_equal?(left[key], right[key])
      else
        left[key] == right[key]
      end
    end)
  end

  defp decimal_equal?(nil, nil), do: true
  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  defp decimal_equal?(_left, _right), do: false

  defp rollback_conflict do
    Repo.rollback(
      error(:concurrent_pricing_conflict, error_message(:concurrent_pricing_conflict))
    )
  end

  defp file_error(reason) do
    error(:file_read_failed, reason |> :file.format_error() |> to_string())
  end

  defp error_message(:conflicting_service_tier_alias),
    do: "fast and priority pricing aliases conflict"

  defp error_message(:concurrent_pricing_conflict),
    do: "concurrent pricing snapshot conflicts with candidate semantics"

  defp error_message(:incompatible_pricing_catalog),
    do: "pricing catalog is incompatible with the supported format"

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
