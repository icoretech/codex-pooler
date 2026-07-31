defmodule CodexPooler.Catalog.OpenAIPricingPreflight do
  @moduledoc """
  Pure, fail-closed compatibility check for `openai-json-pricing` candidates.
  """

  alias CodexPooler.Catalog.OpenAIPricingFormat

  @type issue :: OpenAIPricingFormat.Result.issue()
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
         {:ok, payload} <- OpenAIPricingFormat.decode(raw) do
      validate_payload(payload)
    else
      {:error, :invalid_json} ->
        error_result(:invalid_json, "pricing catalog is not valid JSON", "$")

      {:error, reason} ->
        error_result(:file_read_failed, format_file_error(reason), path)
    end
  end

  def validate_file(_path), do: error_result(:invalid_path, "path must be a string", "$")

  @spec validate_payload(term()) :: result()
  def validate_payload(payload) do
    payload
    |> OpenAIPricingFormat.classify()
    |> Map.take([:compatible?, :errors, :warnings, :summary, :coverage])
  end

  defp error_result(code, message, path) do
    %{
      compatible?: false,
      errors: [%{code: code, message: message, path: path}],
      warnings: [],
      summary: empty_summary(),
      coverage: empty_coverage()
    }
  end

  defp empty_summary do
    %{
      importable_rows: 0,
      priced_rows: 0,
      unavailable_rows: 0,
      skipped_models: 0,
      skipped_price_buckets: 0
    }
  end

  defp empty_coverage do
    %{
      supported_price_buckets: ~w(default short_context long_context),
      imported_price_buckets: %{"default" => 0, "short_context" => 0, "long_context" => 0}
    }
  end

  defp format_file_error(reason), do: reason |> :file.format_error() |> to_string()
end
