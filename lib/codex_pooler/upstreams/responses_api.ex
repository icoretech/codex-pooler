defmodule CodexPooler.Upstreams.ResponsesAPI do
  @moduledoc """
  Explicit API-key upstreams for stateless OpenAI Responses-compatible providers.

  API credentials are separate from Codex OAuth provenance. These providers have
  no Codex weekly quota, saved resets or OAuth refresh flow. Provider responses
  remain authoritative for billing, rate limits and credential rejection.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.Sync
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Lifecycle.AccountAudit
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @provenance "responses_api_key"
  @model_fields ~w(id display_name context_window effective_context_window_percent max_output_tokens supports_streaming supports_tools supports_reasoning supports_parallel_tool_calls supported_reasoning_levels default_reasoning_level input_modalities supports_image_detail_original)a

  @doc "Import a verified API credential and its explicitly configured model capabilities."
  def import_account(%Scope{} = scope, %Pool{} = pool, attrs) when is_map(attrs) do
    with {:ok, _decision} <-
           Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool.id),
         {:ok, config} <- validate(attrs),
         {:ok, advertised} <- fetch_catalog(config.base_url, config.api_key),
         true <- Enum.all?(config.models, &Enum.any?(advertised, fn m -> m["id"] == &1["id"] end)) do
      persist_account(scope, pool, config)
    else
      false ->
        {:error,
         error(:model_not_available, "configured model is not advertised by the provider")}

      {:error, _reason} = error ->
        error
    end
  end

  def import_account(_scope, _pool, _attrs),
    do: {:error, error(:invalid_request, "API upstream requires an operator and Pool")}

  defp persist_account(scope, pool, config) do
    Repo.transaction(fn ->
      identity = create_identity!(scope, config)
      store_key!(identity, config.api_key)
      assignment = create_assignment!(scope, pool, identity)

      result = %{
        identity: identity,
        assignment: assignment,
        status: :created,
        secret_status: :stored
      }

      case AccountAudit.record_change_strict({:ok, result}, scope, "upstream_account.import_api") do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finish_import(pool)
  end

  defp create_identity!(scope, config) do
    now = DateTime.utc_now()

    %UpstreamIdentity{}
    |> UpstreamIdentity.changeset(%{
      account_label: config.label,
      onboarding_method: "import",
      status: "active",
      plan_family: "api",
      plan_label: "API",
      headers_profile_version: 1,
      auth_verified_at: now,
      auth_fresh_at: now,
      created_by_user_id: scope.user.id,
      created_at: now,
      updated_at: now,
      metadata: %{
        "credential_epoch" => 1,
        "base_url" => config.base_url,
        "api_models" => config.models
      }
    })
    |> Ecto.Changeset.put_change(:credential_provenance, @provenance)
    |> Repo.insert!()
  end

  defp store_key!(identity, key) do
    case Secrets.store_encrypted_secret(identity, %{secret_kind: "access_token", plaintext: key}) do
      {:ok, _secret} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_assignment!(scope, pool, identity) do
    case PoolAssignments.create_pool_assignment(pool, identity, %{
           status: "active",
           health_status: "active",
           created_by_user_id: scope.user.id
         }) do
      {:ok, assignment} -> assignment
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finish_import({:ok, result}, pool) do
    Events.broadcast_upstreams(pool.id, "responses_api_imported", %{
      upstream_identity_id: result.identity.id
    })

    case Sync.sync_pool_catalog(pool) do
      {:ok, _catalog} -> {:ok, result}
      _failure -> {:ok, Map.put(result, :catalog_sync_pending, true)}
    end
  end

  defp finish_import({:error, _reason} = error, _pool), do: error

  defp validate(attrs) do
    base_url = attrs[:base_url] || attrs["base_url"]
    api_key = attrs[:api_key] || attrs["api_key"]
    label = attrs[:label] || attrs["label"]
    models = attrs[:models] || attrs["models"]

    with true <- valid_url?(base_url),
         true <- valid_key?(api_key),
         true <- valid_label?(label),
         true <- valid_models?(models) do
      configured =
        Enum.map(models, fn model ->
          fields = Map.take(model, Enum.map(@model_fields, &Atom.to_string/1))

          Map.merge(fields, %{
            "slug" => model["id"],
            "display_name" => model["display_name"] || model["id"],
            "description" => model["display_name"] || model["id"],
            "shell_type" => "shell_command",
            "visibility" => "list",
            "priority" => 0,
            "base_instructions" => "",
            "default_reasoning_summary" => "none",
            "support_verbosity" => false,
            "default_verbosity" => nil,
            "apply_patch_tool_type" => "freeform",
            "web_search_tool_type" => "text",
            "supports_search_tool" => false,
            "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
            "supports_responses" => true,
            "prefer_websockets" => false,
            "pricing_ref" => "responses_api/" <> model["id"],
            "supports_compact_responses" => true
          })
        end)

      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         api_key: String.trim(api_key),
         label: String.trim(label),
         models: configured
       }}
    else
      _invalid ->
        {:error,
         error(
           :invalid_request,
           "API upstream requires a base URL, key, label and model capabilities"
         )}
    end
  end

  defp valid_key?(key) when is_binary(key),
    do: Regex.match?(~r/\A[\x21-\x7e]{1,8192}\z/, String.trim(key))

  defp valid_key?(_key), do: false

  defp valid_label?(label) when is_binary(label), do: byte_size(String.trim(label)) in 1..120
  defp valid_label?(_label), do: false

  defp valid_models?(models) when is_list(models),
    do: length(models) in 1..100 and Enum.all?(models, &valid_model?/1)

  defp valid_models?(_models), do: false

  defp valid_model?(%{"id" => id, "context_window" => context})
       when is_binary(id) and is_integer(context),
       do:
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, id) and
           context in 1024..10_000_000

  defp valid_model?(_model), do: false

  defp valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])

      _invalid ->
        false
    end
  end

  defp valid_url?(_url), do: false

  def fetch_models(%{identity: identity, assignment: assignment}) do
    with {:ok, token} <- Secrets.decrypt_active_secret(identity, "access_token"),
         {:ok, advertised} <-
           fetch_catalog(EndpointMetadata.base_url(identity, assignment), token) do
      ids = MapSet.new(advertised, & &1["id"])
      {:ok, Enum.filter(identity.metadata["api_models"] || [], &MapSet.member?(ids, &1["id"]))}
    end
  end

  defp fetch_catalog(base_url, token) do
    case Req.get(String.trim_trailing(base_url, "/") <> "/models",
           headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
           retry: false,
           redirect: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        if Enum.all?(models, &(is_map(&1) and is_binary(&1["id"]))),
          do: {:ok, models},
          else:
            {:error, error(:invalid_model_catalog, "provider returned an invalid model catalog")}

      {:ok, %{status: status}} ->
        {:error, error(:api_provider_rejected, "provider model catalog returned HTTP #{status}")}

      {:error, _reason} ->
        {:error, error(:api_provider_unavailable, "provider model catalog could not be reached")}
    end
  end

  def reconcile(%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity) do
    result = fetch_models(%{identity: identity, assignment: assignment})

    Repo.transaction(fn ->
      current =
        Repo.one(from u in UpstreamIdentity, where: u.id == ^identity.id, lock: "FOR UPDATE")

      if current.status != "active" or
           current.metadata["credential_epoch"] != identity.metadata["credential_epoch"],
         do:
           Repo.rollback(
             error(:credential_superseded, "API credential changed during verification")
           )

      case result do
        {:ok, _models} ->
          updated =
            current
            |> Ecto.Changeset.change(
              auth_verified_at: DateTime.utc_now(),
              auth_fresh_at: DateTime.utc_now()
            )
            |> Repo.update!()

          %{identity: updated, assignment: assignment, status: :verified}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def endpoint("/backend-api/codex/responses"), do: {:ok, "/responses"}
  def endpoint("/backend-api/codex/responses/compact"), do: {:ok, "/responses"}
  def endpoint("/backend-api/codex/v1/responses"), do: {:ok, "/responses"}
  def endpoint("/v1/responses"), do: {:ok, "/responses"}
  def endpoint(_endpoint), do: {:error, :unsupported_api_upstream_endpoint}

  defp error(code, message), do: %{code: code, message: message}
end
