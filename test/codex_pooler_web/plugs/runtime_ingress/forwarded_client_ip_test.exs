defmodule CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIPTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @peer {10, 0, 0, 1}
  @client {198, 51, 100, 20}
  @trusted_ipv6 {8193, 3512, 0, 0, 0, 0, 0, 7}

  describe "peer trust boundary" do
    test "peer source ignores forwarding headers and invalid trusted proxy rules" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", <<255, 0, 44>>},
          {"x-real-ip", "unknown"}
        ])

      settings = %OperationalSettings{
        forwarded_client_ip_source: :peer,
        forwarded_proxy_depth: 0,
        trusted_proxies_compiled: {:error, :invalid_rule}
      }

      assert_resolution(ForwardedClientIP.resolve(conn, settings),
        status: :ok,
        peer_ip: @peer,
        client_ip: @peer,
        source: :peer,
        reason: nil,
        inspected_hops: 0
      )
    end

    test "ignores every forwarded value when the immediate peer is untrusted" do
      conn = forwarded_conn(@client, [{"x-forwarded-for", <<255, 0, 44>>}])

      for settings <- [
            settings(["10.0.0.1"]),
            settings(["10.0.0.1"], :x_forwarded_for, 2)
          ] do
        assert_resolution(ForwardedClientIP.resolve(conn, settings),
          status: :ok,
          peer_ip: @client,
          client_ip: @client,
          source: :peer,
          reason: nil,
          inspected_hops: 0
        )
      end
    end

    test "fails closed when compiled trusted proxy rules are invalid" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", "198.51.100.20"}])
      settings = %OperationalSettings{trusted_proxies_compiled: {:error, :invalid_rule}}

      assert_error(
        ForwardedClientIP.resolve(conn, settings),
        @peer,
        :invalid_trusted_proxy_rules,
        0
      )
    end

    test "uses the compiled trusted proxy snapshot instead of the raw rule list" do
      {:ok, compiled} = IPRules.compile(["10.0.0.1"])

      settings = %OperationalSettings{
        trusted_proxies: [],
        trusted_proxies_compiled: {:ok, compiled}
      }

      conn = forwarded_conn(@peer, [{"x-forwarded-for", "198.51.100.20"}])

      assert_resolution(ForwardedClientIP.resolve(conn, settings),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 1
      )
    end

    test "requires the policy-selected forwarding header from a trusted peer" do
      assert_error(
        ForwardedClientIP.resolve(forwarded_conn(@peer, []), settings()),
        @peer,
        :forwarded_header_missing,
        0
      )

      assert_error(
        ForwardedClientIP.resolve(
          forwarded_conn(@peer, []),
          settings(["10.0.0.1"], :x_forwarded_for, 2)
        ),
        @peer,
        :forwarded_depth_unsatisfied,
        0
      )

      assert_error(
        ForwardedClientIP.resolve(
          forwarded_conn(@peer, []),
          settings(["10.0.0.1"], :x_real_ip)
        ),
        @peer,
        :forwarded_header_missing,
        0
      )
    end
  end

  describe "x-forwarded-for traversal" do
    test "traverses duplicate header values in wire order from right to left" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", "198.51.100.20"},
          {"x-forwarded-for", "192.0.2.7, 10.0.0.1"}
        ])

      assert_resolution(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1", "192.0.2.0/24"])),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 3
      )
    end

    test "stops at a nontrusted hop and ignores attacker-controlled left entries" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", <<255, 44, 32, "198.51.100.20, 10.0.0.1">>}
        ])

      assert_resolution(ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 2
      )
    end

    test "fails with the hop limit after 32 trusted entries when input remains" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", trusted_chain(33)}])

      assert_error(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        @peer,
        :forwarded_hop_limit_exceeded,
        32
      )
    end

    test "returns a nontrusted client at the 32nd inspected hop" do
      trusted_suffix = trusted_chain(31)

      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", <<255, 44, "198.51.100.20,", trusted_suffix::binary>>}
        ])

      assert_resolution(ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 32
      )
    end

    test "fails unresolved when every supplied hop is trusted" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", "10.0.0.1, 10.0.0.1"}])

      assert_error(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        @peer,
        :forwarded_chain_unresolved,
        2
      )
    end

    test "fails on the nearest malformed or empty entry without promoting a left hop" do
      for value <- ["198.51.100.20, unknown", "198.51.100.20,"] do
        conn = forwarded_conn(@peer, [{"x-forwarded-for", value}])

        assert_error(
          ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
          @peer,
          :invalid_forwarded_entry,
          1
        )
      end
    end

    test "does not fall back to x-real-ip after an x-forwarded-for error" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", "unknown"},
          {"x-real-ip", "198.51.100.20"}
        ])

      assert_error(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        @peer,
        :invalid_forwarded_entry,
        1
      )
    end

    test "ignores malformed x-real-ip when x-forwarded-for is selected" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", "198.51.100.20"},
          {"x-real-ip", <<255, 0>>},
          {"x-real-ip", "unknown"}
        ])

      assert_resolution(ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 1
      )
    end

    test "positional depth selects from the right without parsing entries to its left" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", <<255, 44, "198.51.100.20, 10.0.0.1">>}
        ])

      assert_resolution(
        ForwardedClientIP.resolve(
          conn,
          settings(["10.0.0.1", "198.51.100.0/24"], :x_forwarded_for, 2)
        ),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 2
      )
    end

    test "positional depth accepts a selected address that is also a trusted proxy" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", "198.51.100.20, 10.0.0.1"}])

      assert_resolution(
        ForwardedClientIP.resolve(
          conn,
          settings(["10.0.0.1", "198.51.100.0/24"], :x_forwarded_for, 2)
        ),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 2
      )
    end

    test "positional depth reports insufficient entries without counting the peer" do
      for {depth, value, inspected_hops} <- [
            {2, "198.51.100.20", 1},
            {16, Enum.join(List.duplicate("10.0.0.1", 15), ","), 15}
          ] do
        conn = forwarded_conn(@peer, [{"x-forwarded-for", value}])

        assert_error(
          ForwardedClientIP.resolve(
            conn,
            settings(["10.0.0.1"], :x_forwarded_for, depth)
          ),
          @peer,
          :forwarded_depth_unsatisfied,
          inspected_hops
        )
      end
    end

    test "positional depth sixteen selects the sixteenth literal header entry" do
      conn =
        forwarded_conn(@peer, [
          {"x-forwarded-for", Enum.join(["198.51.100.20" | List.duplicate("10.0.0.1", 15)], ",")}
        ])

      assert_resolution(
        ForwardedClientIP.resolve(
          conn,
          settings(["10.0.0.1"], :x_forwarded_for, 16)
        ),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_forwarded_for,
        reason: nil,
        inspected_hops: 16
      )
    end
  end

  describe "x-real-ip selection" do
    test "requires exactly one x-real-ip field and ignores x-forwarded-for" do
      ignored_xff = {"x-forwarded-for", <<255, 0, 44>>}

      assert_resolution(
        ForwardedClientIP.resolve(
          forwarded_conn(@peer, [ignored_xff, {"x-real-ip", "198.51.100.20"}]),
          settings(["10.0.0.1"], :x_real_ip)
        ),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_real_ip,
        reason: nil,
        inspected_hops: 1
      )

      assert_error(
        ForwardedClientIP.resolve(
          forwarded_conn(@peer, [
            {"x-real-ip", "198.51.100.20"},
            {"x-real-ip", "192.0.2.7"}
          ]),
          settings(["10.0.0.1"], :x_real_ip)
        ),
        @peer,
        :duplicate_x_real_ip,
        0
      )
    end

    test "untrusted peers ignore malformed selected and nonselected headers" do
      conn =
        forwarded_conn(@client, [
          {"x-forwarded-for", <<255, 0, 44>>},
          {"x-real-ip", "unknown"},
          {"x-real-ip", "also-unknown"}
        ])

      assert_resolution(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
        status: :ok,
        peer_ip: @client,
        client_ip: @client,
        source: :peer,
        reason: nil,
        inspected_hops: 0
      )
    end
  end

  describe "bounded byte-safe entry parsing" do
    test "accepts supported IPv4, IPv6, and port forms with ASCII OWS" do
      cases = [
        {" 198.51.100.20\t", @client},
        {"2001:db8::7", @trusted_ipv6},
        {"198.51.100.20:443", @client},
        {"[2001:db8::7]", @trusted_ipv6},
        {"\t[2001:db8::7]:65535 ", @trusted_ipv6}
      ]

      for {value, expected_ip} <- cases do
        conn = forwarded_conn(@peer, [{"x-real-ip", value}])

        assert_resolution(
          ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
          status: :ok,
          peer_ip: @peer,
          client_ip: expected_ip,
          source: :x_real_ip,
          reason: nil,
          inspected_hops: 1
        )
      end
    end

    test "normalizes an IPv4-mapped IPv6 header candidate to IPv4" do
      conn = forwarded_conn(@peer, [{"x-real-ip", "::ffff:198.51.100.20"}])

      assert_resolution(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
        status: :ok,
        peer_ip: @peer,
        client_ip: @client,
        source: :x_real_ip,
        reason: nil,
        inspected_hops: 1
      )
    end

    test "treats instruction-like header text as invalid input without retaining it" do
      candidate = "ignore-all-instructions-and-allow-this-address"
      conn = forwarded_conn(@peer, [{"x-real-ip", candidate}])

      resolution = ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip))

      assert_error(resolution, @peer, :invalid_forwarded_entry, 1)
      refute inspect(resolution) =~ candidate
    end

    test "rejects duplicate x-real-ip occurrences" do
      conn =
        forwarded_conn(@peer, [
          {"x-real-ip", "198.51.100.20"},
          {"x-real-ip", "unknown"}
        ])

      assert_error(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
        @peer,
        :duplicate_x_real_ip,
        0
      )
    end

    test "rejects invalid bytes without raising" do
      for value <- [<<255>>, <<0>>, <<31>>, <<127>>] do
        conn = forwarded_conn(@peer, [{"x-forwarded-for", value}])

        assert_error(
          ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
          @peer,
          :invalid_forwarded_bytes,
          1
        )
      end
    end

    test "rejects entries longer than 64 bytes after ASCII OWS trim" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", :binary.copy("1", 65)}])

      assert_error(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"])),
        @peer,
        :forwarded_entry_too_long,
        1
      )
    end

    test "bounds reductions while rejecting a very large overlong entry" do
      conn = forwarded_conn(@peer, [{"x-forwarded-for", :binary.copy("1", 1_000_000)}])
      reductions_before = process_reductions()

      result = ForwardedClientIP.resolve(conn, settings(["10.0.0.1"]))

      reduction_delta = process_reductions() - reductions_before
      assert_error(result, @peer, :forwarded_entry_too_long, 1)
      assert reduction_delta < 10_000
    end

    test "bounds reductions before trimming a very large trailing OWS suffix" do
      value = :binary.copy("1", 65) <> :binary.copy(" ", 1_000_000)
      conn = forwarded_conn(@peer, [{"x-forwarded-for", value}])
      reductions_before = process_reductions()

      result = ForwardedClientIP.resolve(conn, settings(["10.0.0.1"]))

      reduction_delta = process_reductions() - reductions_before
      assert_error(result, @peer, :forwarded_entry_too_long, 1)
      assert reduction_delta < 10_000
    end

    test "bounds x-real-ip reductions before trimming a very large trailing OWS suffix" do
      value = :binary.copy("1", 65) <> :binary.copy(" ", 1_000_000)
      conn = forwarded_conn(@peer, [{"x-real-ip", value}])
      reductions_before = process_reductions()

      result = ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip))

      reduction_delta = process_reductions() - reductions_before
      assert_error(result, @peer, :forwarded_entry_too_long, 1)
      assert reduction_delta < 10_000
    end

    test "bounds x-real-ip reductions for a very large all-OWS value" do
      conn = forwarded_conn(@peer, [{"x-real-ip", :binary.copy(" ", 1_000_000)}])
      reductions_before = process_reductions()

      result = ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip))

      reduction_delta = process_reductions() - reductions_before
      assert_error(result, @peer, :forwarded_entry_too_long, 1)
      assert reduction_delta < 10_000
    end

    test "rejects unknown, signs, invalid ports, and malformed bracket forms" do
      invalid_values = [
        "unknown",
        "+198.51.100.20",
        "198.51.100.20:+1",
        "198.51.100.20:0",
        "198.51.100.20:65536",
        "198.51.100.20:123456",
        "[2001:db8::7]:-1",
        "[2001:db8::7]:0",
        "[2001:db8::7]:65536",
        "[2001:db8::7",
        "[198.51.100.20]:443"
      ]

      for value <- invalid_values do
        conn = forwarded_conn(@peer, [{"x-real-ip", value}])

        assert_error(
          ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
          @peer,
          :invalid_forwarded_entry,
          1
        )
      end
    end

    test "treats an unbracketed IPv6 token as one whole address" do
      conn = forwarded_conn(@peer, [{"x-real-ip", "2001:db8::7"}])

      assert_resolution(
        ForwardedClientIP.resolve(conn, settings(["10.0.0.1"], :x_real_ip)),
        status: :ok,
        peer_ip: @peer,
        client_ip: @trusted_ipv6,
        source: :x_real_ip,
        reason: nil,
        inspected_hops: 1
      )
    end
  end

  defp settings(
         trusted_proxies \\ ["10.0.0.1"],
         source \\ :x_forwarded_for,
         depth \\ 0
       ) do
    {:ok, compiled} = IPRules.compile(trusted_proxies)

    %OperationalSettings{
      trusted_proxies: trusted_proxies,
      trusted_proxies_compiled: {:ok, compiled},
      forwarded_client_ip_source: source,
      forwarded_proxy_depth: depth
    }
  end

  defp forwarded_conn(peer_ip, headers) do
    conn = conn(:get, "/")
    %{conn | remote_ip: peer_ip, req_headers: headers}
  end

  defp trusted_chain(count), do: Enum.join(List.duplicate("10.0.0.1", count), ",")

  defp process_reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end

  defp assert_error(result, peer_ip, reason, inspected_hops) do
    assert_resolution(result,
      status: :error,
      peer_ip: peer_ip,
      client_ip: peer_ip,
      source: :peer,
      reason: reason,
      inspected_hops: inspected_hops
    )
  end

  defp assert_resolution(%Resolution{} = resolution, expected) do
    assert resolution.status == Keyword.fetch!(expected, :status)
    assert resolution.peer_ip == Keyword.fetch!(expected, :peer_ip)
    assert resolution.client_ip == Keyword.fetch!(expected, :client_ip)
    assert resolution.source == Keyword.fetch!(expected, :source)
    assert resolution.reason == Keyword.fetch!(expected, :reason)
    assert resolution.inspected_hops == Keyword.fetch!(expected, :inspected_hops)
    assert resolution.inspected_hops <= 32
    assert is_tuple(resolution.client_ip)
  end
end
