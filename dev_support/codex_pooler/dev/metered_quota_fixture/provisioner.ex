defmodule CodexPooler.Dev.MeteredQuotaFixture.Provisioner do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.Material
  alias CodexPooler.Accounts.User
  alias CodexPooler.Dev.MeteredQuotaFixture.Provisioner.{Ownership, Rows}
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

  @type result :: %{
          required(:api_key) => String.t(),
          required(:api_key_prefix) => String.t(),
          required(:fixture_hash) => String.t(),
          required(:identity_id) => Ecto.UUID.t(),
          required(:owned_row_count) => pos_integer()
        }

  @spec prepare() :: result()
  def prepare do
    fixture_hash = random_fixture_hash()
    ids = Ownership.derived_ids(fixture_hash)
    {key_prefix, raw_key, _key_hash} = Material.generate()

    %{
      api_key: raw_key,
      api_key_prefix: key_prefix,
      fixture_hash: fixture_hash,
      identity_id: ids.identity_id,
      owned_row_count: 12
    }
  end

  @spec provision!(map(), String.t()) :: :ok
  def provision!(document, raw_key) do
    owner = owner!()
    refuse_unjournaled_collisions!()
    {:ok, ids} = Ownership.ids_from_document(document)
    key_prefix = document["api_key_prefix"]
    {:ok, ^key_prefix, secret} = Material.split(raw_key)
    key_hash = Material.hash_secret(secret)
    timestamp = now()
    fixture_hash = document["fixture_hash"]

    {:ok, :created} =
      Repo.transact(fn ->
        Rows.insert!(ids, owner, key_prefix, key_hash, fixture_hash, timestamp)
        {:ok, :created}
      end)

    :ok
  end

  @spec release(map()) :: :ok | {:error, String.t()}
  def release(document) do
    Ownership.release(document)
  end

  @spec status(map()) ::
          {:ok, %{rows_present: boolean(), selector_complete: boolean()}}
          | {:error, String.t()}
  def status(document) do
    Ownership.status(document)
  end

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

  defp derived_ids(fixture_hash) do
    %{
      fixture_hash: fixture_hash,
      pool_id: derived_uuid(fixture_hash, "pool"),
      api_key_id: derived_uuid(fixture_hash, "api-key"),
      identity_id: derived_uuid(fixture_hash, "identity"),
      assignment_id: derived_uuid(fixture_hash, "assignment"),
      quota_window_ids:
        Enum.map(1..8, fn index -> derived_uuid(fixture_hash, "quota-window-#{index}") end)
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

  defp insert_identity!(id, owner, fixture_hash, timestamp) do
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
      metadata: %{"dev_fixture" => @marker, "fixture_hash" => fixture_hash}
    })
    |> Repo.insert!()
  end

  defp insert_assignment!(id, pool, identity, owner, fixture_hash, timestamp) do
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
      metadata: %{
        "dev_fixture" => @marker,
        "fixture_hash" => fixture_hash,
        "quota_priming" => %{"status" => "known"}
      }
    })
    |> Repo.insert!()
  end

  defp insert_api_key!(id, pool, owner, key_prefix, key_hash, fixture_hash, timestamp) do
    %APIKey{id: id}
    |> APIKey.changeset(%{
      pool_id: pool.id,
      display_name: "Dev Metered Quota Key",
      key_prefix: key_prefix,
      key_hash: key_hash,
      status: "active",
      dashboard_access: false,
      metadata: %{"dev_fixture" => @marker, "fixture_hash" => fixture_hash},
      created_by_user_id: owner.id,
      created_at: timestamp
    })
    |> Repo.insert!()
  end

  defp insert_windows!(ids, identity, fixture_hash, timestamp) do
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
          metadata: %{"dev_fixture" => @marker, "fixture_hash" => fixture_hash},
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

  defp derive_document_ids(%{"fixture_hash" => fixture_hash})
       when is_binary(fixture_hash) and byte_size(fixture_hash) == 64 do
    if fixture_hash =~ ~r/\A[0-9a-f]{64}\z/ do
      {:ok, derived_ids(fixture_hash)}
    else
      {:error, "metered quota fixture receipt contains an invalid fixture hash"}
    end
  end

  defp derive_document_ids(_document),
    do: {:error, "metered quota fixture receipt has no fixture hash"}

  defp derived_uuid(fixture_hash, label) do
    <<a::48, _version::4, b::12, _variant::2, c::62, _rest::128>> =
      :crypto.hash(:sha256, [fixture_hash, ?:, label])

    Ecto.UUID.load!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  defp random_fixture_hash do
    32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp validate_owned_rows(ids) do
    checks =
      [
        owned?(Pool, ids.pool_id, &(&1.slug == @pool_slug)),
        owned?(
          APIKey,
          ids.api_key_id,
          &owned_api_key?(&1, ids)
        ),
        owned?(
          UpstreamIdentity,
          ids.identity_id,
          &owned_identity?(&1, ids)
        ),
        owned?(
          PoolUpstreamAssignment,
          ids.assignment_id,
          &owned_assignment?(&1, ids)
        )
      ] ++
        Enum.map(ids.quota_window_ids, fn id ->
          owned?(
            AccountQuotaWindow,
            id,
            &owned_window?(&1, ids)
          )
        end)

    if Enum.all?(checks, &(&1 in [:owned, :missing])) do
      :ok
    else
      {:error, "metered quota fixture receipt points to a row outside fixture ownership"}
    end
  end

  defp owned_api_key?(row, ids) do
    row.pool_id == ids.pool_id and owned_metadata?(row.metadata, ids.fixture_hash)
  end

  defp owned_identity?(row, ids) do
    row.chatgpt_account_id == @identity_account_id and
      owned_metadata?(row.metadata, ids.fixture_hash)
  end

  defp owned_assignment?(row, ids) do
    row.pool_id == ids.pool_id and row.upstream_identity_id == ids.identity_id and
      owned_metadata?(row.metadata, ids.fixture_hash)
  end

  defp owned_window?(row, ids) do
    row.upstream_identity_id == ids.identity_id and
      owned_metadata?(row.metadata, ids.fixture_hash)
  end

  defp owned_metadata?(metadata, fixture_hash) do
    metadata["dev_fixture"] == @marker and metadata["fixture_hash"] == fixture_hash
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
