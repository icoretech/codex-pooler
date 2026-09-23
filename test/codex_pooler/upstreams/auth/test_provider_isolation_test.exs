defmodule CodexPooler.Upstreams.Auth.TestProviderIsolationTest do
  # The test environment points both provider defaults at a closed loopback
  # port: the gateway base URL and the CodexAuth issuer. A test that refreshes
  # an identity without pointing it at its own fake must fail fast locally with
  # a refused connection, never reach the real provider token endpoint.
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.{CodexAuth, TokenRefresh}
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Secrets

  @closed_port_origin "http://127.0.0.1:9"

  test "the loaded test config points the CodexAuth issuer at the closed loopback port" do
    assert CodexAuth.issuer() == @closed_port_origin
    assert Application.get_env(:codex_pooler, :codex_upstream_base_url) == @closed_port_origin
  end

  test "a refresh of an identity with no base URL fails fast against the closed loopback issuer" do
    # Checked before any outbound call, so a regressed config fails here and
    # never sends the synthetic refresh token anywhere.
    assert CodexAuth.issuer() == @closed_port_origin

    identity = identity_without_base_url!()
    handler = attach_request_starts!()

    {elapsed_us, result} = :timer.tc(fn -> TokenRefresh.refresh_access_token(identity, trigger_kind: "manual") end)

    assert {:ok, %{status: :refresh_failed, retryable?: true}} = result
    assert elapsed_us < 1_000_000

    assert [%{scheme: :http, host: "127.0.0.1", port: 9, path: "/oauth/token"}] = request_starts(handler)
    assert {:ok, "synthetic-isolation-access"} = Secrets.decrypt_active_secret(identity, "access_token")
  end

  defp identity_without_base_url! do
    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_isolation_#{System.unique_integer([:positive])}",
               account_label: "Isolation account",
               onboarding_method: "import",
               status: "active",
               metadata: %{}
             })

    for {kind, plaintext} <- [{"access_token", "synthetic-isolation-access"}, {"refresh_token", "synthetic-isolation-refresh"}] do
      assert {:ok, _secret} = Upstreams.store_encrypted_secret(identity, %{secret_kind: kind, plaintext: plaintext})
    end

    identity
  end

  # Finch emits `[:finch, :request, :start]` in the calling process, so the
  # handler keeps only this test's own outbound requests.
  defp attach_request_starts! do
    handler = "test-provider-isolation-#{System.unique_integer([:positive])}"
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:finch, :request, :start],
        fn _event, _measurements, %{request: request}, _config ->
          if self() == test_pid do
            send(test_pid, {handler, %{scheme: request.scheme, host: request.host, port: request.port, path: request.path}})
          end
        end,
        nil
      )

    handler
  end

  defp request_starts(handler) do
    handler |> collect_request_starts([]) |> Enum.reverse()
  end

  defp collect_request_starts(handler, acc) do
    receive do
      {^handler, request} -> collect_request_starts(handler, [request | acc])
    after
      0 -> acc
    end
  end
end
