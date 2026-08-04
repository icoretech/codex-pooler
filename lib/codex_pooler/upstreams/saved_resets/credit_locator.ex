defmodule CodexPooler.Upstreams.SavedResets.CreditLocator do
  @moduledoc false

  alias CodexPooler.Upstreams.SecretBox

  @purpose "saved_reset_redemption_target"
  @version 1
  @scope_prefix "saved_reset_scope_v1"
  @max_credit_id_bytes 1_024
  @max_endpoint_family_bytes 64
  @fingerprint_pattern ~r/\A[0-9a-f]{64}\z/

  @type binding :: %{
          required(:identity_id) => Ecto.UUID.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer(),
          required(:endpoint_family) => String.t(),
          required(:scope_fingerprint) => String.t()
        }

  @type locator_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec scope_fingerprint(String.t(), String.t(), String.t()) :: String.t()
  def scope_fingerprint(endpoint_family, consume_url, account_scope)
      when is_binary(endpoint_family) and is_binary(consume_url) and is_binary(account_scope) do
    [
      @scope_prefix,
      length_prefixed(endpoint_family),
      length_prefixed(consume_url),
      length_prefixed(account_scope)
    ]
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec seal(String.t(), binding()) :: {:ok, binary()} | {:error, locator_error()}
  def seal(credit_id, binding) do
    with :ok <- validate_credit_id(credit_id),
         {:ok, normalized} <- normalize_binding(binding),
         {:ok, plaintext} <- encode_payload(credit_id, normalized),
         {:ok, envelope} <- SecretBox.encrypt_envelope(plaintext, aad(normalized)) do
      {:ok, envelope}
    else
      _error -> invalid()
    end
  end

  @spec open(binary(), binding()) :: {:ok, String.t()} | {:error, locator_error()}
  def open(envelope, binding) when is_binary(envelope) do
    with {:ok, normalized} <- normalize_binding(binding),
         :ok <- validate_envelope_aad(envelope, normalized),
         {:ok, plaintext} <- SecretBox.decrypt_envelope(envelope),
         {:ok, payload} <- Jason.decode(plaintext),
         :ok <- validate_payload(payload, normalized),
         credit_id when is_binary(credit_id) <- payload["credit_id"],
         :ok <- validate_credit_id(credit_id) do
      {:ok, credit_id}
    else
      _error -> invalid()
    end
  end

  def open(_envelope, _binding), do: invalid()

  defp normalize_binding(%{
         identity_id: identity_id,
         attempt_id: attempt_id,
         generation: generation,
         endpoint_family: endpoint_family,
         scope_fingerprint: scope_fingerprint
       }) do
    with {:ok, identity_id} <- Ecto.UUID.cast(identity_id),
         {:ok, attempt_id} <- Ecto.UUID.cast(attempt_id),
         true <- is_integer(generation) and generation >= 0,
         true <-
           is_binary(endpoint_family) and byte_size(endpoint_family) > 0 and
             byte_size(endpoint_family) <= @max_endpoint_family_bytes,
         true <-
           is_binary(scope_fingerprint) and
             Regex.match?(@fingerprint_pattern, scope_fingerprint) do
      {:ok,
       %{
         identity_id: identity_id,
         attempt_id: attempt_id,
         generation: generation,
         endpoint_family: endpoint_family,
         scope_fingerprint: scope_fingerprint
       }}
    else
      _invalid -> invalid()
    end
  end

  defp normalize_binding(_binding), do: invalid()

  defp encode_payload(credit_id, binding) do
    binding
    |> payload_fields()
    |> Map.put("credit_id", credit_id)
    |> Jason.encode()
  end

  defp validate_payload(payload, binding) when is_map(payload) do
    expected_keys = Map.keys(payload_fields(binding)) ++ ["credit_id"]

    if Map.keys(payload) |> Enum.sort() == Enum.sort(expected_keys) and
         Map.take(payload, Map.keys(payload_fields(binding))) == payload_fields(binding) do
      :ok
    else
      invalid()
    end
  end

  defp validate_payload(_payload, _binding), do: invalid()

  defp payload_fields(binding) do
    %{
      "purpose" => @purpose,
      "version" => @version,
      "identity_id" => binding.identity_id,
      "attempt_id" => binding.attempt_id,
      "generation" => binding.generation,
      "endpoint_family" => binding.endpoint_family,
      "scope_fingerprint" => binding.scope_fingerprint
    }
  end

  defp aad(binding), do: payload_fields(binding)

  defp validate_envelope_aad(envelope, binding) do
    with {:ok, %{"aad" => %{"key_version" => key_version} = envelope_aad}} <-
           Jason.decode(envelope),
         true <- is_binary(key_version) and byte_size(key_version) in 1..64,
         true <- Map.delete(envelope_aad, "key_version") == aad(binding) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_credit_id(credit_id)
       when is_binary(credit_id) and byte_size(credit_id) > 0 and
              byte_size(credit_id) <= @max_credit_id_bytes,
       do: :ok

  defp validate_credit_id(_credit_id), do: invalid()

  defp length_prefixed(value), do: [<<byte_size(value)::unsigned-big-32>>, value]

  defp invalid do
    {:error,
     %{
       code: :saved_reset_credit_locator_invalid,
       message: "saved reset credit locator is invalid"
     }}
  end
end
