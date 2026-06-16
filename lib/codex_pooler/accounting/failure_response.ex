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
  def safe_failure_reason(_reason), do: "unknown"

  defp record_id(%{id: id}) when is_binary(id), do: id
  defp record_id(_record), do: nil

  defp safe_reason_token(reason) do
    reason
    |> scrub_sensitive_reason_text()
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.trim("_")
    |> truncate_reason_token()
    |> case do
      "" -> "unknown"
      token -> token
    end
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
