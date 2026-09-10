defmodule CodexPooler.Upstreams.Quota.Windows.RuntimeCoherence do
  @moduledoc """
  Counts consecutive coherent runtime observations of one quota window.

  A coherent observation is a `codex_response_headers` or
  `codex_rate_limit_event` reading the window row actually adopted, that is
  not exhausted and carries no provider denial (`rate_limit_reached_type`,
  `rate_limit_allowed=false`, `rate_limit_reached=true`), describing the same
  running cycle as the previous coherent observation. A successful provider
  response that reports the window below 100% is itself proof the account
  served, so two such readings let logical window selection drop a fresh
  exhausted Usage API row of the same cycle: after a provider incident the
  Usage API can keep reporting `100% used` every minute while runtime traffic
  keeps succeeding at a lower percentage. Because both surfaces refresh on a
  cadence of about a minute, the confirmation may be observed up to five
  minutes before the exhausted reading it supersedes; a runtime denial or
  exhausted reading clears the count, so a genuine exhaustion re-establishes
  the Usage API row on the next failed request. `UsageCoherence` is the
  mirror direction; both share `Coherence`.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.Coherence

  @metadata_key "__quota_runtime_coherence_v1"
  @runtime_sources ["codex_response_headers", "codex_rate_limit_event"]
  @override_tolerance_seconds 5 * 60

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec required_observations() :: pos_integer()
  def required_observations, do: Coherence.required_observations()

  @spec override_tolerance_seconds() :: non_neg_integer()
  def override_tolerance_seconds, do: @override_tolerance_seconds

  @doc false
  @spec spec() :: Coherence.spec()
  def spec do
    %{
      metadata_key: @metadata_key,
      sources: @runtime_sources,
      coherent_reading?: &coherent_reading?/1,
      override_tolerance_seconds: @override_tolerance_seconds
    }
  end

  @spec observe(map(), Evidence.t(), DateTime.t()) :: map()
  def observe(attrs, evidence, timestamp),
    do: Coherence.observe(spec(), attrs, evidence, timestamp)

  @doc """
  True when the window carries at least two coherent runtime observations of
  its current cycle and is still fresh and not exhausted at `as_of`.
  """
  @spec confirmed?(AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def confirmed?(window, as_of), do: Coherence.confirmed?(spec(), window, as_of)

  @doc """
  True when `runtime` is a confirmed runtime window that supersedes `window`,
  a fresh exhausted row from another surface (the Usage API) describing the
  same cycle and observed no later than the confirming readings plus the
  override tolerance.
  """
  @spec overrides?(AccountQuotaWindow.t(), AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def overrides?(runtime, window, as_of), do: Coherence.overrides?(spec(), runtime, window, as_of)

  @doc false
  @spec parse_marker(map() | nil) :: {:ok, map()} | :none
  def parse_marker(metadata), do: Coherence.parse_marker(metadata, @metadata_key)

  defp coherent_reading?(%Evidence{
         reset_at: %DateTime{},
         observed_at: %DateTime{},
         used_percent: %Decimal{} = used_percent,
         metadata: metadata
       }) do
    metadata = metadata || %{}

    Coherence.not_exhausted?(used_percent) and is_nil(metadata["rate_limit_reached_type"]) and
      metadata["rate_limit_allowed"] != false and metadata["rate_limit_reached"] != true
  end

  defp coherent_reading?(_evidence), do: false
end
