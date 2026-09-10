defmodule CodexPooler.Upstreams.Quota.Windows.UsageCoherence do
  @moduledoc """
  Counts consecutive coherent Usage API observations of one quota window.

  A coherent observation is a `codex_usage_api` reading the window row actually
  adopted (the row's `observed_at` is the incoming observation), whose provider
  permission facts say allowed and not limit-reached, that is not exhausted,
  and that describes the same running cycle as the previous coherent
  observation. The count lets logical window selection drop a fresh exhausted
  row from another surface (response headers, rate-limit events, runtime) once
  the provider itself reported usable capacity twice: one lower reading stays a
  suspicion that the exhausted row keeps winning, two coherent readings are a
  recovery. Any exhausted or permission-denied reading clears the count. The
  mirror direction (runtime readings contradicting a Usage API exhaustion) is
  `RuntimeCoherence`; both share `Coherence`.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.Coherence

  @metadata_key "__quota_usage_coherence_v1"
  @provider_source "codex_usage_api"

  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @spec required_observations() :: pos_integer()
  def required_observations, do: Coherence.required_observations()

  @doc false
  @spec spec() :: Coherence.spec()
  def spec do
    %{
      metadata_key: @metadata_key,
      sources: [@provider_source],
      coherent_reading?: &coherent_reading?/1,
      # The exhausted row must have been observed before the confirming readings.
      override_tolerance_seconds: 0
    }
  end

  @doc """
  Maintains the coherence marker on the merged window attributes.

  Runs on every persisted Usage API observation. Readings the merge did not
  adopt (rejected or retained as a candidate) leave the marker untouched;
  exhausted or permission-denied readings clear it; adopted coherent readings
  extend the count within the same cycle or restart it at one.
  """
  @spec observe(map(), Evidence.t(), DateTime.t()) :: map()
  def observe(attrs, evidence, timestamp),
    do: Coherence.observe(spec(), attrs, evidence, timestamp)

  @doc """
  True when the window carries at least two coherent Usage API observations
  of its current cycle and is still fresh, allowed and not exhausted at `as_of`.
  """
  @spec confirmed?(AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def confirmed?(window, as_of), do: Coherence.confirmed?(spec(), window, as_of)

  @doc """
  True when `usage` is a confirmed Usage API window that supersedes `window`,
  a fresh exhausted row from another evidence surface describing the same
  cycle and observed before the confirming readings.
  """
  @spec overrides?(AccountQuotaWindow.t(), AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def overrides?(usage, window, as_of), do: Coherence.overrides?(spec(), usage, window, as_of)

  @doc false
  @spec parse_marker(map() | nil) :: {:ok, map()} | :none
  def parse_marker(metadata), do: Coherence.parse_marker(metadata, @metadata_key)

  defp coherent_reading?(%Evidence{
         reset_at: %DateTime{},
         observed_at: %DateTime{},
         used_percent: %Decimal{} = used_percent,
         metadata: metadata
       })
       when is_map(metadata) do
    metadata["rate_limit_allowed"] == true and metadata["rate_limit_reached"] == false and
      Coherence.not_exhausted?(used_percent)
  end

  defp coherent_reading?(_evidence), do: false
end
