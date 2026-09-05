defmodule CodexPooler.Upstreams.CredentialExpiryConsumersTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  test "secret status uses only the canonical expiry projection after lifecycle priority" do
    configure_upstream_secret_key!()
    now = now()
    past = DateTime.add(now, -1, :hour)
    future = DateTime.add(now, 1, :day)

    cases = [
      {:trusted_past, trusted_metadata(past), true, :expired},
      {:trusted_past_without_secret, trusted_metadata(past), false, :expired},
      {:trusted_future, trusted_metadata(future), true, :present},
      {:trusted_future_without_secret, trusted_metadata(future), false, :missing},
      {:trusted_unknown, unknown_metadata(), true, :present},
      {:trusted_unknown_without_secret, unknown_metadata(), false, :missing},
      {:legacy_past, %{"access_token_expires_at" => DateTime.to_iso8601(past)}, true, :expired},
      {:legacy_future_epoch_one,
       %{"credential_epoch" => 1, "secret_expires_at" => DateTime.to_iso8601(future)}, true,
       :present},
      {:canonical_raw_key_wins_even_when_invalid,
       %{
         "access_token_expires_at" => "invalid",
         "secret_expires_at" => DateTime.to_iso8601(past)
       }, true, :present},
      {:present_null_refresh_disables_legacy_fallback,
       %{
         "access_token_expires_at" => DateTime.to_iso8601(past),
         "token_refresh" => nil
       }, true, :present},
      {:present_scalar_refresh_disables_legacy_fallback,
       %{
         "access_token_expires_at" => DateTime.to_iso8601(past),
         "token_refresh" => "old-writer"
       }, true, :present},
      {:present_list_refresh_disables_legacy_fallback,
       %{
         "secret_expires_at" => DateTime.to_iso8601(past),
         "token_refresh" => []
       }, true, :present},
      {:markerless_refresh_map_disables_legacy_fallback,
       %{
         "access_token_expires_at" => DateTime.to_iso8601(past),
         "token_refresh" => %{}
       }, true, :present},
      {:mismatched_marker_disables_raw_fallback,
       trusted_metadata(past)
       |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], 2), true,
       :present},
      {:future_marker_with_extra_key_is_untrusted,
       trusted_metadata(future)
       |> put_in(["token_refresh", "access_token_expiry", "extra"], true), false, :missing},
      {:epoch_two_without_marker_disables_legacy_fallback,
       %{
         "credential_epoch" => 2,
         "access_token_expires_at" => DateTime.to_iso8601(past)
       }, true, :present}
    ]

    for {label, metadata, secret?, expected} <- cases do
      identity = active_upstream_identity_fixture(metadata: metadata)

      if secret? do
        store_access_token!(identity, Atom.to_string(label))
      end

      assert Secrets.secret_status(identity) == expected, "unexpected status for #{label}"
    end

    for {status, expected} <- [
          {"reauth_required", :reauth_required},
          {"refresh_due", :refresh_due},
          {"deleted", :missing}
        ] do
      identity =
        active_upstream_identity_fixture(metadata: trusted_metadata(past))
        |> update_identity!(%{status: status})

      store_access_token!(identity, status)
      assert Secrets.secret_status(identity) == expected
    end
  end

  test "usage 401 refresh policy classifies expiry through the canonical projection" do
    observed_at = now()
    future = DateTime.add(observed_at, 1, :day)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {401, %{"error" => "unauthorized"}},
           "/backend-api/codex/usage" => {401, %{"error" => "unauthorized"}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment, access_token: access_token} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          trusted_metadata(future)
          |> Map.put("usage_base_url", FakeUpstream.url(fake))
          |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], 2)
      })

    assert {:error, {:upstream_status, 401}} =
             UsageProbe.fetch(identity, assignment, access_token, observed_at, [])
  end

  test "pause and reactivate preserve trusted expiry while advancing its epoch" do
    transition_at = now()
    future = DateTime.add(transition_at, 1, :day)
    %{scope: scope, identity: identity} = lifecycle_fixture(trusted_metadata(future))
    original = TokenRefreshMetadata.project_access_token_expiry(identity.metadata)

    assert {:ok, %{status: :paused, identity: paused, secret_status: :present}} =
             Upstreams.pause_account_for_scope(scope, identity, %{
               paused_at: transition_at,
               reason: "captured-time-pause"
             })

    assert paused.metadata["credential_epoch"] == 2

    assert get_in(paused.metadata, ["token_refresh", "access_token_expiry", "credential_epoch"]) ==
             2

    assert TokenRefreshMetadata.project_access_token_expiry(paused.metadata) == original

    assert {:ok, %{status: :active, identity: active, secret_status: :present}} =
             Upstreams.reactivate_account_for_scope(scope, paused, %{
               reactivated_at: transition_at
             })

    assert active.metadata["credential_epoch"] == 3

    assert get_in(active.metadata, ["token_refresh", "access_token_expiry", "credential_epoch"]) ==
             3

    assert TokenRefreshMetadata.project_access_token_expiry(active.metadata) == original
  end

  test "reactivation blocks a credential that expired while paused" do
    reactivated_at = now()
    paused_at = DateTime.add(reactivated_at, -2, :hour)
    deadline = DateTime.add(reactivated_at, -1, :hour)
    %{scope: scope, identity: identity} = lifecycle_fixture(trusted_metadata(deadline))

    assert DateTime.compare(paused_at, deadline) == :lt
    assert DateTime.compare(deadline, reactivated_at) in [:lt, :eq]

    assert {:ok, %{status: :paused, identity: paused, secret_status: :expired}} =
             Upstreams.pause_account_for_scope(scope, identity, %{
               paused_at: paused_at
             })

    assert TokenRefreshMetadata.project_access_token_expiry(paused.metadata).deadline == deadline

    assert {:error, %{code: :upstream_secret_not_routable, message: message}} =
             Upstreams.reactivate_account_for_scope(scope, paused, %{
               reactivated_at: reactivated_at
             })

    assert message == "upstream access token is expired"
    assert Repo.reload!(paused).status == "paused"
  end

  test "lifecycle epoch changes never rebind an untrusted marker" do
    transition_at = now()
    future = DateTime.add(transition_at, 1, :day)

    untrusted =
      trusted_metadata(future)
      |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], 7)

    %{scope: scope, identity: identity} = lifecycle_fixture(untrusted)
    original_refresh = Map.delete(identity.metadata["token_refresh"], "access_token_expiry")

    assert {:ok, %{identity: paused, secret_status: :present}} =
             Upstreams.pause_account_for_scope(scope, identity, %{paused_at: transition_at})

    assert paused.metadata["credential_epoch"] == 2
    assert Map.delete(paused.metadata["token_refresh"], "access_token_expiry") == original_refresh

    assert get_in(paused.metadata, ["token_refresh", "access_token_expiry"]) == %{
             "version" => 1,
             "credential_epoch" => 2,
             "state" => "unknown",
             "source" => "unavailable"
           }

    assert TokenRefreshMetadata.project_access_token_expiry(paused.metadata).state == :unknown
  end

  for action <- [:pause, :reactivate], epoch <- [nil, "2", %{"value" => 2}, 0, -1] do
    test "#{action} rejects persisted malformed epoch #{inspect(epoch)} before any mutation" do
      assert_invalid_lifecycle_epoch(unquote(action), unquote(Macro.escape(epoch)))
    end
  end

  for action <- [:pause, :reactivate] do
    test "#{action} preserves missing legacy epoch support" do
      %{scope: scope, identity: identity} = lifecycle_fixture(%{})
      identity = prepare_lifecycle_identity(identity, unquote(action), %{})
      assert {:ok, %{identity: changed}} = lifecycle_action(unquote(action), scope, identity)
      assert changed.metadata["credential_epoch"] == 2
    end

    test "#{action} cannot promote a next epoch mismatched expiry marker" do
      for marker_epoch <- [1, 3, 7], marker_state <- [:known, :unknown] do
        metadata =
          if marker_state == :known,
            do: trusted_metadata(DateTime.add(now(), 1, :day)),
            else: unknown_metadata()

        metadata =
          metadata
          |> Map.put("credential_epoch", 2)
          |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], marker_epoch)

        %{scope: scope, identity: identity} = lifecycle_fixture(%{})
        identity = prepare_lifecycle_identity(identity, unquote(action), metadata)

        assert TokenRefreshMetadata.project_access_token_expiry(identity.metadata).state ==
                 :unknown

        assert {:ok, %{identity: changed}} = lifecycle_action(unquote(action), scope, identity)
        assert changed.metadata["credential_epoch"] == 3

        assert TokenRefreshMetadata.project_access_token_expiry(changed.metadata).state ==
                 :unknown

        assert {:ok, %{identity: repeated}} = lifecycle_action(unquote(action), scope, changed)

        assert TokenRefreshMetadata.project_access_token_expiry(repeated.metadata).state ==
                 :unknown
      end
    end
  end

  test "missing root does not grant trust to either current or next marker epoch" do
    for action <- [:pause, :reactivate],
        marker_epoch <- [1, 2],
        marker_state <- [:known, :unknown] do
      metadata =
        if marker_state == :known,
          do: trusted_metadata(DateTime.add(now(), 1, :day)),
          else: unknown_metadata()

      metadata =
        metadata
        |> Map.delete("credential_epoch")
        |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], marker_epoch)

      %{scope: scope, identity: identity} = lifecycle_fixture(%{})
      identity = prepare_lifecycle_identity(identity, action, metadata)
      assert TokenRefreshMetadata.project_access_token_expiry(identity.metadata).state == :unknown
      assert {:ok, %{identity: changed}} = lifecycle_action(action, scope, identity)
      assert changed.metadata["credential_epoch"] == 2
      assert TokenRefreshMetadata.project_access_token_expiry(changed.metadata).state == :unknown
      assert {:ok, %{identity: repeated}} = lifecycle_action(action, scope, changed)
      assert TokenRefreshMetadata.project_access_token_expiry(repeated.metadata).state == :unknown
    end
  end

  test "reactivation status rejection retains precedence over malformed epoch" do
    %{scope: scope, identity: identity} = lifecycle_fixture(%{})

    identity =
      update_identity!(identity, %{
        status: "reauth_required",
        metadata: %{"credential_epoch" => nil}
      })

    before = lifecycle_snapshot(identity)

    assert {:error, %{code: :upstream_identity_not_reactivatable}} =
             Upstreams.reactivate_account_for_scope(scope, identity, %{})

    assert lifecycle_snapshot(identity) == before
  end

  test "legacy known expiry survives a lifecycle advance only from an eligible original epoch" do
    deadline = DateTime.add(now(), 1, :day)

    for root <- [:absent, 1, 2] do
      metadata = %{"secret_expires_at" => DateTime.to_iso8601(deadline)}

      metadata =
        if root == :absent, do: metadata, else: Map.put(metadata, "credential_epoch", root)

      %{scope: scope, identity: identity} = lifecycle_fixture(%{})
      identity = prepare_lifecycle_identity(identity, :pause, metadata)
      original = TokenRefreshMetadata.project_access_token_expiry(identity.metadata)
      assert {:ok, %{identity: paused}} = lifecycle_action(:pause, scope, identity)
      assert TokenRefreshMetadata.project_access_token_expiry(paused.metadata) == original
      assert {:ok, %{identity: active}} = lifecycle_action(:reactivate, scope, paused)
      assert TokenRefreshMetadata.project_access_token_expiry(active.metadata) == original
    end
  end

  defp assert_invalid_lifecycle_epoch(action, epoch) do
    metadata = %{
      "credential_epoch" => epoch,
      "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now(), 1, :day))
    }

    %{scope: scope, identity: identity} = lifecycle_fixture(%{})
    identity = prepare_lifecycle_identity(identity, action, metadata)
    before = lifecycle_snapshot(identity)
    assert TokenRefreshMetadata.project_access_token_expiry(identity.metadata).state == :unknown

    assert {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}} =
             lifecycle_action(action, scope, identity)

    assert lifecycle_snapshot(identity) == before

    assert TokenRefreshMetadata.project_access_token_expiry(Repo.reload!(identity).metadata).state ==
             :unknown
  end

  defp prepare_lifecycle_identity(identity, action, metadata) do
    status = if action == :reactivate, do: "paused", else: "active"
    update_identity!(identity, %{status: status, metadata: metadata})
  end

  defp lifecycle_action(:pause, scope, identity),
    do: Upstreams.pause_account_for_scope(scope, identity, %{})

  defp lifecycle_action(:reactivate, scope, identity),
    do: Upstreams.reactivate_account_for_scope(scope, identity, %{})

  defp lifecycle_snapshot(identity) do
    %{
      identity: Repo.reload!(identity),
      assignments:
        Repo.all(
          from a in PoolUpstreamAssignment,
            where: a.upstream_identity_id == ^identity.id,
            order_by: a.id
        ),
      secrets:
        Repo.all(
          from s in EncryptedSecret, where: s.upstream_identity_id == ^identity.id, order_by: s.id
        )
    }
  end

  defp lifecycle_fixture(metadata) do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture()
    identity = active_upstream_identity_fixture(metadata: metadata)
    store_access_token!(identity, "lifecycle")

    assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity, %{})
    assert {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)

    %{scope: scope, identity: Repo.reload!(identity)}
  end

  defp store_access_token!(identity, suffix) do
    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "synthetic-access-token-#{suffix}-#{System.unique_integer([:positive])}"
             })
  end

  defp update_identity!(identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(Map.put(attrs, :updated_at, now()))
    |> Repo.update!()
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "t17-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end

  defp trusted_metadata(deadline) do
    %{
      "credential_epoch" => 1,
      "access_token_expires_at" => DateTime.to_iso8601(deadline),
      "token_refresh" => %{
        "status" => "imported",
        "generation" => 1,
        "access_token_expiry" => %{
          "version" => 1,
          "credential_epoch" => 1,
          "state" => "known",
          "source" => "explicit"
        }
      }
    }
  end

  defp unknown_metadata do
    %{
      "credential_epoch" => 1,
      "token_refresh" => %{
        "status" => "imported",
        "generation" => 1,
        "access_token_expiry" => %{
          "version" => 1,
          "credential_epoch" => 1,
          "state" => "unknown",
          "source" => "unavailable"
        }
      }
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
