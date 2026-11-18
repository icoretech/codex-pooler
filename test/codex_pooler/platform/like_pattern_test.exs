defmodule CodexPooler.Platform.LikePatternTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Platform.LikePattern

  test "contains/1 escapes LIKE metacharacters and wraps the text in wildcards" do
    assert LikePattern.contains("gpt_5") == "%gpt\\_5%"
    assert LikePattern.contains("100%") == "%100\\%%"
    assert LikePattern.contains("a\\b") == "%a\\\\b%"
    assert LikePattern.contains("plain") == "%plain%"
  end
end
