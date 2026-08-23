defmodule CodexPooler.Dev.OpenAIV1Fixture.Models do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type provisioned :: %{
          required(:text) => Model.t(),
          required(:audio) => Model.t(),
          required(:image) => Model.t()
        }

  @spec provision!(Pool.t(), PoolUpstreamAssignment.t(), UpstreamIdentity.t()) :: provisioned()
  def provision!(pool, assignment, identity) do
    models = %{
      text: upsert!(pool, assignment, text_attributes(assignment)),
      audio: upsert!(pool, assignment, audio_attributes(assignment)),
      image: upsert!(pool, assignment, image_attributes(assignment))
    }

    ensure_quota_windows!(identity, Map.values(models))
    reset_transcription_route_state!(pool, assignment, models.audio)
    models
  end

  defp upsert!(pool, assignment, attributes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changes = %{
      pool_id: pool.id,
      upstream_model_id: attributes.upstream_model_id,
      exposed_model_id: attributes.exposed_model_id,
      display_name: attributes.display_name,
      status: "active",
      supports_responses: attributes.supports_responses,
      supports_streaming: attributes.supports_streaming,
      supports_tools: attributes.supports_tools,
      supports_reasoning: false,
      source_assignment_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      metadata: Map.put(attributes.metadata, "source_assignment_ids", [assignment.id])
    }

    case Repo.get_by(Model,
           pool_id: pool.id,
           exposed_model_id: attributes.exposed_model_id
         ) do
      %Model{} = model ->
        model
        |> Model.changeset(Map.put(changes, :first_seen_at, model.first_seen_at || now))
        |> Repo.update!()

      nil ->
        %Model{} |> Model.changeset(changes) |> Repo.insert!()
    end
  end

  defp text_attributes(assignment) do
    model_attributes(
      "gpt-5.5",
      "GPT 5.5",
      true,
      true,
      true,
      assignment,
      ["text", "image"]
    )
  end

  defp audio_attributes(assignment) do
    model_attributes(
      "gpt-4o-transcribe",
      "GPT-4o Transcribe",
      false,
      false,
      false,
      assignment,
      ["audio"]
    )
  end

  defp image_attributes(assignment) do
    model_attributes(
      "gpt-image-1",
      "GPT Image 1",
      true,
      true,
      true,
      assignment,
      ["text", "image"]
    )
  end

  defp model_attributes(id, display_name, responses?, streaming?, tools?, assignment, modalities) do
    %{
      exposed_model_id: id,
      upstream_model_id: "provider-#{id}",
      display_name: display_name,
      supports_responses: responses?,
      supports_streaming: streaming?,
      supports_tools: tools?,
      metadata: %{
        "manual_smoke_provisioned" => true,
        "source_assignment_models" => %{
          assignment.id => %{
            "slug" => id,
            "input_modalities" => modalities,
            "supports_tools" => tools?
          }
        },
        "input_modalities" => modalities
      }
    }
  end

  defp ensure_quota_windows!(identity, models) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    model_windows = Enum.flat_map(models, &quota_windows(&1, now))

    {:ok, _windows} =
      Windows.upsert_quota_windows(identity, account_windows(now) ++ model_windows)
  end

  defp quota_windows(model, now) do
    Enum.map(["primary", "secondary"], fn kind ->
      quota_window(kind, now, %{
        quota_key: model.exposed_model_id,
        quota_scope: "model",
        quota_family: "codex_model",
        model: model.exposed_model_id,
        upstream_model: model.upstream_model_id
      })
    end)
  end

  defp account_windows(now) do
    Enum.map(["primary", "secondary"], fn kind ->
      quota_window(kind, now, %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account"
      })
    end)
  end

  defp quota_window(kind, now, attributes) do
    primary? = kind == "primary"

    Map.merge(attributes, %{
      window_kind: kind,
      window_minutes: if(primary?, do: 300, else: 10_080),
      active_limit: if(primary?, do: 120, else: 1_200),
      credits: if(primary?, do: 108, else: 1_050),
      reset_at: DateTime.add(now, if(primary?, do: 900, else: 604_800), :second),
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: now,
      observed_at: now,
      merge_precedence: 70,
      metadata: %{}
    })
  end

  defp reset_transcription_route_state!(pool, assignment, model) do
    Repo.delete_all(
      from state in RoutingCircuitState,
        where:
          state.pool_id == ^pool.id and state.pool_upstream_assignment_id == ^assignment.id and
            state.model_identifier == ^model.exposed_model_id and
            state.route_class == "audio_transcription"
    )

    Repo.delete_all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^pool.id and
            demotion.pool_upstream_assignment_id == ^assignment.id and
            demotion.model_identifier == ^model.exposed_model_id
    )
  end
end
