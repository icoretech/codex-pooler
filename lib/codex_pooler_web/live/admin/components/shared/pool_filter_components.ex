defmodule CodexPoolerWeb.Admin.PoolFilterComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges

  attr :id, :string, required: true
  attr :label, :string, default: "Pool"
  attr :field_name, :string, default: "pool_id"
  attr :hidden_id, :string, required: true
  attr :role, :string, default: "pool-filter"
  attr :event, :string, default: "select_pool_filter"
  attr :selected_value, :string, required: true
  attr :selected, :map, default: nil
  attr :options, :list, required: true

  def pool_filter_dropdown(assigns) do
    assigns =
      assign(
        assigns,
        :selected,
        assigns.selected || selected_pool_filter_option(assigns.options, assigns.selected_value)
      )

    ~H"""
    <div class="grid min-w-0 gap-2">
      <input
        type="hidden"
        id={@hidden_id}
        name={"filters[#{@field_name}]"}
        value={@selected_value}
      />
      <details
        id={@id}
        class="dropdown min-w-0 w-full"
        phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      >
        <summary
          data-role={"#{@role}-trigger"}
          aria-label={@label}
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.pool_filter_icon option={@selected} />
          <span class="min-w-0 flex-1 truncate">{@selected.label}</span>
          <span
            :if={Map.get(@selected, :strategy_label)}
            class="ml-auto shrink-0 text-[0.68rem] text-base-content/50"
          >
            {@selected.strategy_label}
          </span>
        </summary>
        <ul
          data-role={"#{@role}-menu"}
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- @options}>
            <button
              type="button"
              phx-click={@event}
              phx-value-pool-id={option.value}
              data-role={"#{@role}-option"}
              data-pool-id={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == (@selected_value || "") && "active"
              ]}
              aria-current={option.value == (@selected_value || "") && "true"}
            >
              <.pool_filter_icon option={option} />
              <span class="truncate">{option.label}</span>
              <span
                :if={Map.get(option, :strategy_label)}
                class="ml-auto shrink-0 text-[0.68rem] text-base-content/50"
              >
                {option.strategy_label}
              </span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :option, :map, required: true

  defp pool_filter_icon(assigns) do
    ~H"""
    <span
      data-role="pool-filter-icon"
      class={["shrink-0", Map.get(@option, :icon_class, "text-base-content/60")]}
      title={Map.get(@option, :status_label)}
    >
      <.icon name={@option.icon} class="size-4" />
      <span :if={Map.get(@option, :status_label)} class="sr-only">
        {@option.status_label}
      </span>
    </span>
    """
  end

  def pool_filter_options(pools) do
    settings_by_pool_id =
      pools
      |> Enum.map(&pool_id/1)
      |> Enum.reject(&is_nil/1)
      |> PoolRouting.routing_settings_by_pool_ids()

    pool_options =
      pools
      |> Enum.sort_by(fn pool -> pool.name |> to_string() |> String.downcase() end)
      |> Enum.map(&pool_filter_option(&1, settings_by_pool_id))

    [all_pool_filter_option() | pool_options]
  end

  def selected_pool_filter_option(options, pool_id) do
    Enum.find(options, &(&1.value == (pool_id || ""))) || all_pool_filter_option()
  end

  def all_pool_filter_options, do: [all_pool_filter_option()]

  def all_pool_filter_option do
    %{
      label: "All Pools",
      value: "",
      icon: "hero-server-stack",
      icon_class: "text-base-content/60",
      strategy_label: nil,
      status: nil,
      status_label: nil
    }
  end

  defp pool_filter_option(%Pool{} = pool, settings_by_pool_id) do
    strategy = Map.fetch!(settings_by_pool_id, pool.id).routing_strategy

    %{
      label: pool.name,
      value: pool.id,
      icon: AdminBadges.routing_strategy_icon(strategy),
      icon_class: pool_status_icon_class(pool.status),
      strategy_label: AdminBadges.routing_strategy_label(strategy),
      status: pool.status,
      status_label: pool_status_label(pool.status)
    }
  end

  defp pool_filter_option(pool, settings_by_pool_id) when is_map(pool) do
    pool_id = pool_id(pool)
    strategy = Map.fetch!(settings_by_pool_id, pool_id).routing_strategy

    %{
      label: pool_name(pool),
      value: pool_id,
      icon: AdminBadges.routing_strategy_icon(strategy),
      icon_class: pool_status_icon_class(pool_status(pool)),
      strategy_label: AdminBadges.routing_strategy_label(strategy),
      status: pool_status(pool),
      status_label: pool_status_label(pool_status(pool))
    }
  end

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(%{id: id}), do: id
  defp pool_id(%{"id" => id}), do: id
  defp pool_id(_pool), do: nil

  defp pool_name(%{name: name}), do: name
  defp pool_name(%{"name" => name}), do: name

  defp pool_status(%{status: status}), do: status
  defp pool_status(%{"status" => status}), do: status
  defp pool_status(_pool), do: nil

  defp pool_status_icon_class("active"), do: "text-success"
  defp pool_status_icon_class("disabled"), do: "text-warning"
  defp pool_status_icon_class("archived"), do: "text-error"
  defp pool_status_icon_class(_status), do: "text-base-content/60"

  defp pool_status_label("active"), do: "Active Pool"
  defp pool_status_label("disabled"), do: "Disabled Pool"
  defp pool_status_label("archived"), do: "Archived Pool"
  defp pool_status_label(_status), do: nil
end
