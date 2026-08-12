defmodule CodexPooler.Gateway.Facade.TurnState do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPoolerWeb.Endpoint
  alias Plug.Crypto.MessageEncryptor

  @prefix "cpts_"
  @aad "codex-pooler:turn-state:v1"
  @version 1
  @ttl_seconds 86_400
  @max_raw_bytes 2_048
  @max_handle_bytes 4_096

  @type resolution :: %{
          required(:public) => String.t(),
          required(:upstream) => String.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          optional(:session_id) => Ecto.UUID.t() | nil
        }

  @spec mint(String.t(), CodexPooler.Access.auth_context(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid}
  def mint(raw, auth, assignment_id, opts \\ []) do
    with true <- valid_raw?(raw),
         {:ok, pool_id, api_key_id} <- auth_scope(auth),
         {:ok, assignment_id} <- canonical_uuid(assignment_id),
         {:ok, session_id} <- optional_uuid(Keyword.get(opts, :session_id)),
         now when is_integer(now) <- Keyword.get(opts, :now, System.system_time(:second)),
         ttl when is_integer(ttl) and ttl > 0 <- Keyword.get(opts, :ttl_seconds, @ttl_seconds) do
      payload = %{
        "v" => @version,
        "kind" => "turn_state",
        "raw" => raw,
        "pool_id" => pool_id,
        "api_key_id" => api_key_id,
        "assignment_id" => assignment_id,
        "session_id" => session_id,
        "exp" => now + ttl
      }

      encrypted =
        payload
        |> Jason.encode!()
        |> MessageEncryptor.encrypt(@aad, encryption_key(), "")

      handle = @prefix <> encrypted

      if byte_size(handle) <= @max_handle_bytes,
        do: {:ok, handle},
        else: {:error, :invalid}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @spec mint_for_context(String.t(), SelectedCandidateContext.t()) ::
          {:ok, String.t()} | {:error, :invalid}
  def mint_for_context(raw, %SelectedCandidateContext{} = context) do
    mint(raw, context.auth, context.assignment.id,
      session_id: session_id(context.request_options.continuity.codex_session)
    )
  end

  @spec resolve(String.t(), CodexPooler.Access.auth_context(), keyword()) ::
          {:ok, resolution()} | {:error, :invalid}
  def resolve(handle, auth, opts \\ [])

  def resolve(@prefix <> encrypted = public, auth, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with true <- is_integer(now),
         {:ok, pool_id, api_key_id} <- auth_scope(auth),
         true <- canonical_ciphertext?(encrypted),
         {:ok, encoded} <- MessageEncryptor.decrypt(encrypted, @aad, encryption_key(), ""),
         {:ok, payload} <- Jason.decode(encoded),
         :ok <- validate_payload(payload, pool_id, api_key_id, now) do
      {:ok,
       %{
         public: public,
         upstream: payload["raw"],
         assignment_id: payload["assignment_id"],
         session_id: payload["session_id"]
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def resolve(_handle, _auth, _opts), do: {:error, :invalid}

  defp validate_payload(payload, pool_id, api_key_id, now) do
    with %{
           "v" => @version,
           "kind" => "turn_state",
           "raw" => raw,
           "pool_id" => scoped_pool_id,
           "api_key_id" => scoped_api_key_id,
           "assignment_id" => assignment_id,
           "exp" => expiry
         } <- payload,
         true <- valid_raw?(raw),
         true <- secure_equal?(scoped_pool_id, pool_id),
         true <- secure_equal?(scoped_api_key_id, api_key_id),
         {:ok, _assignment_id} <- canonical_uuid(assignment_id),
         {:ok, _session_id} <- optional_uuid(Map.get(payload, "session_id")),
         true <- is_integer(expiry) and expiry > now do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp auth_scope(%{pool: %{id: pool_id}, api_key: %{id: api_key_id}}) do
    with {:ok, pool_id} <- canonical_uuid(pool_id),
         {:ok, api_key_id} <- canonical_uuid(api_key_id) do
      {:ok, pool_id, api_key_id}
    end
  end

  defp auth_scope(_auth), do: {:error, :invalid}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: canonical_uuid(value)

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} when canonical == value -> {:ok, canonical}
      _invalid -> {:error, :invalid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid}

  defp valid_raw?(raw),
    do: is_binary(raw) and byte_size(raw) > 0 and byte_size(raw) <= @max_raw_bytes

  defp canonical_ciphertext?("XCP." <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} -> Base.url_encode64(decoded, padding: false) == encoded
      :error -> false
    end
  end

  defp canonical_ciphertext?(_encrypted), do: false

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp session_id(%{id: id}) when is_binary(id), do: id
  defp session_id(_session), do: nil

  defp encryption_key do
    secret_key_base = Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret_key_base, @aad)
  end
end
