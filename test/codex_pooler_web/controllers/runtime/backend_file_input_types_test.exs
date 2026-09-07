defmodule CodexPoolerWeb.Runtime.BackendFileInputTypesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Repo

  test "invalid JSON field types return 400 before upstream dispatch or persistence" do
    setup = active_api_key_fixture()
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: "file_input_types"))

    active_upstream_assignment_fixture(setup.pool, %{
      metadata: %{"base_url" => FakeUpstream.url(upstream)}
    })

    request_count = Repo.aggregate(Request, :count)
    file_count = Repo.aggregate(FileRecord, :count)

    for {field, values} <- [
          {"file_name", [%{}, [], [65], 123, true, false, nil, "  "]},
          {"use_case", [%{}, [], [99, 111, 100, 101, 120], 123, true, false]},
          {"file_size", [%{}, [], true, false, nil, 0, -1, 1.5, "1x", " "]}
        ],
        value <- values do
      params =
        %{"file_name" => "sample.txt", "file_size" => 12, "use_case" => "codex"}
        |> Map.put(field, value)

      conn =
        Plug.Test.conn("POST", "/backend-api/files", CodexPooler.JSON.encode!(params))
        |> put_req_header("content-type", "application/json")
        |> auth(setup)
        |> @endpoint.call(@endpoint.init([]))

      assert %{"error" => %{"code" => "invalid_request", "param" => ^field}} =
               json_response(conn, 400)
    end

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == request_count
    assert Repo.aggregate(FileRecord, :count) == file_count
  end
end
