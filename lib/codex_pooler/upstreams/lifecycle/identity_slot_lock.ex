defmodule CodexPooler.Upstreams.Lifecycle.IdentitySlotLock do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  @resource_prefix "identity-slot:v1:"
  @resource_domain "codex-pooler.identity-slot"

  @type normalized_identity :: %{
          required(:chatgpt_account_id) => String.t() | nil,
          required(:workspace_id) => String.t() | nil,
          required(:chatgpt_user_id) => String.t() | nil,
          required(:account_email) => String.t() | nil
        }

  @type locked_rows :: %{
          required(:identities) => [UpstreamIdentity.t()],
          required(:assignments) => [PoolUpstreamAssignment.t()],
          required(:secrets) => [EncryptedSecret.t()]
        }

  @spec normalize(map()) :: normalized_identity()
  def normalize(attrs) when is_map(attrs) do
    %{
      chatgpt_account_id: attrs |> fetch(:chatgpt_account_id) |> present_string(),
      workspace_id: attrs |> fetch(:workspace_id) |> present_string(),
      chatgpt_user_id: attrs |> fetch(:chatgpt_user_id) |> present_string(),
      account_email: attrs |> fetch(:account_email) |> normalize_email()
    }
  end

  @spec advisory_resources(map()) :: [String.t()]
  def advisory_resources(attrs) when is_map(attrs) do
    normalized = normalize(attrs)

    [
      advisory_resource("account", normalized.chatgpt_account_id),
      advisory_resource("email", normalized.account_email)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec lock_slots!([map()]) :: [String.t()]
  def lock_slots!(identity_attrs) when is_list(identity_attrs) do
    require_transaction!("identity slot locks require a caller transaction")

    resources =
      identity_attrs
      |> Enum.flat_map(&advisory_resources/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(resources, fn resource ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [resource])
    end)

    resources
  end

  @spec lock_identity_rows!([UpstreamIdentity.t() | Ecto.UUID.t()]) :: locked_rows()
  def lock_identity_rows!(identity_refs) when is_list(identity_refs) do
    require_transaction!("identity row locks require a caller transaction")

    identity_ids =
      identity_refs
      |> Enum.map(&identity_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    identities =
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.id in ^identity_ids,
          order_by: [asc: identity.id],
          lock: "FOR UPDATE"
      )

    locked_identity_ids = Enum.map(identities, & &1.id)

    assignments =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          where: assignment.upstream_identity_id in ^locked_identity_ids,
          order_by: [asc: assignment.id],
          lock: "FOR UPDATE"
      )

    secrets =
      Repo.all(
        from secret in EncryptedSecret,
          where: secret.upstream_identity_id in ^locked_identity_ids,
          order_by: [asc: secret.id],
          lock: "FOR UPDATE"
      )

    %{identities: identities, assignments: assignments, secrets: secrets}
  end

  defp advisory_resource(_kind, nil), do: nil

  defp advisory_resource(kind, value) do
    digest =
      [@resource_domain, "v1", kind, value]
      |> encode_tuple()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    @resource_prefix <> digest
  end

  defp encode_tuple(values) do
    Enum.map_join(values, fn value -> <<byte_size(value)::unsigned-32, value::binary>> end)
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp normalize_email(value) do
    case present_string(value) do
      nil -> nil
      email -> String.downcase(email)
    end
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity), do: nil

  defp require_transaction!(message) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, message)
  end
end
