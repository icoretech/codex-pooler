defmodule CodexPooler.Accounting.PricingResolution.Generations do
  @moduledoc false

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo
  alias CodexPooler.ServiceTier

  # The statement's MVCC snapshot covers anchors, siblings, historical bucket
  # winners and missing-tier evidence together, even while an import commits.
  # Candidate restriction precedes ranking; at most four rows leave PostgreSQL
  # per candidate, irrespective of how much immutable history it holds.
  @sql """
  WITH candidates AS MATERIALIZED (
    SELECT DISTINCT unnest($1::text[]) AS identifier
  ), eligible AS MATERIALIZED (
    SELECT ps.*, lower(ps.model_identifier) AS identifier
    FROM pricing_snapshots ps JOIN candidates c ON lower(ps.model_identifier) = c.identifier
    WHERE ps.effective_at <= $2
      AND (ps.config->>'pricing_effective_until' IS NULL OR (ps.config->>'pricing_effective_until')::timestamptz > $2)
      AND ps.config->>'pricing_type' = 'per_1m_tokens'
  ), anchors AS MATERIALIZED (
    SELECT DISTINCT ON (identifier) e.*
    FROM eligible e WHERE e.config->>'service_tier' = ANY($3::text[])
    ORDER BY identifier, effective_at DESC, captured_at DESC,
      CASE WHEN config->>'service_tier' = $4 THEN 0 ELSE 1 END, id DESC
  ), buckets AS (
    SELECT DISTINCT ON (e.identifier, e.config->>'price_bucket') e.*
    FROM eligible e JOIN anchors a ON e.identifier = a.identifier
    WHERE e.config->>'service_tier' = ANY($3::text[])
      AND e.config->>'price_bucket' IN ('default', 'short_context', 'long_context')
      AND (NOT (COALESCE(a.config->>'importer_format_revision', '') IN ('3', '4', '5') OR a.config ? 'context_pricing')
        OR (e.price_version = a.price_version
          AND COALESCE(e.config->>'importer_format_revision', '') = COALESCE(a.config->>'importer_format_revision', '')))
    ORDER BY e.identifier, e.config->>'price_bucket', e.effective_at DESC, e.captured_at DESC,
      CASE WHEN e.config->>'service_tier' = $4 THEN 0 ELSE 1 END, e.id DESC
  ), selected AS (
    SELECT 'anchor' AS kind, a.* FROM anchors a
    UNION ALL
    SELECT 'bucket' AS kind, b.* FROM buckets b
  )
  SELECT c.identifier AS candidate_identifier,
    EXISTS (SELECT 1 FROM eligible e WHERE e.identifier = c.identifier AND e.config->>'price_bucket' = 'default') AS model_exists,
    s.*
  FROM candidates c LEFT JOIN selected s ON s.identifier = c.identifier
  """

  @type family :: %{anchor: PricingSnapshot.t() | nil, buckets: map(), model_exists: boolean()}

  @spec statement([String.t()], String.t(), DateTime.t()) :: {String.t(), list()}
  def statement(identifiers, service_tier, timestamp) do
    {@sql, [Enum.uniq(identifiers), timestamp, ServiceTier.pricing_aliases(service_tier), ServiceTier.canonicalize(service_tier)]}
  end

  @spec load([String.t()], String.t(), DateTime.t()) :: %{String.t() => family()}
  def load(identifiers, service_tier, timestamp) do
    {sql, params} = statement(identifiers, service_tier, timestamp)
    %{columns: columns, rows: rows} = Repo.query!(sql, params)

    Enum.reduce(rows, %{}, fn row, families ->
      values = Map.new(Enum.zip(columns, row))
      identifier = values["candidate_identifier"]
      family = Map.get(families, identifier, %{anchor: nil, buckets: %{}, model_exists: values["model_exists"]})
      family = put_snapshot(family, values)
      Map.put(families, identifier, family)
    end)
  end

  defp put_snapshot(family, %{"kind" => nil}), do: family

  defp put_snapshot(family, %{"kind" => kind} = values) do
    snapshot = Repo.load(PricingSnapshot, values)

    case kind do
      "anchor" -> %{family | anchor: snapshot}
      "bucket" -> %{family | buckets: Map.put(family.buckets, snapshot.config["price_bucket"], snapshot)}
    end
  end
end
