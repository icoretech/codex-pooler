defmodule CodexPooler.Mailer.Config do
  @moduledoc false

  alias CodexPooler.InstanceSettings.Settings

  @accepted_tls_values %{
    "always" => :always,
    "if_available" => :if_available,
    "never" => :never
  }

  @probe_timeout_ms 5_000

  @spec from_settings(Settings.t() | map()) :: {:ok, map() | nil} | {:error, map()}
  def from_settings(%Settings{} = settings) do
    with {:ok, smtp} <- hydrated_smtp_settings(settings) do
      from_settings(smtp)
    end
  end

  def from_settings(%{} = smtp_settings) do
    {:ok, from_settings!(smtp_settings)}
  rescue
    error in ArgumentError ->
      {:error,
       %{
         code: :invalid_mailer_config,
         message: Exception.message(error)
       }}
  end

  @spec from_settings!(Settings.t() | map()) :: map() | nil | no_return()
  def from_settings!(%Settings{} = settings) do
    case hydrated_smtp_settings(settings) do
      {:ok, smtp} -> from_settings!(smtp)
      {:error, reason} -> raise ArgumentError, reason.message
    end
  end

  def from_settings!(%_{} = smtp_settings) do
    smtp_settings
    |> Map.from_struct()
    |> from_settings!()
  end

  def from_settings!(%{} = smtp_settings) do
    smtp_settings
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> build_config!()
  end

  @spec probe_options(Settings.t() | map()) :: {:ok, keyword() | nil} | {:error, map()}
  def probe_options(settings_or_smtp) do
    with {:ok, %{adapter_config: adapter_config}} <- from_settings(settings_or_smtp) do
      probe_options =
        adapter_config
        |> Keyword.put(:timeout, @probe_timeout_ms)
        |> Keyword.put(:retries, 0)
        |> maybe_require_auth()

      {:ok, probe_options}
    end
  end

  @spec sanitize_delivery_error(term()) :: map()
  def sanitize_delivery_error({:error, :bad_option, :no_relay}) do
    %{code: :smtp_test_email_invalid_config, message: "SMTP relay host is required"}
  end

  def sanitize_delivery_error({:error, :bad_option, :invalid_port}) do
    %{code: :smtp_test_email_invalid_config, message: "SMTP port must be a positive integer"}
  end

  def sanitize_delivery_error({:error, :bad_option, :no_credentials}) do
    %{
      code: :smtp_test_email_invalid_config,
      message: "SMTP username and password are both required for authentication"
    }
  end

  def sanitize_delivery_error({:error, {:network_failure, {:error, :timeout}}}) do
    %{code: :smtp_test_email_timeout, message: "SMTP test email timed out"}
  end

  def sanitize_delivery_error(
        {:error, :no_more_hosts, {:network_failure, _host, {:error, :timeout}}}
      ) do
    %{code: :smtp_test_email_timeout, message: "SMTP test email timed out"}
  end

  def sanitize_delivery_error({:error, {:network_failure, {:error, _reason}}}) do
    %{code: :smtp_test_email_connection_failed, message: "SMTP connection failed"}
  end

  def sanitize_delivery_error(
        {:error, :no_more_hosts, {:network_failure, _host, {:error, _reason}}}
      ) do
    %{code: :smtp_test_email_connection_failed, message: "SMTP connection failed"}
  end

  def sanitize_delivery_error({:error, {:permanent_failure, :auth_failed}}) do
    %{code: :smtp_test_email_auth_failed, message: "SMTP authentication failed"}
  end

  def sanitize_delivery_error({:error, :no_more_hosts, {:permanent_failure, _host, :auth_failed}}) do
    %{code: :smtp_test_email_auth_failed, message: "SMTP authentication failed"}
  end

  def sanitize_delivery_error({:error, {:missing_requirement, :auth}}) do
    %{
      code: :smtp_test_email_auth_unavailable,
      message: "SMTP server does not support the requested authentication flow"
    }
  end

  def sanitize_delivery_error({:error, {:missing_requirement, :tls}}) do
    %{
      code: :smtp_test_email_tls_unavailable,
      message: "SMTP server does not support the requested TLS mode"
    }
  end

  def sanitize_delivery_error({:error, {:temporary_failure, _reason}}) do
    %{
      code: :smtp_test_email_temporary_failure,
      message: "SMTP server temporarily rejected the test email"
    }
  end

  def sanitize_delivery_error({:error, :no_more_hosts, {:temporary_failure, _host, _reason}}) do
    %{
      code: :smtp_test_email_temporary_failure,
      message: "SMTP server temporarily rejected the test email"
    }
  end

  def sanitize_delivery_error({:error, {:permanent_failure, _reason}}) do
    %{code: :smtp_test_email_rejected, message: "SMTP server rejected the test email"}
  end

  def sanitize_delivery_error({:error, :no_more_hosts, {:permanent_failure, _host, _reason}}) do
    %{code: :smtp_test_email_rejected, message: "SMTP server rejected the test email"}
  end

  def sanitize_delivery_error({:error, {:unexpected_response, _responses}}) do
    %{
      code: :smtp_test_email_unexpected_response,
      message: "SMTP server returned an unexpected response"
    }
  end

  def sanitize_delivery_error(reason) do
    cond do
      auth_failed_reason?(reason) ->
        %{code: :smtp_test_email_auth_failed, message: "SMTP authentication failed"}

      timeout_reason?(reason) ->
        %{code: :smtp_test_email_timeout, message: "SMTP test email timed out"}

      network_failure_reason?(reason) ->
        %{code: :smtp_test_email_connection_failed, message: "SMTP connection failed"}

      temporary_failure_reason?(reason) ->
        %{
          code: :smtp_test_email_temporary_failure,
          message: "SMTP server temporarily rejected the test email"
        }

      permanent_failure_reason?(reason) ->
        %{code: :smtp_test_email_rejected, message: "SMTP server rejected the test email"}

      true ->
        %{code: :smtp_test_email_failed, message: "SMTP test email failed"}
    end
  end

  defp timeout_reason?(:timeout), do: true

  defp timeout_reason?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&timeout_reason?/1)
  end

  defp timeout_reason?(term) when is_list(term), do: Enum.any?(term, &timeout_reason?/1)
  defp timeout_reason?(_term), do: false

  defp network_failure_reason?({:network_failure, _reason}), do: true
  defp network_failure_reason?({:network_failure, _host, _reason}), do: true

  defp network_failure_reason?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&network_failure_reason?/1)
  end

  defp network_failure_reason?(term) when is_list(term),
    do: Enum.any?(term, &network_failure_reason?/1)

  defp network_failure_reason?(_term), do: false

  defp temporary_failure_reason?({:temporary_failure, _reason}), do: true
  defp temporary_failure_reason?({:temporary_failure, _host, _reason}), do: true

  defp temporary_failure_reason?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&temporary_failure_reason?/1)
  end

  defp temporary_failure_reason?(term) when is_list(term),
    do: Enum.any?(term, &temporary_failure_reason?/1)

  defp temporary_failure_reason?(_term), do: false

  defp permanent_failure_reason?({:permanent_failure, _reason}), do: true
  defp permanent_failure_reason?({:permanent_failure, _host, _reason}), do: true

  defp permanent_failure_reason?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&permanent_failure_reason?/1)
  end

  defp permanent_failure_reason?(term) when is_list(term),
    do: Enum.any?(term, &permanent_failure_reason?/1)

  defp permanent_failure_reason?(_term), do: false

  @spec sanitize_probe_error(term()) :: map()
  def sanitize_probe_error({:error, :bad_option, :no_relay}) do
    %{code: :smtp_probe_invalid_config, message: "SMTP relay host is required"}
  end

  def sanitize_probe_error({:error, :bad_option, :invalid_port}) do
    %{code: :smtp_probe_invalid_config, message: "SMTP port must be a positive integer"}
  end

  def sanitize_probe_error({:error, :bad_option, :no_credentials}) do
    %{
      code: :smtp_probe_invalid_config,
      message: "SMTP username and password are both required for authentication"
    }
  end

  def sanitize_probe_error({:error, {:network_failure, {:error, :timeout}}}) do
    %{code: :smtp_probe_timeout, message: "SMTP probe timed out"}
  end

  def sanitize_probe_error(
        {:error, :no_more_hosts, {:network_failure, _host, {:error, :timeout}}}
      ) do
    %{code: :smtp_probe_timeout, message: "SMTP probe timed out"}
  end

  def sanitize_probe_error({:error, {:network_failure, {:error, _reason}}}) do
    %{code: :smtp_probe_connection_failed, message: "SMTP connection failed"}
  end

  def sanitize_probe_error({:error, :no_more_hosts, {:network_failure, _host, {:error, _reason}}}) do
    %{code: :smtp_probe_connection_failed, message: "SMTP connection failed"}
  end

  def sanitize_probe_error({:error, {:permanent_failure, :auth_failed}}) do
    %{code: :smtp_probe_auth_failed, message: "SMTP authentication failed"}
  end

  def sanitize_probe_error({:error, :no_more_hosts, {:permanent_failure, _host, :auth_failed}}) do
    %{code: :smtp_probe_auth_failed, message: "SMTP authentication failed"}
  end

  def sanitize_probe_error({:error, {:missing_requirement, :auth}}) do
    %{
      code: :smtp_probe_auth_unavailable,
      message: "SMTP server does not support the requested authentication flow"
    }
  end

  def sanitize_probe_error({:error, {:missing_requirement, :tls}}) do
    %{
      code: :smtp_probe_tls_unavailable,
      message: "SMTP server does not support the requested TLS mode"
    }
  end

  def sanitize_probe_error({:error, {:temporary_failure, _reason}}) do
    %{code: :smtp_probe_temporary_failure, message: "SMTP server temporarily rejected the probe"}
  end

  def sanitize_probe_error({:error, :no_more_hosts, {:temporary_failure, _host, _reason}}) do
    %{code: :smtp_probe_temporary_failure, message: "SMTP server temporarily rejected the probe"}
  end

  def sanitize_probe_error({:error, {:permanent_failure, _reason}}) do
    %{code: :smtp_probe_rejected, message: "SMTP server rejected the probe"}
  end

  def sanitize_probe_error({:error, :no_more_hosts, {:permanent_failure, _host, _reason}}) do
    %{code: :smtp_probe_rejected, message: "SMTP server rejected the probe"}
  end

  def sanitize_probe_error({:error, {:unexpected_response, _responses}}) do
    %{
      code: :smtp_probe_unexpected_response,
      message: "SMTP server returned an unexpected response"
    }
  end

  def sanitize_probe_error(reason) do
    cond do
      auth_failed_reason?(reason) ->
        %{code: :smtp_probe_auth_failed, message: "SMTP authentication failed"}

      timeout_reason?(reason) ->
        %{code: :smtp_probe_timeout, message: "SMTP probe timed out"}

      network_failure_reason?(reason) ->
        %{code: :smtp_probe_connection_failed, message: "SMTP connection failed"}

      temporary_failure_reason?(reason) ->
        %{
          code: :smtp_probe_temporary_failure,
          message: "SMTP server temporarily rejected the probe"
        }

      permanent_failure_reason?(reason) ->
        %{code: :smtp_probe_rejected, message: "SMTP server rejected the probe"}

      true ->
        %{code: :smtp_probe_failed, message: "SMTP probe failed"}
    end
  end

  defp build_config!(%{enabled: false}), do: nil

  defp build_config!(smtp_settings) do
    host = require_non_blank_string!(smtp_settings, :host, "SMTP host")
    port = require_positive_integer!(smtp_settings, :port, "SMTP port")
    username = optional_non_blank_string!(smtp_settings, :username, "SMTP username")
    password = optional_non_blank_string!(smtp_settings, :password, "SMTP password")
    from = require_non_blank_string!(smtp_settings, :from, "SMTP from address")
    ssl = require_boolean!(smtp_settings, :ssl, "SMTP SSL")
    tls = require_tls_atom!(smtp_settings, :tls)
    retries = require_non_negative_integer!(smtp_settings, :retries, "SMTP retries")

    validate_auth_fields!(username, password)

    %{
      adapter_config:
        [
          adapter: Swoosh.Adapters.SMTP,
          relay: host,
          port: port,
          username: username,
          password: password,
          ssl: ssl,
          tls: tls,
          retries: retries
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end),
      from: from
    }
  end

  defp validate_auth_fields!(nil, nil), do: :ok

  defp validate_auth_fields!(username, nil) when is_binary(username) do
    raise ArgumentError, "SMTP password must be present when SMTP username is set"
  end

  defp validate_auth_fields!(nil, password) when is_binary(password) do
    raise ArgumentError, "SMTP username must be present when SMTP password is set"
  end

  defp validate_auth_fields!(_username, _password), do: :ok

  defp hydrated_smtp_settings(%Settings{smtp: smtp} = settings) do
    smtp_settings =
      smtp
      |> Map.from_struct()
      |> Map.take([:enabled, :host, :port, :username, :from, :ssl, :tls, :retries])

    if is_binary(smtp.password_ciphertext) do
      case Settings.decrypt_smtp_password(settings) do
        {:ok, password} -> {:ok, Map.put(smtp_settings, :password, password)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, Map.put(smtp_settings, :password, nil)}
    end
  end

  defp require_non_blank_string!(settings, key, label) do
    case optional_non_blank_string!(settings, key, label) do
      nil -> raise ArgumentError, "#{label} must be present when SMTP is enabled"
      value -> value
    end
  end

  defp optional_non_blank_string!(settings, key, label) do
    value = Map.get(settings, key)

    cond do
      is_nil(value) -> nil
      is_binary(value) -> blank_to_nil(value)
      true -> raise ArgumentError, "#{label} must be a string"
    end
  end

  defp require_positive_integer!(settings, key, label) do
    value = Map.get(settings, key)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError, "#{label} must be a positive integer"
    end
  end

  defp require_non_negative_integer!(settings, key, label) do
    value = Map.get(settings, key)

    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError, "#{label} must be a non-negative integer"
    end
  end

  defp require_boolean!(settings, key, label) do
    value = Map.get(settings, key)

    if is_boolean(value) do
      value
    else
      raise ArgumentError, "#{label} must be true or false"
    end
  end

  defp require_tls_atom!(settings, key) do
    case Map.get(settings, key) do
      value when is_binary(value) ->
        Map.get(@accepted_tls_values, value) ||
          raise ArgumentError, "SMTP TLS must be one of always, if_available, or never"

      value when value in [:always, :if_available, :never] ->
        value

      _invalid ->
        raise ArgumentError, "SMTP TLS must be one of always, if_available, or never"
    end
  end

  @smtp_setting_keys %{
    "enabled" => :enabled,
    "host" => :host,
    "port" => :port,
    "username" => :username,
    "password" => :password,
    "from" => :from,
    "ssl" => :ssl,
    "tls" => :tls,
    "retries" => :retries
  }

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@smtp_setting_keys, key, key)

  defp auth_failed_reason?(:auth_failed), do: true

  defp auth_failed_reason?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&auth_failed_reason?/1)
  end

  defp auth_failed_reason?(term) when is_list(term), do: Enum.any?(term, &auth_failed_reason?/1)
  defp auth_failed_reason?(_term), do: false

  defp maybe_require_auth(options) do
    if is_binary(options[:username]) do
      Keyword.put(options, :auth, :always)
    else
      options
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
