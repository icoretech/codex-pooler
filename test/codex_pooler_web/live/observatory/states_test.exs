defmodule CodexPoolerWeb.Observatory.StatesTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.States

  test "states expose every stable selector with safe accessible copy" do
    states = [:loading, :empty, :partial_accounting, :stale, :disconnected, :error]

    for state <- states do
      html = render_component(&States.state/1, %{state: state})
      fragment = LazyHTML.from_fragment(html)
      state_id = if state == :partial_accounting, do: "partial-accounting", else: state
      selector = "#observatory-state-#{state_id}"

      refute fragment |> LazyHTML.query(selector) |> Enum.empty?()
      refute fragment |> LazyHTML.query("#{selector}[role='status']") |> Enum.empty?()
      refute fragment |> LazyHTML.query("#{selector}[aria-live='polite']") |> Enum.empty?()
      refute LazyHTML.text(fragment) =~ "redaction-probe"
      refute html =~ ~r/\b(admin|Pool|upstream|operator)\b/i
    end

    assert render_component(&States.state/1, %{state: :loading}) =~ "Loading usage"
    assert render_component(&States.state/1, %{state: :empty}) =~ "No usage in this window"
    assert render_component(&States.state/1, %{state: :partial_accounting}) =~ "estimated"
    assert render_component(&States.state/1, %{state: :stale}) =~ "Updates paused"
    assert render_component(&States.state/1, %{state: :disconnected}) =~ "Connection interrupted"
    assert render_component(&States.state/1, %{state: :error}) =~ "temporarily unavailable"
  end

  test "states render distinct contract anatomy" do
    loading = state_fragment(:loading)
    empty = state_fragment(:empty)
    partial = state_fragment(:partial_accounting)
    stale = state_fragment(:stale)
    disconnected = state_fragment(:disconnected)
    error = state_fragment(:error)

    refute loading
           |> LazyHTML.query("#observatory-state-loading [data-role='loading-progress']")
           |> Enum.empty?()

    refute empty
           |> LazyHTML.query(
             "#observatory-state-empty > #observatory-state-empty-anatomy.border-dashed"
           )
           |> Enum.empty?()

    refute partial
           |> LazyHTML.query(
             "#observatory-state-partial-accounting [data-accounting-status='settled']"
           )
           |> Enum.empty?()

    refute partial
           |> LazyHTML.query(
             "#observatory-state-partial-accounting [data-accounting-status='estimated']"
           )
           |> Enum.empty?()

    refute stale
           |> LazyHTML.query("#observatory-state-stale [data-role='paused-state']")
           |> Enum.empty?()

    refute disconnected
           |> LazyHTML.query("#observatory-state-disconnected [data-role='reconnect-flash']")
           |> Enum.empty?()

    refute disconnected
           |> LazyHTML.query("#observatory-state-disconnected-spinner")
           |> Enum.empty?()

    refute error
           |> LazyHTML.query("#observatory-state-error [data-role='error-state']")
           |> Enum.empty?()
  end

  defp state_fragment(state) do
    render_component(&States.state/1, %{state: state})
    |> LazyHTML.from_fragment()
  end
end
