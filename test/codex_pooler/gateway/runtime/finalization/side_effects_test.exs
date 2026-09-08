defmodule CodexPooler.Gateway.Runtime.Finalization.SideEffectsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  test "continuity registration failure stays best effort after successful settlement" do
    request_options =
      RequestOptions.build(
        %{transport: "http_json"},
        "/backend-api/codex/responses",
        %{}
      )

    context = %SelectedCandidateContext{
      reserved: %{request: %Request{id: Ecto.UUID.generate()}},
      assignment: %PoolUpstreamAssignment{id: Ecto.UUID.generate()},
      attempt: %{replay_generation: 0},
      request_options: request_options
    }

    log =
      capture_log(fn ->
        assert :ok =
                 SideEffects.record_success(
                   context,
                   %{},
                   "{}",
                   request_options,
                   %{
                     register_continuity: fn _options, _payload, _body ->
                       {:error, :stale_owner}
                     end
                   }
                 )
      end)

    assert log =~ "gateway continuity registration failed"
    refute log =~ "stale_owner"
  end
end
