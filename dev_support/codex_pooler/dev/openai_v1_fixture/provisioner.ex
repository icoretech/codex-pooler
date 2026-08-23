defmodule CodexPooler.Dev.OpenAIV1Fixture.Provisioner do
  @moduledoc false

  alias CodexPooler.{Access, Accounts, Pools, Repo, Upstreams}
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Dev.OpenAIV1Fixture.Models
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @pool_slug "openai-v1-smoke"
  @account_id "openai-v1-smoke"

  @type result :: %{
          required(:api_key) => String.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:identity_id) => Ecto.UUID.t(),
          required(:identity_created?) => boolean(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_created?) => boolean(),
          required(:pool_slug) => String.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          required(:assignment_created?) => boolean(),
          required(:text_model) => String.t(),
          required(:audio_model) => String.t(),
          required(:image_model) => String.t()
        }

  @spec provision!(String.t()) :: result()
  def provision!(upstream_base_url) do
    scope = operator_scope!()
    {identity, identity_created?} = ensure_identity!(upstream_base_url)
    {pool, pool_created?} = ensure_pool!(scope)
    ensure_active_pool!(pool)
    ensure_routing_settings!(pool)
    {assignment, assignment_created?} = ensure_assignment!(pool, identity)
    ensure_active_assignment!(assignment)
    models = Models.provision!(pool, assignment, identity)
    {raw_key, api_key_id} = create_api_key!(scope, pool)

    %{
      api_key: raw_key,
      api_key_id: api_key_id,
      identity_id: identity.id,
      identity_created?: identity_created?,
      pool_id: pool.id,
      pool_created?: pool_created?,
      pool_slug: pool.slug,
      assignment_id: assignment.id,
      assignment_created?: assignment_created?,
      text_model: models.text.exposed_model_id,
      audio_model: models.audio.exposed_model_id,
      image_model: models.image.exposed_model_id
    }
  end

  defp operator_scope! do
    Accounts.list_operators()
    |> Enum.find_value(fn user ->
      scope = Scope.for_user(user, Accounts.roles_for_user(user))
      if Pools.can_manage_pools?(scope), do: scope
    end)
    |> Kernel.||(
      raise "OpenAI V1 fixture requires a bootstrapped local operator with pool access"
    )
  end

  defp ensure_identity!(upstream_base_url) do
    attributes = %{
      chatgpt_account_id: @account_id,
      account_label: "OpenAI V1 Smoke Upstream",
      onboarding_method: "import",
      metadata: %{"base_url" => upstream_base_url}
    }

    {identity, created?} = find_or_create_identity!(attributes)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        status: "active",
        auth_verified_at: now,
        auth_fresh_at: now,
        disabled_at: nil,
        metadata: attributes.metadata
      })
      |> Repo.update!()

    unless active_access_token?(identity) do
      {:ok, _secret} =
        Upstreams.store_encrypted_secret(identity, %{
          secret_kind: "access_token",
          plaintext: "openai-v1-smoke-upstream-token"
        })
    end

    {identity, created?}
  end

  defp find_or_create_identity!(attributes) do
    case IdentityLifecycle.create_upstream_identity(attributes) do
      {:ok, identity} ->
        {identity, true}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :chatgpt_account_id) do
          case Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id) do
            %UpstreamIdentity{} = identity -> {identity, false}
            nil -> raise "OpenAI V1 fixture identity was not persisted"
          end
        else
          raise "failed to create OpenAI V1 fixture identity"
        end

      {:error, _reason} ->
        raise "failed to create OpenAI V1 fixture identity"
    end
  end

  defp ensure_pool!(scope) do
    case Repo.get_by(Pool, slug: @pool_slug) do
      %Pool{} = pool ->
        {pool, false}

      nil ->
        case Pools.create_pool(scope, %{
               "slug" => @pool_slug,
               "name" => "OpenAI V1 Smoke",
               "status" => "active"
             }) do
          {:ok, pool} -> {pool, true}
          {:error, %Ecto.Changeset{}} -> find_existing_pool!()
          {:error, _reason} -> raise "failed to create OpenAI V1 fixture pool"
        end
    end
  end

  defp find_existing_pool! do
    case Repo.get_by(Pool, slug: @pool_slug) do
      %Pool{} = pool -> {pool, false}
      nil -> raise "failed to create OpenAI V1 fixture pool"
    end
  end

  defp ensure_active_pool!(pool) do
    pool |> Pool.changeset(%{status: "active", disabled_at: nil}) |> Repo.update!()
  end

  defp ensure_routing_settings!(pool) do
    settings = Pools.get_routing_settings(pool) || Pools.ensure_routing_settings(pool)

    settings
    |> RoutingSettings.changeset(%{
      routing_strategy: "bridge_ring",
      bridge_ring_size: 3,
      sticky_websocket_sessions: true,
      sticky_http_sessions: false,
      v1_compatibility_enabled: true,
      prompt_cache_affinity_enabled: settings.prompt_cache_affinity_enabled,
      request_compression_enabled: settings.request_compression_enabled,
      allow_image_generation: true,
      metadata: settings.metadata || %{},
      created_at: settings.created_at,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp ensure_assignment!(pool, identity) do
    case Repo.get_by(PoolUpstreamAssignment,
           pool_id: pool.id,
           upstream_identity_id: identity.id
         ) do
      %PoolUpstreamAssignment{} = assignment ->
        {assignment, false}

      nil ->
        case PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "OpenAI V1 Smoke",
               metadata: %{}
             }) do
          {:ok, assignment} -> {assignment, true}
          {:error, %Ecto.Changeset{}} -> find_existing_assignment!(pool, identity)
          {:error, _reason} -> raise "failed to create OpenAI V1 fixture assignment"
        end
    end
  end

  defp find_existing_assignment!(pool, identity) do
    case Repo.get_by(PoolUpstreamAssignment,
           pool_id: pool.id,
           upstream_identity_id: identity.id
         ) do
      %PoolUpstreamAssignment{} = assignment -> {assignment, false}
      nil -> raise "failed to create OpenAI V1 fixture assignment"
    end
  end

  defp ensure_active_assignment!(assignment) do
    assignment
    |> PoolUpstreamAssignment.changeset(%{
      status: "active",
      health_status: "active",
      eligibility_status: "eligible",
      disabled_at: nil
    })
    |> Repo.update!()
  end

  defp create_api_key!(scope, pool) do
    {:ok, %{api_key: %APIKey{id: id}, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "OpenAI V1 Smoke #{System.system_time(:second)}"
      })

    {raw_key, id}
  end

  defp active_access_token?(identity) do
    match?({:ok, _token}, Upstreams.Secrets.decrypt_active_secret(identity, "access_token"))
  end
end
