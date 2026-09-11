defmodule CodexPooler.Accounting.WebsocketOwnerBinding do
  @moduledoc false
  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Metadata, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @spec bind(CodexPooler.Access.auth_context(), Request.t(), Attempt.t(), RequestOptions.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def bind(auth, request, attempt, options) do
    case bind_transaction(auth, request, attempt, options, nil) do
      {:ok, %{request: request}} -> {:ok, request}
      {:error, _reason} = error -> error
    end
  end

  @spec bind_bridge(
          CodexPooler.Access.auth_context(),
          Request.t(),
          Attempt.t(),
          RequestOptions.t()
        ) :: {:ok, %{request: Request.t(), attempt: Attempt.t()}} | {:error, term()}
  def bind_bridge(
        auth,
        request,
        attempt,
        options
      ) do
    bind_transaction(auth, request, attempt, options, "websocket")
  end

  defp bind_transaction(
         %{pool: %{id: pool_id}, api_key: %APIKey{id: key_id} = authenticated_key},
         %Request{id: request_id},
         %Attempt{id: attempt_id},
         %RequestOptions{
           continuity: %{codex_session: %CodexSession{id: session_id}},
           transport: %{websocket_owner: %{enabled?: true, lease_token: lease_token} = owner}
         },
         upstream_transport
       )
       when is_binary(lease_token) do
    Repo.transaction(fn ->
      session =
        Repo.one(from row in CodexSession, where: row.id == ^session_id, lock: "FOR UPDATE")

      key = Access.lock_api_key_for_read(key_id)

      turn =
        Repo.one(
          from row in CodexTurn,
            where: row.codex_session_id == ^session_id and row.request_id == ^request_id,
            lock: "FOR UPDATE"
        )

      request = Repo.one(from row in Request, where: row.id == ^request_id, lock: "FOR UPDATE")

      attempt =
        Repo.one(
          from row in Attempt,
            where: row.request_id == ^request_id,
            order_by: [desc: row.attempt_number],
            limit: 1,
            lock: "FOR UPDATE"
        )

      binding = metadata(owner)

      lease =
        Repo.one(
          from row in BridgeOwnerLease,
            where:
              row.codex_session_id == ^session_id and row.lease_token == ^lease_token and
                row.status == "active",
            lock: "FOR UPDATE"
        )

      with true <- current_session?(session, pool_id, key_id, owner),
           true <- current_lease?(lease, session, owner),
           %APIKey{status: "active", runtime_revocation_epoch: epoch} <- key,
           true <- epoch == authenticated_key.runtime_revocation_epoch,
           %CodexTurn{status: "in_progress"} <- turn,
           %Request{
             pool_id: ^pool_id,
             api_key_id: ^key_id,
             status: "in_progress",
             completed_at: nil
           } <- request,
           %Attempt{
             id: ^attempt_id,
             status: "in_progress",
             completed_at: nil,
             replay_generation: 0
           } <- attempt,
           true <- binding_compatible?(request.request_metadata, binding) do
        persist_binding(request, attempt, binding, upstream_transport)
      else
        _invalid -> Repo.rollback(:stale_websocket_owner_binding)
      end
    end)
  end

  defp bind_transaction(_auth, _request, _attempt, _options, _upstream_transport),
    do: {:error, :stale_websocket_owner_binding}

  @spec restore_http_fallback(
          CodexPooler.Access.auth_context(),
          Request.t(),
          Attempt.t(),
          RequestOptions.t()
        ) :: {:ok, %{request: Request.t(), attempt: Attempt.t()}} | {:error, term()}
  def restore_http_fallback(
        %{pool: %{id: pool_id}, api_key: %APIKey{id: key_id} = authenticated_key},
        %Request{id: request_id},
        %Attempt{id: attempt_id},
        %RequestOptions{
          continuity: %{codex_session: %CodexSession{id: session_id}},
          transport: %{websocket_owner: %{enabled?: true, lease_token: lease_token} = owner}
        }
      )
      when is_binary(lease_token) do
    Repo.transaction(fn ->
      session =
        Repo.one(from row in CodexSession, where: row.id == ^session_id, lock: "FOR UPDATE")

      key = Access.lock_api_key_for_read(key_id)

      turn =
        Repo.one(
          from row in CodexTurn,
            where: row.codex_session_id == ^session_id and row.request_id == ^request_id,
            lock: "FOR UPDATE"
        )

      request = Repo.one(from row in Request, where: row.id == ^request_id, lock: "FOR UPDATE")

      attempt =
        Repo.one(
          from row in Attempt,
            where: row.request_id == ^request_id,
            order_by: [desc: row.attempt_number],
            limit: 1,
            lock: "FOR UPDATE"
        )

      binding = metadata(owner)

      lease =
        Repo.one(
          from row in BridgeOwnerLease,
            where:
              row.codex_session_id == ^session_id and row.lease_token == ^lease_token and
                row.status == "active",
            lock: "FOR UPDATE"
        )

      with true <- current_session?(session, pool_id, key_id, owner),
           true <- current_lease?(lease, session, owner),
           %APIKey{status: "active", runtime_revocation_epoch: epoch} <- key,
           true <- epoch == authenticated_key.runtime_revocation_epoch,
           %CodexTurn{status: "in_progress"} <- turn,
           %Request{
             pool_id: ^pool_id,
             api_key_id: ^key_id,
             status: "in_progress",
             completed_at: nil
           } <- request,
           %Attempt{
             id: ^attempt_id,
             status: "in_progress",
             completed_at: nil,
             replay_generation: 0,
             transport: "websocket"
           } <- attempt,
           true <- request.request_metadata["websocket_owner_forwarding"] == binding do
        restore_http_binding(request, attempt)
      else
        _invalid -> Repo.rollback(:stale_websocket_owner_binding)
      end
    end)
  end

  def restore_http_fallback(_auth, _request, _attempt, _options),
    do: {:error, :stale_websocket_owner_binding}

  defp persist_binding(request, attempt, binding, upstream_transport) do
    with {:ok, attempt} <- maybe_update_attempt_transport(attempt, upstream_transport),
         {:ok, request} <-
           Metadata.merge_request_metadata(request, %{"websocket_owner_forwarding" => binding}) do
      %{request: request, attempt: attempt}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_update_attempt_transport(attempt, nil), do: {:ok, attempt}

  defp maybe_update_attempt_transport(attempt, transport),
    do: update_attempt_transport(attempt, transport)

  defp restore_http_binding(request, attempt) do
    with {:ok, attempt} <- update_attempt_transport(attempt, "http_sse"),
         {:ok, request} <-
           request
           |> Ecto.Changeset.change(
             request_metadata: Map.delete(request.request_metadata, "websocket_owner_forwarding")
           )
           |> Repo.update() do
      %{request: request, attempt: attempt}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_attempt_transport(attempt, transport) do
    attempt
    |> Ecto.Changeset.change(transport: transport)
    |> Repo.update()
  end

  defp current_session?(
         %CodexSession{status: "active", owner_lease_expires_at: %DateTime{} = expiry} = session,
         pool_id,
         key_id,
         %{downstream_epoch: epoch, owner_instance_id: owner_id, proxy_instance_id: proxy_id} =
           owner
       )
       when is_integer(epoch) and epoch > 0 and is_binary(owner_id) and is_binary(proxy_id) do
    session.pool_id == pool_id and session.api_key_id == key_id and
      session.owner_instance_id == owner_id and session.owner_lease_token == owner.lease_token and
      DateTime.compare(expiry, DateTime.utc_now()) == :gt
  end

  defp current_session?(_session, _pool_id, _key_id, _owner), do: false

  defp current_lease?(%BridgeOwnerLease{status: "active"} = lease, session, owner) do
    lease.pool_id == session.pool_id and lease.api_key_id == session.api_key_id and
      lease.lease_token == owner.lease_token and
      lease.owner_instance_id == owner.owner_instance_id and
      match?(%DateTime{}, lease.expires_at) and
      DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
  end

  defp current_lease?(_lease, _session, _owner), do: false

  defp metadata(owner) do
    %{
      "enabled" => true,
      "downstream_epoch" => owner.downstream_epoch,
      "proxy_instance_id" => owner.proxy_instance_id,
      "owner_instance_id" => owner.owner_instance_id
    }
  end

  defp binding_compatible?(metadata, binding) when is_map(metadata) do
    case Map.fetch(metadata, "websocket_owner_forwarding") do
      :error -> true
      {:ok, existing} -> existing == binding
    end
  end

  defp binding_compatible?(_metadata, _binding), do: false
end
