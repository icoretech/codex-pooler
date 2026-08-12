defmodule CodexPooler.Gateway.Facade.FileCapability do
  @moduledoc false

  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Files.UploadUrlPolicy
  alias CodexPoolerWeb.Endpoint
  alias Plug.Crypto.MessageEncryptor

  @prefix "cpfc_"
  @path_prefix "/file-capabilities/"
  @aad "codex-pooler:file-capability:v1"
  @version 1
  @max_url_bytes 4_096
  @max_file_id_bytes 512
  @max_handle_bytes 8_192
  @kinds ~w(upload download)

  @type kind :: :upload | :download
  @type resolution :: %{
          required(:url) => String.t(),
          required(:kind) => kind(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:file_id) => String.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          required(:identity_id) => Ecto.UUID.t(),
          required(:byte_size) => pos_integer(),
          required(:expires_at) => integer()
        }

  @spec mint(String.t(), FileRecord.t(), kind(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid}
  def mint(url, %FileRecord{} = file, kind, opts \\ []) when kind in [:upload, :download] do
    now = Keyword.get(opts, :now, System.system_time(:second))
    expires_at = Keyword.get(opts, :expires_at, DateTime.to_unix(file.expires_at))
    origin = Keyword.get(opts, :origin)
    kind = Atom.to_string(kind)

    with true <- is_integer(now),
         true <- is_integer(expires_at) and expires_at > now,
         {:ok, origin} <- validate_origin(origin),
         true <- valid_url?(url),
         :ok <- UploadUrlPolicy.validate(url),
         true <- valid_file_id?(file.file_id),
         true <- is_integer(file.byte_size) and file.byte_size > 0,
         {:ok, pool_id} <- canonical_uuid(file.pool_id),
         {:ok, api_key_id} <- canonical_uuid(file.api_key_id),
         {:ok, assignment_id} <- canonical_uuid(file.pool_upstream_assignment_id),
         {:ok, identity_id} <- canonical_uuid(file.upstream_identity_id) do
      payload = %{
        "v" => @version,
        "kind" => kind,
        "url" => url,
        "pool_id" => pool_id,
        "api_key_id" => api_key_id,
        "file_id" => file.file_id,
        "assignment_id" => assignment_id,
        "identity_id" => identity_id,
        "byte_size" => file.byte_size,
        "exp" => expires_at
      }

      encrypted =
        payload
        |> Jason.encode!()
        |> MessageEncryptor.encrypt(@aad, encryption_key(), "")

      handle = @prefix <> encrypted

      if byte_size(handle) <= @max_handle_bytes,
        do: {:ok, local_url(origin, handle)},
        else: {:error, :invalid}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @spec resolve(String.t(), kind(), keyword()) ::
          {:ok, resolution()} | {:error, :invalid}
  def resolve(handle_or_url, kind, opts \\ []) when kind in [:upload, :download] do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with true <- is_integer(now),
         {:ok, encrypted} <- encrypted_token(handle_or_url),
         true <- canonical_ciphertext?(encrypted),
         {:ok, encoded} <- MessageEncryptor.decrypt(encrypted, @aad, encryption_key(), ""),
         {:ok, payload} <- Jason.decode(encoded),
         :ok <- validate_payload(payload, Atom.to_string(kind), now) do
      {:ok,
       %{
         url: payload["url"],
         kind: kind,
         pool_id: payload["pool_id"],
         api_key_id: payload["api_key_id"],
         file_id: payload["file_id"],
         assignment_id: payload["assignment_id"],
         identity_id: payload["identity_id"],
         byte_size: payload["byte_size"],
         expires_at: payload["exp"]
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @spec local_url?(term(), kind()) :: boolean()
  def local_url?(value, kind) when is_binary(value) and kind in [:upload, :download] do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, path: @path_prefix <> token}
      when is_binary(scheme) and is_binary(host) and byte_size(token) > 0 ->
        String.downcase(scheme) in ["http", "https"] and
          String.starts_with?(token, @prefix) and match?({:ok, _resolution}, resolve(token, kind))

      _other ->
        false
    end
  rescue
    _exception -> false
  end

  def local_url?(_value, _kind), do: false

  defp validate_payload(payload, expected_kind, now) do
    with %{
           "v" => @version,
           "kind" => kind,
           "url" => url,
           "pool_id" => pool_id,
           "api_key_id" => api_key_id,
           "file_id" => file_id,
           "assignment_id" => assignment_id,
           "identity_id" => identity_id,
           "byte_size" => byte_size,
           "exp" => expires_at
         } <- payload,
         true <- kind in @kinds and secure_equal?(kind, expected_kind),
         true <- valid_url?(url),
         :ok <- UploadUrlPolicy.validate(url),
         true <- valid_file_id?(file_id),
         {:ok, _pool_id} <- canonical_uuid(pool_id),
         {:ok, _api_key_id} <- canonical_uuid(api_key_id),
         {:ok, _assignment_id} <- canonical_uuid(assignment_id),
         {:ok, _identity_id} <- canonical_uuid(identity_id),
         true <- is_integer(byte_size) and byte_size > 0,
         true <- is_integer(expires_at) and expires_at > now do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp encrypted_token(@prefix <> encrypted) when byte_size(encrypted) > 0,
    do: {:ok, encrypted}

  defp encrypted_token(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{path: @path_prefix <> token} -> encrypted_token(token)
      _other -> {:error, :invalid}
    end
  end

  defp encrypted_token(_value), do: {:error, :invalid}

  defp canonical_ciphertext?("XCP." <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} -> Base.url_encode64(decoded, padding: false) == encoded
      :error -> false
    end
  end

  defp canonical_ciphertext?(_encrypted), do: false

  defp local_url(origin, handle) do
    String.trim_trailing(origin, "/") <> @path_prefix <> handle
  end

  defp validate_origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, ""] ->
        {:ok, String.trim_trailing(origin, "/")}

      _invalid ->
        {:error, :invalid}
    end
  end

  defp validate_origin(_origin), do: {:error, :invalid}

  defp valid_url?(url),
    do: is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @max_url_bytes

  defp valid_file_id?(file_id),
    do: is_binary(file_id) and byte_size(file_id) > 0 and byte_size(file_id) <= @max_file_id_bytes

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} when canonical == value -> {:ok, canonical}
      _invalid -> {:error, :invalid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid}

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp encryption_key do
    secret_key_base = Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret_key_base, @aad)
  end
end
