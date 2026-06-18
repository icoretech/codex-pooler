defmodule CodexPooler.Upstreams.Lifecycle.IdentityRouting do
  @moduledoc false

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @model_routable_statuses [
    UpstreamIdentity.active_status(),
    UpstreamIdentity.refreshing_status()
  ]
  @file_routable_statuses [
    UpstreamIdentity.active_status()
  ]

  @type status_or_identity :: UpstreamIdentity.t() | UpstreamIdentity.status() | nil

  @spec model_routable_statuses() :: [UpstreamIdentity.status()]
  def model_routable_statuses, do: @model_routable_statuses

  @spec file_routable_statuses() :: [UpstreamIdentity.status()]
  def file_routable_statuses, do: @file_routable_statuses

  @spec model_routable?(status_or_identity()) :: boolean()
  def model_routable?(%UpstreamIdentity{status: status}), do: model_routable?(status)
  def model_routable?(status) when is_binary(status), do: status in @model_routable_statuses
  def model_routable?(nil), do: false

  @spec file_routable?(status_or_identity()) :: boolean()
  def file_routable?(%UpstreamIdentity{status: status}), do: file_routable?(status)
  def file_routable?(status) when is_binary(status), do: status in @file_routable_statuses
  def file_routable?(nil), do: false
end
