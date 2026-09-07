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
  def codex_header_windows(headers, synced_at, dispatched_model \\ nil) do
    headers
    |> ResponseHeaders.parse(synced_at, dispatched_model)
    |> Enum.map(&Evidence.to_window_attrs/1)
  end

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
