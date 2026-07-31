defmodule CodexPooler.Gateway.Transports.Websocket.OwnerErrorDiagnosticsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Websocket.OwnerErrorDiagnostics

  @context %{
    request_id: "request/owner diagnostics",
    codex_session_id: "session-owner-diagnostics",
    owner_instance_id: "owner@diagnostics.example",
    proxy_instance_id: "proxy@diagnostics.example"
  }

  test "passes contract reasons through without logging a collapse" do
    logs =
      capture_log(fn ->
        assert OwnerErrorDiagnostics.normalize(:stale_owner, :retarget, @context) ==
                 {:error, :stale_owner}

        assert OwnerErrorDiagnostics.normalize(:owner_busy, :attach, @context) ==
                 {:error, :owner_busy}
      end)

    refute logs =~ "websocket owner reason collapsed"
  end

  test "logs one safe canonical collapse for each literal boundary" do
    Enum.each([:retarget, :attach, :detach], fn boundary ->
      logs =
        capture_log(fn ->
          assert OwnerErrorDiagnostics.normalize(:synthetic_owner_failure, boundary, @context) ==
                   {:error, :owner_unavailable}
        end)

      assert_single_collapse!(logs, boundary, "synthetic_owner_failure")
    end)
  end

  test "fingerprints unknown binaries and never emits their raw values" do
    unknown_reason = "synthetic unknown owner binary"

    logs =
      capture_log(fn ->
        assert OwnerErrorDiagnostics.normalize(unknown_reason, :attach, @context) ==
                 {:error, :owner_unavailable}
      end)

    assert logs =~ ~r/reason_code=sha256_[0-9a-f]{12}/
    refute logs =~ unknown_reason
  end

  test "uses unknown for non-code structured failures without inspecting them" do
    logs =
      capture_log(fn ->
        assert OwnerErrorDiagnostics.normalize(
                 %{reason: "raw structured sentinel"},
                 :detach,
                 @context
               ) ==
                 {:error, :owner_unavailable}
      end)

    assert_single_collapse!(logs, :detach, "unknown")
    refute logs =~ "raw structured sentinel"
    refute logs =~ "%{"
  end

  defp assert_single_collapse!(logs, boundary, reason_code) do
    assert length(Regex.scan(~r/websocket owner reason collapsed/, logs)) == 1
    assert logs =~ "boundary=#{boundary}"
    assert logs =~ "reason_code=#{reason_code}"
    assert logs =~ "canonical_error=owner_unavailable"
    assert logs =~ "request_id=request_owner_diagnostics"
    assert logs =~ "codex_session_id=session-owner-diagnostics"
    assert logs =~ "owner_instance_id=owner_diagnostics.example"
    assert logs =~ "proxy_instance_id=proxy_diagnostics.example"
  end
end
