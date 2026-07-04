defmodule CodexPooler.Accounts.MFA do
  @moduledoc false

  import Bitwise
  import Ecto.Changeset
  import Ecto.Query

  alias CodexPooler.Accounts.{AuditLog, OperatorEvents, RecoveryCode, TOTPSetting, User}
  alias CodexPooler.Repo

  @recovery_code_bytes 10
  @recovery_code_count 10
  @totp_secret_bytes 20
  @totp_period_seconds 30
  @totp_digits 6

  @spec enable_totp_for_user(User.t()) :: {:ok, map()} | {:error, term()}
  def enable_totp_for_user(%User{} = user) do
    secret = generate_totp_secret()
    encrypted_secret = encrypt_totp_secret!(secret)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      existing = Repo.get_by(TOTPSetting, user_id: user.id)
      recovery_generation = if existing, do: existing.recovery_generation + 1, else: 1

      setting_changes = %{
        secret_ciphertext: encrypted_secret,
        secret_key_version: totp_key_version(),
        recovery_generation: recovery_generation,
        status: "active",
        enrolled_at: now,
        verified_at: now,
        disabled_at: nil,
        updated_at: now
      }

      setting =
        if existing do
          existing
          |> change(setting_changes)
          |> Repo.update!()
        else
          %TOTPSetting{user_id: user.id, created_at: now}
          |> change(setting_changes)
          |> Repo.insert!()
        end

      revoke_recovery_codes(setting.id, now)
      codes = insert_recovery_codes(user, setting, now)

      AuditLog.record_user_event(user, %{
        action: "auth.totp_enrolled",
        target_type: "totp_setting",
        target_id: setting.id
      })

      %{secret: secret, recovery_codes: codes, setting: setting}
    end)
    |> broadcast_operator_mfa_change(user)
  end

  defp broadcast_operator_mfa_change({:ok, _result} = result, %User{id: user_id}) do
    _ = OperatorEvents.broadcast_update("operator.totp_update", %{operator_id: user_id})
    result
  end

  defp broadcast_operator_mfa_change(result, _user), do: result

  @spec totp_enabled?(User.t() | term()) :: boolean()
  def totp_enabled?(%User{id: user_id}) do
    Repo.exists?(
      from setting in TOTPSetting,
        where: setting.user_id == ^user_id and setting.status == "active"
    )
  end

  def totp_enabled?(_user), do: false

  @spec current_totp_code(binary()) :: String.t()
  def current_totp_code(secret) when is_binary(secret) do
    totp_code(secret, DateTime.utc_now())
  end

  @spec verify_second_factor(User.t(), term(), term(), map()) :: :ok | {:error, atom()}
  def verify_second_factor(%User{} = user, totp_code, recovery_code, metadata) do
    setting = Repo.get_by(TOTPSetting, user_id: user.id, status: "active")

    cond do
      is_nil(setting) ->
        :ok

      normalize_totp_code(totp_code) != "" ->
        secret = decrypt_totp_secret!(setting.secret_ciphertext)

        if valid_totp_code?(secret, totp_code) do
          :ok
        else
          {:error, :invalid_totp_code}
        end

      normalize_recovery_code(recovery_code) != "" ->
        consume_recovery_code(user, setting, recovery_code, metadata)

      true ->
        {:error, :totp_required}
    end
  end

  defp consume_recovery_code(user, setting, recovery_code, metadata) do
    now = DateTime.utc_now()
    code_hash = hash_recovery_code(recovery_code)

    {count, rows} =
      Repo.update_all(
        from(c in RecoveryCode,
          where:
            c.user_id == ^user.id and c.totp_setting_id == ^setting.id and c.status == "active" and
              c.code_hash == ^code_hash,
          select: c.id
        ),
        set: [status: "used", used_at: now]
      )

    case {count, rows} do
      {1, [code_id]} ->
        AuditLog.record_user_event(user, %{
          action: "auth.recovery_code_used",
          target_type: "recovery_code",
          target_id: code_id,
          metadata: metadata
        })

        :ok

      _ ->
        {:error, :invalid_recovery_code}
    end
  end

  defp revoke_recovery_codes(setting_id, now) do
    Repo.update_all(
      from(c in RecoveryCode, where: c.totp_setting_id == ^setting_id and c.status == "active"),
      set: [status: "revoked", used_at: now]
    )
  end

  defp insert_recovery_codes(user, setting, now) do
    codes = Enum.map(1..@recovery_code_count, fn _ -> generate_recovery_code() end)

    rows =
      Enum.map(codes, fn code ->
        %{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          totp_setting_id: setting.id,
          code_hash: hash_recovery_code(code),
          status: "active",
          created_at: now
        }
      end)

    Repo.insert_all(RecoveryCode, rows)
    codes
  end

  defp hash_recovery_code(code), do: :crypto.hash(:sha256, normalize_recovery_code(code))

  defp normalize_totp_code(code) do
    code
    |> to_string()
    |> String.replace(~r/\D/, "")
  end

  defp normalize_recovery_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace("-", "")
  end

  defp totp_key_version do
    config = Application.get_env(:codex_pooler, CodexPooler.Accounts, [])
    Keyword.get(config, :totp_key_version, "v1")
  end

  defp totp_encryption_key do
    config = Application.get_env(:codex_pooler, CodexPooler.Accounts, [])
    configured = Keyword.get(config, :totp_encryption_key)

    cond do
      is_binary(configured) and byte_size(configured) == 32 ->
        configured

      is_binary(configured) ->
        Base.decode64!(configured)

      true ->
        :crypto.hash(:sha256, "codex-pooler-local-totp-key")
    end
  end

  defp encrypt_totp_secret!(secret) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        totp_encryption_key(),
        nonce,
        secret,
        "totp",
        true
      )

    nonce <> tag <> ciphertext
  end

  defp decrypt_totp_secret!(<<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      totp_encryption_key(),
      nonce,
      ciphertext,
      "totp",
      tag,
      false
    )
  end

  defp generate_totp_secret do
    @totp_secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :upper, padding: false)
  end

  defp generate_recovery_code do
    raw =
      Base.encode32(:crypto.strong_rand_bytes(@recovery_code_bytes), case: :upper, padding: false)

    <<left::binary-size(4), mid::binary-size(4), right::binary-size(4), _rest::binary>> = raw
    Enum.join([left, mid, right], "-")
  end

  defp valid_totp_code?(secret, code) do
    normalized = normalize_totp_code(code)
    now = DateTime.utc_now()

    Enum.any?(-1..1, fn offset ->
      expected = totp_code(secret, DateTime.add(now, offset * @totp_period_seconds, :second))
      Plug.Crypto.secure_compare(expected, normalized)
    end)
  end

  defp totp_code(secret, %DateTime{} = at) do
    key = Base.decode32!(secret, case: :mixed, padding: false)
    counter = div(DateTime.to_unix(at), @totp_period_seconds)
    counter_binary = <<counter::unsigned-big-integer-size(64)>>
    hmac = :crypto.mac(:hmac, :sha, key, counter_binary)
    offset = :binary.last(hmac) &&& 0x0F
    part = binary_part(hmac, offset, 4)
    <<value::unsigned-big-integer-size(32)>> = part
    truncated = Bitwise.band(value, 0x7FFFFFFF)

    truncated
    |> rem(round(:math.pow(10, @totp_digits)))
    |> Integer.to_string()
    |> String.pad_leading(@totp_digits, "0")
  end
end
