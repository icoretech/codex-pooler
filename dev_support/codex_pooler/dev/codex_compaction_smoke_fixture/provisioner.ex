defmodule CodexPooler.Dev.CodexCompactionSmokeFixture.Provisioner do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.{Access, Accounts, Catalog, Pools, Repo, Upstreams}
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.CodexCompactionSmokeFixture.Journal
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, BridgeSessionAlias, CodexSession}
  alias CodexPooler.Pools.{ModelServingOverride, Pool}
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @model "gpt-6-sol"

  # The served catalog entry is this source map verbatim, so it carries every
  # field Codex's `ModelInfo` (codex-rs/protocol/src/openai_models.rs at
  # rust-v0.156.0) decodes without a serde default, reasoning levels as
  # `{effort, description}` presets, and the instructions the catalog decoder
  # requires (`base_instructions` or `model_messages.instructions_template`).
  # One undecodable entry makes Codex discard the whole catalog and keep its
  # bundled one.
  @base_instructions "You are Codex, a coding agent. Synthetic instructions of the Codex Pooler compaction smoke fixture."

  @type provisioned :: %{
          pool: Pool.t(),
          identity: UpstreamIdentity.t(),
          assignment: PoolUpstreamAssignment.t(),
          model: Model.t(),
          api_key: APIKey.t(),
          raw_key: String.t()
        }

  @spec provision!(String.t(), String.t(), map(), (map() -> map()), keyword()) :: provisioned()
  def provision!(run_id, upstream_base_url, journal, persist_journal, options \\ []) do
    scope = owner_scope!()
    interrupt_after = Keyword.get(options, :interrupt_after)
    serving_mode = serving_mode(Keyword.get(options, :serving_mode))

    {:ok, provisioned} =
      Repo.transact(fn ->
        pool = create_pool!(scope, run_id)
        journal = journal |> Journal.put_resource(:pool, pool.id) |> persist_journal.()
        maybe_interrupt!(interrupt_after, :pool)

        identity = create_identity!(run_id, upstream_base_url)
        journal = journal |> Journal.put_resource(:identity, identity.id) |> persist_journal.()
        maybe_interrupt!(interrupt_after, :identity)

        assignment = create_assignment!(pool, identity)

        journal =
          journal |> Journal.put_resource(:assignment, assignment.id) |> persist_journal.()

        maybe_interrupt!(interrupt_after, :assignment)

        model = create_model!(pool, assignment, serving_mode)
        journal = journal |> Journal.put_resource(:model, model.id) |> persist_journal.()
        create_quota_windows!(identity, model)
        maybe_interrupt!(interrupt_after, :model)

        %{api_key: api_key, raw_key: raw_key} = create_api_key!(scope, pool, run_id)
        journal = journal |> Journal.put_resource(:api_key, api_key.id) |> persist_journal.()
        maybe_interrupt!(interrupt_after, :api_key)

        {:ok,
         %{
           pool: pool,
           identity: identity,
           assignment: assignment,
           model: model,
           api_key: api_key,
           raw_key: raw_key,
           journal: journal
         }}
      end)

    provisioned
  end

  @doc """
  Writes (`full`, `lite`) or clears (`auto`) the run model's serving override
  through the product write path and returns the written row id, or `nil` once
  cleared.
  """
  @spec set_serving_override!(map(), String.t()) :: String.t() | nil
  def set_serving_override!(%{"pool_id" => pool_id}, mode)
      when is_binary(pool_id) and mode in ["full", "lite", "auto"] do
    scope = owner_scope!()
    {:ok, %{overrides: overrides}} = update_serving_mode(scope, pool_id, @model, mode)

    case {mode, Enum.find(overrides, &(&1.exposed_model_id == @model))} do
      {"auto", nil} -> nil
      {mode, %ModelServingOverride{id: id, mode: mode}} when mode != "auto" -> id
      _unexpected -> raise "serving override was not written as requested"
    end
  end

  @spec cleanup!(map()) :: :ok
  def cleanup!(journal) do
    scope = owner_scope!()
    pool_id = journal["pool_id"]

    drop_serving_override(scope, pool_id, Map.get(journal, "serving_override_id"))
    revoke_key(scope, Map.get(journal, "api_key_id"))
    retire_model(journal["model_id"])
    delete_assignment(pool_id, journal["assignment_id"])
    archive_pool(scope, pool_id)
    expire_continuity(pool_id)
    disable_identity(journal["identity_id"])
    :ok
  end

  @spec model() :: String.t()
  def model, do: @model

  @spec serving_mode(term()) :: :full | :lite
  def serving_mode(value) when value in [:full, "full"], do: :full
  def serving_mode(value) when value in [:lite, "lite"], do: :lite
  def serving_mode(nil), do: :lite

  defp owner_scope! do
    Accounts.list_operators()
    |> Enum.find_value(fn user ->
      scope = Scope.for_user(user, Accounts.roles_for_user(user))
      if Pools.can_manage_pools?(scope), do: scope
    end)
    |> Kernel.||(raise "fixture requires a bootstrapped instance owner")
  end

  defp maybe_interrupt!(stage, stage), do: raise("fixture interrupted after #{stage}")
  defp maybe_interrupt!(_configured, _stage), do: :ok

  defp create_pool!(scope, run_id) do
    {:ok, pool} =
      Pools.create_pool(
        scope,
        %{slug: "codex-compact-#{run_id}", name: "Codex compaction smoke", status: "active"},
        broadcast?: false
      )

    pool
  end

  defp create_identity!(run_id, upstream_base_url) do
    {:ok, identity} =
      IdentityLifecycle.create_upstream_identity(%{
        chatgpt_account_id: "codex-compaction-smoke-#{run_id}",
        account_label: "Codex compaction smoke",
        onboarding_method: "import",
        metadata: %{"base_url" => upstream_base_url, "fixture_run_id" => run_id}
      })

    {:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)

    {:ok, _secret} =
      Upstreams.store_encrypted_secret(identity, %{
        secret_kind: "access_token",
        plaintext: "codex-compaction-upstream-#{run_id}"
      })

    identity
  end

  defp create_assignment!(pool, identity) do
    {:ok, assignment} =
      PoolAssignments.create_pool_assignment(pool, identity, %{
        assignment_label: "Codex compaction smoke",
        metadata: %{"fixture_run_id" => pool.slug}
      })

    {:ok, assignment} =
      PoolAssignments.activate_pool_assignment(assignment, %{skip_quota_priming: true})

    assignment
  end

  defp create_model!(pool, assignment, serving_mode) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    use_responses_lite = serving_mode == :lite

    %Model{}
    |> Model.changeset(%{
      pool_id: pool.id,
      upstream_model_id: @model,
      exposed_model_id: @model,
      display_name: "GPT Smoke",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      source_assignment_count: 1,
      first_seen_at: now,
      last_seen_at: now,
      metadata: %{
        "source_assignment_ids" => [assignment.id],
        "source_assignment_models" => %{
          assignment.id => %{
            "slug" => @model,
            "display_name" => "GPT Smoke",
            "description" => "Codex compaction smoke fixture model",
            "shell_type" => "shell_command",
            "visibility" => "list",
            "supported_in_api" => true,
            "priority" => 0,
            "support_verbosity" => false,
            "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
            "experimental_supported_tools" => [],
            "base_instructions" => @base_instructions,
            "supports_responses" => true,
            "supports_streaming" => true,
            "supports_tools" => true,
            "supports_reasoning" => true,
            "prefer_websockets" => true,
            "capabilities" => %{
              "responses" => true,
              "streaming" => true,
              "tools" => true,
              "reasoning" => true
            },
            "use_responses_lite" => use_responses_lite,
            "input_modalities" => ["text", "image"],
            "supports_image_detail_original" => true,
            "supported_reasoning_levels" => [%{"effort" => "low", "description" => "Low reasoning effort"}],
            "default_reasoning_level" => "low",
            "context_window" => 128_000,
            "auto_compact_token_limit" => 200
          }
        }
      }
    })
    |> Repo.insert!()
  end

  defp create_api_key!(scope, pool, run_id) do
    {:ok, result} =
      Access.create_api_key(scope, pool, %{display_name: "Codex compaction #{run_id}"})

    result
  end

  defp create_quota_windows!(identity, model) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    windows =
      for quota <- [
            %{key: "account", scope: "account", family: "account", model: nil},
            %{
              key: model.exposed_model_id,
              scope: "model",
              family: "codex_model",
              model: model.exposed_model_id
            }
          ],
          kind <- ["primary", "secondary"] do
        %{
          quota_key: quota.key,
          quota_scope: quota.scope,
          quota_family: quota.family,
          model: quota.model,
          upstream_model: if(quota.model, do: model.upstream_model_id),
          window_kind: kind,
          window_minutes: if(kind == "primary", do: 300, else: 10_080),
          active_limit: 1_000,
          credits: 900,
          reset_at: DateTime.add(now, 604_800, :second),
          source: "codex_response_headers",
          source_precision: "observed",
          freshness_state: "fresh",
          last_sync_at: now,
          observed_at: now,
          merge_precedence: 70,
          metadata: %{}
        }
      end

    {:ok, _windows} = Windows.upsert_quota_windows(identity, windows)
  end

  defp update_serving_mode(scope, pool_id, model, mode) do
    {:ok, %{revision: revision}} = Pools.model_serving_modes_snapshot(scope, pool_id)
    Pools.update_model_serving_modes(scope, pool_id, [%{exposed_model_id: model, mode: mode}], revision)
  end

  # Drops exactly the journalled row, through the product, and only while it
  # still belongs to the run Pool. Any other override row is left in place, so
  # the release postcondition reports it instead of hiding it.
  defp drop_serving_override(_scope, _pool_id, nil), do: :ok

  defp drop_serving_override(scope, pool_id, override_id) do
    case Repo.get(ModelServingOverride, override_id) do
      nil ->
        :ok

      %ModelServingOverride{pool_id: ^pool_id, exposed_model_id: model} ->
        {:ok, %{overrides: overrides}} = update_serving_mode(scope, pool_id, model, "auto")
        if Enum.any?(overrides, &(&1.id == override_id)), do: raise("serving override was not dropped")
        :ok

      %ModelServingOverride{} ->
        raise "journalled serving override is not run-owned"
    end
  end

  defp revoke_key(_scope, nil), do: :ok

  defp revoke_key(scope, key_id) do
    case Repo.get(APIKey, key_id) do
      nil -> :ok
      %APIKey{status: "revoked"} -> :ok
      %APIKey{} -> {:ok, _key} = Access.revoke_api_key(scope, key_id)
    end
  end

  defp retire_model(nil), do: :ok

  defp retire_model(model_id) do
    case Repo.get(Model, model_id) do
      nil -> :ok
      %Model{status: "retired"} -> :ok
      %Model{} = model -> {:ok, _model} = Catalog.retire_model(model)
    end
  end

  defp delete_assignment(_pool_id, nil), do: :ok

  defp delete_assignment(pool_id, assignment_id) do
    case Repo.get(PoolUpstreamAssignment, assignment_id) do
      nil ->
        :ok

      %PoolUpstreamAssignment{status: "deleted"} ->
        :ok

      %PoolUpstreamAssignment{} ->
        {:ok, _result} = PoolAssignments.delete_pool_assignment(pool_id, assignment_id)
    end
  end

  defp archive_pool(_scope, nil), do: :ok

  defp archive_pool(scope, pool_id) do
    case Pools.get_pool(pool_id) do
      nil -> :ok
      %Pool{status: "archived"} -> :ok
      %Pool{} = pool -> {:ok, _pool} = Pools.change_pool_status(scope, pool, "archived")
    end
  end

  defp disable_identity(nil), do: :ok

  defp disable_identity(identity_id) do
    Repo.delete_all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity_id)

    case Repo.get(UpstreamIdentity, identity_id) do
      nil ->
        :ok

      %UpstreamIdentity{status: "disabled"} ->
        :ok

      %UpstreamIdentity{} = identity ->
        {:ok, _identity} = IdentityLifecycle.disable_upstream_identity(identity)
    end
  end

  defp expire_continuity(nil), do: :ok

  defp expire_continuity(pool_id) do
    session_ids =
      Repo.all(from session in CodexSession, where: session.pool_id == ^pool_id, select: session.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(lease in BridgeOwnerLease,
        where: lease.codex_session_id in ^session_ids and lease.status == "active"
      ),
      set: [status: "expired", released_at: now, updated_at: now]
    )

    Repo.update_all(
      from(alias_record in BridgeSessionAlias,
        where: alias_record.codex_session_id in ^session_ids and alias_record.status == "active"
      ),
      set: [status: "expired", updated_at: now]
    )

    Repo.update_all(
      from(session in CodexSession,
        where: session.pool_id == ^pool_id and session.status == "active"
      ),
      set: [status: "closed", closed_at: now, updated_at: now]
    )

    :ok
  end
end
