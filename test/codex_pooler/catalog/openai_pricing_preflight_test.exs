defmodule CodexPooler.Catalog.OpenAIPricingPreflightTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.OpenAIPricingPreflight

  test "reports complete import coverage for supported price buckets without side effects" do
    payload = %{
      "generated_at" => "2026-07-11T12:34:56Z",
      "models" => %{
        "gpt-example" => %{
          "model" => "gpt-example",
          "pricing_type" => "per_1m_tokens",
          "prices" => %{
            "standard" => %{
              "default" => %{"input" => 1, "output" => 2},
              "short_context" => %{"input" => "0.5", "cached_input" => 0.1, "output" => 1},
              "long_context" => %{"available" => false}
            }
          }
        }
      }
    }

    assert %{
             compatible?: true,
             errors: [],
             summary: %{
               importable_rows: 3,
               priced_rows: 2,
               unavailable_rows: 1,
               skipped_models: 0,
               skipped_price_buckets: 0
             },
             coverage: %{
               supported_price_buckets: ["default", "short_context", "long_context"],
               imported_price_buckets: %{
                 "default" => 1,
                 "long_context" => 1,
                 "short_context" => 1
               }
             }
           } = OpenAIPricingPreflight.validate_payload(payload)
  end

  test "fails closed for an unknown price bucket that the importer would silently omit" do
    payload = valid_payload(%{"experimental_context" => %{"input" => 1, "output" => 2}})

    result = OpenAIPricingPreflight.validate_payload(payload)

    refute result.compatible?

    assert %{
             code: :unknown_price_bucket,
             path: "models.gpt-example.prices.standard.experimental_context"
           } =
             Enum.find(result.errors, &(&1.code == :unknown_price_bucket))

    assert result.summary.importable_rows == 1
    assert result.summary.skipped_price_buckets == 1
  end

  test "fails closed for unknown pricing fields that are not represented by snapshots" do
    payload = valid_payload(%{"default" => %{"input" => 1, "output" => 2, "cache_write" => 3}})

    result = OpenAIPricingPreflight.validate_payload(payload)

    refute result.compatible?

    assert %{
             code: :unknown_price_field,
             path: "models.gpt-example.prices.standard.default.cache_write"
           } =
             Enum.find(result.errors, &(&1.code == :unknown_price_field))
  end

  test "returns a controlled invalid_json error without loading application services" do
    path =
      Path.join(System.tmp_dir!(), "pricing-preflight-#{System.unique_integer([:positive])}.json")

    File.write!(path, "{bad json")

    assert %{compatible?: false, errors: [%{code: :invalid_json}]} =
             OpenAIPricingPreflight.validate_file(path)
  end

  test "returns a controlled file_read_failed error for a missing file" do
    path =
      Path.join(System.tmp_dir!(), "missing-pricing-#{System.unique_integer([:positive])}.json")

    assert %{
             compatible?: false,
             errors: [%{code: :file_read_failed, message: message, path: ^path}]
           } = OpenAIPricingPreflight.validate_file(path)

    assert message == :enoent |> :file.format_error() |> to_string()
  end

  defp valid_payload(extra_buckets) do
    %{
      "generated_at" => "2026-07-11T12:34:56Z",
      "models" => %{
        "gpt-example" => %{
          "model" => "gpt-example",
          "pricing_type" => "per_1m_tokens",
          "prices" => %{
            "standard" => Map.merge(%{"default" => %{"input" => 1, "output" => 2}}, extra_buckets)
          }
        }
      }
    }
  end
end
