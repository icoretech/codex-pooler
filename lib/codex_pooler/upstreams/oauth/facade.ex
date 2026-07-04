defmodule CodexPooler.Upstreams.OAuth do
  @moduledoc """
  Public OAuth account-linking workflows for upstream accounts.

  Keep browser, device, polling, cancellation, and cleanup calls behind this
  focused boundary instead of reaching through the broader upstream context.
  """

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.OAuthFlows
  alias CodexPooler.Upstreams.Schemas.OAuthFlow

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type start_result :: OAuthFlows.start_result()
  @type completion_result :: OAuthFlows.completion_result()
  @type safe_flow_summary :: OAuthFlows.safe_flow_summary()

  @spec start_browser_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  defdelegate start_browser_oauth(scope, pool, opts \\ []), to: OAuthFlows

  @spec start_device_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  defdelegate start_device_oauth(scope, pool, opts \\ []), to: OAuthFlows

  @spec complete_browser_oauth(Scope.t(), Ecto.UUID.t(), String.t()) :: completion_result()
  defdelegate complete_browser_oauth(scope, flow_id, callback_url), to: OAuthFlows

  @spec poll_device_oauth(Scope.t(), Ecto.UUID.t()) :: completion_result()
  defdelegate poll_device_oauth(scope, flow_id), to: OAuthFlows

  @spec cancel_oauth_flow(Scope.t(), Ecto.UUID.t()) ::
          {:ok, OAuthFlow.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  defdelegate cancel_oauth_flow(scope, flow_id), to: OAuthFlows

  @spec expire_oauth_flows(DateTime.t()) :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
        }
  defdelegate expire_oauth_flows(now), to: OAuthFlows

  @spec cleanup_oauth_flows(DateTime.t()) :: %{
          expired: non_neg_integer(),
          deleted: non_neg_integer()
        }
  defdelegate cleanup_oauth_flows(now), to: OAuthFlows

  @spec list_visible_oauth_flow_summaries(Scope.t(), keyword()) :: [safe_flow_summary()]
  defdelegate list_visible_oauth_flow_summaries(scope, opts \\ []), to: OAuthFlows
end
