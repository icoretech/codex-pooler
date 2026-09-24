defmodule CodexPoolerWeb.Admin.LogPagination do
  @moduledoc """
  The pager shared by the record tables that draw from a set larger than a page.

  Shape and arithmetic live here so a second log page does not become a second
  copy of both. Callers keep their route, their filter keys, and whatever the
  page needs beside the range.
  """

  use CodexPoolerWeb, :html

  @doc """
  Page metadata derived from a reader's `{items, total, limit, offset}` window.

  A window whose `total_exact?` is `false` counted only up to `total` and more
  rows match: its page count and range read as a lower bound ("200+",
  "1-50 of 10000+"). A reader counts past its current page, so the next page
  stays reachable.
  """
  @spec metadata(map()) :: map()
  def metadata(%{total: total, limit: limit, offset: offset} = window)
      when is_integer(limit) and limit > 0 do
    exact? = Map.get(window, :total_exact?, true) != false
    total_pages = max(ceil(total / limit), 1)

    %{
      current_page: div(offset, limit) + 1,
      total_pages: total_pages,
      total_pages_label: bound_label(total_pages, exact?),
      has_previous_page: offset > 0,
      has_next_page: offset + limit < total,
      range: range(total, limit, offset, exact?)
    }
  end

  # A caller can satisfy the `:map` attr without carrying a window.
  def metadata(_window) do
    %{
      current_page: 1,
      total_pages: 1,
      total_pages_label: "1",
      has_previous_page: false,
      has_next_page: false,
      range: "0 of 0"
    }
  end

  defp range(0, _limit, _offset, _exact?), do: "0 of 0"

  defp range(total, limit, offset, exact?),
    do: "#{offset + 1}-#{min(offset + limit, total)} of #{bound_label(total, exact?)}"

  defp bound_label(count, true), do: Integer.to_string(count)
  defp bound_label(count, false), do: "#{count}+"

  @doc """
  The last page that still has rows, for correcting a page past the end.
  """
  @spec last_page(map()) :: pos_integer()
  def last_page(%{total: total, limit: limit}) when is_integer(limit) and limit > 0,
    do: max(div(max(total - 1, 0), limit) + 1, 1)

  def last_page(_window), do: 1

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :page, :map, required: true, doc: "the result of metadata/1"
  attr :previous_path, :string, default: nil
  attr :next_path, :string, default: nil

  slot :aside, doc: "page-specific detail rendered beside the range"

  @doc """
  One row, at every width and in every state.

  Sticky above the rows rather than rendered at both ends: fifty records is a
  long scroll to reach Next. Below `sm` the ordinal steps aside, since the range
  says the same thing more precisely.
  """
  def pager(assigns) do
    ~H"""
    <nav
      id={@id}
      class="sticky top-0 z-20 -mx-1 bg-base-200 px-1 py-2 text-xs"
      aria-label={@label}
    >
      <div class="flex items-center gap-3">
        <p data-role="pagination-status" class="hidden shrink-0 text-base-content/60 sm:block">
          Page {@page.current_page} of {@page.total_pages_label}
        </p>

        <div class="flex min-w-0 grow items-center gap-2 sm:justify-center">
          <p
            id={"#{@id}-range"}
            data-role="pagination-range"
            class="min-w-0 truncate tabular-nums text-base-content/70"
          >
            <span class="hidden sm:inline">Showing </span>{@page.range}
          </p>
          {render_slot(@aside)}
        </div>

        <div class="join shrink-0">
          <.pagination_link
            id={"#{@id}-prev"}
            label="Previous"
            path={@previous_path}
            enabled={@page.has_previous_page}
          />
          <.pagination_link
            id={"#{@id}-next"}
            label="Next"
            path={@next_path}
            enabled={@page.has_next_page}
          />
        </div>
      </div>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, default: nil
  attr :enabled, :boolean, required: true

  # Disabled as a span rather than removed, so the row does not reflow under the
  # cursor at the boundaries.
  defp pagination_link(assigns) do
    ~H"""
    <.link
      :if={@enabled and @path}
      id={@id}
      data-role="pagination-link"
      patch={@path}
      class="btn btn-xs join-item"
    >
      {@label}
    </.link>
    <span
      :if={!(@enabled and @path)}
      id={@id}
      data-role="pagination-link"
      aria-disabled="true"
      class="btn btn-xs join-item btn-disabled"
    >
      {@label}
    </span>
    """
  end
end
