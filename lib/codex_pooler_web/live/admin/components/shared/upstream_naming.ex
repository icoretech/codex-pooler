defmodule CodexPoolerWeb.Admin.UpstreamNaming do
  @moduledoc """
  One rule for naming an upstream account on live admin surfaces.

  A live surface reports what is true now, so it names an upstream from the
  identity's own label and never from `assignment_label`. That column reads like
  a per-Pool nickname, but `PoolAssignments.create_pool_assignment/3` defaults it
  to `account_label` at creation, nothing re-syncs it afterwards, and no operator
  surface can edit it. It can therefore only repeat the account name or hold the
  name the account carried before it was renamed.

  Surfaces that report history are the deliberate exception, not a second
  opinion: a request log outlives the identity it points at, so
  `RequestLogsDisplay.format_upstream_account_label/1` keeps its own chain and
  may fall back to what the row recorded.
  """

  @fallback "Upstream account"

  @doc """
  Names an upstream account from anything carrying its identity fields.

  Accepts an `UpstreamIdentity` or any map exposing `:account_label`, so a
  projection that already selected the label can pass it without loading the
  identity again.
  """
  @spec account_name(term()) :: String.t()
  def account_name(identity) when is_map(identity) do
    present(Map.get(identity, :account_label)) ||
      present(Map.get(identity, :chatgpt_account_id)) ||
      @fallback
  end

  def account_name(_identity), do: @fallback

  @doc """
  Returns the string when it carries something, `nil` when it is blank or absent.
  """
  @spec present(term()) :: String.t() | nil
  def present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def present(_value), do: nil
end
