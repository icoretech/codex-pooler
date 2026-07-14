defmodule CodexPoolerWeb.Admin.LogPaginationTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.LogPagination

  describe "parse_page/1" do
    test "defaults missing and blank pages to the first page" do
      assert {1, nil} = LogPagination.parse_page(%{})
      assert {1, nil} = LogPagination.parse_page(%{"page" => "  "})
    end

    test "accepts trimmed positive integers" do
      assert {3, nil} = LogPagination.parse_page(%{"page" => " 3 "})
      assert {4, nil} = LogPagination.parse_page(%{"page" => 4})
    end

    test "rejects non-positive, partial, and structured values without raising" do
      for value <- ["0", "-1", "2x", "10001", %{"nested" => "1"}] do
        assert {1, %{field: :page, message: "Page must be an integer between 1 and 10,000"}} =
                 LogPagination.parse_page(%{"page" => value})
      end
    end
  end

  test "computes offsets, bounds, navigation state, and visible ranges" do
    assert LogPagination.offset(3, 50) == 100
    assert LogPagination.clamp_page(99, %{total: 51, limit: 50, offset: 4_900}) == 2
    assert LogPagination.clamp_page(7, %{total: 0, limit: 50, offset: 300}) == 1

    assert %{
             current_page: 2,
             total_pages: 2,
             previous_page: 1,
             next_page: 3,
             has_previous_page: true,
             has_next_page: false,
             range: "Showing 51-51 of 51"
           } = LogPagination.metadata(%{total: 51, limit: 50, offset: 50})

    assert %{current_page: 1, total_pages: 1, range: "Showing 0 of 0"} =
             LogPagination.metadata(%{total: 0, limit: 50, offset: 0})
  end

  test "builds deterministic paths while removing first-page and blank parameters" do
    params = %{"model" => "gpt-5", "page" => "8", "status" => "", pool_id: "pool-1"}

    assert LogPagination.path("/admin/request-logs", params, 2) ==
             "/admin/request-logs?model=gpt-5&page=2&pool_id=pool-1"

    assert LogPagination.path("/admin/request-logs", params, 1) ==
             "/admin/request-logs?model=gpt-5&pool_id=pool-1"

    assert LogPagination.path("/admin/audit-logs", %{"page" => "3"}, 1) ==
             "/admin/audit-logs"
  end
end
