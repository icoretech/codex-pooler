defmodule CodexPooler.InstanceSettings.Settings do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias CodexPooler.InstanceSettings.{AppSecretCrypto, Defaults}
  alias CodexPooler.RouteClass

  @primary_key {:singleton, :boolean, autogenerate: false}
  @foreign_key_type :binary_id

  @tls_values ~w(always if_available never)
  @decompression_algorithms ~w(gzip deflate zstd)
  @default_openai_pricing_url Defaults.catalog()["openai_pricing_url"]
  @default_development Defaults.development()

  @gateway_embed_fields [
    :gateway_debug,
    :sse_keepalive_interval_ms,
    :websocket_idle_timeout_ms,
    :upstream_connect_timeout_ms,
    :upstream_pool_timeout_ms,
    :upstream_receive_timeout_ms,
    :expired_alias_ttl_seconds,
    :bridge_owner_lease_ttl_seconds,
    :bridge_owner_lease_renewal_seconds,
    :circuit_failure_threshold,
    :circuit_open_seconds,
    :circuit_half_open_probe_limit,
    :circuit_success_threshold,
    :bulkheads,
    :model_context_window_overrides
  ]

  @type t :: %__MODULE__{}

  schema "instance_settings" do
    embeds_one :gateway, Gateway, on_replace: :update, primary_key: false do
      field :gateway_debug, :boolean
      field :sse_keepalive_interval_ms, :integer
      field :websocket_idle_timeout_ms, :integer
      field :upstream_connect_timeout_ms, :integer
      field :upstream_pool_timeout_ms, :integer
      field :upstream_receive_timeout_ms, :integer
      field :expired_alias_ttl_seconds, :integer
      field :bridge_owner_lease_ttl_seconds, :integer
      field :bridge_owner_lease_renewal_seconds, :integer
      field :circuit_failure_threshold, :integer
      field :circuit_open_seconds, :integer
      field :circuit_half_open_probe_limit, :integer
      field :circuit_success_threshold, :integer
      field :bulkheads, :map
      field :model_context_window_overrides, :map
    end

    embeds_one :ingress, Ingress, on_replace: :update, primary_key: false do
      field :firewall_allowlist, {:array, :string}
      field :trusted_proxies, {:array, :string}
      field :decompression_algorithms, {:array, :string}
      field :max_compressed_body_bytes, :integer
      field :max_decompressed_body_bytes, :integer
      field :max_decompression_ratio, :integer
      field :decompression_timeout_ms, :integer
    end

    embeds_one :files, Files, on_replace: :update, primary_key: false do
      field :max_size_bytes, :integer
      field :upload_ttl_seconds, :integer
      field :abandoned_upload_cleanup_interval_seconds, :integer
    end

    embeds_one :transcription, Transcription, on_replace: :update, primary_key: false do
      field :max_upload_bytes, :integer
    end

    embeds_one :operator, Operator, on_replace: :update, primary_key: false do
      field :login_base_url, :string
    end

    embeds_one :catalog, Catalog, on_replace: :update, primary_key: false do
      field :openai_pricing_url, :string
    end

    embeds_one :development, Development, on_replace: :update, primary_key: false do
      field :impeccable_live_enabled, :boolean
      field :account_reconciliation_paused, :boolean
    end

    embeds_one :mcp, MCP, on_replace: :update, primary_key: false do
      field :enabled, :boolean, default: false
    end

    embeds_one :metrics, Metrics, on_replace: :update, primary_key: false do
      field :bearer_token_hmac_digest, :string
      field :bearer_token_fingerprint, :string
      field :bearer_token_key_version, :string
      field :bearer_token, :string, virtual: true
      field :bearer_token_action, :string, virtual: true

      field :bearer_token_status, Ecto.Enum,
        values: [:configured, :intentionally_unset, :unavailable],
        virtual: true
    end

    embeds_one :smtp, Smtp, on_replace: :update, primary_key: false do
      field :enabled, :boolean
      field :host, :string
      field :port, :integer
      field :username, :string
      field :from, :string
      field :ssl, :boolean
      field :tls, :string
      field :retries, :integer
      field :password_ciphertext, :string
      field :password_nonce, :string
      field :password_aad, :map
      field :password_key_version, :string
      field :password, :string, virtual: true
      field :password_action, :string, virtual: true

      field :password_status, Ecto.Enum,
        values: [:configured, :intentionally_unset, :unavailable],
        virtual: true
    end

    field :metadata, :map, default: %{}
    field :lock_version, :integer, default: 1
    field :updated_by_user_id, :binary_id
    field :source, Ecto.Enum, values: [:database, :fallback_defaults], virtual: true
    field :db_available?, :boolean, virtual: true
    field :secrets_available?, :boolean, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @spec default() :: t()
  def default do
    %__MODULE__{singleton: true}
    |> changeset(Defaults.all())
    |> apply_changes()
    |> mark_loaded(:database)
  end

  @spec fallback_default() :: t()
  def fallback_default do
    default()
    |> mark_loaded(:fallback_defaults)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = settings, attrs) when is_map(attrs) do
    settings
    |> cast(attrs, [:metadata, :updated_by_user_id, :lock_version])
    |> put_change(:singleton, true)
    |> cast_embed(:gateway, required: true, with: &gateway_changeset/2)
    |> cast_embed(:ingress, required: true, with: &ingress_changeset/2)
    |> cast_embed(:files, required: true, with: &files_changeset/2)
    |> cast_embed(:transcription, required: true, with: &transcription_changeset/2)
    |> cast_embed(:operator, required: true, with: &operator_changeset/2)
    |> cast_embed(:catalog, required: true, with: &catalog_changeset/2)
    |> cast_embed(:development, required: true, with: &development_changeset/2)
    |> cast_embed(:mcp, required: true, with: &mcp_changeset/2)
    |> cast_embed(:metrics, required: true, with: &metrics_changeset/2)
    |> cast_embed(:smtp, required: true, with: &smtp_changeset/2)
    |> validate_required([:singleton, :metadata])
    |> optimistic_lock(:lock_version)
  end

  @spec mark_loaded(t(), :database | :fallback_defaults) :: t()
  def mark_loaded(%__MODULE__{} = settings, source) do
    db_available? = source == :database

    %__MODULE__{
      settings
      | source: source,
        db_available?: db_available?,
        secrets_available?: db_available?,
        gateway: default_gateway(settings.gateway),
        catalog: default_catalog(settings.catalog),
        development: default_development(settings.development),
        metrics: mark_metrics_status(settings.metrics, source),
        smtp: mark_smtp_status(settings.smtp, source)
    }
  end

  @spec decrypt_smtp_password(t()) :: {:ok, binary()} | {:error, map()}
  def decrypt_smtp_password(%__MODULE__{smtp: %{password_aad: password_aad} = smtp}) do
    with {:ok, ciphertext} <- decode64(smtp.password_ciphertext),
         {:ok, nonce} <- decode64(smtp.password_nonce),
         aad when is_map(aad) <- password_aad do
      AppSecretCrypto.decrypt(ciphertext, nonce, aad)
    else
      _missing ->
        {:error, %{code: :smtp_password_unavailable, message: "SMTP password is unavailable"}}
    end
  end

  @spec metrics_token_matches?(t(), binary()) :: boolean()
  def metrics_token_matches?(
        %__MODULE__{metrics: %{bearer_token_hmac_digest: hmac_digest}},
        token
      )
      when is_binary(token) do
    with digest when is_binary(digest) <- hmac_digest,
         {:ok, decoded} <- Base.decode64(digest) do
      AppSecretCrypto.verify_hmac(token, decoded)
    else
      _missing -> false
    end
  end

  def metrics_token_matches?(_settings, _token), do: false

  defp gateway_changeset(gateway, attrs) do
    gateway
    |> cast(attrs, [
      :gateway_debug,
      :sse_keepalive_interval_ms,
      :websocket_idle_timeout_ms,
      :upstream_connect_timeout_ms,
      :upstream_pool_timeout_ms,
      :upstream_receive_timeout_ms,
      :expired_alias_ttl_seconds,
      :bridge_owner_lease_ttl_seconds,
      :bridge_owner_lease_renewal_seconds,
      :circuit_failure_threshold,
      :circuit_open_seconds,
      :circuit_half_open_probe_limit,
      :circuit_success_threshold,
      :bulkheads,
      :model_context_window_overrides
    ])
    |> validate_required([
      :gateway_debug,
      :sse_keepalive_interval_ms,
      :websocket_idle_timeout_ms,
      :upstream_connect_timeout_ms,
      :upstream_pool_timeout_ms,
      :upstream_receive_timeout_ms,
      :expired_alias_ttl_seconds,
      :bridge_owner_lease_ttl_seconds,
      :bridge_owner_lease_renewal_seconds,
      :circuit_failure_threshold,
      :circuit_open_seconds,
      :circuit_half_open_probe_limit,
      :circuit_success_threshold,
      :bulkheads,
      :model_context_window_overrides
    ])
    |> validate_number(:sse_keepalive_interval_ms, greater_than_or_equal_to: 0)
    |> validate_number(:websocket_idle_timeout_ms,
      greater_than_or_equal_to: 60_000,
      less_than_or_equal_to: 3_600_000
    )
    |> validate_positive_integer(:upstream_connect_timeout_ms)
    |> validate_positive_integer(:upstream_pool_timeout_ms)
    |> validate_positive_integer(:upstream_receive_timeout_ms)
    |> validate_positive_integer(:expired_alias_ttl_seconds)
    |> validate_positive_integer(:bridge_owner_lease_ttl_seconds)
    |> validate_positive_integer(:bridge_owner_lease_renewal_seconds)
    |> validate_positive_integer(:circuit_failure_threshold)
    |> validate_positive_integer(:circuit_open_seconds)
    |> validate_positive_integer(:circuit_half_open_probe_limit)
    |> validate_positive_integer(:circuit_success_threshold)
    |> validate_change(:bulkheads, &validate_bulkheads/2)
    |> validate_change(:model_context_window_overrides, &validate_positive_integer_map/2)
  end

  defp ingress_changeset(ingress, attrs) do
    ingress
    |> cast(attrs, [
      :firewall_allowlist,
      :trusted_proxies,
      :decompression_algorithms,
      :max_compressed_body_bytes,
      :max_decompressed_body_bytes,
      :max_decompression_ratio,
      :decompression_timeout_ms
    ])
    |> validate_required([
      :firewall_allowlist,
      :trusted_proxies,
      :max_compressed_body_bytes,
      :max_decompressed_body_bytes,
      :max_decompression_ratio,
      :decompression_timeout_ms
    ])
    |> validate_change(:firewall_allowlist, &validate_cidr_rules/2)
    |> validate_change(:trusted_proxies, &validate_cidr_rules/2)
    |> validate_subset(:decompression_algorithms, @decompression_algorithms)
    |> validate_positive_integer(:max_compressed_body_bytes)
    |> validate_positive_integer(:max_decompressed_body_bytes)
    |> validate_positive_integer(:max_decompression_ratio)
    |> validate_positive_integer(:decompression_timeout_ms)
  end

  defp files_changeset(files, attrs) do
    files
    |> cast(attrs, [
      :max_size_bytes,
      :upload_ttl_seconds,
      :abandoned_upload_cleanup_interval_seconds
    ])
    |> validate_required([
      :max_size_bytes,
      :upload_ttl_seconds,
      :abandoned_upload_cleanup_interval_seconds
    ])
    |> validate_positive_integer(:max_size_bytes)
    |> validate_positive_integer(:upload_ttl_seconds)
    |> validate_positive_integer(:abandoned_upload_cleanup_interval_seconds)
  end

  defp transcription_changeset(transcription, attrs) do
    transcription
    |> cast(attrs, [:max_upload_bytes])
    |> validate_required([:max_upload_bytes])
    |> validate_positive_integer(:max_upload_bytes)
  end

  defp operator_changeset(operator, attrs) do
    operator
    |> cast(attrs, [:login_base_url])
    |> validate_required([:login_base_url])
    |> update_change(:login_base_url, &normalize_operator_app_url/1)
    |> validate_format(:login_base_url, ~r/^https?:\/\//)
    |> validate_change(:login_base_url, &validate_operator_app_url/2)
  end

  defp normalize_operator_app_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_operator_app_url(value), do: value

  defp validate_operator_app_url(:login_base_url, value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        if login_path?(path),
          do: [login_base_url: "must be the public app URL without /login"],
          else: []

      _invalid ->
        []
    end
  end

  defp validate_operator_app_url(:login_base_url, _value), do: []

  defp login_path?(path) when path in [nil, ""], do: false
  defp login_path?(path), do: String.trim_trailing(path, "/") == "/login"

  defp catalog_changeset(catalog, attrs) do
    catalog
    |> cast(attrs, [:openai_pricing_url])
    |> default_openai_pricing_url()
    |> validate_required([:openai_pricing_url])
    |> update_change(:openai_pricing_url, &normalize_catalog_url/1)
    |> validate_format(:openai_pricing_url, ~r/^https?:\/\//)
    |> validate_change(:openai_pricing_url, &validate_catalog_url/2)
  end

  defp normalize_catalog_url(value) when is_binary(value) do
    String.trim(value)
  end

  defp normalize_catalog_url(value), do: value

  defp validate_catalog_url(:openai_pricing_url, value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        []

      _invalid ->
        [openai_pricing_url: "has invalid format"]
    end
  end

  defp validate_catalog_url(:openai_pricing_url, _value) do
    [openai_pricing_url: "has invalid format"]
  end

  defp default_openai_pricing_url(changeset) do
    if is_nil(get_field(changeset, :openai_pricing_url)) do
      put_change(changeset, :openai_pricing_url, @default_openai_pricing_url)
    else
      changeset
    end
  end

  defp development_changeset(development, attrs) do
    development
    |> cast(attrs, [:impeccable_live_enabled, :account_reconciliation_paused])
    |> default_development_flags()
    |> validate_required([:impeccable_live_enabled, :account_reconciliation_paused])
  end

  defp default_development_flags(changeset) do
    Enum.reduce(@default_development, changeset, fn {field, value}, changeset ->
      field = String.to_existing_atom(field)

      if is_nil(get_field(changeset, field)),
        do: put_change(changeset, field, value),
        else: changeset
    end)
  end

  defp mcp_changeset(mcp, attrs) do
    mcp
    |> cast(attrs, [:enabled])
    |> default_mcp_enabled()
    |> validate_required([:enabled])
  end

  defp metrics_changeset(metrics, attrs) do
    metrics
    |> cast(attrs, [
      :bearer_token_hmac_digest,
      :bearer_token_fingerprint,
      :bearer_token_key_version,
      :bearer_token,
      :bearer_token_action
    ])
    |> maybe_apply_metrics_token()
  end

  defp smtp_changeset(smtp, attrs) do
    smtp
    |> cast(attrs, [
      :enabled,
      :host,
      :port,
      :username,
      :from,
      :ssl,
      :tls,
      :retries,
      :password_ciphertext,
      :password_nonce,
      :password_aad,
      :password_key_version,
      :password,
      :password_action
    ])
    |> validate_required([:enabled, :port, :from, :ssl, :tls, :retries])
    |> update_change(:host, &blank_to_nil/1)
    |> update_change(:username, &blank_to_nil/1)
    |> update_change(:from, &String.trim/1)
    |> validate_positive_integer(:port)
    |> validate_positive_integer(:retries)
    |> validate_inclusion(:tls, @tls_values)
    |> validate_smtp_enabled_host()
    |> maybe_apply_smtp_password()
    |> validate_smtp_password_requirements()
  end

  defp default_mcp_enabled(changeset) do
    if is_nil(get_field(changeset, :enabled)) do
      put_change(changeset, :enabled, false)
    else
      changeset
    end
  end

  defp maybe_apply_metrics_token(changeset) do
    action = get_field(changeset, :bearer_token_action)
    token = changeset |> get_field(:bearer_token) |> blank_to_nil()

    cond do
      action == "clear" ->
        changeset
        |> put_change(:bearer_token_hmac_digest, nil)
        |> put_change(:bearer_token_fingerprint, nil)
        |> put_change(:bearer_token_key_version, nil)

      is_binary(token) ->
        case AppSecretCrypto.hmac_digest(token) do
          {:ok, digest} ->
            changeset
            |> put_change(:bearer_token_hmac_digest, Base.encode64(digest))
            |> put_change(:bearer_token_fingerprint, AppSecretCrypto.safe_fingerprint(token))
            |> put_change(:bearer_token_key_version, AppSecretCrypto.key_version())

          {:error, reason} ->
            add_error(changeset, :bearer_token, reason.message)
        end

      true ->
        changeset
    end
  end

  defp maybe_apply_smtp_password(changeset) do
    action = get_field(changeset, :password_action)
    password = changeset |> get_field(:password) |> blank_to_nil()

    cond do
      action == "clear" ->
        clear_smtp_password(changeset)

      is_binary(password) ->
        case AppSecretCrypto.encrypt(password, "smtp_password") do
          {:ok, encrypted} -> put_smtp_password(changeset, encrypted)
          {:error, reason} -> add_error(changeset, :password, reason.message)
        end

      true ->
        changeset
    end
  end

  defp clear_smtp_password(changeset) do
    changeset
    |> put_change(:password_ciphertext, nil)
    |> put_change(:password_nonce, nil)
    |> put_change(:password_aad, nil)
    |> put_change(:password_key_version, nil)
  end

  defp put_smtp_password(changeset, encrypted) do
    changeset
    |> put_change(:password_ciphertext, Base.encode64(encrypted.ciphertext))
    |> put_change(:password_nonce, Base.encode64(encrypted.nonce))
    |> put_change(:password_aad, encrypted.aad)
    |> put_change(:password_key_version, encrypted.key_version)
  end

  defp validate_smtp_enabled_host(changeset) do
    if get_field(changeset, :enabled) == true and is_nil(get_field(changeset, :host)) do
      add_error(changeset, :host, "must be present when SMTP is enabled")
    else
      changeset
    end
  end

  defp validate_smtp_password_requirements(changeset) do
    username = get_field(changeset, :username) |> blank_to_nil()
    password_configured? = is_binary(get_field(changeset, :password_ciphertext))
    enabled? = get_field(changeset, :enabled) == true

    cond do
      enabled? and is_binary(username) and not password_configured? ->
        add_error(changeset, :password, "must be present when SMTP username is set")

      enabled? and password_configured? and is_nil(username) ->
        add_error(changeset, :username, "must be present when SMTP password is set")

      true ->
        changeset
    end
  end

  defp validate_positive_integer(changeset, field) do
    validate_number(changeset, field, greater_than: 0)
  end

  defp validate_cidr_rules(field, rules) when is_list(rules) do
    if Enum.all?(rules, &valid_ip_rule?/1),
      do: [],
      else: [{field, "contains an invalid IP or CIDR rule"}]
  end

  defp validate_cidr_rules(field, _rules), do: [{field, "must be a list"}]

  defp valid_ip_rule?(rule) when is_binary(rule) do
    case String.split(String.trim(rule), "/", parts: 2) do
      [address] -> valid_ip?(address)
      [address, prefix] -> valid_cidr?(address, prefix)
    end
  end

  defp valid_ip_rule?(_rule), do: false

  defp valid_cidr?(address, prefix) do
    with {:ok, ip} <- parse_ip(address),
         {prefix, ""} <- Integer.parse(prefix) do
      prefix >= 0 and prefix <= tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16)
    else
      _invalid -> false
    end
  end

  defp valid_ip?(address), do: match?({:ok, _ip}, parse_ip(address))

  defp parse_ip(address) do
    address
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp validate_bulkheads(:bulkheads, value) when is_map(value) do
    expected = MapSet.new(RouteClass.all())
    actual = value |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    cond do
      actual != expected ->
        [bulkheads: "must include exactly the known route classes"]

      Enum.all?(value, fn {_class, config} -> valid_bulkhead?(config) end) ->
        []

      true ->
        [
          bulkheads:
            "must contain positive max_concurrency, non-negative queue_limit, and positive queue_timeout_ms"
        ]
    end
  end

  defp validate_bulkheads(:bulkheads, _value), do: [bulkheads: "must be a map"]

  defp valid_bulkhead?(config) when is_map(config) do
    max_concurrency = map_get(config, "max_concurrency")
    queue_limit = map_get(config, "queue_limit")
    queue_timeout_ms = map_get(config, "queue_timeout_ms")

    positive_integer?(max_concurrency) and non_negative_integer?(queue_limit) and
      positive_integer?(queue_timeout_ms)
  end

  defp valid_bulkhead?(_config), do: false

  defp validate_positive_integer_map(field, value) when is_map(value) do
    if Enum.all?(value, fn {key, integer} ->
         is_binary(key) and key != "" and positive_integer?(integer)
       end),
       do: [],
       else: [{field, "must map non-empty model ids to positive integers"}]
  end

  defp validate_positive_integer_map(field, _value), do: [{field, "must be a map"}]

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp map_get(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp default_gateway(nil), do: default_gateway(%{})

  defp default_gateway(gateway) when is_map(gateway) do
    defaults = gateway_embed_attrs(Defaults.gateway())

    attrs =
      if Map.has_key?(gateway, :__struct__) do
        Map.from_struct(gateway)
      else
        gateway
      end
      |> gateway_embed_attrs()

    attrs = Map.merge(defaults, attrs)

    struct(__MODULE__.Gateway, attrs)
  end

  defp gateway_embed_attrs(attrs) when is_map(attrs) do
    @gateway_embed_fields
    |> Map.new(fn field -> {field, map_get(attrs, Atom.to_string(field))} end)
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp default_catalog(nil), do: default().catalog

  defp default_catalog(%{openai_pricing_url: nil} = catalog) do
    %{catalog | openai_pricing_url: @default_openai_pricing_url}
  end

  defp default_catalog(catalog), do: catalog

  defp default_development(nil), do: default().development

  defp default_development(%{} = development) do
    Enum.reduce(@default_development, development, fn {field, value}, development ->
      field = String.to_existing_atom(field)

      if is_nil(Map.get(development, field)),
        do: Map.put(development, field, value),
        else: development
    end)
  end

  defp mark_metrics_status(nil, _source), do: nil

  defp mark_metrics_status(%{} = metrics, :fallback_defaults) do
    %{metrics | bearer_token_status: :unavailable}
  end

  defp mark_metrics_status(%{} = metrics, :database) do
    status =
      if is_binary(metrics.bearer_token_hmac_digest), do: :configured, else: :intentionally_unset

    %{metrics | bearer_token_status: status}
  end

  defp mark_smtp_status(nil, _source), do: nil

  defp mark_smtp_status(%{} = smtp, :fallback_defaults),
    do: %{smtp | password_status: :unavailable}

  defp mark_smtp_status(%{} = smtp, :database) do
    status = if is_binary(smtp.password_ciphertext), do: :configured, else: :intentionally_unset
    %{smtp | password_status: status}
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_value), do: :error
end
