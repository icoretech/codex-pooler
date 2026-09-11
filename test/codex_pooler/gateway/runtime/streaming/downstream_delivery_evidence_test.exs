defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamDeliveryEvidenceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamDeliveryEvidence, as: Evidence

  @delta "data: " <>
           ~s({"type":"response.output_text.delta","delta":"evidence-prompt-sentinel"}) <> "\n\n"
  @completed "event: response.completed\ndata: " <>
               ~s({"type":"response.completed","response":{"id":"resp_evidence_completed"}}) <>
               "\n\n"
  @failed "event: response.failed\ndata: " <>
            ~s({"type":"response.failed","response":{"id":"resp_evidence_failed","error":{"code":"server_error"}}}) <>
            "\n\n"

  test "counts chunks only after visible output and records the first terminal once" do
    state = Evidence.record_write(%{target: :conn}, @delta)

    assert Evidence.receipt(state) == %{
             "outcome" => "completed",
             "terminal_class" => "none",
             "pushed_at" => nil,
             "frames_after_visible" => 0,
             "transport" => "http_sse"
           }

    state =
      state
      |> Map.put(:visible_output_marked?, true)
      |> Evidence.record_write(@delta)
      |> Evidence.record_write(@completed)
      |> Evidence.record_write("data: [DONE]\n\n")

    assert %{
             "outcome" => "delivered",
             "terminal_class" => "response.completed",
             "pushed_at" => pushed_at,
             "frames_after_visible" => 3,
             "transport" => "http_sse"
           } = Evidence.receipt(state)

    assert {:ok, _pushed_at, 0} = DateTime.from_iso8601(pushed_at)

    later = Evidence.record_write(state, @failed)
    assert Evidence.receipt(later)["terminal_class"] == "response.completed"
    assert Evidence.receipt(later)["pushed_at"] == pushed_at
    assert Evidence.receipt(later)["frames_after_visible"] == 4
  end

  test "classifies a terminal block that arrives split across two chunks" do
    {head, tail} = String.split_at(@completed, 40)

    state = Evidence.record_write(%{visible_output_marked?: true}, head)
    assert Evidence.receipt(state)["terminal_class"] == "none"

    state = Evidence.record_write(state, tail)
    assert Evidence.receipt(state)["terminal_class"] == "response.completed"
    assert Evidence.receipt(state)["frames_after_visible"] == 2
  end

  test "maps a failed provider terminal and a synthetic error onto the fixed vocabulary" do
    failed = Evidence.record_write(%{visible_output_marked?: true}, @failed)
    assert Evidence.receipt(failed)["terminal_class"] == "response.failed"
    assert Evidence.receipt(failed)["outcome"] == "delivered"

    synthetic =
      "event: error\ndata: " <>
        ~s({"type":"error","sequence_number":3,"error":{"type":"server_error","code":"server_error","message":"synthetic"}}) <>
        "\n\n"

    error = Evidence.record_write(%{visible_output_marked?: true}, synthetic)
    assert Evidence.receipt(error)["terminal_class"] == "error"
  end

  test "a failed downstream write before the terminal aborts; after the terminal it stays delivered" do
    aborted =
      %{visible_output_marked?: true}
      |> Evidence.record_write(@delta)
      |> Evidence.record_write_failure()

    assert %{
             "outcome" => "aborted",
             "terminal_class" => "none",
             "pushed_at" => nil,
             "frames_after_visible" => 1
           } = Evidence.receipt(aborted)

    delivered =
      %{visible_output_marked?: true}
      |> Evidence.record_write(@completed)
      |> Evidence.record_write_failure()

    assert Evidence.receipt(delivered)["outcome"] == "delivered"
  end

  test "empty writes are not frames and the receipt stays metadata-only" do
    state = Evidence.record_write(%{visible_output_marked?: true}, "")
    assert Evidence.receipt(state)["frames_after_visible"] == 0

    receipt = state |> Evidence.record_write(@delta) |> Evidence.receipt()
    refute inspect(receipt) =~ "evidence-prompt-sentinel"
    refute inspect(receipt) =~ "resp_evidence"

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w(frames_after_visible outcome pushed_at terminal_class transport)
  end
end
