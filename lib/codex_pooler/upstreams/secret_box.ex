defmodule CodexPooler.Upstreams.SecretBox do
  @moduledoc """
  Narrow AES-GCM helper for upstream-owned secret-bearing fields.

  This is shared by durable upstream secret rows and transient OAuth flow state.
  Callers choose where the encrypted bytes are stored.
  """

  @secret_key_env "CODEX_POOLER_UPSTREAM_SECRET_KEY"
  @secret_key_bytes 32
  @secret_nonce_bytes 12
  @invalid_secret_key_message "#{@secret_key_env} must be 32 raw bytes or base64-encoded 32 bytes"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type encrypted_fields :: %{
          required(:ciphertext) => binary(),
          required(:nonce) => binary(),
          required(:aad) => map(),
          required(:key_version) => String.t()
        }

  @spec validate_secret_key!(binary() | nil) :: :ok
  def validate_secret_key!(configured_key) do
    case decode_secret_key(configured_key) do
      {:ok, _key} -> :ok
      {:error, _reason} -> raise @invalid_secret_key_message
    end
  end

  @spec encrypt_fields(binary(), map()) :: {:ok, encrypted_fields()} | {:error, lifecycle_error()}
  def encrypt_fields(plaintext, aad) when is_binary(plaintext) and is_map(aad) do
    with {:ok, key} <- secret_key() do
      key_version = secret_key_version()
      nonce = :crypto.strong_rand_bytes(@secret_nonce_bytes)
      aad = Map.put_new(aad, "key_version", key_version)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          aad_binary(aad),
          true
        )

      {:ok,
       %{
         ciphertext: IO.iodata_to_binary(tag) <> IO.iodata_to_binary(ciphertext),
         nonce: nonce,
         aad: aad,
         key_version: key_version
       }}
    end
  end

  def encrypt_fields(_plaintext, _aad) do
    {:error, lifecycle_error(:upstream_secret_plaintext_required, "plaintext secret is required")}
  end

  @spec decrypt_fields(map()) :: {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_fields(%{ciphertext: ciphertext, nonce: nonce, aad: aad})
      when is_binary(ciphertext) and is_binary(nonce) and is_map(aad) do
    with {:ok, key} <- secret_key(),
         <<tag::binary-size(16), encrypted::binary>> <- ciphertext,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             encrypted,
             aad_binary(aad),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error ->
        decryption_failed()

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error,
         lifecycle_error(
           :upstream_secret_invalid_ciphertext,
           "secret ciphertext is invalid"
         )}
    end
  end

  def decrypt_fields(_encrypted_fields), do: decryption_failed()

  @spec encrypt_envelope(binary(), map()) :: {:ok, binary()} | {:error, lifecycle_error()}
  def encrypt_envelope(plaintext, aad) when is_binary(plaintext) and is_map(aad) do
    with {:ok, fields} <- encrypt_fields(plaintext, aad) do
      encode_envelope(fields)
    end
  end

  def encrypt_envelope(_plaintext, _aad) do
    {:error, lifecycle_error(:upstream_secret_plaintext_required, "plaintext secret is required")}
  end

  @spec decrypt_envelope(binary()) :: {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_envelope(envelope) when is_binary(envelope) do
    with {:ok, fields} <- decode_envelope(envelope) do
      decrypt_fields(fields)
    end
  end

  def decrypt_envelope(_envelope), do: decryption_failed()

  @spec configured_key_version() :: String.t()
  def configured_key_version, do: secret_key_version()

  @spec configured_key_env() :: String.t()
  def configured_key_env, do: @secret_key_env

  @spec aad_binary(map()) :: binary()
  def aad_binary(aad) when is_map(aad) do
    aad
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> :erlang.term_to_binary()
  end

  defp decode_envelope(envelope) do
    with {:ok, decoded} <- CodexPooler.JSON.decode(envelope),
         %{"ciphertext" => ciphertext, "nonce" => nonce, "aad" => aad} <- decoded,
         {:ok, ciphertext} <- decode64_field(ciphertext),
         {:ok, nonce} <- decode64_field(nonce),
         true <- is_map(aad) do
      {:ok, %{ciphertext: ciphertext, nonce: nonce, aad: aad}}
    else
      _invalid -> invalid_ciphertext()
    end
  end

  defp encode_envelope(%{ciphertext: ciphertext, nonce: nonce, aad: aad})
       when is_binary(ciphertext) and is_binary(nonce) and is_map(aad) do
    %{
      "v" => 1,
      "ciphertext" => Base.encode64(ciphertext),
      "nonce" => Base.encode64(nonce),
      "aad" => aad
    }
    |> CodexPooler.JSON.encode()
    |> case do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> invalid_ciphertext()
    end
  end

  defp decode64_field(value) when is_binary(value), do: Base.decode64(value)
  defp decode64_field(_value), do: :error

  defp secret_key do
    configured =
      :codex_pooler
      |> Application.get_env(CodexPooler.Upstreams, [])
      |> Keyword.get(:upstream_secret_key)

    configured = configured || System.get_env(@secret_key_env)

    cond do
      is_binary(configured) ->
        decode_secret_key(configured)

      local_secret_key_fallback?() ->
        {:ok, :crypto.hash(:sha256, "codex-pooler-local-upstream-secret-key")}

      true ->
        {:error,
         lifecycle_error(
           :upstream_secret_key_missing,
           "#{@secret_key_env} must be configured before storing upstream secrets"
         )}
    end
  end

  defp secret_key_version do
    :codex_pooler
    |> Application.get_env(CodexPooler.Upstreams, [])
    |> Keyword.get(:upstream_secret_key_version, "v1")
  end

  defp decode_secret_key(key) when byte_size(key) == @secret_key_bytes, do: {:ok, key}

  defp decode_secret_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @secret_key_bytes ->
        {:ok, decoded}

      _invalid ->
        {:error,
         lifecycle_error(
           :upstream_secret_key_invalid,
           @invalid_secret_key_message
         )}
    end
  end

  defp decode_secret_key(_key) do
    {:error,
     lifecycle_error(
       :upstream_secret_key_invalid,
       @invalid_secret_key_message
     )}
  end

  defp local_secret_key_fallback? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() in [:dev, :test]
  end

  defp decryption_failed do
    {:error,
     lifecycle_error(
       :upstream_secret_decryption_failed,
       "secret could not be decrypted"
     )}
  end

  defp invalid_ciphertext do
    {:error,
     lifecycle_error(
       :upstream_secret_invalid_ciphertext,
       "secret ciphertext is invalid"
     )}
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
end
