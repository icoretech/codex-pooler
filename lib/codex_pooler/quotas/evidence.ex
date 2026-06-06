defmodule CodexPooler.Quotas.Evidence do
  @moduledoc """
  Normalized quota-window evidence captured from upstream usage, headers, events, or errors.

  This is a value module, not a persistence boundary. It keeps parser outputs
  explicit before they are stored on `account_quota_windows`.
  """

  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Quotas.Evidence.Descriptors

  @enforce_keys [
    :quota_key,
    :window_kind,
    :window_minutes,
    :source,
    :source_precision,
    :quota_scope,
    :quota_family,
    :freshness_state,
    :last_sync_at,
    :observed_at,
    :merge_precedence
  ]
  defstruct [
    :quota_key,
    :window_kind,
    :window_minutes,
    :active_limit,
    :credits,
    :reset_at,
    :used_percent,
    :display_label,
    :limit_name,
    :metered_feature,
    :source,
    :source_precision,
    :quota_scope,
    :quota_family,
    :model,
    :upstream_model,
    :raw_limit_id,
    :raw_limit_name,
    :raw_metered_feature,
    :freshness_state,
    :last_sync_at,
    :observed_at,
    :merge_precedence,
    metadata: %{}
  ]

  @account_quota_key "account"
  @window_kinds ~w(primary secondary)
  @source_precisions ~w(authoritative observed inferred unknown)
  @quota_scopes ~w(account model upstream_model feature)
  @freshness_states ~w(fresh stale unknown)
  @source_precedence %{
    "codex_rate_limit_event" => 90,
    "codex_response_headers" => 80,
    "codex_rate_limit_error" => 80,
    "codex_usage_api" => 60,
    "local_reconciliation" => 30
  }
  @resetless_precedence_penalty 20
  @default_freshness_ttl_seconds 15 * 60
  @default_future_observed_skew_seconds 5 * 60

  @type errors :: %{optional(atom()) => [String.t()]}
  @type t :: %__MODULE__{
          quota_key: String.t(),
          window_kind: String.t(),
          window_minutes: pos_integer(),
          active_limit: non_neg_integer() | nil,
          credits: non_neg_integer() | nil,
          reset_at: DateTime.t() | nil,
          used_percent: Decimal.t() | nil,
          display_label: String.t() | nil,
          limit_name: String.t() | nil,
          metered_feature: String.t() | nil,
          source: String.t(),
          source_precision: String.t(),
          quota_scope: String.t(),
          quota_family: String.t(),
          model: String.t() | nil,
          upstream_model: String.t() | nil,
          raw_limit_id: String.t() | nil,
          raw_limit_name: String.t() | nil,
          raw_metered_feature: String.t() | nil,
          freshness_state: String.t(),
          last_sync_at: DateTime.t(),
          observed_at: DateTime.t(),
          merge_precedence: non_neg_integer(),
          metadata: map()
        }

  @spec new(map(), DateTime.t()) :: {:ok, t()} | {:error, errors()}
  def new(attrs, observed_at \\ now())

  def new(attrs, observed_at) when is_map(attrs) do
    evidence = normalize(attrs, observed_at)

    case validate(evidence) do
      :ok -> {:ok, struct!(__MODULE__, evidence)}
      {:error, _errors} = error -> error
    end
  end

  def new(_attrs, _observed_at), do: {:error, %{attrs: ["must be a map"]}}

  @spec new!(map(), DateTime.t()) :: t() | no_return()
  def new!(attrs, observed_at \\ now()) do
    case new(attrs, observed_at) do
      {:ok, evidence} -> evidence
      {:error, errors} -> raise ArgumentError, "invalid quota evidence: #{inspect(errors)}"
    end
  end

  @spec parse_codex_usage_payload(term(), DateTime.t()) ::
          {:ok, [t()]} | {:error, %{required(:code) => atom(), required(:message) => String.t()}}
  def parse_codex_usage_payload(payload, observed_at \\ now()),
    do: CodexParsers.parse_codex_usage_payload(payload, observed_at)

  @spec parse_codex_headers([{String.t(), String.t()}] | map() | term(), DateTime.t()) :: [t()]
  def parse_codex_headers(headers, observed_at \\ now()),
    do: CodexParsers.parse_codex_headers(headers, observed_at)

  @spec parse_codex_rate_limit_event(term(), DateTime.t()) :: [t()]
  def parse_codex_rate_limit_event(event, observed_at \\ now()),
    do: CodexParsers.parse_codex_rate_limit_event(event, observed_at)

  @spec parse_rate_limit_error(term(), DateTime.t()) :: [t()]
  def parse_rate_limit_error(payload, observed_at \\ now()),
    do: CodexParsers.parse_rate_limit_error(payload, observed_at)

  @spec routing_usable?(t(), DateTime.t()) :: boolean()
  def routing_usable?(%__MODULE__{} = evidence, timestamp \\ now()) do
    current_freshness_state(evidence, timestamp) == "fresh" and not exhausted?(evidence) and
      reset_bearing?(evidence) and not expired?(evidence, timestamp)
  end

  @spec current_freshness_state(t() | map(), DateTime.t()) :: String.t()
  def current_freshness_state(evidence_or_window, timestamp \\ now())

  def current_freshness_state(%__MODULE__{} = evidence, timestamp) do
    freshness_state(
      %{
        freshness_state: evidence.freshness_state,
        observed_at: evidence.observed_at,
        reset_at: evidence.reset_at
      },
      timestamp
    )
  end

  def current_freshness_state(%{} = attrs, timestamp), do: freshness_state(attrs, timestamp)

  @spec reset_bearing?(t() | map() | term()) :: boolean()
  def reset_bearing?(%__MODULE__{reset_at: %DateTime{}}), do: true
  def reset_bearing?(%{reset_at: %DateTime{}}), do: true
  def reset_bearing?(_evidence_or_attrs), do: false

  @spec expired?(t() | map() | term(), DateTime.t()) :: boolean()
  def expired?(evidence_or_attrs, timestamp \\ now())

  def expired?(%__MODULE__{} = evidence, timestamp),
    do: expired?(Map.from_struct(evidence), timestamp)

  def expired?(%{reset_at: %DateTime{} = reset_at}, timestamp) do
    DateTime.compare(reset_at, timestamp) != :gt
  end

  def expired?(_attrs, _timestamp), do: false

  @spec freshness_ttl_seconds() :: pos_integer()
  def freshness_ttl_seconds do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:quota_freshness_ttl_seconds, @default_freshness_ttl_seconds)
  end

  @spec future_observed_skew_seconds() :: pos_integer()
  def future_observed_skew_seconds do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:quota_future_observed_skew_seconds, @default_future_observed_skew_seconds)
  end

  @spec merge_precedence(String.t() | nil, DateTime.t() | nil, String.t() | nil) ::
          non_neg_integer()
  def merge_precedence(source, reset_at, source_precision \\ nil) do
    base = Map.get(@source_precedence, source, 0)

    cond do
      match?(%DateTime{}, reset_at) -> base
      source_precision == "authoritative" -> base
      true -> max(base - @resetless_precedence_penalty, 0)
    end
  end

  def merge_precedence(%__MODULE__{} = evidence),
    do: merge_precedence(evidence.source, evidence.reset_at, evidence.source_precision)

  def merge_precedence(%{} = attrs) do
    source = fetch(attrs, :source)
    reset_at = datetime_or_nil(fetch(attrs, :reset_at))
    source_precision = fetch(attrs, :source_precision)
    merge_precedence(source, reset_at, source_precision)
  end

  @spec validate(t() | map() | term()) :: :ok | {:error, errors()}
  def validate(%__MODULE__{} = evidence), do: evidence |> Map.from_struct() |> validate()

  def validate(attrs) when is_map(attrs) do
    errors =
      %{}
      |> require_present(attrs, :quota_key)
      |> require_inclusion(attrs, :window_kind, @window_kinds)
      |> require_positive_integer(attrs, :window_minutes)
      |> require_present(attrs, :source)
      |> require_inclusion(attrs, :source_precision, @source_precisions)
      |> require_inclusion(attrs, :quota_scope, @quota_scopes)
      |> require_present(attrs, :quota_family)
      |> require_inclusion(attrs, :freshness_state, @freshness_states)
      |> require_datetime(attrs, :last_sync_at)
      |> require_datetime(attrs, :observed_at)
      |> require_non_negative_integer(attrs, :merge_precedence)
      |> validate_optional_non_negative_integer(attrs, :active_limit)
      |> validate_optional_non_negative_integer(attrs, :credits)
      |> validate_optional_percent(attrs, :used_percent)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  def validate(_attrs), do: {:error, %{attrs: ["must be a map"]}}

  @spec to_window_attrs(t()) :: map()
  def to_window_attrs(%__MODULE__{} = evidence), do: Map.from_struct(evidence)

  @spec identity_key(t()) :: tuple()
  def identity_key(%__MODULE__{} = evidence) do
    {
      evidence.quota_scope,
      evidence.quota_family,
      normalize_identity_part(evidence.model),
      normalize_identity_part(evidence.upstream_model),
      evidence.quota_key,
      evidence.window_kind,
      evidence.window_minutes,
      evidence.source,
      optional_identity_part(evidence.raw_limit_id),
      optional_identity_part(evidence.raw_limit_name),
      optional_identity_part(evidence.raw_metered_feature)
    }
  end

  # Reason: evidence normalization preserves all optional upstream quota identity fields.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp normalize(attrs, observed_at) do
    last_sync_at = datetime_or_nil(fetch(attrs, :last_sync_at)) || observed_at
    quota_key = normalize_quota_key(fetch(attrs, :quota_key) || @account_quota_key)
    model = present_string(fetch(attrs, :model))
    upstream_model = present_string(fetch(attrs, :upstream_model))
    raw_limit_name = present_string(fetch(attrs, :raw_limit_name) || fetch(attrs, :limit_name))

    raw_metered_feature =
      present_string(fetch(attrs, :raw_metered_feature) || fetch(attrs, :metered_feature))

    source = present_string(fetch(attrs, :source))

    canonical =
      Descriptors.canonical_additional_quota(
        quota_key,
        raw_limit_name || fetch(attrs, :limit_name)
      )

    quota_key = if canonical, do: canonical.quota_key, else: quota_key

    %{}
    |> put(:quota_key, quota_key)
    |> put(:window_kind, normalize_token(fetch(attrs, :window_kind)))
    |> put(:window_minutes, integer_or_nil(fetch(attrs, :window_minutes)))
    |> put(:active_limit, integer_or_nil(fetch(attrs, :active_limit)))
    |> put(:credits, integer_or_nil(fetch(attrs, :credits)))
    |> put(:reset_at, datetime_or_nil(fetch(attrs, :reset_at)))
    |> put(:used_percent, decimal_or_nil(fetch(attrs, :used_percent)))
    |> put(:display_label, present_string(fetch(attrs, :display_label)))
    |> put(:limit_name, present_string(fetch(attrs, :limit_name)))
    |> put(:metered_feature, present_string(fetch(attrs, :metered_feature)))
    |> put(:source, source)
    |> put(:source_precision, normalize_token(fetch(attrs, :source_precision) || "observed"))
    |> put(
      :quota_scope,
      normalize_token(
        fetch(attrs, :quota_scope) || Descriptors.infer_scope(model, upstream_model, quota_key)
      )
    )
    |> put(
      :quota_family,
      normalize_quota_key(fetch(attrs, :quota_family) || quota_key || @account_quota_key)
    )
    |> put(:model, model)
    |> put(:upstream_model, upstream_model)
    |> put(:raw_limit_id, present_string(fetch(attrs, :raw_limit_id)))
    |> put(:raw_limit_name, raw_limit_name)
    |> put(:raw_metered_feature, raw_metered_feature)
    |> put(:freshness_state, normalize_token(fetch(attrs, :freshness_state) || "fresh"))
    |> put(:last_sync_at, last_sync_at)
    |> put(:observed_at, datetime_or_nil(fetch(attrs, :observed_at)) || last_sync_at)
    |> put(
      :merge_precedence,
      integer_or_nil(fetch(attrs, :merge_precedence)) ||
        merge_precedence(
          source,
          datetime_or_nil(fetch(attrs, :reset_at)),
          fetch(attrs, :source_precision)
        )
    )
    |> put(:metadata, fetch(attrs, :metadata) || %{})
  end

  defp freshness_state(attrs, timestamp) do
    persisted_state = fetch(attrs, :freshness_state) || "unknown"
    observed_at = datetime_or_nil(fetch(attrs, :observed_at))

    cond do
      persisted_state != "fresh" -> persisted_state
      expired?(attrs, timestamp) -> "stale"
      stale_observed_at?(observed_at, timestamp) -> "stale"
      future_observed_at?(observed_at, timestamp) -> "stale"
      true -> "fresh"
    end
  end

  defp stale_observed_at?(nil, _timestamp), do: true

  defp stale_observed_at?(observed_at, timestamp) do
    DateTime.diff(timestamp, observed_at, :second) > freshness_ttl_seconds()
  end

  defp future_observed_at?(observed_at, timestamp) do
    DateTime.diff(observed_at, timestamp, :second) > future_observed_skew_seconds()
  end

  defp exhausted?(%__MODULE__{used_percent: %Decimal{} = used_percent}) do
    Decimal.compare(used_percent, Decimal.new(100)) != :lt
  end

  defp exhausted?(%__MODULE__{active_limit: 0}), do: true
  defp exhausted?(%__MODULE__{credits: 0}), do: true

  defp exhausted?(_evidence), do: false

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp require_present(errors, attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: add_error(errors, field, "can't be blank"), else: errors

      nil ->
        add_error(errors, field, "can't be blank")

      _value ->
        errors
    end
  end

  defp require_inclusion(errors, attrs, field, allowed) do
    if Map.get(attrs, field) in allowed, do: errors, else: add_error(errors, field, "is invalid")
  end

  defp require_positive_integer(errors, attrs, field) do
    case Map.get(attrs, field) do
      value when is_integer(value) and value > 0 -> errors
      _value -> add_error(errors, field, "must be greater than 0")
    end
  end

  defp require_non_negative_integer(errors, attrs, field) do
    case Map.get(attrs, field) do
      value when is_integer(value) and value >= 0 -> errors
      _value -> add_error(errors, field, "must be greater than or equal to 0")
    end
  end

  defp require_datetime(errors, attrs, field) do
    case Map.get(attrs, field) do
      %DateTime{} -> errors
      _value -> add_error(errors, field, "must be a DateTime")
    end
  end

  defp validate_optional_non_negative_integer(errors, attrs, field) do
    case Map.get(attrs, field) do
      nil -> errors
      value when is_integer(value) and value >= 0 -> errors
      _value -> add_error(errors, field, "must be greater than or equal to 0")
    end
  end

  defp validate_optional_percent(errors, attrs, field) do
    case Map.get(attrs, field) do
      nil ->
        errors

      %Decimal{} = value ->
        if Decimal.compare(value, Decimal.new(0)) in [:eq, :gt] and
             Decimal.compare(value, Decimal.new(100)) in [:eq, :lt],
           do: errors,
           else: add_error(errors, field, "must be between 0 and 100")

      _value ->
        add_error(errors, field, "must be a Decimal")
    end
  end

  defp add_error(errors, field, message),
    do: Map.update(errors, field, [message], &[message | &1])

  defp normalize_identity_part(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim()

  defp normalize_identity_part(_value), do: ""

  defp optional_identity_part(value) when is_binary(value), do: String.trim(value)
  defp optional_identity_part(_value), do: ""

  defp normalize_quota_key(nil), do: nil

  defp normalize_quota_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_quota_key(value), do: value |> to_string() |> normalize_quota_key()

  defp normalize_token(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_token(value), do: value

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: trunc(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp datetime_or_nil(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp datetime_or_nil(nil), do: nil

  defp datetime_or_nil(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp datetime_or_nil(_value), do: nil

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(%Decimal{} = value), do: value
  defp decimal_or_nil(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_nil(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal_or_nil(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _invalid -> nil
    end
  end

  defp decimal_or_nil(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
