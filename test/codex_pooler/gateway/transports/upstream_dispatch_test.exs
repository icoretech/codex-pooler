defmodule CodexPooler.Gateway.Transports.UpstreamDispatchTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @receive_timeout_ms 25
  @websocket_idle_timeout_ms 1_000

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        upstream_receive_timeout_ms: @receive_timeout_ms,
        websocket_idle_timeout_ms: @websocket_idle_timeout_ms
      }
    )

    reset_bootstrap_state_fixture!()
    auth = auth_fixture()

    on_exit(fn ->
      restore_operational_settings(previous_settings)
      cleanup_local_owner_sessions()
    end)

    {:ok, auth: auth}
  end

  @tag :websocket_owner_submit_timeout
  test "owner submit uses the websocket session budget instead of the receive timeout", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@submit-timeout-owner.example"
    short_receive_budget_ms = @receive_timeout_ms + 1_000

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    downstream = %{pid: self(), epoch: 1, correlation_id: "corr-owner-submit-timeout"}

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    request_options =
      websocket_owner_request_options(session, lease_token, downstream, forwarder_opts)

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
               url: "https://upstream.example.test/backend-api/codex/responses",
               token: "redacted",
               upstream_payload: "{}",
               identity: upstream_identity(),
               accounting_request: nil,
               writer: fn _message -> :ok end,
               request_options: request_options
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request,
                      arity: 4,
                      timeout: observed_timeout_ms
                    }}

    assert observed_timeout_ms > short_receive_budget_ms,
           "expected remote submit timeout to exceed receive_timeout_ms + 1000 (#{short_receive_budget_ms}ms), got #{observed_timeout_ms}ms"
  end

  test "explicit owner forwarder timeout override is preserved for remote submit", %{
    auth: auth
  } do
    remote_node = :"codex_pooler@explicit-submit-timeout-owner.example"

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, Atom.to_string(remote_node))

    downstream = %{pid: self(), epoch: 1, correlation_id: "corr-explicit-owner-submit-timeout"}

    forwarder_opts =
      [remote_node]
      |> WebsocketOwnerNodeHarness.node_client_opts(calls: %{remote_node => :timeout})
      |> Keyword.put(:timeout, 25)

    request_options =
      websocket_owner_request_options(session, lease_token, downstream, forwarder_opts)

    assert {:error, %{reason: :owner_forward_timeout, started: false}} =
             UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
               url: "https://upstream.example.test/backend-api/codex/responses",
               token: "redacted",
               upstream_payload: "{}",
               identity: upstream_identity(),
               accounting_request: nil,
               writer: fn _message -> :ok end,
               request_options: request_options
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request,
                      arity: 4,
                      timeout: 25
                    }}
  end

  test "http request does not reuse Cloudflare cookies for non-ChatGPT upstream origins" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json, %{"/backend-api/codex/responses" => {200, %{"ok" => true}}}}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    chatgpt_url =
      "https://dispatch-cookie-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/responses"

    assert CloudflareCookies.store_from_headers(chatgpt_url, [
             {"set-cookie", "__cf_bm=dispatch-token; Path=/; HttpOnly; Secure"}
           ])

    assert [{"cookie", "__cf_bm=dispatch-token"}] =
             CloudflareCookies.request_headers(chatgpt_url, [])

    payload = %{"model" => "example-model"}
    url = FakeUpstream.url(upstream) <> "/backend-api/codex/responses"

    request = %UpstreamDispatch.Request{
      url: url,
      token: "redacted",
      upstream_payload: Jason.encode!(payload),
      original_payload: payload,
      identity: upstream_identity(),
      request_options:
        RequestOptions.build(
          %{receive_timeout_ms: 1_000},
          "/backend-api/codex/responses",
          payload
        )
    }

    assert {:ok, _response} = UpstreamDispatch.http_request(request)
    assert {:ok, _response} = UpstreamDispatch.http_request(request)

    [first_request, second_request] = FakeUpstream.requests(upstream)
    first_headers = Map.new(first_request.headers)
    second_headers = Map.new(second_request.headers)
    version = CodexClientIdentity.version()

    assert first_headers["user-agent"] == "codex_cli_rs/#{version}"
    assert first_headers["originator"] == CodexClientIdentity.originator()
    assert first_headers["version"] == version

    refute Map.has_key?(first_headers, "cookie")
    refute Map.has_key?(second_headers, "cookie")
  end

  test "direct websocket request preserves exact connection metadata through result recording" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [
           websocket_success("direct-initial"),
           websocket_success("direct-reused"),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success("direct-reconnected")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)
    on_exit(fn -> FakeUpstream.stop(upstream) end)

    request_options = websocket_request_options(session)
    request = websocket_dispatch_request(upstream, request_options)

    assert {:ok, initial} = UpstreamDispatch.websocket_request(request)
    initial_connection = Map.fetch!(initial, :upstream_websocket_connection)

    assert initial_connection == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 1,
             reused: false,
             reconnected: false
           }

    assert {:ok, reused} = UpstreamDispatch.websocket_request(request)

    assert Map.fetch!(reused, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 1,
             reused: true,
             reconnected: false
           }

    assert {:ok, reconnected} = UpstreamDispatch.websocket_request(request)

    assert Map.fetch!(reconnected, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 2,
             reused: false,
             reconnected: true
           }

    FakeUpstream.set_mode(
      upstream,
      {:sequence,
       [
         FakeUpstream.websocket_sse_then_close([]),
         FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "reconnect_rejected"}},
           status: 503
         )
       ]}
    )

    assert {:error, failed_reconnect} = UpstreamDispatch.websocket_request(request)
    assert %{body: "", reason: {:websocket_upgrade_failed, 503, _headers}} = failed_reconnect

    assert Map.fetch!(failed_reconnect, :upstream_websocket_connection) == %{
             lifecycle_id: initial_connection.lifecycle_id,
             generation: 2,
             reused: true,
             reconnected: false
           }
  end

  test "one-shot websocket request preserves success metadata and omits it on initial upgrade failure" do
    {:ok, success_upstream} = FakeUpstream.start_link(websocket_success("one-shot-success"))
    on_exit(fn -> FakeUpstream.stop(success_upstream) end)

    success_request =
      websocket_dispatch_request(
        success_upstream,
        websocket_request_options()
      )

    assert {:ok, success} = UpstreamDispatch.websocket_request(success_request)
    success_connection = Map.fetch!(success, :upstream_websocket_connection)

    assert success_connection == %{
             lifecycle_id: success_connection.lifecycle_id,
             generation: 1,
             reused: false,
             reconnected: false
           }

    {:ok, failed_upstream} =
      FakeUpstream.start_link(
        FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "initial_rejected"}},
          status: 401
        )
      )

    on_exit(fn -> FakeUpstream.stop(failed_upstream) end)

    failure_request =
      websocket_dispatch_request(
        failed_upstream,
        websocket_request_options()
      )

    assert {:error, failure} = UpstreamDispatch.websocket_request(failure_request)
    assert %{body: "", reason: {:websocket_upgrade_failed, 401, _headers}} = failure
    refute Map.has_key?(failure, :upstream_websocket_connection)
  end

  defp websocket_request_options(session \\ nil) do
    opts = %{receive_timeout_ms: 1_000}
    opts = if is_pid(session), do: Map.put(opts, :upstream_websocket_session, session), else: opts
    RequestOptions.for_websocket(opts, %{"model" => "example-model"})
  end

  defp websocket_dispatch_request(upstream, request_options) do
    %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: upstream_identity(),
      accounting_request: nil,
      writer: fn _message -> :ok end,
      assignment_advertised?: false,
      request_options: request_options
    }
  end

  defp websocket_success(id) do
    FakeUpstream.websocket_text_frames([
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => id}
      })
    ])
  end

  defp websocket_owner_request_options(session, lease_token, downstream, forwarder_opts) do
    RequestOptions.for_websocket(
      %{
        codex_session: session,
        receive_timeout_ms: @receive_timeout_ms,
        websocket_owner_forwarding_enabled?: true,
        websocket_owner_session: session,
        websocket_owner_lease_token: lease_token,
        websocket_owner_downstream: downstream,
        websocket_owner_downstream_epoch: downstream.epoch,
        websocket_owner_proxy_instance_id: Atom.to_string(node()),
        websocket_owner_instance_id: session.owner_instance_id,
        websocket_owner_forwarder_opts: forwarder_opts
      },
      %{"model" => "example-model"}
    )
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture(auth, owner_instance_id) do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "owner-submit-timeout-#{System.unique_integer([:positive])}",
               owner_instance_id: owner_instance_id
             })

    session = Repo.get!(CodexSession, session.id)
    %{session: session, lease_token: session.owner_lease_token}
  end

  defp upstream_identity do
    %UpstreamIdentity{chatgpt_account_id: "acct_owner_submit_timeout"}
  end

  defp restore_operational_settings(nil) do
    Application.delete_env(:codex_pooler, OperationalSettings)
  end

  defp restore_operational_settings(previous_settings) do
    Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
  end

  defp cleanup_local_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn codex_session_id ->
        try do
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
            _result = GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        catch
          :exit, _reason -> :ok
        end
      end)
    end)

    :ok
  end
end
