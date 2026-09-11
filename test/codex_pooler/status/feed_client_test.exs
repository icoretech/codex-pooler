defmodule CodexPooler.Status.FeedClientTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Status.FeedClient

  test "classifies network failures with bounded metadata" do
    assert {:error, %{code: :network_error, message: "feed transport failed"}} =
             FeedClient.fetch(%{}, url: "http://127.0.0.1:1/feed.rss", timeout: 100)
  end
end
