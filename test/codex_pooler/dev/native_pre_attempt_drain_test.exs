defmodule CodexPooler.Dev.NativePreAttemptDrainTest do
  use CodexPooler.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Dev.NativePreAttemptDrain
  alias CodexPooler.Dev.NativePreAttemptDrain.Plug, as: DrainPlug

  setup do
    on_exit(fn -> NativePreAttemptDrain.disarm() end)
    %{owned: api_key_fixture(), foreign: api_key_fixture()}
  end

  test "idle capture requires an actual scoped successful session and idle live owner", %{
    owned: owned
  } do
    response =
      conn(:post, "/capture-idle", "{}")
      |> put_req_header("authorization", owned.authorization)
      |> DrainPlug.call([])

    assert response.status == 409
    assert CodexPooler.JSON.decode!(response.resp_body) == %{"error" => "idle_owner_required"}
    refute NativePreAttemptDrain.status().captured
    refute NativePreAttemptDrain.status().armed
  end

  test "visible capture requires an actual attempted visible request", %{owned: owned} do
    response =
      conn(:post, "/capture-visible", "{}")
      |> put_req_header("authorization", owned.authorization)
      |> DrainPlug.call([])

    assert response.status == 409

    assert CodexPooler.JSON.decode!(response.resp_body) == %{
             "error" => "visible_attempt_required"
           }

    refute NativePreAttemptDrain.status().captured
    refute NativePreAttemptDrain.status().armed
  end

  test "rearms after its owner process exits without retaining the old telemetry handler", %{
    owned: owned
  } do
    assert :ok = NativePreAttemptDrain.arm(owned.pool.id)
    pid = Process.whereis(NativePreAttemptDrain)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert :ok = NativePreAttemptDrain.arm(owned.pool.id)
    assert :ok = NativePreAttemptDrain.disarm()
    assert Process.whereis(NativePreAttemptDrain) == nil
  end

  test "requires authenticated loopback authority before arming", %{owned: owned} do
    assert conn(:post, "/arm", "{}") |> DrainPlug.call([]) |> Map.fetch!(:status) == 403

    remote = %{conn(:post, "/arm", "{}") | remote_ip: {192, 0, 2, 1}}

    assert remote
           |> put_req_header("authorization", owned.authorization)
           |> DrainPlug.call([])
           |> Map.fetch!(:status) == 403

    refute NativePreAttemptDrain.status().armed

    response =
      conn(:post, "/drain", "{}")
      |> put_req_header("authorization", owned.authorization)
      |> DrainPlug.call([])

    assert response.status == 409
    assert CodexPooler.JSON.decode!(response.resp_body) == %{"error" => "capture_required"}

    for route <- [
          "/drain",
          "/disarm",
          "/hold-caller",
          "/begin-drain",
          "/release-caller",
          "/await-finalization",
          "/await-drained"
        ] do
      response =
        conn(:post, route, "malformed")
        |> put_req_header("authorization", owned.authorization)
        |> DrainPlug.call([])

      assert response.status == 400
      assert CodexPooler.JSON.decode!(response.resp_body) == %{"error" => "invalid_control"}
    end
  end

  test "rejects malformed bodies and derives pool only from authentication", %{
    owned: owned,
    foreign: foreign
  } do
    for body <- ["invalid", "[]", ~s({"poolId":"#{foreign.pool.id}"})] do
      response =
        conn(:post, "/arm", body)
        |> put_req_header("authorization", owned.authorization)
        |> DrainPlug.call([])

      assert response.status == 400
    end

    response =
      conn(:post, "/arm", "{}")
      |> put_req_header("authorization", owned.authorization)
      |> DrainPlug.call([])

    assert response.status == 200
    assert NativePreAttemptDrain.status().armed

    for route <- [
          "/hold-caller",
          "/begin-drain",
          "/release-caller",
          "/await-finalization",
          "/await-drained"
        ] do
      response =
        conn(:post, route, "{}")
        |> put_req_header("authorization", foreign.authorization)
        |> DrainPlug.call([])

      assert response.status == 403
    end

    for method <- [:get, :post] do
      response =
        conn(method, if(method == :get, do: "/", else: "/disarm"), "{}")
        |> put_req_header("authorization", foreign.authorization)
        |> DrainPlug.call([])

      assert response.status == 403
    end

    response =
      conn(:post, "/disarm", "{}")
      |> put_req_header("authorization", owned.authorization)
      |> DrainPlug.call([])

    assert response.status == 200
    refute NativePreAttemptDrain.status().armed
  end
end
