defmodule CodexPooler.Repo.Migrations.CreatePoolModelServingOverrides do
  use Ecto.Migration

  def change do
    create table(:pool_model_serving_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all), null: false
      add :exposed_model_id, :text, null: false
      add :mode, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(
             :pool_model_serving_overrides,
             :pool_model_serving_overrides_exposed_model_id_check,
             check:
               "char_length(exposed_model_id) BETWEEN 1 AND 255 AND exposed_model_id = lower(exposed_model_id) AND exposed_model_id !~ '^[[:space:]]|[[:space:]]$'"
           )

    create constraint(
             :pool_model_serving_overrides,
             :pool_model_serving_overrides_mode_check,
             check: "mode = ANY (ARRAY['lite'::text, 'full'::text])"
           )

    create unique_index(:pool_model_serving_overrides, [:pool_id, :exposed_model_id],
             name: :pool_model_serving_overrides_pool_model_uq
           )
  end
end
