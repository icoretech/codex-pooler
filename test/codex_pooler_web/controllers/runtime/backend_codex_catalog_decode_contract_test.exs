defmodule CodexPoolerWeb.Runtime.BackendCodexCatalogDecodeContractTest do
  # findings#258 row 258-34: the released Codex client decodes the whole
  # `/models` body as one `ModelsResponse`, so one entry it cannot decode makes
  # it discard every entry and fall back to its bundled catalog. A client
  # inside the verified decode window (0.154.0 through 0.156.1) is served the
  # catalog without that entry, the omission is logged with the model slug and
  # field names only, and its turns name the ETag of that same body. Clients
  # outside the window and `/v1/models` keep the unchecked catalog.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import ExUnit.CaptureLog

  alias CodexPooler.CodexCatalogShapes
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Metadata.CodexModelDecodeContract
  alias CodexPooler.Repo

  @broken_slug "gpt-catalog-undecodable"
  @user_agent "codex_cli_rs/0.156.1 (Mac OS 26.0.0; arm64) xterm-256color"

  test "a client inside the verified window is served every entry but the one it cannot decode", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = catalog_setup(upstream)
    good_slug = setup.model.exposed_model_id

    for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"] do
      log =
        capture_log(fn ->
          response = conn |> recycle() |> auth(setup) |> put_req_header("user-agent", @user_agent) |> get(path, %{"client_version" => "0.156.1"})
          body = json_response(response, 200)

          assert Enum.map(body["models"], & &1["slug"]) == [good_slug], path
          assert get_resp_header(response, "etag") == [CodexCatalog.etag(body)], path
        end)

      assert log =~ "codex catalog entry left out", path
      assert log =~ "pool_id=#{setup.pool.id} model=#{@broken_slug} fields=experimental_supported_tools,support_verbosity", path
      refute log =~ "Synthetic instructions template", path
      refute log =~ "Synthetic #{@broken_slug}", path
    end

    for version <- ["0.157.0", "0.153.4", "0.146.1", ""] do
      response = conn |> recycle() |> auth(setup) |> put_req_header("user-agent", user_agent(version)) |> get("/backend-api/codex/models", %{"client_version" => version})
      assert response |> json_response(200) |> Map.fetch!("models") |> Enum.map(& &1["slug"]) |> Enum.sort() == Enum.sort([good_slug, @broken_slug]), version
    end

    openai = conn |> recycle() |> auth(setup) |> get("/v1/models") |> json_response(200)
    assert @broken_slug in Enum.map(openai["data"], & &1["id"])
    assert FakeUpstream.count(upstream) == 0
  end

  test "a turn from a client inside the window names the ETag of the checked catalog", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_catalog_decode_contract_etag",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = catalog_setup(upstream)

    capture_log(fn ->
      models =
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header("user-agent", @user_agent)
        |> get("/backend-api/codex/models", %{"client_version" => "0.156.1"})

      assert [catalog_etag] = get_resp_header(models, "etag")

      unchecked =
        conn |> recycle() |> auth(setup) |> put_req_header("user-agent", user_agent("0.157.0")) |> get("/backend-api/codex/models", %{"client_version" => "0.157.0"}) |> get_resp_header("etag")

      refute unchecked == [catalog_etag]

      turn =
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header("user-agent", @user_agent)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic catalog decode contract turn"),
          "stream" => true
        })

      assert turn.status == 200
      assert get_resp_header(turn, "x-models-etag") == [catalog_etag]
    end)
  end

  # findings#206 row 206-444: the model every `gateway_setup/2` test routes to
  # is a catalog entry the released client decodes, so a test sending an
  # in-window `User-Agent` computes its ETag from a body that still lists it.
  test "the default gateway fixture model is a decodable catalog entry for every client", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)

    log =
      capture_log(fn ->
        for version <- ["0.156.1", "0.154.0", "0.157.0", "0.146.1"] do
          body = conn |> recycle() |> auth(setup) |> put_req_header("user-agent", user_agent(version)) |> get("/backend-api/codex/models", %{"client_version" => version}) |> json_response(200)

          assert [entry] = body["models"], version
          assert entry["slug"] == setup.model.exposed_model_id, version
          assert CodexModelDecodeContract.violations(entry) == [], version
        end
      end)

    refute log =~ "codex catalog entry left out"
  end

  # The catalog fetch selects its representation from the Codex build's
  # `User-Agent`, exactly as its turns do (findings#258 row 258-102).
  defp user_agent(""), do: "codex_cli_rs"
  defp user_agent(version), do: "codex_cli_rs/#{version} (Mac OS 26.0.0; arm64) xterm-256color"

  defp catalog_setup(upstream) do
    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => CodexCatalogShapes.synced_source(setup.model.exposed_model_id)
          }
        }
      )
      |> Repo.update!()

    broken_source =
      @broken_slug
      |> CodexCatalogShapes.synced_source()
      |> Map.drop(["support_verbosity", "experimental_supported_tools"])

    broken =
      model_fixture(setup.pool, %{
        exposed_model_id: @broken_slug,
        upstream_model_id: "provider-#{@broken_slug}",
        display_name: "Catalog Undecodable",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{setup.assignment.id => broken_source}
        }
      })

    setup
    |> Map.put(:model, model)
    |> Map.put(:broken_model, broken)
  end
end
