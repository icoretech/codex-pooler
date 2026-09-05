defmodule CodexPooler.Accounting.WebsocketOwnerBindingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexTurn}
  alias CodexPooler.Gateway.Websocket

  test "persists the trusted owner binding once and rejects a different downstream" do
    fixture = fixture()
    assert {:ok, bound} = bind(fixture)
    assert bound.request_metadata["websocket_owner_forwarding"] == expected_binding(fixture)
    assert Repo.reload!(fixture.request).request_metadata == bound.request_metadata
    assert {:ok, repeated} = bind(fixture)
    assert repeated.request_metadata == bound.request_metadata

    changed = RequestOptions.put_transport(fixture.options, websocket_owner_downstream_epoch: 2)
    assert {:error, :stale_websocket_owner_binding} = bind(%{fixture | options: changed})
    assert Repo.reload!(fixture.request).request_metadata == bound.request_metadata
  end

  for invalid <- [
        :released_lease,
        :expired_lease,
        :wrong_lease,
        :closed_session,
        :expired_session,
        :key_epoch,
        :terminal_request,
        :terminal_attempt,
        :replacement_attempt
      ] do
    test "rejects #{invalid} without changing request metadata" do
      fixture = fixture()
      invalidate(fixture, unquote(invalid))
      before = Repo.reload!(fixture.request)
      assert {:error, :stale_websocket_owner_binding} = bind(fixture)
      assert Repo.reload!(fixture.request) == before
    end
  end

  test "rejects another authenticated scope without changing either request" do
    fixture = fixture()
    foreign = accounting_setup(%{price_version: "foreign-#{System.unique_integer([:positive])}"})
    assert {:error, :stale_websocket_owner_binding} = bind(%{fixture | auth: foreign.auth})
    assert Repo.reload!(fixture.request).request_metadata == %{}
  end

  test "historical released leases do not replace the current exact lease" do
    fixture = fixture()
    lease = Repo.get_by!(BridgeOwnerLease, codex_session_id: fixture.session.id)

    for status <- ["released", "expired"] do
      lease
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id])
      |> Map.merge(%{
        lease_token: Ecto.UUID.generate(),
        status: status,
        expires_at: past(),
        released_at: past()
      })
      |> then(&struct!(BridgeOwnerLease, &1))
      |> Repo.insert!()
    end

    assert {:ok, request} = bind(fixture)
    assert request.request_metadata["websocket_owner_forwarding"] == expected_binding(fixture)
  end

  defp fixture do
    setup = accounting_setup()
    assert {:ok, session} = Websocket.start_codex_session(setup.auth, %{})

    request =
      request_fixture(setup, %{status: "in_progress", completed_at: nil, transport: "http_sse"})

    attempt =
      attempt_fixture(request, setup.assignment, %{status: "in_progress", completed_at: nil})

    now = DateTime.utc_now()

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "http_sse",
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })

    options =
      Websocket.websocket_owner_response_options(%{}, session, session.owner_lease_token, %{
        pid: self(),
        epoch: 1,
        correlation_id: Ecto.UUID.generate()
      })

    Map.merge(setup, %{session: session, request: request, attempt: attempt, options: options})
  end

  defp bind(fixture),
    do:
      Accounting.bind_websocket_owner(
        fixture.auth,
        fixture.request,
        fixture.attempt,
        fixture.options
      )

  defp expected_binding(fixture) do
    %{
      "enabled" => true,
      "downstream_epoch" => 1,
      "owner_instance_id" => fixture.session.owner_instance_id,
      "proxy_instance_id" => Atom.to_string(node())
    }
  end

  defp invalidate(fixture, :released_lease), do: change_lease(fixture, status: "released")
  defp invalidate(fixture, :expired_lease), do: change_lease(fixture, expires_at: past())

  defp invalidate(fixture, :wrong_lease),
    do: change_lease(fixture, lease_token: Ecto.UUID.generate())

  defp invalidate(fixture, :closed_session), do: update_row(fixture.session, status: "closed")

  defp invalidate(fixture, :expired_session),
    do: update_row(fixture.session, owner_lease_expires_at: past())

  defp invalidate(fixture, :key_epoch),
    do: update_row(fixture.api_key, runtime_revocation_epoch: 1)

  defp invalidate(fixture, :terminal_request),
    do: update_row(fixture.request, status: "failed", completed_at: past())

  defp invalidate(fixture, :terminal_attempt),
    do: update_row(fixture.attempt, status: "failed", completed_at: past())

  defp invalidate(fixture, :replacement_attempt) do
    attempt_fixture(fixture.request, fixture.assignment, %{
      attempt_number: 2,
      status: "in_progress",
      completed_at: nil
    })
  end

  defp change_lease(fixture, attrs),
    do:
      fixture.session.id
      |> then(&Repo.get_by!(BridgeOwnerLease, codex_session_id: &1))
      |> update_row(attrs)

  defp update_row(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
  defp past, do: DateTime.add(DateTime.utc_now(), -60, :second)
end
