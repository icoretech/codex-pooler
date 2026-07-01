defmodule CodexPoolerWeb.Browser.BrowserAnnotationCompatibilityTest do
  use CodexPoolerWeb.ConnCase, async: true

  test "LiveView roots keep generated boxes for external annotation overlays" do
    css = File.read!("assets/css/app.css")

    refute css =~ ~r/\[data-phx-session\][^{]*\{[^}]*display:\s*contents/i
  end
end
