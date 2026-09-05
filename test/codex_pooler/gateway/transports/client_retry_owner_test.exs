defmodule CodexPooler.Gateway.Transports.ClientRetryOwnerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5

  test "the successor owner envelope is versioned, opaque, and cannot downgrade to v1" do
    authority = dispatch_authority()
    attrs = Map.merge(base_attrs(), %{version: 5, client_retry_dispatch_authority: authority})

    assert {:ok, request} = WebsocketOwnerRequestV5.new(attrs)
    assert WebsocketOwnerRequestV5.validate(request) == :ok
    assert inspect(request) == "#WebsocketOwnerRequestV5<version: 5, client_retry: redacted>"
    refute inspect(request) =~ authority.successor_claim

    assert {:error, {:unknown_fields, [:client_retry_dispatch_authority]}} =
             attrs |> Map.put(:version, 1) |> WebsocketOwnerRequest.new()
  end

  test "the successor owner envelope rejects an untyped authority" do
    attrs =
      Map.merge(base_attrs(), %{
        version: 5,
        client_retry_dispatch_authority: Map.from_struct(dispatch_authority())
      })

    assert {:error, {:invalid_field, :client_retry_dispatch_authority}} =
             WebsocketOwnerRequestV5.new(attrs)
  end

  test "an old owner without the v5 entrypoint fails closed without a v1 fallback" do
    module = WebsocketOwnerForwarder
    args = [Ecto.UUID.generate(), %{pid: self(), epoch: 1}, :opaque_v5_request]

    reason =
      {:exception, :undef,
       [{module, :remote_submit_request_v5, args, [file: ~c"previous_release.ex", line: 1]}]}

    assert :owner_unavailable =
             WebsocketOwnerForwarder.normalize_remote_failure(
               :error,
               reason,
               module,
               :remote_submit_request_v5,
               args
             )
  end

  defp base_attrs do
    %{
      url: "https://upstream.example.com/backend-api/codex/responses",
      headers: [{"authorization", "synthetic-value"}],
      payload: Jason.encode!(%{"model" => "example-model", "input" => []}),
      timeouts: %TimeoutConfig{
        connect_timeout_ms: 1_000,
        pool_timeout_ms: 1_000,
        receive_timeout_ms: 30_000
      },
      mapper: :codex_responses,
      upstream_identity_id: Ecto.UUID.generate(),
      observation: %{
        request_id: Ecto.UUID.generate(),
        client_request_id: "client-request",
        attempt_id: Ecto.UUID.generate(),
        mode: "full"
      },
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: true,
      connection_bound_continuation?: false,
      forward_error_body?: false,
      submission_notification?: true
    }
  end

  defp dispatch_authority do
    %ClientRetry.DispatchAuthority{
      version: 1,
      predecessor_request_id: Ecto.UUID.generate(),
      successor_request_id: Ecto.UUID.generate(),
      link_id: Ecto.UUID.generate(),
      successor_claim: "client-retry-v1:synthetic-claim"
    }
  end
end
