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
    # The line names the rolled-back reason with its bounded code, so the
    # cause can be read from production, and nothing of the raw result
    # (findings#225, row 225-96).
    assert log =~ "pool_upstream_assignment_id=#{context.assignment.id} reason_code=stale_owner"
    refute log =~ "{:error"
  end

  for {label, result, code} <- [
        {"a deadlock after its retries", {:error, :continuity_deadlock}, "continuity_deadlock"},
        {"a non-identifier reason", {:error, %Ecto.Changeset{}}, "unclassified_error"},
        {"an unexpected result", :unexpected, "unexpected_result"}
      ] do
    test "continuity registration failure names #{label} with a bounded code" do
      context = context()

      log =
        capture_log(fn ->
          assert :ok =
                   SideEffects.record_success(context, %{}, "{}", context.request_options, %{
                     register_continuity: fn _options, _payload, _body -> unquote(Macro.escape(result)) end
                   })
        end)

      assert log =~ "gateway continuity registration failed pool_upstream_assignment_id=#{context.assignment.id} reason_code=#{unquote(code)}"
      refute log =~ "Changeset"
    end
  end

  test "continuity registration that raises a database error names its class" do
    context = context()

    log =
      capture_log(fn ->
        assert :ok =
                 SideEffects.record_success(context, %{}, "{}", context.request_options, %{
                   register_continuity: fn _options, _payload, _body -> raise Postgrex.Error, message: "synthetic" end
                 })
      end)

    assert log =~ "reason_code=database_error"
    refute log =~ "synthetic"
  end

  defp context do
    request_options = RequestOptions.build(%{transport: "http_json"}, "/backend-api/codex/responses", %{})

    %SelectedCandidateContext{
      reserved: %{request: %Request{id: Ecto.UUID.generate()}},
      assignment: %PoolUpstreamAssignment{id: Ecto.UUID.generate()},
      attempt: %{replay_generation: 0},
      request_options: request_options
    }
  end
end
