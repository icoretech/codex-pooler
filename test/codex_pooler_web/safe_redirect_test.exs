defmodule CodexPoolerWeb.SafeRedirectTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.SafeRedirect

  test "keeps local absolute paths, query strings, fragments, and encoded ordinary content" do
    for path <- ["/", "/admin/pools", "/admin/settings?tab=appearance", "/login#language", "/admin/pools?name=Pool%20A", "/search?url=https://example.com", "/%E4%B8%AD%E6%96%87"] do
      assert SafeRedirect.local_path(path) == path
    end
  end

  test "rejects external, scheme-relative, non-path, backslash, and encoded open redirects" do
    for path <- ["https://example.com/evil", "//example.com", "///example.com", "javascript:alert(1)", "admin/pools", "", nil, %{}, "/\\example.com", "/%5cexample.com", "/%5Cexample.com", "/%2fexample.com", "/%2F%2Fexample.com", "/%252fexample.com", "/%255cexample.com", "/%2509/example.com"] do
      assert SafeRedirect.local_path(path) == nil
    end
  end

  test "rejects raw and encoded controls at every position" do
    for codepoint <- Enum.to_list(0..31) ++ Enum.to_list(127..159) do
      control = <<codepoint::utf8>>
      assert SafeRedirect.local_path("/admin/" <> control <> "settings") == nil
      assert SafeRedirect.local_path("/" <> control <> "/example.com") == nil
      assert SafeRedirect.local_path("/admin/" <> URI.encode(control, fn _byte -> false end)) == nil
    end

    assert SafeRedirect.local_path(<<"/", 255>>) == nil
    assert SafeRedirect.local_path("/%FF") == nil
  end
end
