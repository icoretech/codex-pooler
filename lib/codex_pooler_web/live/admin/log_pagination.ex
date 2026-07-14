defmodule CodexPoolerWeb.Admin.LogPagination do
  @moduledoc false

  use CodexPoolerWeb, :html

  @max_page 10_000

  @type page_error :: %{required(:field) => :page, required(:message) => String.t()}
  @type page_projection :: %{
          required(:total) => non_neg_integer(),
          required(:limit) => pos_integer(),
          required(:offset) => non_neg_integer()
        }

  attr :page, :map, required: true
  attr :base_path, :string, required: true
  attr :current_params, :map, required: true
  attr :id_prefix, :string, required: true
  attr :range_id, :string, required: true
  attr :range_role, :string, required: true
  attr :label, :string, required: true
  attr :placement, :atom, required: true, values: [:top, :bottom]
  attr :show_border, :boolean, default: true

  def controls(assigns) do
    assigns = assign(assigns, metadata(assigns.page))

    ~H"""
    <div
      :if={@page.total > 0}
      class={[
        "border-base-300/70 py-3",
        @show_border && @placement == :top && "border-b px-3",
        @show_border && @placement == :bottom && "border-t px-3",
        !@show_border && "px-3"
      ]}
    >
      <nav
        id={@id_prefix}
        class="grid gap-3 text-sm sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center"
        aria-label={pagination_label(@label, @placement)}
      >
        <p data-role="pagination-status" class="text-base-content/60">
          Page {@current_page} of {@total_pages}
        </p>
        <p
          id={@range_id}
          data-role={@range_role}
          class="text-center tabular-nums text-base-content/70"
        >
          {@range}
        </p>
        <div class="join">
          <.pagination_link
            id={"#{@id_prefix}-prev"}
            label="Previous"
            enabled={@has_previous_page}
            path={__MODULE__.path(@base_path, @current_params, @previous_page)}
          />
          <.pagination_link
            id={"#{@id_prefix}-next"}
            label="Next"
            enabled={@has_next_page}
            path={__MODULE__.path(@base_path, @current_params, @next_page)}
          />
        </div>
      </nav>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :enabled, :boolean, required: true
  attr :path, :string, required: true

  defp pagination_link(assigns) do
    ~H"""
    <.link
      :if={@enabled}
      id={@id}
      data-role="pagination-link"
      patch={@path}
      class="btn btn-sm join-item"
    >
      {@label}
    </.link>
    <span
      :if={!@enabled}
      id={@id}
      data-role="pagination-link"
      aria-disabled="true"
      class="btn btn-sm join-item btn-disabled"
    >
      {@label}
    </span>
    """
  end

  @spec parse_page(map()) :: {pos_integer(), page_error() | nil}
  def parse_page(params) when is_map(params) do
    params
    |> Map.get("page")
    |> normalize_page_value()
    |> parse_page_value()
  end

  @spec offset(pos_integer(), pos_integer()) :: non_neg_integer()
  def offset(page, page_size) when page > 0 and page_size > 0, do: (page - 1) * page_size

  @spec clamp_page(pos_integer(), page_projection()) :: pos_integer()
  def clamp_page(page, %{total: total, limit: limit})
      when is_integer(page) and page > 0 and is_integer(total) and total >= 0 and
             is_integer(limit) and limit > 0 do
    min(page, total_pages(total, limit))
  end

  @spec put_page(map(), integer()) :: map()
  def put_page(params, page) when is_map(params) and page <= 1 do
    params
    |> stringify_keys()
    |> Map.delete("page")
  end

  def put_page(params, page) when is_map(params) do
    params
    |> stringify_keys()
    |> Map.put("page", Integer.to_string(page))
  end

  @spec metadata(page_projection()) :: map()
  def metadata(%{total: total, limit: limit, offset: offset})
      when is_integer(total) and total >= 0 and is_integer(limit) and limit > 0 and
             is_integer(offset) and offset >= 0 do
    current_page = div(offset, limit) + 1

    %{
      current_page: current_page,
      total_pages: total_pages(total, limit),
      previous_page: current_page - 1,
      next_page: current_page + 1,
      has_previous_page: offset > 0,
      has_next_page: offset + limit < total,
      range: range(total, limit, offset)
    }
  end

  @spec path(String.t(), map(), integer()) :: String.t()
  def path(base_path, params, page) when is_binary(base_path) and is_map(params) do
    query =
      params
      |> put_page(page)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> URI.encode_query()

    if query == "", do: base_path, else: base_path <> "?" <> query
  end

  defp normalize_page_value(nil), do: nil
  defp normalize_page_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_page_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_page_value(_value), do: :invalid

  defp parse_page_value(value) when value in [nil, ""], do: {1, nil}

  defp parse_page_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 and page <= @max_page -> {page, nil}
      _other -> invalid_page()
    end
  end

  defp parse_page_value(_value), do: invalid_page()

  defp invalid_page,
    do: {1, %{field: :page, message: "Page must be an integer between 1 and 10,000"}}

  defp stringify_keys(params),
    do: Map.new(params, fn {key, value} -> {to_string(key), value} end)

  defp total_pages(total, limit), do: max(div(total + limit - 1, limit), 1)

  defp range(0, _limit, _offset), do: "Showing 0 of 0"

  defp range(total, limit, offset) do
    first = offset + 1
    last = min(offset + limit, total)
    "Showing #{first}-#{last} of #{total}"
  end

  defp pagination_label(label, :top), do: "#{label} pagination (top)"
  defp pagination_label(label, :bottom), do: "#{label} pagination"
end
