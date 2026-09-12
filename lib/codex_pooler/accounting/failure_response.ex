defmodule CodexPooler.Accounting.FailureResponse do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting.{Attempt, Request}

  @max_failure_reason_bytes 80

  @type gateway_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @spec accounting_failure(atom(), Request.t() | term(), Attempt.t() | nil, term()) ::
          {:error, gateway_error()}
  def accounting_failure(operation, request, attempt, reason) do
    Logger.error([
      "gateway accounting finalization failed",
      " operation=#{operation}",
      " request_id=#{record_id(request) || "unknown"}",
      " attempt_id=#{record_id(attempt) || "unknown"}",
      " reason=#{safe_failure_reason(reason)}"
    ])

    {:error,
     %{
       status: 500,
       code: "gateway_accounting_failed",
       message: "gateway accounting finalization failed"
     }}
  end

  @doc false
  @spec safe_failure_reason(term()) :: String.t()
  def safe_failure_reason(%Ecto.Changeset{}), do: "changeset"

  def safe_failure_reason(%{code: code}), do: safe_failure_reason(code)
  def safe_failure_reason(%{"code" => code}), do: safe_failure_reason(code)

  def safe_failure_reason({reason, _details}) when is_atom(reason),
    do: safe_failure_reason(reason)

  def safe_failure_reason(%module{}) when is_atom(module), do: inspect(module)

  def safe_failure_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> safe_reason_token()

  def safe_failure_reason(reason) when is_binary(reason), do: safe_reason_token(reason)
  # findings#165: a sanitizer bounds a value, it never erases it. A term this
  # module cannot name is still a term that was there, and answering it with
  # the same `"unknown"` that means "there was no reason" makes the two
  # indistinguishable in the one log line an operator reads after a
  # finalization failure. A fingerprint discloses nothing -- the term is
  # hashed, never rendered -- while keeping two different unnameable reasons
  # two different tokens.
  def safe_failure_reason(reason),
    do: "unnamed_" <> fingerprint(:erlang.term_to_binary(reason, [:deterministic]))

  defp record_id(%{id: id}) when is_binary(id), do: id
  defp record_id(_record), do: nil

  defp safe_reason_token(reason) do
    reason
    |> scrub_sensitive_reason_text()
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.trim("_")
    |> truncate_reason_token()
    |> case do
      "" -> "unnamed_" <> fingerprint(reason)
      token -> token
    end
  end

  @fingerprint_length 12

  # The term is hashed, never its rendering. `inspect/2` with a `:limit` is not
  # a usable input here: it elides past the limit, so two genuinely different
  # reasons collapse to the same string and therefore the same token, which is
  # the one property this fingerprint exists to provide.
  # `String.slice/3` rather than `binary_part/3` matches the fingerprint helpers
  # elsewhere in this application and cannot raise on a short input.
  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, @fingerprint_length)
  end

  defp scrub_sensitive_reason_text(reason) do
    reason
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "bearer_redacted")
    |> String.replace(
      ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b\s*[:=]\s*[^,;\s]+/,
      "\\1_redacted"
    )
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "redacted")
  end

  defp truncate_reason_token(reason) when byte_size(reason) > @max_failure_reason_bytes,
    do: binary_part(reason, 0, @max_failure_reason_bytes)

  defp truncate_reason_token(reason), do: reason
end
