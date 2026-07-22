defmodule CodexPooler.Upstreams.SavedResets.ProbeLeaseTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @generation 3
  @attempt "attempt-abc"

  defp pending_fixture(opts \\ []) do
    consumed_at =
      Keyword.get_lazy(opts, :consumed_at, fn ->
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
      end)

    phase = Keyword.get(opts, :phase, "consumed_pending_probe")

    redemption =
      %{
        "status" => RedemptionLifecycle.legacy_status_for(phase) || "redeeming",
        "phase" => phase,
        "attempt_id" => Keyword.get(opts, :attempt_id, @attempt),
        "generation" => Keyword.get(opts, :generation, @generation),
        "trigger_kind" => "gateway_auto",
        "consumed_at" => DateTime.to_iso8601(consumed_at),
        "deadline_at" =>
          consumed_at |> RedemptionLifecycle.deadline_at() |> DateTime.to_iso8601(),
        "result" => %{"code" => "reset", "applied" => true}
      }
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    active_upstream_assignment_fixture(pool_fixture(), %{
      metadata: %{"saved_reset_redemption" => redemption}
    })
  end

  defp identity_with_pending(opts \\ []), do: pending_fixture(opts).identity

  defp bound_probe(assignment, identity, overrides \\ []) do
    assert {:ok, probe} =
             ResetProbe.new()
             |> ResetProbe.bind(
               assignment.id,
               identity.id,
               "gpt-5.4",
               "proxy_http"
             )

    struct!(probe, overrides)
  end

  defp redemption(identity),
    do: Repo.reload!(identity).metadata["saved_reset_redemption"]

  defp persist_redemption!(identity, redemption) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", redemption)
    })
    |> Repo.update!()
  end

  defp stale_v2_probe_fixture do
    now = ~U[2026-07-21 12:00:00.000000Z]
    %{assignment: foreign_assignment} = pending_fixture()
    %{identity: identity} = pending_fixture(consumed_at: now)
    probe = bound_probe(foreign_assignment, identity)

    persisted =
      redemption(identity)
      |> Map.put("probe", %{
        "version" => probe.version,
        "token" => probe.token,
        "claimed_at" => DateTime.to_iso8601(now),
        "scope" => %{
          "pool_upstream_assignment_id" => foreign_assignment.id,
          "upstream_identity_id" => identity.id,
          "effective_model" => probe.effective_model,
          "route_class" => probe.route_class
        }
      })

    persist_redemption!(identity, persisted)
    {identity, probe, persisted, now}
  end

  defp probe_holder(identity),
    do:
      RedemptionLifecycle.probe_holder(Repo.reload!(identity).metadata["saved_reset_redemption"])

  test "a fresh legacy token cannot create a new probe claim" do
    identity = identity_with_pending()

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation, @attempt, "token-A")

    assert probe_holder(identity) == nil
  end

  test "a bound v2 probe claim persists its exact immutable scope under the identity" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{assignment: assignment, identity: identity} = pending_fixture()
    probe = bound_probe(assignment, identity)

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe, now)

    assert redemption(identity)["probe"] == %{
             "claimed_at" => DateTime.to_iso8601(now),
             "scope" => %{
               "effective_model" => probe.effective_model,
               "pool_upstream_assignment_id" => assignment.id,
               "route_class" => probe.route_class,
               "upstream_identity_id" => identity.id
             },
             "token" => probe.token,
             "version" => 2
           }
  end

  test "a bound v2 probe with an assignment outside the locked identity cannot claim" do
    %{assignment: assignment, identity: identity} = pending_fixture()
    probe = bound_probe(assignment, identity, pool_upstream_assignment_id: Ecto.UUID.generate())
    persisted = redemption(identity)

    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, probe)
    assert redemption(identity) == persisted
  end

  test "the identical bound v2 probe re-claims without changing scope or lifecycle identity" do
    %{assignment: assignment, identity: identity} = pending_fixture()
    probe = bound_probe(assignment, identity)

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe)
    persisted = redemption(identity)

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe)
    assert redemption(identity) == persisted
  end

  test "a stale v2 claim bound to another identity's assignment cannot re-claim" do
    {identity, probe, persisted, now} = stale_v2_probe_fixture()

    assert {:error, :unavailable} =
             ProbeLease.claim(
               identity,
               @generation,
               @attempt,
               probe,
               DateTime.add(now, 1, :second)
             )

    assert redemption(identity) == persisted
  end

  test "a changed v2 scope cannot re-claim and leaves the persisted claim unchanged" do
    %{assignment: assignment, identity: identity} = pending_fixture()
    probe = bound_probe(assignment, identity)

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe)
    persisted = redemption(identity)

    mismatches = [
      %{probe | pool_upstream_assignment_id: Ecto.UUID.generate()},
      %{probe | upstream_identity_id: Ecto.UUID.generate()},
      %{probe | effective_model: "gpt-5.4-mini"},
      %{probe | route_class: "proxy_stream"}
    ]

    for mismatch <- mismatches do
      assert {:error, :unavailable} =
               ProbeLease.claim(identity, @generation, @attempt, mismatch)

      assert redemption(identity) == persisted
    end
  end

  test "a stale generation cannot claim the probe" do
    identity = identity_with_pending()

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation - 1, @attempt, "token-A")

    assert probe_holder(identity) == nil
  end

  test "a mismatched attempt cannot claim the probe" do
    identity = identity_with_pending()

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation, "other-attempt", "token-A")

    assert probe_holder(identity) == nil
  end

  test "a settled (confirmed) redemption is not probeable" do
    identity = identity_with_pending(phase: "confirmed_by_quota")

    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == nil
  end

  test "an elapsed bounded window is not probeable" do
    old = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity_with_pending(consumed_at: old)

    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == nil
  end

  test "v2 fresh and held claims require a persisted deadline strictly after now" do
    now = ~U[2026-07-21 12:00:00.000000Z]

    deadline_cases = [
      {:future, DateTime.to_iso8601(DateTime.add(now, 1, :second)), {:ok, :claimed}},
      {:missing, nil, {:error, :unavailable}},
      {:malformed, "not-a-datetime", {:error, :unavailable}},
      {:exact, DateTime.to_iso8601(now), {:error, :unavailable}},
      {:elapsed, DateTime.to_iso8601(DateTime.add(now, -1, :microsecond)), {:error, :unavailable}}
    ]

    for {deadline_name, deadline_at, expected} <- deadline_cases do
      %{assignment: assignment, identity: fresh_identity} = pending_fixture(consumed_at: now)
      fresh_probe = bound_probe(assignment, fresh_identity)

      fresh_redemption =
        case deadline_at do
          nil -> Map.delete(redemption(fresh_identity), "deadline_at")
          value -> Map.put(redemption(fresh_identity), "deadline_at", value)
        end

      persist_redemption!(Repo.reload!(fresh_identity), fresh_redemption)
      persisted_fresh = redemption(fresh_identity)

      assert ProbeLease.claim(fresh_identity, @generation, @attempt, fresh_probe, now) ==
               expected,
             "expected fresh #{deadline_name} deadline result"

      case expected do
        {:ok, :claimed} ->
          assert redemption(fresh_identity)["probe"]["token"] == fresh_probe.token

        {:error, :unavailable} ->
          assert redemption(fresh_identity) == persisted_fresh
      end

      %{assignment: assignment, identity: held_identity} = pending_fixture(consumed_at: now)
      held_probe = bound_probe(assignment, held_identity)

      assert {:ok, :claimed} =
               ProbeLease.claim(held_identity, @generation, @attempt, held_probe, now)

      held_redemption =
        case deadline_at do
          nil -> Map.delete(redemption(held_identity), "deadline_at")
          value -> Map.put(redemption(held_identity), "deadline_at", value)
        end

      persist_redemption!(Repo.reload!(held_identity), held_redemption)
      persisted_held = redemption(held_identity)

      assert ProbeLease.claim(held_identity, @generation, @attempt, held_probe, now) ==
               expected,
             "expected held #{deadline_name} deadline result"

      assert redemption(held_identity) == persisted_held
    end
  end

  test "legacy claims fail closed without a persisted deadline" do
    now = ~U[2026-07-21 12:00:00.000000Z]
    identity = identity_with_pending(consumed_at: now)

    missing_deadline =
      identity
      |> redemption()
      |> Map.delete("deadline_at")
      |> Map.put("probe", %{
        "claimed_at" => DateTime.to_iso8601(now),
        "token" => "legacy-token"
      })

    persist_redemption!(Repo.reload!(identity), missing_deadline)
    persisted = redemption(identity)

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation, @attempt, "legacy-token", now)

    assert redemption(identity) == persisted
  end

  test "a malformed legacy claimed_at fails confirmation closed without mutation" do
    now = ~U[2026-07-21 12:00:00.000000Z]
    identity = identity_with_pending(consumed_at: DateTime.add(now, -1, :minute))

    persisted =
      identity
      |> redemption()
      |> Map.put("probe", %{
        "claimed_at" => "not-a-datetime",
        "token" => "legacy-token"
      })

    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "legacy-token", now)
    assert redemption(identity) == persisted
  end

  test "a malformed legacy deadline_at fails confirmation closed without mutation" do
    now = ~U[2026-07-21 12:00:00.000000Z]
    identity = identity_with_pending(consumed_at: DateTime.add(now, -1, :minute))

    persisted =
      identity
      |> redemption()
      |> Map.put("deadline_at", "not-a-datetime")
      |> Map.put("probe", legacy_probe("legacy-token", DateTime.add(now, -1, :second)))

    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "legacy-token", now)
    assert redemption(identity) == persisted
  end

  test "a legacy confirmation at the exact deadline fails closed without mutation" do
    now = ~U[2026-07-21 12:00:00.000000Z]
    identity = identity_with_pending(consumed_at: DateTime.add(now, -1, :minute))

    persisted =
      identity
      |> redemption()
      |> Map.put("deadline_at", DateTime.to_iso8601(now))
      |> Map.put("probe", legacy_probe("legacy-token", DateTime.add(now, -1, :second)))

    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "legacy-token", now)
    assert redemption(identity) == persisted
  end

  test "a legacy confirmation after the deadline fails closed without mutation" do
    now = ~U[2026-07-21 12:00:00.000000Z]
    identity = identity_with_pending(consumed_at: DateTime.add(now, -1, :minute))

    persisted =
      identity
      |> redemption()
      |> Map.put(
        "deadline_at",
        now |> DateTime.add(-1, :microsecond) |> DateTime.to_iso8601()
      )
      |> Map.put("probe", legacy_probe("legacy-token", DateTime.add(now, -1, :second)))

    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "legacy-token", now)
    assert redemption(identity) == persisted
  end

  defp phase(identity),
    do: RedemptionLifecycle.phase(Repo.reload!(identity).metadata["saved_reset_redemption"])

  test "an already-held exact legacy claim reclaims and confirms before its deadline" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    identity = identity_with_pending(consumed_at: DateTime.add(now, -1, :minute))

    persisted =
      identity
      |> redemption()
      |> Map.put("probe", %{
        "claimed_at" => DateTime.to_iso8601(now),
        "token" => "legacy-token"
      })

    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :claimed} =
             ProbeLease.claim(identity, @generation, @attempt, "legacy-token", now)

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]

    assert redemption["probe"] == %{
             "claimed_at" => DateTime.to_iso8601(now),
             "token" => "legacy-token"
           }

    assert {:ok, :confirmed} =
             ProbeLease.confirm_upstream(identity, "legacy-token", DateTime.add(now, 1, :second))

    assert phase(identity) == "confirmed_by_upstream"
  end

  test "v2 confirmation requires generation, attempt, token, version, and every exact scope dimension" do
    cases = [
      {:generation, fn generation, attempt, probe -> {generation + 1, attempt, probe} end},
      {:attempt, fn generation, _attempt, probe -> {generation, "other-attempt", probe} end},
      {:token,
       fn generation, attempt, probe ->
         {generation, attempt, %{probe | token: Ecto.UUID.generate()}}
       end},
      {:version,
       fn generation, attempt, probe -> {generation, attempt, %{probe | version: 3}} end},
      {:assignment,
       fn generation, attempt, probe ->
         {generation, attempt, %{probe | pool_upstream_assignment_id: Ecto.UUID.generate()}}
       end},
      {:identity,
       fn generation, attempt, probe ->
         {generation, attempt, %{probe | upstream_identity_id: Ecto.UUID.generate()}}
       end},
      {:effective_model,
       fn generation, attempt, probe ->
         {generation, attempt, %{probe | effective_model: "gpt-5.4-mini"}}
       end},
      {:route_class,
       fn generation, attempt, probe ->
         {generation, attempt, %{probe | route_class: "proxy_stream"}}
       end}
    ]

    for {dimension, mismatch} <- cases do
      %{assignment: assignment, identity: identity} = pending_fixture()
      probe = bound_probe(assignment, identity)

      assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe)
      persisted = redemption(identity)
      {generation, attempt, confirmation_probe} = mismatch.(@generation, @attempt, probe)

      assert {:ok, :unchanged} =
               ProbeLease.confirm_upstream(
                 identity,
                 generation,
                 attempt,
                 confirmation_probe
               ),
             "expected #{dimension} mismatch to fail closed"

      assert redemption(identity) == persisted
    end
  end

  test "a stale v2 claim bound to another identity's assignment cannot confirm" do
    {identity, probe, persisted, now} = stale_v2_probe_fixture()

    assert {:ok, :unchanged} =
             ProbeLease.confirm_upstream(
               identity,
               @generation,
               @attempt,
               probe,
               DateTime.add(now, 1, :second)
             )

    assert redemption(identity) == persisted
    assert phase(identity) == "consumed_pending_probe"
  end

  test "malformed and partial persisted v2 claims fail closed without changing lifecycle facts" do
    malformed_probes = [
      nil,
      %{},
      %{"version" => 2},
      %{"version" => 2, "token" => Ecto.UUID.generate()},
      %{
        "version" => 2,
        "token" => Ecto.UUID.generate(),
        "claimed_at" => "not-a-datetime",
        "scope" => %{}
      },
      %{
        "version" => 99,
        "token" => Ecto.UUID.generate(),
        "claimed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "scope" => %{}
      }
    ]

    for malformed_probe <- malformed_probes do
      %{assignment: assignment, identity: identity} = pending_fixture()
      probe = bound_probe(assignment, identity)
      original = redemption(identity)
      malformed = Map.put(original, "probe", malformed_probe)
      persist_redemption!(identity, malformed)

      assert {:ok, :unchanged} =
               ProbeLease.confirm_upstream(identity, @generation, @attempt, probe)

      assert redemption(identity) == malformed
    end
  end

  test "v2 confirmation fails closed for terminal, duplicate, exact-deadline, and late events" do
    now = ~U[2026-07-21 12:00:00.000000Z]

    cases = [
      {:terminal, "confirmed_by_quota", DateTime.add(now, 1, :second)},
      {:exact_deadline, "consumed_pending_probe", DateTime.add(now, 15, :minute)},
      {:after_deadline, "consumed_pending_probe",
       now |> DateTime.add(15, :minute) |> DateTime.add(1, :microsecond)}
    ]

    for {event, phase, confirmation_time} <- cases do
      %{assignment: assignment, identity: identity} = pending_fixture(consumed_at: now)
      probe = bound_probe(assignment, identity)

      assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe, now)

      if phase != "consumed_pending_probe" do
        current = redemption(identity)

        persist_redemption!(
          Repo.reload!(identity),
          Map.merge(current, %{
            "phase" => phase,
            "status" => RedemptionLifecycle.legacy_status_for(phase)
          })
        )
      end

      persisted = redemption(identity)

      assert {:ok, :unchanged} =
               ProbeLease.confirm_upstream(
                 identity,
                 @generation,
                 @attempt,
                 probe,
                 confirmation_time
               ),
             "expected #{event} confirmation to fail closed"

      assert redemption(identity) == persisted
    end

    %{assignment: assignment, identity: identity} = pending_fixture(consumed_at: now)
    probe = bound_probe(assignment, identity)
    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe, now)

    assert {:ok, :confirmed} =
             ProbeLease.confirm_upstream(
               identity,
               @generation,
               @attempt,
               probe,
               now |> DateTime.add(15, :minute) |> DateTime.add(-1, :microsecond)
             )

    persisted = redemption(identity)

    assert {:ok, :unchanged} =
             ProbeLease.confirm_upstream(
               identity,
               @generation,
               @attempt,
               probe,
               DateTime.add(now, 2, :second)
             )

    assert redemption(identity) == persisted
  end

  test "v2 confirmation fails closed when the persisted deadline is malformed or missing" do
    now = ~U[2026-07-21 12:00:00.000000Z]

    for {deadline_name, deadline_at} <- [{:malformed, "not-a-datetime"}, {:missing, nil}] do
      %{assignment: assignment, identity: identity} = pending_fixture(consumed_at: now)
      probe = bound_probe(assignment, identity)

      assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, probe, now)

      corrupted =
        case deadline_at do
          nil -> Map.delete(redemption(identity), "deadline_at")
          value -> Map.put(redemption(identity), "deadline_at", value)
        end

      persist_redemption!(Repo.reload!(identity), corrupted)

      assert {:ok, :unchanged} =
               ProbeLease.confirm_upstream(
                 identity,
                 @generation,
                 @attempt,
                 probe,
                 DateTime.add(now, 1, :second)
               ),
             "expected #{deadline_name} deadline to fail closed"

      assert redemption(identity) == corrupted
    end
  end

  test "a successful probe confirms the holding token as upstream-confirmed" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    identity = identity_with_pending()
    persisted = Map.put(redemption(identity), "probe", legacy_probe("token-A", now))
    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :confirmed} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "confirmed_by_upstream"
  end

  test "a non-holding token cannot confirm the probe" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    identity = identity_with_pending()
    persisted = Map.put(redemption(identity), "probe", legacy_probe("token-A", now))
    persist_redemption!(Repo.reload!(identity), persisted)

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-B")
    assert phase(identity) == "consumed_pending_probe"
  end

  test "confirming an unclaimed probe is a no-op" do
    identity = identity_with_pending()

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "consumed_pending_probe"
  end

  test "a probe already settled by quota is not re-confirmed by a late success" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    identity =
      identity_with_pending(
        phase: "confirmed_by_quota",
        extra: %{"probe" => legacy_probe("token-A", now)}
      )

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "confirmed_by_quota"
  end

  defp legacy_probe(token, claimed_at) do
    %{"token" => token, "claimed_at" => DateTime.to_iso8601(claimed_at)}
  end
end
