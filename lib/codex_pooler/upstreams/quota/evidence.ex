defmodule CodexPooler.Upstreams.Quota.Evidence do
  @moduledoc """
  Converts upstream quota evidence payloads into quota-window attrs.
  """

  alias CodexPooler.Quotas
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.Evidence.CodexParsers.ResponseHeaders

  @type window_attrs :: map()

  @spec codex_usage_windows_from_payload(term(), DateTime.t()) ::
          {:ok, [window_attrs()]} | {:error, term()}
  def codex_usage_windows_from_payload(payload, synced_at) do
    case Quotas.parse_codex_usage_payload(payload, synced_at) do
      {:ok, evidence} -> {:ok, Enum.map(evidence, &Evidence.to_window_attrs/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec codex_header_windows([{String.t(), String.t()}] | map(), DateTime.t()) :: [
          window_attrs()
        ]
  @spec codex_header_windows(term(), DateTime.t(), String.t() | nil) :: [window_attrs()]
  @spec codex_header_windows(term(), DateTime.t(), String.t() | nil, String.t() | nil) ::
          [window_attrs()]
  def codex_header_windows(headers, synced_at, dispatched_model \\ nil, denial_code \\ nil) do
    headers
    |> ResponseHeaders.parse(synced_at, dispatched_model)
    |> Enum.map(&preserve_header_denial(&1, denial_code, synced_at))
    |> Enum.map(&Evidence.to_window_attrs/1)
  end

  defp preserve_header_denial(%Evidence{reset_at: %DateTime{} = reset_at} = evidence, code, at)
       when code in ["usage_limit_reached", "usage_limit_exceeded"] do
    if DateTime.compare(reset_at, at) == :gt and
         Decimal.compare(evidence.used_percent, Decimal.new(100)) == :eq do
      metadata =
        Map.merge(evidence.metadata, %{
          "rate_limit_reached" => true,
          "rate_limit_error_code" => code
        })

      source = "codex_rate_limit_error"

      %{
        evidence
        | metadata: metadata,
          source: source,
          merge_precedence: Evidence.merge_precedence(source, reset_at, evidence.source_precision)
      }
    else
      mark_usage_limit_refusal(evidence, code)
    end
  end

  defp preserve_header_denial(evidence, _code, _at), do: evidence

  # A window the refusal reported below 100% (or without a reset ahead) keeps
  # its percentage and source, but records that it came from a provider
  # usage-limit refusal: the account-denial routing filter reads that, whatever
  # the reached type (findings#206 row 206-594).
  defp mark_usage_limit_refusal(%Evidence{} = evidence, code),
    do: %{evidence | metadata: Map.put(evidence.metadata || %{}, "rate_limit_error_code", code)}

  @spec codex_rate_limit_event_windows(term(), DateTime.t()) :: [window_attrs()]
  def codex_rate_limit_event_windows(event, synced_at) do
    event
    |> Quotas.parse_codex_rate_limit_event(synced_at)
    |> Enum.map(&Evidence.to_window_attrs/1)
  end

  @spec codex_rate_limit_error_windows(term(), DateTime.t()) :: [window_attrs()]
  def codex_rate_limit_error_windows(payload, synced_at) do
    payload
    |> Quotas.parse_rate_limit_error(synced_at)
    |> Enum.map(&Evidence.to_window_attrs/1)
  end
end
