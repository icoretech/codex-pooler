defmodule CodexPooler.Access.Invites.ReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.{Invite, InviteAcceptance}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @status_active "active"
  @status_accepted "accepted"
  @status_revoked "revoked"
  @status_expired "expired"

  @type list_opts :: [
          {:limit, pos_integer()}
          | {:filters, Enumerable.t()}
        ]
  @type invite_row :: %{
          id: Ecto.UUID.t(),
          pool_id: Ecto.UUID.t(),
          pool_name: String.t(),
          pool_slug: String.t(),
          invited_email: String.t(),
          inviter_email: String.t(),
          status: String.t(),
          stored_status: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          accepted_at: DateTime.t() | nil,
          accepted_by_email: String.t() | nil,
          email_sent_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          upstream_identity_id: Ecto.UUID.t() | nil,
          pool_upstream_assignment_id: Ecto.UUID.t() | nil
        }
  @type invite_page :: %{
          items: [invite_row()],
          total: non_neg_integer(),
          limit: pos_integer()
        }

  @spec empty_page(list_opts()) :: invite_page()
  def empty_page(opts \\ []) do
    %{items: [], total: 0, limit: opts |> Keyword.get(:limit, 50) |> clamp_limit()}
  end

  @spec list_invites(Scope.t(), list_opts()) :: invite_page()
  def list_invites(%Scope{} = scope, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
    filters = opts |> Keyword.get(:filters, []) |> Map.new()
    visible_pool_ids = scope |> Pools.list_visible_pools() |> Enum.map(& &1.id)

    query =
      from invite in Invite,
        join: pool in Pool,
        on: pool.id == invite.pool_id,
        left_join: user in User,
        on: user.id == invite.created_by_user_id,
        left_join: acceptance in InviteAcceptance,
        on: acceptance.invite_id == invite.id

    query =
      query
      |> maybe_filter_visible_pools(visible_pool_ids)
      |> maybe_filter_pool(Map.get(filters, :pool_id))
      |> maybe_filter_status(Map.get(filters, :status))
      |> maybe_filter_email(Map.get(filters, :email))

    %{
      items: invite_rows(query, limit),
      total: Repo.aggregate(query, :count, :id),
      limit: limit
    }
  end

  defp invite_rows(query, limit) do
    Repo.all(
      from [invite, pool, user, acceptance] in query,
        order_by: [desc: invite.created_at, desc: invite.id],
        limit: ^limit,
        select: {invite, pool.name, pool.slug, user.email, acceptance}
    )
    |> Enum.map(&invite_row/1)
  end

  defp invite_row({invite, pool_name, pool_slug, inviter_email, acceptance}) do
    %{
      id: invite.id,
      pool_id: invite.pool_id,
      pool_name: pool_name,
      pool_slug: pool_slug,
      invited_email: invite.invited_email,
      inviter_email: inviter_email || "",
      status: effective_status(invite),
      stored_status: invite.status,
      created_at: invite.created_at,
      updated_at: invite.updated_at,
      expires_at: invite.expires_at,
      accepted_at: invite.accepted_at || (acceptance && acceptance.accepted_at),
      accepted_by_email: acceptance && acceptance.accepted_by_email,
      email_sent_at: invite.email_sent_at,
      revoked_at: invite.revoked_at,
      upstream_identity_id: acceptance && acceptance.upstream_identity_id,
      pool_upstream_assignment_id: acceptance && acceptance.pool_upstream_assignment_id
    }
  end

  defp maybe_filter_visible_pools(query, []), do: from([_invite, ...] in query, where: false)

  defp maybe_filter_visible_pools(query, pool_ids) when is_list(pool_ids),
    do: from([invite, ...] in query, where: invite.pool_id in ^pool_ids)

  defp maybe_filter_pool(query, nil), do: query
  defp maybe_filter_pool(query, ""), do: query

  defp maybe_filter_pool(query, pool_id) when is_binary(pool_id),
    do: from([invite, ...] in query, where: invite.pool_id == ^pool_id)

  defp maybe_filter_pool(query, _pool_id), do: query

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query

  defp maybe_filter_status(query, @status_expired) do
    now = now()

    from [invite, ...] in query,
      where:
        invite.status == ^@status_expired or
          (invite.status == ^@status_active and not is_nil(invite.expires_at) and
             invite.expires_at <= ^now)
  end

  defp maybe_filter_status(query, @status_active) do
    now = now()

    from [invite, ...] in query,
      where:
        invite.status == ^@status_active and
          (is_nil(invite.expires_at) or invite.expires_at > ^now)
  end

  defp maybe_filter_status(query, status)
       when status in [@status_accepted, @status_revoked],
       do: from([invite, ...] in query, where: invite.status == ^status)

  defp maybe_filter_status(query, _status), do: query

  defp maybe_filter_email(query, nil), do: query
  defp maybe_filter_email(query, ""), do: query

  defp maybe_filter_email(query, email) when is_binary(email) do
    pattern = "%#{String.downcase(String.trim(email))}%"

    from [invite, ...] in query,
      where: fragment("lower(?) LIKE ?", invite.invited_email, ^pattern)
  end

  defp maybe_filter_email(query, _email), do: query

  defp effective_status(%Invite{status: @status_active, expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, now()) == :gt, do: @status_active, else: @status_expired
  end

  defp effective_status(%Invite{status: status}), do: status

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)
  defp clamp_limit(_limit), do: 50

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
