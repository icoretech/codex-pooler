defmodule CodexPooler.Access.APIKeyDashboardPersistenceTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  describe "dashboard capability persistence" do
    test "persists dashboard access as disabled for new API keys" do
      %{api_key: api_key} = active_api_key_fixture()

      persisted = Repo.get!(APIKey, api_key.id)

      assert persisted.dashboard_access == false

      assert %{rows: [[false]]} =
               Repo.query!(
                 """
                 SELECT dashboard_access
                 FROM api_keys
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(api_key.id)]
               )
    end

    test "rejects a missing dashboard capability value" do
      %{api_key: api_key} = active_api_key_fixture()

      changeset = APIKey.changeset(api_key, %{dashboard_access: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).dashboard_access
    end
  end

  describe "dashboard session persistence" do
    test "persists only hashed key-scoped session state" do
      %{api_key: api_key} = active_api_key_fixture()

      assert APIKeyDashboardSession.__schema__(:fields) == [
               :id,
               :api_key_id,
               :token_hash,
               :expires_at,
               :inserted_at
             ]

      assert {:ok, session} =
               api_key.id
               |> session_changeset(session_attrs())
               |> Repo.insert()

      assert session.api_key_id == api_key.id
      assert byte_size(session.token_hash) == 32
      assert %DateTime{} = session.expires_at
      assert %DateTime{} = session.inserted_at
    end

    test "requires API key ownership, a session hash, and expiry" do
      missing_fields =
        nil
        |> session_changeset(%{})
        |> errors_on()

      assert "can't be blank" in missing_fields.api_key_id
      assert "can't be blank" in missing_fields.token_hash
      assert "can't be blank" in missing_fields.expires_at
    end

    test "rejects a blank session hash" do
      blank_hash =
        Ecto.UUID.generate()
        |> session_changeset(%{token_hash: "", expires_at: future_expiry()})
        |> errors_on()

      assert "can't be blank" in blank_hash.token_hash
    end

    test "rejects non-digest session material" do
      unhashed_material =
        Ecto.UUID.generate()
        |> session_changeset(%{
          token_hash: :crypto.strong_rand_bytes(48),
          expires_at: future_expiry()
        })
        |> errors_on()

      assert "must be a 32-byte digest" in unhashed_material.token_hash
    end

    test "does not substitute unsupported plaintext session material for a hash" do
      changeset =
        Ecto.UUID.generate()
        |> session_changeset(%{
          session_token: :crypto.strong_rand_bytes(48),
          expires_at: future_expiry()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).token_hash
    end

    test "does not accept API key ownership from session attributes" do
      canonical_api_key_id = Ecto.UUID.generate()

      changeset =
        canonical_api_key_id
        |> session_changeset(Map.put(session_attrs(), :api_key_id, Ecto.UUID.generate()))

      assert get_field(changeset, :api_key_id) == canonical_api_key_id
    end

    test "enforces globally unique session hashes" do
      %{api_key: api_key} = active_api_key_fixture()
      attrs = session_attrs()

      assert {:ok, _session} =
               api_key.id
               |> session_changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               api_key.id
               |> session_changeset(attrs)
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token_hash
    end

    test "enforces the session hash shape at the database boundary" do
      %{api_key: api_key} = active_api_key_fixture()

      assert {:error, changeset} =
               api_key.id
               |> session_changeset(session_attrs())
               |> put_change(:token_hash, :crypto.strong_rand_bytes(31))
               |> Repo.insert()

      assert "is invalid" in errors_on(changeset).token_hash
    end

    test "rejects an unknown API key at the database boundary" do
      assert {:error, changeset} =
               Ecto.UUID.generate()
               |> session_changeset(session_attrs())
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).api_key_id
    end

    test "deletes sessions when their API key is deleted" do
      %{api_key: api_key} = active_api_key_fixture()

      session =
        api_key.id
        |> session_changeset(session_attrs())
        |> Repo.insert!()

      Repo.delete!(api_key)

      refute Repo.get(APIKeyDashboardSession, session.id)
    end
  end

  defp session_changeset(api_key_id, attrs) do
    APIKeyDashboardSession
    |> struct(api_key_id: api_key_id)
    |> APIKeyDashboardSession.changeset(attrs)
  end

  defp session_attrs do
    %{
      token_hash: :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)),
      expires_at: future_expiry()
    }
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.add(3_600, :second)
    |> DateTime.truncate(:microsecond)
  end
end
