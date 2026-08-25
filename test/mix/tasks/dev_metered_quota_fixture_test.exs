defmodule CodexPooler.MixTasks.DevMeteredQuotaFixtureTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query

  alias CodexPooler.Access.APIKeys.Authentication
  alias CodexPooler.Accounts.User
  alias CodexPooler.Dev.MeteredQuotaFixture
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @password "dev-password-123"

  setup do
    owner =
      %User{}
      |> User.operator_create_changeset(%{
        email: "dev-owner@example.com",
        display_name: "Dev Owner",
        password: @password,
        password_change_required: false
      })
      |> Ecto.Changeset.put_change(:created_at, now())
      |> Ecto.Changeset.put_change(:updated_at, now())
      |> Repo.insert!()

    %Membership{}
    |> Membership.changeset(%{
      user_id: owner.id,
      role: "instance_owner",
      status: "active",
      created_by_user_id: owner.id,
      created_at: now()
    })
    |> Repo.insert!()

    root =
      Path.join(System.tmp_dir!(), "metered-quota-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    receipt_path = Path.join(root, "receipt.json")
    on_exit(fn -> File.rm_rf!(root) end)

    options = [
      environment: :test,
      allow_test_database: true,
      receipt_path: receipt_path,
      allowed_receipt_root: root
    ]

    %{options: options, owner: owner, receipt_path: receipt_path, root: root}
  end

  test "acquire, status, and release preserve exact fixture ownership", context do
    assert {:ok, %{status: "ready", leases: 1, rows_present: true}} =
             MeteredQuotaFixture.acquire(context.options)

    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 8

    assert {:ok, %{status: "ready", leases: 1, rows_present: true}} =
             MeteredQuotaFixture.status(context.options)

    assert {:ok, %{status: "released", leases: 0}} =
             MeteredQuotaFixture.release(context.options)

    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 0
    assert Repo.get(User, context.owner.id)
  end

  test "receipt and repeatable output omit secrets and owner identifiers", context do
    assert {:ok,
            %{
              status: "ready",
              one_time_api_key: raw_key,
              admin_identity_route: admin_identity_route
            } = acquisition} = MeteredQuotaFixture.acquire(context.options)

    assert raw_key =~ ~r/^sk-cxp-/
    assert admin_identity_route =~ ~r|^/admin/upstreams/[0-9a-f-]{36}$|
    assert {:ok, %{key_prefix: key_prefix}} = Authentication.authenticate_api_key(raw_key)

    receipt_body = File.read!(context.receipt_path)
    receipt = Jason.decode!(receipt_body)

    assert Enum.sort(Map.keys(receipt)) ==
             ~w(api_key_prefix fixture_hash leases owned_row_count route_paths state version)

    refute receipt_body =~ raw_key

    refute receipt_body =~
             ~r/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i

    refute Map.has_key?(receipt, "identity_id")
    refute Map.has_key?(receipt, "owned_row_ids")

    assert {:ok, status} = MeteredQuotaFixture.status(context.options)
    status_output = Jason.encode!(status)

    refute Map.has_key?(status, :one_time_api_key)
    refute Map.has_key?(status, :identity_id)
    refute Map.has_key?(status, :admin_identity_route)
    refute status_output =~ raw_key

    refute status_output =~
             ~r/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i

    assert acquisition.api_key_prefix == receipt["api_key_prefix"]
    assert key_prefix == receipt["api_key_prefix"]

    assert {:ok, %{status: "released", leases: 0}} =
             MeteredQuotaFixture.release(context.options)

    refute File.exists?(context.receipt_path)
    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 0
  end

  test "acquire is reference counted and release deletes only exact journaled ids", context do
    assert {:ok, %{status: "ready", leases: 1, selector_complete: true}} =
             MeteredQuotaFixture.acquire(context.options)

    assert file_mode(context.root) == 0o700
    assert file_mode(context.receipt_path) == 0o600

    receipt = context.receipt_path |> File.read!() |> Jason.decode!()
    assert receipt["api_key_prefix"] =~ ~r/^sk-cxp-/
    assert receipt["owned_row_count"] == 12

    windows =
      Repo.all(
        from window in AccountQuotaWindow,
          order_by: [asc: window.quota_key, asc: window.raw_metered_feature]
      )

    assert length(windows) == 8

    snapshot_at = now()

    assert Enum.frequencies_by(
             windows,
             &Evidence.current_freshness_state(&1, snapshot_at)
           ) == %{
             "fresh" => 5,
             "stale" => 2,
             "unknown" => 1
           }

    same_label = Enum.filter(windows, &(&1.display_label == "Shared model meter"))
    assert Enum.map(same_label, & &1.raw_metered_feature) == ["dev-meter-alpha", "dev-meter-beta"]
    assert Enum.uniq(Enum.map(same_label, & &1.quota_key)) == ["shared-model-meter"]

    assert {:ok, %{status: "ready", leases: 2}} = MeteredQuotaFixture.acquire(context.options)

    assert {:ok, %{status: "ready", leases: 2, selector_complete: true}} =
             MeteredQuotaFixture.status(context.options)

    assert {:ok, %{status: "ready", leases: 1}} = MeteredQuotaFixture.release(context.options)
    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 8

    assert {:ok, %{status: "released", leases: 0}} = MeteredQuotaFixture.release(context.options)
    refute File.exists?(context.receipt_path)
    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 0
    assert Repo.get(User, context.owner.id)
    assert {:ok, %{status: "absent", leases: 0}} = MeteredQuotaFixture.status(context.options)
  end

  test "status before acquire is read-only and actionable", context do
    before_count = Repo.aggregate(AccountQuotaWindow, :count, :id)

    assert {:ok, %{status: "absent", leases: 0, action: action}} =
             MeteredQuotaFixture.status(context.options)

    assert action =~ "acquire"
    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == before_count
    refute File.exists?(context.receipt_path)
  end

  test "release recovers a prepared journal after an interrupted acquire", context do
    assert {:ok, %{status: "ready"}} = MeteredQuotaFixture.acquire(context.options)

    receipt = context.receipt_path |> File.read!() |> Jason.decode!()
    File.write!(context.receipt_path, Jason.encode!(Map.put(receipt, "state", "prepared")))
    File.chmod!(context.receipt_path, 0o600)

    assert {:ok, %{status: "released", leases: 0}} =
             MeteredQuotaFixture.release(context.options)

    refute File.exists?(context.receipt_path)
    assert Repo.aggregate(AccountQuotaWindow, :count, :id) == 0
  end

  test "refuses unsafe output paths, symlinks, and unjournaled collisions", context do
    outside_path =
      Path.join(System.tmp_dir!(), "outside-metered-quota-#{System.unique_integer()}.json")

    assert {:error, message} =
             MeteredQuotaFixture.status(Keyword.put(context.options, :receipt_path, outside_path))

    assert message =~ "inside"

    symlink_path = Path.join(context.root, "linked.json")
    File.ln_s!(Path.join(context.root, "missing-target.json"), symlink_path)

    assert {:error, message} =
             MeteredQuotaFixture.acquire(
               Keyword.put(context.options, :receipt_path, symlink_path)
             )

    assert message =~ "symlink"

    File.write!(context.receipt_path, "{}")
    File.chmod!(context.receipt_path, 0o600)
    assert {:error, message} = MeteredQuotaFixture.acquire(context.options)
    assert message =~ "invalid"
  end

  test "refuses insecure existing parent and receipt modes", context do
    File.chmod!(context.root, 0o755)
    assert {:error, message} = MeteredQuotaFixture.acquire(context.options)
    assert message =~ "0700"

    File.chmod!(context.root, 0o700)
    File.write!(context.receipt_path, "{}")
    File.chmod!(context.receipt_path, 0o644)
    assert {:error, message} = MeteredQuotaFixture.status(context.options)
    assert message =~ "0600"
  end

  defp file_mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
