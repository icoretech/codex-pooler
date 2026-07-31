defmodule CodexPooler.TestHelperTest do
  use ExUnit.Case, async: false

  @native_turn_console_filter :codex_pooler_test_native_turn_console_filter

  test "keeps the native-turn console filter installed across repeated ExUnit runs" do
    assert {:ok, %{filters: filters}} = :logger.get_handler_config(:default)

    assert Enum.any?(filters, fn {filter_id, _filter} ->
             filter_id == @native_turn_console_filter
           end)
  end
end
