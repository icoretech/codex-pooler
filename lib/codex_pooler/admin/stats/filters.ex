defmodule CodexPooler.Admin.Stats.Filters do
  @moduledoc false

  alias CodexPooler.Pools.Pool

  @supported_windows %{
    "1h" => {:one_hour, 1, :hour},
    "5h" => {:five_hours, 5, :hour},
    "24h" => {:twenty_four_hours, 24, :hour},
    "7d" => {:seven_days, 7, :day}
  }

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type window :: :one_hour | :five_hours | :twenty_four_hours | :seven_days
  @type pool_summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:name) => String.t(),
          required(:slug) => String.t(),
          required(:status) => String.t()
        }
  @type normalized :: %{
          required(:pool_id) => String.t() | nil,
          required(:selected_pool) => Pool.t() | nil,
          required(:window) => window(),
          required(:window_key) => String.t(),
          required(:started_at) => DateTime.t(),
          required(:ended_at) => DateTime.t()
        }
  @type public_filters :: %{
          required(:pool_id) => String.t() | nil,
          required(:window) => String.t(),
          required(:started_at) => DateTime.t(),
          required(:ended_at) => DateTime.t(),
          required(:pool_options) => [pool_summary()]
        }

  @spec normalize(map() | keyword(), [Pool.t()]) :: {:ok, normalized()} | {:error, access_error()}
  def normalize(filters, pools) do
    filters = Map.new(filters)
    pool_id = blank_to_nil(value_for(filters, :pool_id))
    window_key = blank_to_nil(value_for(filters, :window)) || "24h"

    with {:ok, selected_pool} <- selected_pool(pool_id, pools),
         {:ok, window} <- normalize_window(window_key) do
      ended_at = normalize_as_of(value_for(filters, :as_of))
      started_at = DateTime.add(ended_at, -window_seconds(window), :second)

      {:ok,
       %{
         pool_id: pool_id,
         selected_pool: selected_pool,
         window: window,
         window_key: window_key,
         started_at: started_at,
         ended_at: ended_at
       }}
    end
  end

  @spec dashboard_pool_ids(normalized(), [Pool.t()]) :: [Ecto.UUID.t()]
  def dashboard_pool_ids(%{selected_pool: %Pool{id: id}}, _pools), do: [id]
  def dashboard_pool_ids(_normalized, pools), do: Enum.map(pools, & &1.id)

  @spec public(normalized(), [Pool.t()]) :: public_filters()
  def public(normalized, pools) do
    %{
      pool_id: normalized.pool_id,
      window: normalized.window_key,
      started_at: normalized.started_at,
      ended_at: normalized.ended_at,
      pool_options: Enum.map(pools, &pool_summary/1)
    }
  end

  @spec pool_summary(Pool.t() | nil) :: pool_summary() | nil
  def pool_summary(nil), do: nil

  def pool_summary(%Pool{} = pool),
    do: %{id: pool.id, name: pool.name, slug: pool.slug, status: pool.status}

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}

  defp selected_pool(nil, _pools), do: {:ok, nil}

  defp selected_pool(pool_id, pools) do
    case Enum.find(pools, &(&1.id == pool_id)) do
      %Pool{} = pool -> {:ok, pool}
      nil -> {:error, access_error(:pool_not_found, "pool filter is not available")}
    end
  end

  defp normalize_window(window_key) do
    case Map.fetch(@supported_windows, to_string(window_key)) do
      {:ok, {window, _amount, _unit}} ->
        {:ok, window}

      :error ->
        {:error, access_error(:invalid_window, "window must be one of 1h, 5h, 24h, or 7d")}
    end
  end

  defp window_seconds(:one_hour), do: 60 * 60
  defp window_seconds(:five_hours), do: 5 * 60 * 60
  defp window_seconds(:twenty_four_hours), do: 24 * 60 * 60
  defp window_seconds(:seven_days), do: 7 * 24 * 60 * 60

  defp normalize_as_of(%DateTime{} = as_of), do: DateTime.truncate(as_of, :microsecond)
  defp normalize_as_of(_as_of), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value_for(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
