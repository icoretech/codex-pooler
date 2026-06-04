defmodule CodexPooler.Upstreams.Lifecycle.IdentityLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active UpstreamIdentity.active_status()
  @disabled UpstreamIdentity.disabled_status()
  @pending UpstreamIdentity.pending_status()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type identity_result ::
          {:ok, UpstreamIdentity.t()}
          | {:error, Ecto.Changeset.t() | lifecycle_error() | identity_conflict()}
  @type conflict_map :: %{
          required(:path) => String.t(),
          required(:stored_workspace_ref) => String.t(),
          required(:incoming_workspace_ref) => String.t(),
          required(:stored_plan_family) => String.t() | nil,
          required(:incoming_plan_family) => String.t() | nil,
          required(:stored_seat_type) => String.t() | nil,
          required(:incoming_seat_type) => String.t() | nil
        }
  @type identity_conflict :: {:identity_conflict, :workspace_identity_mismatch, conflict_map()}

  @spec create_upstream_identity(map()) :: identity_result()
  def create_upstream_identity(attrs) when is_map(attrs) do
    create_identity(attrs, plan_metadata: :ignore)
  end

  @spec activate_upstream_identity_with_plan(identity_ref(), map()) :: identity_result()
  def activate_upstream_identity_with_plan(identity_or_id, attrs \\ %{}) do
    activate_identity(identity_or_id, attrs, plan_metadata: :allow)
  end

  @spec update_upstream_identity(UpstreamIdentity.t(), map()) :: identity_result()
  def update_upstream_identity(%UpstreamIdentity{} = identity, attrs) when is_map(attrs) do
    update_identity(identity, attrs, plan_metadata: :ignore)
  end

  @spec upsert_upstream_identity(map()) :: identity_result()
  def upsert_upstream_identity(attrs) when is_map(attrs) do
    attrs = atomize_attrs(attrs)

    case select_upsert_identity(attrs) do
      {:ok, %UpstreamIdentity{} = identity} -> update_upstream_identity(identity, attrs)
      {:ok, nil} -> create_upstream_identity(attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec select_upsert_identity(map()) ::
          {:ok, UpstreamIdentity.t() | nil} | {:error, identity_conflict()}
  def select_upsert_identity(attrs) when is_map(attrs) do
    attrs = atomize_attrs(attrs)
    chatgpt_account_id = attrs |> Map.get(:chatgpt_account_id) |> present_string()
    workspace_id = attrs |> Map.get(:workspace_id) |> present_string()

    case chatgpt_account_id do
      nil -> select_email_fallback_identity(attrs, workspace_id)
      account_id -> select_account_slot_identity(account_id, workspace_id)
    end
  end

  @spec get_upstream_identity_by_chatgpt_account(term()) :: UpstreamIdentity.t() | nil
  def get_upstream_identity_by_chatgpt_account(chatgpt_account_id)
      when is_binary(chatgpt_account_id) do
    case identities_for_account(chatgpt_account_id) do
      [identity] -> identity
      _ambiguous_or_missing -> nil
    end
  end

  def get_upstream_identity_by_chatgpt_account(_chatgpt_account_id), do: nil

  @spec list_upstream_identities_by_chatgpt_account(term()) :: [UpstreamIdentity.t()]
  def list_upstream_identities_by_chatgpt_account(chatgpt_account_id)
      when is_binary(chatgpt_account_id) do
    identities_for_account(chatgpt_account_id)
  end

  def list_upstream_identities_by_chatgpt_account(_chatgpt_account_id), do: []

  @spec get_upstream_identity_by_chatgpt_account_and_workspace(term(), term()) ::
          UpstreamIdentity.t() | nil
  def get_upstream_identity_by_chatgpt_account_and_workspace(chatgpt_account_id, workspace_id)
      when is_binary(chatgpt_account_id) do
    account_id = String.trim(chatgpt_account_id)
    workspace_id = present_string(workspace_id)

    UpstreamIdentity
    |> where([identity], identity.chatgpt_account_id == ^account_id)
    |> where_workspace(workspace_id)
    |> limit(1)
    |> Repo.one()
  end

  def get_upstream_identity_by_chatgpt_account_and_workspace(_chatgpt_account_id, _workspace_id),
    do: nil

  @spec identity_conflict(map(), UpstreamIdentity.t() | nil) :: identity_conflict()
  def identity_conflict(attrs, stored_identity) when is_map(attrs) do
    attrs = atomize_attrs(attrs)

    {:identity_conflict, :workspace_identity_mismatch,
     %{
       path: "upstream_identity.reconciliation",
       stored_workspace_ref: workspace_ref(stored_identity && stored_identity.workspace_id),
       incoming_workspace_ref: workspace_ref(Map.get(attrs, :workspace_id)),
       stored_plan_family: stored_identity && stored_identity.plan_family,
       incoming_plan_family: incoming_plan_family(attrs),
       stored_seat_type: stored_identity && stored_identity.seat_type,
       incoming_seat_type: present_string(Map.get(attrs, :seat_type))
     }}
  end

  @spec guard_workspace_slot_mutation(identity_ref(), map()) ::
          :ok | {:error, identity_conflict() | lifecycle_error()}
  def guard_workspace_slot_mutation(identity_or_id, attrs \\ %{}) when is_map(attrs) do
    attrs = atomize_attrs(attrs)

    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        guard_identity_slot(identity, attrs)

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp guard_identity_slot(%UpstreamIdentity{} = identity, attrs) do
    incoming_workspace_id = attrs |> Map.get(:workspace_id) |> present_string()

    cond do
      is_binary(incoming_workspace_id) and identity.workspace_id == incoming_workspace_id ->
        :ok

      is_binary(incoming_workspace_id) ->
        {:error, identity_conflict(attrs, identity)}

      concrete_workspace?(identity) ->
        guard_missing_workspace_evidence(identity, attrs)

      sibling_concrete_slot?(identity) ->
        {:error, identity_conflict(attrs, concrete_sibling(identity) || identity)}

      true ->
        :ok
    end
  end

  defp guard_missing_workspace_evidence(%UpstreamIdentity{} = identity, attrs) do
    if plan_compatible?(identity, attrs) and seat_compatible?(identity, attrs) do
      :ok
    else
      {:error, identity_conflict(attrs, identity)}
    end
  end

  defp plan_compatible?(%UpstreamIdentity{} = identity, attrs) do
    case incoming_plan_family(attrs) do
      nil -> true
      incoming -> incoming == stored_plan_family(identity)
    end
  end

  defp stored_plan_family(%UpstreamIdentity{} = identity) do
    present_string(identity.plan_family) || plan_family(identity.plan_label)
  end

  defp seat_compatible?(%UpstreamIdentity{} = identity, attrs) do
    case present_string(Map.get(attrs, :seat_type)) do
      nil -> true
      incoming -> incoming == present_string(identity.seat_type)
    end
  end

  defp concrete_workspace?(%UpstreamIdentity{} = identity),
    do: not is_nil(present_string(identity.workspace_id))

  defp select_account_slot_identity(account_id, workspace_id) do
    identities = identities_for_account(account_id)

    case identity_for_workspace(identities, workspace_id) do
      %UpstreamIdentity{} = identity ->
        {:ok, identity}

      nil ->
        legacy_identity = identity_for_workspace(identities, nil)
        concrete_identities = Enum.reject(identities, &is_nil(&1.workspace_id))

        if (is_binary(workspace_id) and legacy_identity) && concrete_identities == [] do
          {:ok, legacy_identity}
        else
          {:ok, nil}
        end
    end
  end

  defp select_email_fallback_identity(attrs, workspace_id) do
    account_email = attrs |> Map.get(:account_email) |> normalize_email()

    case account_email do
      nil ->
        {:error, identity_conflict(attrs, nil)}

      email ->
        candidates = identities_for_email_workspace(email, workspace_id)

        case candidates do
          [candidate] -> maybe_select_email_candidate(candidate, attrs)
          [] -> {:error, identity_conflict(attrs, nil)}
          [conflict | _rest] -> {:error, identity_conflict(attrs, conflict)}
        end
    end
  end

  defp maybe_select_email_candidate(%UpstreamIdentity{} = candidate, attrs) do
    incoming_workspace_id = attrs |> Map.get(:workspace_id) |> present_string()

    if is_nil(incoming_workspace_id) and sibling_concrete_slot?(candidate) do
      {:error, identity_conflict(attrs, concrete_sibling(candidate) || candidate)}
    else
      {:ok, candidate}
    end
  end

  @spec activate_upstream_identity(identity_ref(), map()) :: identity_result()
  def activate_upstream_identity(identity_or_id, attrs \\ %{}) do
    activate_identity(identity_or_id, attrs, plan_metadata: :ignore)
  end

  @spec disable_upstream_identity(identity_ref()) :: identity_result()
  def disable_upstream_identity(identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        update_upstream_identity(identity, %{status: @disabled, disabled_at: now()})

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp create_identity(attrs, opts) do
    now = now()

    attrs
    |> atomize_attrs()
    |> maybe_drop_plan_metadata(opts)
    |> put_default(:status, @pending)
    |> put_default(:headers_profile_version, 1)
    |> put_default(:metadata, %{})
    |> put_default(:created_at, now)
    |> put_default(:updated_at, now)
    |> then(&UpstreamIdentity.changeset(%UpstreamIdentity{}, &1))
    |> Repo.insert()
  end

  defp update_identity(%UpstreamIdentity{} = identity, attrs, opts) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_attrs()
      |> maybe_drop_plan_metadata(opts)
      |> Map.put(:updated_at, now())

    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update()
  end

  defp activate_identity(identity_or_id, attrs, opts) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        timestamp = now()
        attrs = atomize_attrs(attrs)

        update_identity(
          identity,
          attrs
          |> Map.merge(%{
            status: @active,
            auth_verified_at: Map.get(attrs, :auth_verified_at, timestamp),
            auth_fresh_at: Map.get(attrs, :auth_fresh_at, timestamp),
            disabled_at: nil
          }),
          opts
        )

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp maybe_drop_plan_metadata(attrs, plan_metadata: :allow), do: attrs

  defp maybe_drop_plan_metadata(attrs, plan_metadata: :ignore) do
    Map.drop(attrs, [:plan_family, :plan_label])
  end

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp identities_for_account(chatgpt_account_id) when is_binary(chatgpt_account_id) do
    account_id = String.trim(chatgpt_account_id)

    Repo.all(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id == ^account_id,
        order_by: [
          asc_nulls_first: identity.workspace_id,
          asc: identity.created_at,
          asc: identity.id
        ]
    )
  end

  defp identities_for_email_workspace(account_email, workspace_id) do
    UpstreamIdentity
    |> where([identity], identity.account_email == ^account_email)
    |> where_workspace(workspace_id)
    |> order_by([identity], asc: identity.created_at, asc: identity.id)
    |> Repo.all()
  end

  defp where_workspace(query, nil), do: where(query, [identity], is_nil(identity.workspace_id))

  defp where_workspace(query, workspace_id),
    do: where(query, [identity], identity.workspace_id == ^workspace_id)

  defp identity_for_workspace(identities, workspace_id) do
    Enum.find(identities, &(&1.workspace_id == workspace_id))
  end

  defp sibling_concrete_slot?(%UpstreamIdentity{chatgpt_account_id: nil}), do: false

  defp sibling_concrete_slot?(%UpstreamIdentity{} = candidate) do
    not is_nil(concrete_sibling(candidate))
  end

  defp concrete_sibling(%UpstreamIdentity{chatgpt_account_id: account_id, id: identity_id}) do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id == ^account_id,
        where: identity.id != ^identity_id,
        where: not is_nil(identity.workspace_id),
        order_by: [asc: identity.workspace_id, asc: identity.created_at, asc: identity.id],
        limit: 1
    )
  end

  defp workspace_ref(workspace_id) do
    case present_string(workspace_id) do
      nil ->
        "legacy"

      workspace_id ->
        digest = :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower)
        "ws:" <> binary_part(digest, 0, 8)
    end
  end

  defp incoming_plan_family(attrs) do
    present_string(Map.get(attrs, :plan_family)) || plan_family(Map.get(attrs, :plan_label))
  end

  defp plan_family(nil), do: nil

  defp plan_family(plan) when is_binary(plan) do
    plan
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> present_string()
  end

  defp plan_family(_plan), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp normalize_email(value) do
    value
    |> present_string()
    |> case do
      nil -> nil
      email -> String.downcase(email)
    end
  end

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
