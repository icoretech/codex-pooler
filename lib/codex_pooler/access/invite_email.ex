defmodule CodexPooler.Access.InviteEmail do
  @moduledoc """
  Email builders and delivery helpers for Pool onboarding invites.
  """

  import Swoosh.Email

  require Logger

  alias CodexPooler.Access.Invite
  alias CodexPooler.Accounts.User
  alias CodexPooler.Events
  alias CodexPooler.Mailer
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @subject "Codex Pooler Pool invite"

  @type delivery_result :: {:ok, term()} | {:error, term()}
  @type pool_invite_result :: %{
          required(:invite) => Invite.t(),
          optional(:emailed?) => boolean(),
          optional(:email_error?) => boolean(),
          optional(atom()) => term()
        }

  @spec pool_invite_email(Invite.t(), binary(), Pool.t(), User.t()) :: Swoosh.Email.t()
  def pool_invite_email(
        %Invite{invited_email: invited_email},
        invite_url,
        %Pool{} = pool,
        %User{} = inviter
      )
      when is_binary(invited_email) and is_binary(invite_url) do
    new()
    |> from(Mailer.default_sender())
    |> to(invited_email)
    |> subject(@subject)
    |> text_body(text_body(pool, inviter, invite_url))
    |> html_body(html_body(pool, inviter, invite_url))
  end

  @spec deliver_pool_invite(Invite.t(), binary(), Pool.t(), User.t()) :: delivery_result()
  def deliver_pool_invite(
        %Invite{invited_email: invited_email} = invite,
        invite_url,
        %Pool{} = pool,
        %User{} = inviter
      )
      when is_binary(invited_email) and invited_email != "" and is_binary(invite_url) do
    invite
    |> pool_invite_email(invite_url, pool, inviter)
    |> Mailer.deliver()
  end

  def deliver_pool_invite(_invite, _invite_url, _pool, _inviter),
    do: {:error, :missing_invited_email}

  @spec maybe_deliver_pool_invite(pool_invite_result(), boolean(), binary(), Pool.t(), User.t()) ::
          pool_invite_result()
  def maybe_deliver_pool_invite(result, false, _invite_url, _pool, _inviter)
      when is_map(result) do
    result
    |> Map.put(:emailed?, false)
    |> Map.put(:email_error?, false)
  end

  def maybe_deliver_pool_invite(
        %{invite: %Invite{} = invite} = result,
        true,
        invite_url,
        %Pool{} = pool,
        %User{} = inviter
      ) do
    case deliver_pool_invite(invite, invite_url, pool, inviter) do
      {:ok, _email} ->
        result
        |> Map.put(:invite, mark_email_sent(invite))
        |> Map.put(:emailed?, true)
        |> Map.put(:email_error?, false)

      {:error, reason} ->
        log_invite_email_failure(reason)

        result
        |> Map.put(:emailed?, false)
        |> Map.put(:email_error?, true)
    end
  rescue
    error ->
      log_invite_email_exception(error)

      result
      |> Map.put(:emailed?, false)
      |> Map.put(:email_error?, true)
  end

  defp text_body(%Pool{} = pool, %User{} = inviter, invite_url) do
    inviter_label = inviter_label(inviter)

    [
      "#{inviter_label} invited you to connect an OpenAI account to #{pool.name}.",
      "",
      "Accept invite: #{invite_url}",
      "",
      "What happens next:",
      "After accepting the invite and linking an OpenAI account, that account becomes part of #{pool.name} and can be used by its routing policy.",
      "",
      "If this invite was unexpected, verify it with your system administrator before opening it. You can also discard this email.",
      "",
      "Invited by: #{inviter.email}"
    ]
    |> Enum.join("\n")
  end

  defp html_body(%Pool{} = pool, %User{} = inviter, invite_url) do
    pool_name = html_escape(pool.name)
    invite_href = html_escape(invite_url)
    inviter_name = html_escape(inviter_label(inviter))
    inviter_email = html_escape(inviter.email)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Codex Pooler Pool invite</title>
      </head>
      <body style="margin:0;padding:0;background:#0e0e0e;color:#e7e5e5;font-family:'Roboto Condensed','Segoe UI',Arial,sans-serif;">
        <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">
          #{inviter_name} invited you to connect an OpenAI account to #{pool_name}.
        </div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0e0e0e;margin:0;padding:32px 16px;">
          <tr>
            <td align="center">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#131313;border:1px solid #252626;border-radius:8px;overflow:hidden;">
                <tr>
                  <td style="padding:24px 28px 20px;border-bottom:1px solid #252626;">
                    <div style="color:#ff9900;font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;line-height:1.2;">Codex Pooler</div>
                    <h1 style="margin:10px 0 0;color:#e7e5e5;font-size:28px;line-height:1.15;font-weight:700;">Pool invite for #{pool_name}</h1>
                    <p style="margin:12px 0 0;color:#a6a3a3;font-size:16px;line-height:1.5;">
                      #{inviter_name} invited you to connect an OpenAI account to #{pool_name}.
                    </p>
                  </td>
                </tr>
                <tr>
                  <td style="padding:28px;">
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 22px;background:#1a140c;border:1px solid #4d2b0f;border-radius:6px;">
                      <tr>
                        <td style="padding:16px 18px;">
                          <p style="margin:0 0 6px;color:#f0c08c;font-size:13px;font-weight:700;line-height:1.35;">What happens after accepting</p>
                          <p style="margin:0;color:#d8d0ca;font-size:15px;line-height:1.55;">
                            After you accept and link an OpenAI account, that account becomes part of #{pool_name} and can be used by its routing policy.
                          </p>
                        </td>
                      </tr>
                    </table>

                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 28px;background:#191111;border:1px solid #5d2630;border-radius:6px;">
                      <tr>
                        <td style="padding:16px 18px;">
                          <p style="margin:0 0 6px;color:#ff6b8a;font-size:13px;font-weight:700;line-height:1.35;">Verify unexpected invites</p>
                          <p style="margin:0;color:#d8d0ca;font-size:15px;line-height:1.55;">
                            If this invite was unexpected, verify it with your system administrator before opening it. You can also discard this email.
                          </p>
                        </td>
                      </tr>
                    </table>

                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                      <tr>
                        <td align="center" style="padding:2px 0 30px;">
                          <a href="#{invite_href}" style="display:inline-block;background:#ff9900;border:1px solid #e17d00;border-radius:4px;color:#111111;font-size:16px;font-weight:700;line-height:1;text-decoration:none;padding:15px 28px;">Accept invite</a>
                        </td>
                      </tr>
                    </table>

                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #252626;padding-top:18px;">
                      <tr>
                        <td style="padding-top:18px;color:#8b8787;font-size:13px;line-height:1.5;">
                          <p style="margin:0 0 6px;">Sent by <strong style="color:#e7e5e5;">#{inviter_name}</strong> from <span style="color:#e7e5e5;">#{inviter_email}</span>.</p>
                          <p style="margin:0;">This invite is intended only for the Codex account email that received it. Do not forward the link.</p>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp inviter_label(%User{display_name: display_name, email: email}) do
    case normalize_display_name(display_name) do
      "" -> email
      name -> name
    end
  end

  defp normalize_display_name(value) when is_binary(value), do: String.trim(value)
  defp normalize_display_name(_value), do: ""

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp mark_email_sent(%Invite{} = invite) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    invite
    |> Invite.changeset(%{email_sent_at: now, updated_at: now})
    |> Repo.update()
    |> case do
      {:ok, invite} ->
        Events.broadcast_upstreams(invite.pool_id, "invite_email_sent", %{
          invite_id: invite.id,
          status: invite.status
        })

        invite

      {:error, _changeset} ->
        invite
    end
  end

  defp log_invite_email_failure(reason) do
    Logger.warning(fn ->
      "invite email delivery failed reason=#{delivery_failure_class(reason)}"
    end)
  end

  defp log_invite_email_exception(error) do
    Logger.warning(fn ->
      "invite email delivery raised exception=#{exception_class(error)}"
    end)
  end

  defp delivery_failure_class(%{__struct__: struct}), do: inspect(struct)
  defp delivery_failure_class({class, _details}) when is_atom(class), do: Atom.to_string(class)
  defp delivery_failure_class(class) when is_atom(class), do: Atom.to_string(class)
  defp delivery_failure_class(_reason), do: "unknown"

  defp exception_class(%{__struct__: struct}), do: inspect(struct)
end
