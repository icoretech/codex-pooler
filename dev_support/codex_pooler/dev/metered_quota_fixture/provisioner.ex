defmodule CodexPooler.Dev.MeteredQuotaFixture.Provisioner do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.Material
  alias CodexPooler.Accounts.User
  alias CodexPooler.Dev.Seeds
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @owner_email "dev-owner@example.com"
  @password "dev-password-123"
  @pool_slug "dev-metered-quota"
  @identity_account_id "dev-metered-quota"
  @marker "metered_quota"

  @type owned_ids :: %{
          required(String.t()) => String.t() | [String.t()]
        }

  @type result :: %{
          required(:api_key) => String.t(),
          required(:api_key_prefix) => String.t(),
          required(:identity_id) => Ecto.UUID.t(),
          required(:owned_row_ids) => owned_ids()
        }

  @spec prepare() :: result()
  def prepare do
    ids = generated_ids()
    {key_prefix, raw_key, _key_hash} = Material.generate()

    %{
      api_key: raw_key,
      api_key_prefix: key_prefix,
      identity_id: ids.identity_id,
      owned_row_ids: %{
        "pool_id" => ids.pool_id,
        "api_key_id" => ids.api_key_id,
        "identity_id" => ids.identity_id,
        "assignment_id" => ids.assignment_id,
        "quota_window_ids" => ids.quota_window_ids
      }
    }
  end

  @spec provision!(map()) :: :ok
  def provision!(document) do
    owner = owner!()
    refuse_unjournaled_collisions!()
    {:ok, ids} = parse_owned_ids(document["owned_row_ids"])
    %{"prefix" => key_prefix, "value" => raw_key} = document["api_key"]
    {:ok, ^key_prefix, secret} = Material.split(raw_key)
    key_hash = Material.hash_secret(secret)
    timestamp = now()

    {:ok, :created} =
      Repo.transact(fn ->
        pool = insert_pool!(ids.pool_id, owner, timestamp)
        identity = insert_identity!(ids.identity_id, owner, timestamp)
        insert_assignment!(ids.assignment_id, pool, identity, owner, timestamp)
        insert_api_key!(ids.api_key_id, pool, owner, key_prefix, key_hash, timestamp)
        insert_windows!(ids.quota_window_ids, identity, timestamp)
        {:ok, :created}
      end)

    :ok
  end

  @spec release(map()) :: :ok | {:error, String.t()}
  def release(%{"owned_row_ids" => owned_ids}) when is_map(owned_ids) do
    with {:ok, ids} <- parse_owned_ids(owned_ids),
         :ok <- validate_owned_rows(ids),
         {:ok, :released} <- exact_delete(ids) do
      :ok
    end
  end

  def release(_document), do: {:error, "metered quota fixture receipt has no owned row ids"}

  @spec status(map()) ::
          {:ok, %{rows_present: boolean(), selector_complete: boolean()}}
          | {:error, String.t()}
  def status(%{"owned_row_ids" => owned_ids}) when is_map(owned_ids) do
    with {:ok, ids} <- parse_owned_ids(owned_ids),
         :ok <- validate_owned_rows(ids) do
      rows_present = owned_row_count(ids) == 4 + length(ids.quota_window_ids)

      {:ok,
       %{rows_present: rows_present, selector_complete: rows_present and selector_complete?(ids)}}
    end
  end

  def status(_document), do: {:error, "metered quota fixture receipt has no owned row ids"}

  defp owner! do
    owner = Repo.get_by(User, email: @owner_email)

    owner =
      if valid_owner?(owner) do
        owner
      else
        Seeds.ensure_metered_quota_owner!()
      end

    unless valid_owner?(owner) do
      raise "metered quota fixture requires the active dev owner and existing dev password"
    end

    owner
  end

  defp valid_owner?(%User{status: "active"} = owner) do
    User.valid_password?(owner, @password) and
      Repo.exists?(
        from membership in Membership,
          where:
            membership.user_id == ^owner.id and membership.role == "instance_owner" and
              membership.status == "active"
      )
  end

  defp valid_owner?(_owner), do: false

  defp refuse_unjournaled_collisions! do
    if Repo.exists?(from pool in Pool, where: pool.slug == ^@pool_slug) or
         Repo.exists?(
           from identity in UpstreamIdentity,
             where: identity.chatgpt_account_id == ^@identity_account_id
         ) do
      raise "metered quota fixture found unjournaled deterministic rows; remove them explicitly"
    end
  end

  defp generated_ids do
    %{
      pool_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate(),
      identity_id: Ecto.UUID.generate(),
      assignment_id: Ecto.UUID.generate(),
      quota_window_ids: Enum.map(1..8, fn _index -> Ecto.UUID.generate() end)
    }
  end

  defp insert_pool!(id, owner, timestamp) do
    %Pool{id: id}
    |> Pool.changeset(%{
      slug: @pool_slug,
      name: "Dev Metered Quota",
      status: "active",
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.insert!()
  end

  defp insert_identity!(id, owner, timestamp) do
    %UpstreamIdentity{id: id}
    |> UpstreamIdentity.changeset(%{
      chatgpt_account_id: @identity_account_id,
      account_email: "dev-metered-quota@example.com",
      account_label: "Dev Metered Quota Identity",
      onboarding_method: "import",
      status: "active",
      plan_family: "dev",
      plan_label: "Dev",
      headers_profile_version: 1,
      auth_fresh_at: timestamp,
      auth_verified_at: timestamp,
      last_successful_sync_at: timestamp,
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp,
      metadata: %{"dev_fixture" => @marker}
    })
    |> Repo.insert!()
  end

  defp insert_assignment!(id, pool, identity, owner, timestamp) do
    %PoolUpstreamAssignment{id: id}
    |> PoolUpstreamAssignment.changeset(%{
      pool_id: pool.id,
      upstream_identity_id: identity.id,
      assignment_label: "Dev Metered Quota Assignment",
      status: "active",
      health_status: "active",
      eligibility_status: "eligible",
      last_successful_sync_at: timestamp,
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp,
      metadata: %{"dev_fixture" => @marker, "quota_priming" => %{"status" => "known"}}
    })
    |> Repo.insert!()
  end

  defp insert_api_key!(id, pool, owner, key_prefix, key_hash, timestamp) do
    %APIKey{id: id}
    |> APIKey.changeset(%{
      pool_id: pool.id,
      display_name: "Dev Metered Quota Key",
      key_prefix: key_prefix,
      key_hash: key_hash,
      status: "active",
      dashboard_access: false,
      metadata: %{"dev_fixture" => @marker},
      created_by_user_id: owner.id,
      created_at: timestamp
    })
    |> Repo.insert!()
  end

  defp insert_windows!(ids, identity, timestamp) do
    stale_at = DateTime.add(timestamp, -2, :day)

    specs = [
      account_spec("primary", 300, 12, timestamp),
      account_spec("secondary", 10_080, 24, timestamp),
      meter_spec("dev-fresh", "Fresh meter", 18, "fresh", timestamp, timestamp),
      meter_spec("dev-stale", "Stale meter", 52, "fresh", stale_at, timestamp),
      meter_spec(
        "dev-stale-exhausted",
        "Stale exhausted meter",
        100,
        "fresh",
        stale_at,
        timestamp
      ),
      meter_spec("dev-unknown-reset", "Unknown reset meter", 41, "unknown", timestamp, nil),
      meter_spec("dev-meter-alpha", "Shared model meter", 27, "fresh", timestamp, timestamp),
      meter_spec("dev-meter-beta", "Shared model meter", 63, "fresh", timestamp, timestamp)
    ]

    Enum.zip(ids, specs)
    |> Enum.each(fn {id, attrs} ->
      %AccountQuotaWindow{id: id}
      |> AccountQuotaWindow.changeset(
        Map.merge(attrs, %{
          upstream_identity_id: identity.id,
          source: "dev_metered_quota_fixture",
          source_precision: "observed",
          last_sync_at: attrs.observed_at,
          merge_precedence: 50,
          metadata: %{"dev_fixture" => @marker},
          created_at: timestamp,
          updated_at: timestamp
        })
      )
      |> Repo.insert!()
    end)
  end

  defp account_spec(kind, minutes, percent, timestamp) do
    %{
      quota_key: "account",
      window_kind: kind,
      window_minutes: minutes,
      reset_at: DateTime.add(timestamp, minutes, :minute),
      used_percent: Decimal.new(percent),
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: timestamp
    }
  end

  defp meter_spec(token, label, percent, state, observed_at, reset_anchor) do
    %{
      quota_key: "shared-model-meter",
      window_kind: "secondary",
      window_minutes: 10_080,
      reset_at: if(reset_anchor, do: DateTime.add(reset_anchor, 7, :day)),
      used_percent: Decimal.new(percent),
      display_label: label,
      limit_name: "Shared model meter",
      metered_feature: token,
      quota_scope: "model",
      quota_family: "shared-model-meter",
      model: "gpt-5.4",
      raw_limit_id: "limit-#{token}",
      raw_limit_name: "Shared model meter",
      raw_metered_feature: token,
      freshness_state: state,
      observed_at: observed_at
    }
  end

  defp parse_owned_ids(owned_ids) do
    with {:ok, pool_id} <- uuid(owned_ids["pool_id"]),
         {:ok, api_key_id} <- uuid(owned_ids["api_key_id"]),
         {:ok, identity_id} <- uuid(owned_ids["identity_id"]),
         {:ok, assignment_id} <- uuid(owned_ids["assignment_id"]),
         {:ok, quota_window_ids} <- uuid_list(owned_ids["quota_window_ids"], 8) do
      {:ok,
       %{
         pool_id: pool_id,
         api_key_id: api_key_id,
         identity_id: identity_id,
         assignment_id: assignment_id,
         quota_window_ids: quota_window_ids
       }}
    else
      :error -> {:error, "metered quota fixture receipt contains invalid owned row ids"}
    end
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp uuid(_value), do: :error

  defp uuid_list(values, expected_count)
       when is_list(values) and length(values) == expected_count do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case uuid(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  defp uuid_list(_values, _expected_count), do: :error

  defp validate_owned_rows(ids) do
    checks =
      [
        owned?(Pool, ids.pool_id, &(&1.slug == @pool_slug)),
        owned?(
          APIKey,
          ids.api_key_id,
          &(&1.pool_id == ids.pool_id and &1.metadata["dev_fixture"] == @marker)
        ),
        owned?(
          UpstreamIdentity,
          ids.identity_id,
          &(&1.chatgpt_account_id == @identity_account_id and
              &1.metadata["dev_fixture"] == @marker)
        ),
        owned?(
          PoolUpstreamAssignment,
          ids.assignment_id,
          &(&1.pool_id == ids.pool_id and &1.upstream_identity_id == ids.identity_id and
              &1.metadata["dev_fixture"] == @marker)
        )
      ] ++
        Enum.map(ids.quota_window_ids, fn id ->
          owned?(
            AccountQuotaWindow,
            id,
            &(&1.upstream_identity_id == ids.identity_id and &1.metadata["dev_fixture"] == @marker)
          )
        end)

    if Enum.all?(checks, &(&1 in [:owned, :missing])) do
      :ok
    else
      {:error, "metered quota fixture receipt points to a row outside fixture ownership"}
    end
  end

  defp owned?(schema, id, predicate) do
    case Repo.get(schema, id) do
      nil -> :missing
      row -> if(predicate.(row), do: :owned, else: :foreign)
    end
  end

  defp exact_delete(ids) do
    Repo.transact(fn ->
      Repo.delete_all(from row in AccountQuotaWindow, where: row.id in ^ids.quota_window_ids)
      Repo.delete_all(from row in PoolUpstreamAssignment, where: row.id == ^ids.assignment_id)
      Repo.delete_all(from row in APIKey, where: row.id == ^ids.api_key_id)
      Repo.delete_all(from row in Pool, where: row.id == ^ids.pool_id)
      Repo.delete_all(from row in UpstreamIdentity, where: row.id == ^ids.identity_id)
      {:ok, :released}
    end)
  end

  defp owned_row_count(ids) do
    Enum.sum([
      Repo.aggregate(from(row in Pool, where: row.id == ^ids.pool_id), :count, :id),
      Repo.aggregate(from(row in APIKey, where: row.id == ^ids.api_key_id), :count, :id),
      Repo.aggregate(
        from(row in UpstreamIdentity, where: row.id == ^ids.identity_id),
        :count,
        :id
      ),
      Repo.aggregate(
        from(row in PoolUpstreamAssignment, where: row.id == ^ids.assignment_id),
        :count,
        :id
      ),
      Repo.aggregate(
        from(row in AccountQuotaWindow, where: row.id in ^ids.quota_window_ids),
        :count,
        :id
      )
    ])
  end

  defp selector_complete?(ids) do
    windows = Repo.all(from row in AccountQuotaWindow, where: row.id in ^ids.quota_window_ids)

    dynamic_states =
      Enum.frequencies_by(
        windows,
        &Evidence.current_freshness_state(&1, now())
      )

    same_label = Enum.filter(windows, &(&1.display_label == "Shared model meter"))

    dynamic_states["fresh"] == 5 and dynamic_states["stale"] == 2 and
      dynamic_states["unknown"] == 1 and length(same_label) == 2 and
      same_label |> Enum.map(& &1.raw_metered_feature) |> Enum.uniq() |> length() == 2
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
