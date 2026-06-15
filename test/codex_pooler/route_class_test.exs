defmodule CodexPooler.RouteClassTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.ControlPlaneRoutes
  alias CodexPooler.RouteClass

  test "detects streaming payloads for string and atom keys" do
    assert RouteClass.streaming?(%{"stream" => true})
    assert RouteClass.streaming?(%{stream: true})

    refute RouteClass.streaming?(%{"stream" => false})
    refute RouteClass.streaming?(%{stream: false})
    refute RouteClass.streaming?(%{})
  end

  test "uses the shared streaming predicate for route classification" do
    assert RouteClass.classify("/backend-api/codex/responses", %{"stream" => true}, nil) ==
             RouteClass.proxy_stream()

    assert RouteClass.classify("/backend-api/codex/responses", %{stream: true}, nil) ==
             RouteClass.proxy_stream()
  end

  test "classifies backend compact aliases as proxy compact" do
    for endpoint <- [
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/v1/responses/compact"
        ] do
      assert RouteClass.classify(endpoint, %{}, nil) == RouteClass.proxy_compact()
    end
  end

  test "keeps public compact outside the backend compact route class" do
    assert RouteClass.classify("/v1/responses/compact", %{}, nil) == RouteClass.proxy_http()
  end

  test "classifies websocket surfaces before streaming payloads" do
    for endpoint <- [
          "/backend-api/codex/responses",
          "/backend-api/codex/v1/responses",
          "/v1/responses"
        ] do
      assert RouteClass.classify(endpoint, %{"stream" => true}, "websocket") ==
               RouteClass.proxy_websocket()
    end
  end

  test "classifies shared control-plane route definitions as proxy control" do
    for %{local_path: local_path} <- ControlPlaneRoutes.all() do
      assert RouteClass.classify(local_path, %{"stream" => true}, nil) ==
               RouteClass.proxy_control()
    end
  end
end
