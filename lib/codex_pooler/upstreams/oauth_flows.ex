defmodule CodexPooler.Upstreams.OAuthFlows do
  @moduledoc """
  Public facade for OpenAI OAuth upstream-linking flows.

  Flow lifecycle, operator-safe summaries, and token-link completion live in
  focused child modules so callers can keep a stable context API without
  depending on one monolithic implementation module.
  """

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.OAuthFlows.{Completion, Lifecycle, Summary}
  alias CodexPooler.Upstreams.Schemas.OAuthFlow

  @type lifecycle_error :: Lifecycle.lifecycle_error()
  @type flow_result :: Lifecycle.flow_result()
  @type start_result :: Lifecycle.start_result()
  @type completion_result :: Completion.completion_result()
  @type cleanup_result :: Lifecycle.cleanup_result()
  @type result_identity_summary :: Summary.result_identity_summary()
  @type device_summary :: Summary.device_summary()
  @type error_summary :: Summary.error_summary()
  @type safe_flow_summary :: Summary.safe_flow_summary()

  @spec start_browser_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  defdelegate start_browser_oauth(scope, pool, opts \\ []), to: Lifecycle

  @spec start_device_oauth(Scope.t(), Pool.t(), keyword()) :: start_result()
  defdelegate start_device_oauth(scope, pool, opts \\ []), to: Lifecycle

  @spec list_visible_oauth_flow_summaries(Scope.t(), keyword()) :: [safe_flow_summary()]
  defdelegate list_visible_oauth_flow_summaries(scope, opts \\ []), to: Summary

  @spec complete_browser_oauth(Scope.t(), Ecto.UUID.t(), String.t()) :: completion_result()
  defdelegate complete_browser_oauth(scope, flow_id, callback_url), to: Completion

  @spec poll_device_oauth(Scope.t(), Ecto.UUID.t()) :: completion_result()
  defdelegate poll_device_oauth(scope, flow_id), to: Completion

  @spec cancel_oauth_flow(Scope.t(), Ecto.UUID.t()) :: flow_result()
  defdelegate cancel_oauth_flow(scope, flow_id), to: Lifecycle

  @spec expire_oauth_flows(DateTime.t()) :: cleanup_result()
  defdelegate expire_oauth_flows(now), to: Lifecycle

  @spec create_oauth_flow(map()) :: flow_result()
  defdelegate create_oauth_flow(attrs), to: Lifecycle

  @spec hash_state_token(String.t()) :: binary()
  defdelegate hash_state_token(state_token), to: Lifecycle

  @spec decrypt_code_verifier(OAuthFlow.t()) :: {:ok, binary()} | {:error, lifecycle_error()}
  defdelegate decrypt_code_verifier(flow), to: Lifecycle

  @spec decrypt_device_auth_id(OAuthFlow.t()) :: {:ok, binary()} | {:error, lifecycle_error()}
  defdelegate decrypt_device_auth_id(flow), to: Lifecycle

  @spec cleanup_oauth_flows(DateTime.t()) :: cleanup_result()
  defdelegate cleanup_oauth_flows(now), to: Lifecycle

  @spec expire_pending_oauth_flows(DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  defdelegate expire_pending_oauth_flows(now), to: Lifecycle

  @spec delete_terminal_oauth_flows(DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  defdelegate delete_terminal_oauth_flows(now), to: Lifecycle
end
