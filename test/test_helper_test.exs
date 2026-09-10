defmodule CodexPooler.TestHelperTest do
  use ExUnit.Case, async: false

  @native_turn_console_filter :codex_pooler_test_native_turn_console_filter

  test "keeps expected native-turn failures out of the console across repeated ExUnit runs" do
    case :logger.get_handler_config(:default) do
      {:ok, %{filters: filters}} ->
        assert Enum.any?(filters, fn {filter_id, _filter} ->
                 filter_id == @native_turn_console_filter
               end)

      {:error, {:not_found, :default}} ->
        # ExUnit replaces the console handler while capturing logs per test;
        # captured output is shown only for failures, so nothing leaks either.
        assert ExUnit.configuration()[:capture_log] == true
    end
  end
end
