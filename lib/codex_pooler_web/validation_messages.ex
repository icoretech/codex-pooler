defmodule CodexPoolerWeb.ValidationMessages do
  @moduledoc """
  Custom changeset messages rendered by the web layer.

  Ecto's built-in messages are extracted by the `errors` domain automatically.
  Keep custom messages here as no-op `errors` translations so they remain
  discoverable without putting Gettext calls in domain code.
  """

  use Gettext, backend: CodexPoolerWeb.Gettext

  @messages [
    # Accounts and auth
    dgettext_noop("errors", "must have the @ sign and no spaces"),
    dgettext_noop("errors", "must be a valid IANA time zone"),

    # Pools, invites, API keys, and upstream accounts
    dgettext_noop("errors", "must contain only lowercase letters, numbers, and hyphens"),
    dgettext_noop("errors", "must be a valid email address"),
    dgettext_noop("errors", "must be a valid email"),
    dgettext_noop("errors", "already has an active invite for this Pool"),
    dgettext_noop("errors", "must be an active Pool"),
    dgettext_noop("errors", "must be empty for default policy bindings"),
    dgettext_noop("errors", "is required for model policy bindings"),
    dgettext_noop("errors", "cannot be set when exact reasoning effort is enforced"),
    dgettext_noop("errors", "must be a list of non-empty strings"),
    dgettext_noop("errors", "must be a non-empty model identifier without whitespace"),
    dgettext_noop("errors", "labels must be a list of strings"),
    dgettext_noop("errors", "operator_notes must be a string"),
    dgettext_noop("errors", "must be a policy form"),
    dgettext_noop("errors", "contains unexpected fields"),
    dgettext_noop("errors", "type the account label exactly"),
    dgettext_noop("errors", "account was not selected"),
    dgettext_noop("errors", "must be a boolean"),
    dgettext_noop("errors", "is required"),
    dgettext_noop("errors", "only the provider credits control may be changed"),

    # Observatory/API-key policy and date validation
    dgettext_noop("errors", "must be enabled or disabled"),
    dgettext_noop("errors", "must be a positive whole number"),
    dgettext_noop("errors", "occurs twice in %{timezone}; choose a time outside the repeated hour"),
    dgettext_noop("errors", "does not exist in %{timezone} because the clocks move forward"),
    dgettext_noop("errors", "needs a valid account timezone"),
    dgettext_noop("errors", "must be a valid date and time"),

    # Operator and instance settings
    dgettext_noop("errors", "was updated by another operator"),
    dgettext_noop("errors", "must be 0 unless forwarded client IP source is X-Forwarded-For"),
    dgettext_noop("errors", "must be the public app URL without /login"),
    dgettext_noop("errors", "must be present when SMTP is enabled"),
    dgettext_noop("errors", "must be present when SMTP username is set"),
    dgettext_noop("errors", "must be present when SMTP password is set"),
    dgettext_noop("errors", "must be less than or equal to %{number}, a third of the owner lease TTL"),
    dgettext_noop("errors", "contains an invalid IP or CIDR rule"),
    dgettext_noop("errors", "must include exactly the known route classes"),
    dgettext_noop("errors", "must contain positive max_concurrency, non-negative queue_limit, and positive queue_timeout_ms"),
    dgettext_noop("errors", "must map non-empty model ids to positive integers"),
    dgettext_noop("errors", "is only available for email channels"),
    dgettext_noop("errors", "must use https"),
    dgettext_noop("errors", "must be a valid https URL"),
    dgettext_noop("errors", "could not be stored"),
    dgettext_noop("errors", "must be a valid host"),
    dgettext_noop("errors", "must start with /"),
    dgettext_noop("errors", "must not include query strings or fragments"),
    dgettext_noop("errors", "must be blank"),
    dgettext_noop("errors", "is not supported for this rule kind"),

    # Alert editor preflight and persistence failures are attached as form errors.
    dgettext_noop("errors", "Pool is not available"),
    dgettext_noop("errors", "Rule is not available"),
    dgettext_noop("errors", "Rule changed since you opened it. Reopen it to review the latest values"),
    dgettext_noop("errors", "Delivery channel is not available"),
    dgettext_noop("errors", "Rule could not be saved"),
    dgettext_noop("errors", "Channel is not available"),
    dgettext_noop("errors", "Channel changed since you opened it. Reopen it to review the latest values"),
    dgettext_noop("errors", "Channel could not be saved"),

    # Upstream auth.json import and device authorization
    dgettext_noop("errors", "Codex auth.json is required"),
    dgettext_noop("errors", "Codex auth.json must be a JSON object"),
    dgettext_noop("errors", "Codex auth.json is malformed"),
    dgettext_noop("errors", "Codex API-key auth.json is not supported"),
    dgettext_noop("errors", "Codex personal access token auth.json is not supported in this cycle"),
    dgettext_noop("errors", "Codex auth.json must contain ChatGPT token auth"),
    dgettext_noop("errors", "Codex auth.json is missing ChatGPT token data"),
    dgettext_noop("errors", "Codex auth.json contains an invalid id_token"),
    dgettext_noop("errors", "Codex auth.json contains an invalid access_token"),
    dgettext_noop("errors", "Codex auth.json is missing id_token"),
    dgettext_noop("errors", "Codex auth.json is missing access_token"),
    dgettext_noop("errors", "Codex auth.json is missing refresh_token"),
    dgettext_noop("errors", "Codex auth.json access token is expired"),
    dgettext_noop("errors", "Codex auth.json is missing account identity"),
    dgettext_noop("errors", "must be a map"),

    # Errors returned while storing write-only instance setting secrets.
    dgettext_noop("errors", "instance setting secret operation failed")
  ]

  @spec messages() :: [String.t()]
  def messages, do: @messages
end
