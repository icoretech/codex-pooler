defmodule CodexPoolerWeb.Plugs.RuntimeIngress.FirewallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 2]
  import Plug.Test, only: [conn: 2]

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.Decision
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @event [:codex_pooler, :ingress, :firewall, :denied]

  test "defines the complete bounded denial reason taxonomy" do
    assert Firewall.denial_reasons() == [
             :invalid_trusted_proxy_rules,
             :invalid_forwarded_bytes,
             :forwarded_entry_too_long,
             :invalid_forwarded_entry,
             :forwarded_hop_limit_exceeded,
             :forwarded_chain_unresolved,
             :forwarded_header_missing,
             :forwarded_depth_unsatisfied,
             :duplicate_x_real_ip,
             :invalid_allowlist_rules,
             :not_allowed,
             :settings_unavailable,
             :websocket_revoked
           ]
  end

  test "returns a reusable allow decision without emitting telemetry" do
    attach_denial_handler()
    settings = settings(["203.0.113.10"])

    {evaluated_conn, decision} =
      {203, 0, 113, 10}
      |> runtime_conn()
      |> Firewall.evaluate(settings)

    assert %Decision{outcome: :allow, reason: nil, client_ip: {203, 0, 113, 10}} = decision
    assert evaluated_conn.remote_ip == {203, 0, 113, 10}
    refute_received {@event, _measurements, _metadata}
  end

  test "preserves each reachable forwarded-resolution denial reason" do
    {:ok, allowlist} = IPRules.compile(["203.0.113.10"])

    for reason <- [
          :invalid_trusted_proxy_rules,
          :invalid_forwarded_bytes,
          :forwarded_entry_too_long,
          :invalid_forwarded_entry,
          :forwarded_hop_limit_exceeded,
          :forwarded_chain_unresolved
        ] do
      settings = %OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        firewall_allowlist_compiled: {:ok, allowlist}
      }

      resolution = %Resolution{
        status: :error,
        peer_ip: {10, 0, 0, 1},
        client_ip: {10, 0, 0, 1},
        source: :peer,
        reason: reason,
        inspected_hops: 1
      }

      {_conn, decision} =
        {10, 0, 0, 1}
        |> runtime_conn()
        |> Plug.Conn.put_private(:codex_pooler_client_ip_resolution, resolution)
        |> Firewall.evaluate(settings)

      assert %Decision{outcome: :deny, reason: ^reason} = decision
    end
  end

  test "distinguishes invalid allowlist rules from an ordinary mismatch" do
    invalid_settings = %OperationalSettings{
      firewall_allowlist: ["invalid rule"],
      firewall_allowlist_compiled: {:error, :invalid_rule}
    }

    {_conn, invalid_decision} =
      {203, 0, 113, 10}
      |> runtime_conn()
      |> Firewall.evaluate(invalid_settings)

    assert %Decision{outcome: :deny, reason: :invalid_allowlist_rules} = invalid_decision

    {_conn, mismatch_decision} =
      {198, 51, 100, 20}
      |> runtime_conn()
      |> Firewall.evaluate(settings(["203.0.113.10"]))

    assert %Decision{outcome: :deny, reason: :not_allowed} = mismatch_decision
  end

  test "cold settings deny before allowlist or forwarding evaluation" do
    cold_settings = %OperationalSettings{
      source: :fallback_defaults,
      db_available?: false,
      secrets_available?: false,
      firewall_allowlist: [],
      trusted_proxies: ["invalid rule"],
      trusted_proxies_compiled: {:error, :invalid_rule}
    }

    conn = runtime_conn({198, 51, 100, 20})

    assert {^conn, %Decision{outcome: :deny, reason: :settings_unavailable}} =
             Firewall.evaluate(conn, cold_settings)

    assert %Decision{outcome: :deny, reason: :settings_unavailable} =
             Firewall.evaluate_client_ip({198, 51, 100, 20}, cold_settings)
  end

  test "reuses client-only evaluation for later firewall checks" do
    settings = settings(["203.0.113.10"])

    assert %Decision{outcome: :allow, reason: nil} =
             Firewall.evaluate_client_ip({203, 0, 113, 10}, settings)

    assert %Decision{outcome: :deny, reason: :not_allowed} =
             Firewall.evaluate_client_ip({198, 51, 100, 20}, settings)
  end

  test "emits one bounded event and one sanitized structured log for a denial" do
    attach_denial_handler()
    decision = Firewall.denied(:not_allowed, {198, 51, 100, 20})

    request_metadata = [
      request_id: "request-sensitive",
      path: "/backend-api/codex/responses"
    ]

    Logger.metadata(request_metadata)

    previous_metadata = Logger.metadata()

    log =
      capture_log([metadata: [:scope, :reason, :request_id, :path]], fn ->
        assert :ok = Firewall.observe_denial(decision, :runtime)
      end)

    assert_received {@event, %{count: 1}, %{scope: "runtime", reason: "not_allowed"}}
    refute_received {@event, _measurements, _metadata}
    assert log =~ "ingress firewall denied"
    assert log =~ "scope=runtime"
    assert log =~ "reason=not_allowed"
    assert Logger.metadata() == previous_metadata

    for forbidden <- [
          "198.51.100.20",
          "x-forwarded-for",
          "/backend-api",
          "request_id",
          "request-sensitive",
          "path="
        ] do
      refute log =~ forbidden
    end
  end

  test "emits each fixed denial reason with exactly one count and no extra tags" do
    attach_denial_handler()

    for reason <- Firewall.denial_reasons() do
      decision = Firewall.denied(reason, {198, 51, 100, 20})
      assert :ok = Firewall.observe_denial(decision, :mcp)

      assert_receive {@event, %{count: 1}, metadata}
      assert metadata == %{scope: "mcp", reason: Atom.to_string(reason)}
      refute_received {@event, _measurements, _metadata}
    end
  end

  defp settings(allowlist) do
    {:ok, allowlist_compiled} = IPRules.compile(allowlist)
    {:ok, trusted_proxies_compiled} = IPRules.compile([])

    %OperationalSettings{
      firewall_allowlist: allowlist,
      firewall_allowlist_compiled: {:ok, allowlist_compiled},
      trusted_proxies_compiled: {:ok, trusted_proxies_compiled}
    }
  end

  defp runtime_conn(ip), do: %{conn(:get, "/backend-api/codex/models") | remote_ip: ip}

  defp attach_denial_handler do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
