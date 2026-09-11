defmodule CodexPooler.OpenAIStatusTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Status.Schemas.{Dismissal, FeedState, Incident}

  test "changesets bound fields and reject unknown status" do
    now = DateTime.utc_now()

    assert %{valid?: false} =
             Incident.changeset(%Incident{}, %{
               guid: "",
               title: String.duplicate("x", 4_001),
               status: "Nope",
               summary: "",
               link: "https://status.openai.com/a",
               published_at: now,
               first_seen_at: now,
               last_seen_at: now,
               omission_count: 0,
               revision: 1,
               content_hash: "h",
               created_at: now,
               updated_at: now
             })
  end

  test "changeset rejects content beyond the normalized summary contract" do
    now = DateTime.utc_now()

    changeset =
      Incident.changeset(%Incident{}, %{
        guid: "summary-overflow",
        title: "Outage",
        status: "Investigating",
        summary: String.duplicate("x", 4_001),
        link: "https://status.openai.com/incidents/summary-overflow",
        published_at: now,
        first_seen_at: now,
        last_seen_at: now,
        omission_count: 0,
        revision: 1,
        content_hash: "hash",
        created_at: now,
        updated_at: now
      })

    assert %{summary: ["should be at most 4000 character(s)"]} = errors_on(changeset)
  end

  test "singleton state upsert and guid revision are idempotent" do
    now = DateTime.utc_now()
    assert {:ok, %FeedState{singleton: true}} = OpenAIStatus.upsert_feed_state(%{updated_at: now})

    attrs = %{
      guid: "fixture-guid",
      title: "Outage",
      status: "Investigating",
      summary: "safe summary",
      link: "https://status.openai.com/incidents/fixture",
      published_at: now,
      content_hash: "hash-1"
    }

    assert {:ok, first} = OpenAIStatus.upsert_incident(attrs, now)
    assert {:ok, same} = OpenAIStatus.upsert_incident(attrs, now)
    assert same.id == first.id
    assert same.revision == first.revision
    assert length(OpenAIStatus.list_incidents()) == 1

    assert {:ok, changed} = OpenAIStatus.upsert_incident(%{attrs | summary: "changed"}, now)
    assert changed.id == first.id
    assert changed.revision == first.revision + 1
  end

  test "dismissal is revision aware and cascades with incident" do
    now = DateTime.utc_now()
    operator_id = Ecto.UUID.generate()

    Repo.insert!(%CodexPooler.Accounts.User{
      id: operator_id,
      email: "status-#{System.unique_integer([:positive])}@example.com",
      password_hash: "test-hash",
      status: "active",
      created_at: now,
      updated_at: now
    })

    {:ok, incident} =
      OpenAIStatus.upsert_incident(
        %{
          guid: "dismiss-guid",
          title: "Outage",
          status: "Resolved",
          link: "https://status.openai.com/i",
          published_at: now,
          content_hash: "h"
        },
        now
      )

    assert {:ok, %Dismissal{}} =
             OpenAIStatus.dismiss(operator_id, incident.id, incident.revision, now)

    assert {:error, :invalid_revision} =
             OpenAIStatus.dismiss(operator_id, incident.id, incident.revision + 1, now)
  end

  test "normalizes status before comparison and keeps resolved lifecycle idempotent" do
    first_at = ~U[2026-09-10 10:00:00.000000Z]
    second_at = ~U[2026-09-10 10:01:00.000000Z]

    attrs = %{
      "guid" => "resolved-stable",
      "title" => "Outage",
      "status" => "resolved",
      "link" => "https://status.openai.com/incidents/resolved-stable",
      "published_at" => first_at,
      "content_hash" => "stable"
    }

    assert {:ok, first} = OpenAIStatus.upsert_incident(attrs, first_at)
    assert first.status == "Resolved"
    assert first.resolved_at == first_at
    assert {:ok, second} = OpenAIStatus.upsert_incident(attrs, second_at)
    assert second.revision == first.revision
    assert second.resolved_at == first_at
  end
end
