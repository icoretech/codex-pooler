defmodule CodexPooler.Gateway.Payloads.RequestOptions.FileBridgeContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization

  defstruct [
    :operation,
    :endpoint,
    :route_metadata,
    :pool_upstream_assignment_id,
    :upstream_identity_id,
    :defer_create_request,
    :finalize_retry_timeout_ms,
    :finalize_retry_interval_ms,
    forwarded_headers: []
  ]

  @type t :: %__MODULE__{
          operation: atom() | String.t() | nil,
          endpoint: String.t() | nil,
          route_metadata: map() | nil,
          pool_upstream_assignment_id: Ecto.UUID.t() | nil,
          upstream_identity_id: Ecto.UUID.t() | nil,
          defer_create_request: boolean() | nil,
          finalize_retry_timeout_ms: non_neg_integer() | nil,
          finalize_retry_interval_ms: non_neg_integer() | nil,
          forwarded_headers: [{String.t(), String.t()}]
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      operation: Map.get(opts, :file_bridge_operation),
      endpoint: Map.get(opts, :file_bridge_endpoint),
      route_metadata: Map.get(opts, :file_bridge_route_metadata),
      forwarded_headers: Normalization.forwarded_headers(Map.get(opts, :forwarded_headers, [])),
      pool_upstream_assignment_id: Map.get(opts, :pool_upstream_assignment_id),
      upstream_identity_id: Map.get(opts, :upstream_identity_id),
      defer_create_request: Map.get(opts, :defer_file_create_request),
      finalize_retry_timeout_ms:
        Normalization.optional_non_negative_integer(Map.get(opts, :finalize_retry_timeout_ms)),
      finalize_retry_interval_ms:
        Normalization.optional_non_negative_integer(Map.get(opts, :finalize_retry_interval_ms))
    }
  end

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = file_bridge, updates) do
    updates
    |> Map.new()
    |> Normalization.normalize_optional_update(
      :forwarded_headers,
      &Normalization.forwarded_headers_update/1
    )
    |> Normalization.normalize_optional_update(
      :finalize_retry_timeout_ms,
      &Normalization.optional_non_negative_integer/1
    )
    |> Normalization.normalize_optional_update(
      :finalize_retry_interval_ms,
      &Normalization.optional_non_negative_integer/1
    )
    |> then(&struct!(file_bridge, &1))
  end
end
