defmodule CodexPooler.Accounting.WebsocketOwnerBinding do
  @moduledoc false
  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Metadata, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @spec bind(CodexPooler.Access.auth_context(), Request.t(), Attempt.t(), RequestOptions.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def bind(
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

      key = Repo.one(from row in APIKey, where: row.id == ^key_id, lock: "FOR UPDATE")

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
        persist_binding(request, binding)
      else
        _invalid -> Repo.rollback(:stale_websocket_owner_binding)
      end
    end)
  end

  def bind(_auth, _request, _attempt, _options), do: {:error, :stale_websocket_owner_binding}

  defp persist_binding(request, binding) do
    case Metadata.merge_request_metadata(request, %{"websocket_owner_forwarding" => binding}) do
      {:ok, request} -> request
      {:error, reason} -> Repo.rollback(reason)
    end
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
