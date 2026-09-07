defmodule CodexPooler.Metrics.AccountValues do
  @moduledoc false

  def timestamp(%DateTime{} = value), do: value
  def timestamp(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  def timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  def timestamp(_value), do: nil

  def visible_timestamp(value, as_of) do
    case timestamp(value) do
      nil -> nil
      time -> if DateTime.compare(time, as_of) != :gt, do: time
    end
  end

  def seconds(nil), do: nil
  def seconds(time), do: DateTime.to_unix(time, :microsecond) / 1_000_000

  def percent(%Decimal{coef: coefficient} = value) when is_integer(coefficient) do
    if Decimal.compare(value, 0) != :lt and Decimal.compare(value, 100) != :gt, do: value
  end

  def percent(_value), do: nil

  def uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "invalid internal metric identity"
    end
  end

  def closed(value, allowed), do: if(value in allowed, do: value, else: "unknown")
  def flag(true), do: 1
  def flag(false), do: 0

  # SQL supplies PostgreSQL lower(model) and lower(upstream_model). Other
  # strings deliberately retain their persisted case, spacing and nullability.
  def observation_id(row) do
    tuple = {
      row.upstream_identity_id,
      row.quota_scope,
      row.quota_family,
      row.index_model,
      row.index_upstream_model,
      row.quota_key,
      row.window_kind,
      row.window_minutes,
      row.source,
      row.raw_limit_id || "",
      row.raw_limit_name || "",
      row.raw_metered_feature || ""
    }

    :crypto.hash(:sha256, "quota-persisted-observation-v1:" <> :erlang.term_to_binary(tuple))
    |> Base.encode16(case: :lower)
  end
end
