defmodule CodexPooler.AccountingTestSupport do
  @moduledoc false

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  def accounting_setup(pricing_attrs \\ %{}) do
    %{pool: pool, api_key: api_key} =
      key =
      active_api_key_fixture(pool_fixture(), %{
        default_policy: %{max_tokens_per_day: 10_000, max_requests_per_minute: 60}
      })

    ensure_default_policy!(api_key)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-accounting-mini",
        upstream_model_id: "provider-gpt-accounting-mini",
        pricing_ref: "provider-gpt-accounting-mini"
      })

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: Map.get(pricing_attrs, :account_label, "Primary upstream"),
        account_email: Map.get(pricing_attrs, :account_email),
        plan_label: Map.get(pricing_attrs, :plan_label),
        plan_family: Map.get(pricing_attrs, :plan_family)
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    pricing =
      %PricingSnapshot{
        model_identifier: "provider-gpt-accounting-mini",
        price_version: "test-v1",
        currency_code: "USD",
        billing_unit: "token",
        input_token_micros: Map.get(pricing_attrs, :input_token_micros, Decimal.new(10)),
        cached_input_token_micros:
          Map.get(pricing_attrs, :cached_input_token_micros, Decimal.new(1)),
        output_token_micros: Map.get(pricing_attrs, :output_token_micros, Decimal.new(20)),
        reasoning_token_micros: Map.get(pricing_attrs, :reasoning_token_micros, Decimal.new(30)),
        request_base_micros: Map.get(pricing_attrs, :request_base_micros, Decimal.new(0)),
        effective_at: DateTime.add(now, -60, :second),
        captured_at: now,
        config: pricing_config(Map.get(pricing_attrs, :config, %{}))
      }
      |> Repo.insert!()

    Map.merge(key, %{
      auth: %{pool: pool, api_key: api_key, key_prefix: api_key.key_prefix},
      model: model,
      identity: identity,
      assignment: assignment,
      pricing: pricing
    })
  end

  def pricing_snapshot_fixture(%PricingSnapshot{} = base, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: Map.get(attrs, :model_identifier, base.model_identifier),
      price_version: Map.get(attrs, :price_version, "test-#{System.unique_integer([:positive])}"),
      currency_code: Map.get(attrs, :currency_code, base.currency_code),
      billing_unit: Map.get(attrs, :billing_unit, base.billing_unit),
      input_token_micros: Map.get(attrs, :input_token_micros, base.input_token_micros),
      cached_input_token_micros:
        Map.get(attrs, :cached_input_token_micros, base.cached_input_token_micros),
      output_token_micros: Map.get(attrs, :output_token_micros, base.output_token_micros),
      reasoning_token_micros:
        Map.get(attrs, :reasoning_token_micros, base.reasoning_token_micros),
      request_base_micros: Map.get(attrs, :request_base_micros, base.request_base_micros),
      effective_at: Map.get(attrs, :effective_at, DateTime.add(now, -60, :second)),
      captured_at: Map.get(attrs, :captured_at, now),
      config: Map.get(attrs, :config, base.config)
    }
    |> Repo.insert!()
  end

  def write_tmp_pricing_json!(generated_at, model_identifier, prices) do
    path =
      Path.join(
        System.tmp_dir!(),
        "accounting-pricing-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "generated_at" => DateTime.to_iso8601(generated_at),
        "models" => %{
          model_identifier => %{
            "model" => model_identifier,
            "pricing_type" => "per_1m_tokens",
            "prices" => %{
              "standard" => %{
                "default" => prices
              }
            }
          }
        }
      })
    )

    path
  end

  def pricing_config(overrides) do
    Map.merge(
      %{
        "service_tier" => "standard",
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens"
      },
      overrides
    )
  end

  defp ensure_default_policy!(api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.one(
           from b in APIKeyPolicyBinding,
             where: b.api_key_id == ^api_key.id and b.binding_scope == "default",
             limit: 1
         ) do
      %APIKeyPolicyBinding{} = binding ->
        binding
        |> Ecto.Changeset.change(%{
          max_tokens_per_day: 10_000,
          max_requests_per_minute: 60,
          updated_at: now
        })
        |> Repo.update!()

      nil ->
        %APIKeyPolicyBinding{
          api_key_id: api_key.id,
          binding_scope: "default",
          status: "active",
          max_tokens_per_day: 10_000,
          max_requests_per_minute: 60,
          created_at: now,
          updated_at: now
        }
        |> Repo.insert!()
    end
  end

  def update_default_policy!(api_key, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    APIKeyPolicyBinding
    |> Repo.get_by!(api_key_id: api_key.id, binding_scope: "default", status: "active")
    |> Ecto.Changeset.change(Map.merge(attrs, %{updated_at: now}))
    |> Repo.update!()
  end
end
