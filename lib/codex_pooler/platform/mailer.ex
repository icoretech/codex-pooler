defmodule CodexPooler.Mailer do
  use Swoosh.Mailer, otp_app: :codex_pooler

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Swoosh.Email

  require Logger

  alias CodexPooler.InstanceSettings
  alias CodexPooler.Mailer.Config
  alias CodexPooler.SupportedLocales

  @default_sender_name "Codex Pooler"

  @spec deliver(Swoosh.Email.t(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def deliver(email, config) do
    super(email, merge_runtime_config(config))
  end

  @doc """
  Returns whether email delivery is configured for an operator-visible send option.
  """
  @spec configured?() :: boolean()
  def configured? do
    case runtime_delivery_config() do
      {:ok, %{adapter_config: [_ | _]}} -> true
      _other -> configured_adapter?(static_adapter())
    end
  end

  @spec default_sender() :: {String.t(), String.t()}
  def default_sender do
    case Application.get_env(:codex_pooler, :mailer_from, "codex-pooler@example.com") do
      {name, address} when is_binary(name) and is_binary(address) and address != "" ->
        {name, default_from_address()}

      _other ->
        {@default_sender_name, default_from_address()}
    end
  end

  @spec default_from_address() :: String.t()
  def default_from_address do
    case runtime_delivery_config() do
      {:ok, %{from: from}} when is_binary(from) -> from
      _other -> static_from_address()
    end
  end

  @spec send_smtp_test_email(
          String.t(),
          %{
            required(:adapter_config) => Keyword.t(),
            required(:from) => String.t()
          },
          String.t() | nil
        ) ::
          {:ok, map()} | {:error, map()}
  def send_smtp_test_email(recipient_email, %{adapter_config: adapter_config, from: from}, locale)
      when is_binary(recipient_email) and is_list(adapter_config) and is_binary(from) do
    recipient_email = String.trim(recipient_email)

    recipient_email
    |> smtp_test_email(from, locale)
    |> deliver(adapter_config)
    |> case do
      {:ok, _receipt} ->
        {:ok, %{code: :smtp_test_email_sent, message: "SMTP test email sent"}}

      {:error, reason} ->
        {:error, Config.sanitize_delivery_error(reason)}
    end
  end

  @spec probe(keyword()) :: {:ok, map()} | {:error, map()}
  def probe(options) when is_list(options) do
    case :gen_smtp_client.open(options) do
      {:ok, socket} ->
        :ok = :gen_smtp_client.close(socket)
        {:ok, %{code: :smtp_probe_succeeded, message: "SMTP credentials verified"}}

      reason ->
        {:error, Config.sanitize_probe_error(reason)}
    end
  end

  defp configured_adapter?(nil), do: false

  defp configured_adapter?(Swoosh.Adapters.Local),
    do: Application.get_env(:swoosh, :local, true) != false

  defp configured_adapter?(_adapter), do: true

  defp merge_runtime_config(config) do
    case runtime_delivery_config() do
      {:ok, %{adapter_config: adapter_config}} -> Keyword.merge(adapter_config, config)
      _other -> config
    end
  end

  defp runtime_delivery_config do
    if test_settings_override?() do
      :disabled
    else
      case current_smtp_config() do
        {:ok, nil} ->
          :disabled

        {:ok, config} ->
          {:ok, config}

        {:error, reason} ->
          Logger.warning("instance SMTP config unavailable code=#{reason.code}")
          {:error, reason}
      end
    end
  end

  defp current_smtp_config do
    settings = InstanceSettings.current()
    smtp_settings = Map.from_struct(settings.smtp || %{})

    with {:ok, smtp_settings} <- maybe_put_decrypted_password(settings, smtp_settings) do
      Config.from_settings(smtp_settings)
    end
  end

  defp maybe_put_decrypted_password(settings, smtp_settings) do
    if is_binary(smtp_settings[:password_ciphertext]) do
      case InstanceSettings.decrypt_smtp_password(settings) do
        {:ok, password} -> {:ok, Map.put(smtp_settings, :password, password)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, smtp_settings}
    end
  end

  defp test_settings_override? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
      config = Application.get_env(:codex_pooler, __MODULE__, [])
      not Keyword.get(config, :use_instance_settings?, false)
    else
      false
    end
  end

  defp static_adapter do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter)
  end

  defp static_from_address do
    case Application.get_env(:codex_pooler, :mailer_from, "codex-pooler@example.com") do
      {_name, address} when is_binary(address) and address != "" -> address
      address when is_binary(address) and address != "" -> address
      _other -> "codex-pooler@example.com"
    end
  end

  defp smtp_test_email(recipient_email, from, locale) do
    Gettext.with_locale(SupportedLocales.gettext_locale(locale), fn ->
      new()
      |> from(sender_for_from(from))
      |> to(recipient_email)
      |> subject(dgettext("emails", "Codex Pooler SMTP test email"))
      |> text_body(dgettext("emails", "This test email confirms Codex Pooler can send email with the current SMTP settings."))
    end)
  end

  defp sender_for_from(from) do
    {sender_name(), from}
  end

  defp sender_name do
    case Application.get_env(:codex_pooler, :mailer_from, "codex-pooler@example.com") do
      {name, _address} when is_binary(name) and name != "" -> name
      _other -> @default_sender_name
    end
  end
end
