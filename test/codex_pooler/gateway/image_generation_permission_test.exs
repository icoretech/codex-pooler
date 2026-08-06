defmodule CodexPooler.Gateway.ImageGenerationPermissionTest do
  use CodexPooler.DataCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @image_endpoint "/backend-api/codex/images/generations"

  test "marked execution denies a disabled pool before model validation or side effects" do
    attach_admission_telemetry()
    upstream = start_upstream(FakeUpstream.json_response(%{"created" => 1, "data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(allow_image_generation: false)
    |> Repo.update!()

    payload = %{"prompt" => "synthetic permission probe"}

    request_options =
      RequestOptions.build(
        %{image_generation_permission_required?: true},
        @image_endpoint,
        payload
      )

    assert {:error,
            %{
              status: 403,
              code: "image_generation_disabled",
              message: "Image generation is disabled for this pool"
            }} = Gateway.execute(auth, @image_endpoint, payload, request_options)

    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert FakeUpstream.requests(upstream) == []
    refute_received {:admission_event, _event}
  end

  test "the server marker remains authoritative after request-option retargeting" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(allow_image_generation: false)
    |> Repo.update!()

    payload = %{"input" => "synthetic retarget probe"}

    request_options =
      RequestOptions.build(
        %{image_generation_permission_required?: true},
        @image_endpoint,
        payload
      )

    assert {:error, %{status: 403, code: "image_generation_disabled"}} =
             Gateway.execute(
               auth,
               "/backend-api/codex/responses",
               payload,
               request_options
             )

    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert FakeUpstream.requests(upstream) == []
  end

  test "unmarked execution keeps ordinary model validation behavior" do
    upstream = start_upstream(FakeUpstream.json_response(%{"created" => 1, "data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"prompt" => "synthetic unmarked probe"}
    request_options = RequestOptions.build(%{}, @image_endpoint, payload)

    assert {:error, %{status: 400, code: "invalid_request", param: "model"}} =
             Gateway.execute(auth, @image_endpoint, payload, request_options)

    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert FakeUpstream.requests(upstream) == []
  end

  defp attach_admission_telemetry do
    test_pid = self()
    handler_id = "image-permission-admission-#{System.unique_integer([:positive])}"

    events =
      Enum.map([:accepted, :rejected, :enqueued, :dequeued, :timeout], fn event ->
        [:codex_pooler, :gateway, :admission, event]
      end)

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, _metadata, _config ->
          send(test_pid, {:admission_event, event})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
