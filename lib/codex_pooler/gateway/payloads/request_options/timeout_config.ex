defmodule CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings

  defstruct [:connect_timeout_ms, :pool_timeout_ms, :receive_timeout_ms]

  @type t :: %__MODULE__{
          connect_timeout_ms: non_neg_integer(),
          pool_timeout_ms: non_neg_integer(),
          receive_timeout_ms: non_neg_integer()
        }

  @spec build(map() | keyword()) :: t()
  def build(opts) do
    opts = Map.new(opts)
    settings = OperationalSettings.current()
    shared_timeout = Map.get(opts, :timeout)

    %__MODULE__{
      connect_timeout_ms:
        configured_timeout(
          opts,
          :connect_timeout,
          :connect_timeout_ms,
          shared_timeout,
          settings.upstream_connect_timeout_ms
        ),
      pool_timeout_ms:
        configured_timeout(
          opts,
          :pool_timeout,
          :pool_timeout_ms,
          shared_timeout,
          settings.upstream_pool_timeout_ms
        ),
      receive_timeout_ms:
        configured_timeout(
          opts,
          :receive_timeout,
          :receive_timeout_ms,
          shared_timeout,
          settings.upstream_receive_timeout_ms
        )
    }
  end

  defp configured_timeout(opts, opts_key, opts_ms_key, shared_timeout, default) do
    [Map.get(opts, opts_key), Map.get(opts, opts_ms_key), shared_timeout]
    |> Enum.find(&non_negative_integer?/1)
    |> case do
      nil -> default
      timeout -> timeout
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
