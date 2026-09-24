defmodule CodexPoolerWeb.Runtime.BackendCodexCatalogInstructionsTest do
  # findings#258 rows 258-43/258-62: a Codex client whose catalog decoder
  # prefers `model_messages.instructions_template` (every build reporting
  # 0.148.0 or newer in its `User-Agent`) gets entries without the mirrored
  # `base_instructions`; older, 0.147.0, absent and unparsable versions and
  # every non-Codex agent keep the entry verbatim. The ETag is the digest of the
  # served representation, and a Responses turn names the representation the
  # same client's catalog fetch selected from the same `User-Agent`. The sources
  # are decodable by the released client, so the decode-checked representation
  # of 0.155.0 and 0.156.0 (row 258-34) serves the same bytes as 0.148.0.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Repo

  @template "Synthetic instructions template for the catalog representation test."
  @template_only_versions ["0.156.0", "0.148.0", "0.155.0"]
  @verbatim_versions ["0.147.0", "0.146.1", "not-a-version", ""]
  # Agents whose catalog fetch appends a template-preferring `client_version`
  # but whose `User-Agent` is not a Codex build's: the query value is ignored.
  @verbatim_agents [nil, "curl/8.22.0", "Bun/1.3.14", "p23-catalog-measure/0.156.0"]

  test "the catalog drops the mirrored legacy field only for template-preferring client versions",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = catalog_setup(upstream)

    verbatim = conn |> recycle() |> auth(setup) |> get("/backend-api/codex/models")
    verbatim_body = json_response(verbatim, 200)
    assert [verbatim_etag] = get_resp_header(verbatim, "etag")
    assert verbatim_etag == CodexCatalog.etag(verbatim_body)

    templated = entry!(verbatim_body, setup.model.exposed_model_id)
    legacy_only = entry!(verbatim_body, setup.legacy_model.exposed_model_id)
    assert templated["base_instructions"] == @template
    assert templated["model_messages"]["instructions_template"] == @template
    assert legacy_only["base_instructions"] == @template
    refute Map.has_key?(legacy_only, "model_messages")

    assert get_resp_header(verbatim, "vary") == ["user-agent"]

    for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"],
        version <- @verbatim_versions do
      response = conn |> recycle() |> auth(setup) |> put_codex_user_agent(version) |> get(path, %{"client_version" => version})

      assert json_response(response, 200) == verbatim_body, "#{path} #{version}"
      assert get_resp_header(response, "etag") == [verbatim_etag], "#{path} #{version}"
    end

    for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"],
        user_agent <- @verbatim_agents,
        version <- @template_only_versions do
      response = conn |> recycle() |> auth(setup) |> put_user_agent(user_agent) |> get(path, %{"client_version" => version})

      assert json_response(response, 200) == verbatim_body, "#{path} #{inspect(user_agent)} #{version}"
      assert get_resp_header(response, "etag") == [verbatim_etag], "#{path} #{inspect(user_agent)} #{version}"
    end

    template_responses =
      for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"],
          version <- @template_only_versions do
        response = conn |> recycle() |> auth(setup) |> put_codex_user_agent(version) |> get(path, %{"client_version" => version})
        body = json_response(response, 200)
        assert get_resp_header(response, "vary") == ["user-agent"]
        assert [etag] = get_resp_header(response, "etag")
        assert etag == CodexCatalog.etag(body)

        stripped = entry!(body, setup.model.exposed_model_id)
        refute Map.has_key?(stripped, "base_instructions")
        assert stripped == Map.delete(templated, "base_instructions")
        assert entry!(body, setup.legacy_model.exposed_model_id) == legacy_only

        {response.resp_body, etag}
      end

    assert [{template_bytes, template_etag}] = Enum.uniq(template_responses)
    refute template_etag == verbatim_etag
    assert byte_size(template_bytes) < byte_size(verbatim.resp_body)
    assert FakeUpstream.count(upstream) == 0
  end

  test "a turn names the catalog ETag of the representation its own client version fetched",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_catalog_representation_etag",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = catalog_setup(upstream)
    port = start_public_endpoint!()

    for {user_agent, client_version} <- [
          {"codex_exec/0.156.0 (Linux 6.10.14-linuxkit; aarch64) unknown", "0.156.0"},
          {"Codex Desktop/0.155.0-alpha.16 (Mac OS 26.0.0; arm64) unknown", "0.155.0"},
          {"codex_cli_rs/0.147.0 (Mac OS 15.5.0; arm64) xterm", "0.147.0"},
          {"codex_cli_rs/0.146.1 (Linux 6.8.0; x86_64) unknown", "0.146.1"}
        ] do
      models =
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header("user-agent", user_agent)
        |> get("/backend-api/codex/models", %{"client_version" => client_version})

      assert [catalog_etag] = get_resp_header(models, "etag")

      for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
        turn =
          conn
          |> recycle()
          |> auth(setup)
          |> put_req_header("user-agent", user_agent)
          |> post(path, %{
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("synthetic catalog representation turn"),
            "stream" => true
          })

        assert turn.status == 200
        assert get_resp_header(turn, "x-models-etag") == [catalog_etag], "#{user_agent} #{path}"
      end

      {socket, _websocket, _ref, response_headers} =
        public_websocket_connect_with_request_headers!(
          port,
          setup,
          "",
          "/backend-api/codex/responses",
          [{"user-agent", user_agent}]
        )

      try do
        assert List.keyfind(response_headers, "x-models-etag", 0) ==
                 {"x-models-etag", catalog_etag},
               user_agent
      after
        Mint.HTTP.close(socket)
      end
    end

    new_etag = catalog_etag(conn, setup, "0.156.0")
    old_etag = catalog_etag(conn, setup, "0.146.1")
    refute new_etag == old_etag
  end

  # findings#206 row 206-459 and findings#258 row 258-102: the catalog fetch
  # and the turn choose their representation from one parse of the request's
  # User-Agent, so the turn's x-models-etag equals the ETag that client's own
  # catalog fetch got, whatever `client_version` it appends. Codex refetches
  # the catalog whenever the two differ (`refresh_if_new_etag`, rust-v0.156.1).
  # oh-my-pi sends `omp/<version>` on turns and `client_version=0.153.0` on its
  # catalog fetch with no User-Agent of its own (Bun's default); curl reports
  # whatever it is told. An app-server host names the originator with any
  # header-valid `clientInfo.name`, including one with a slash or longer than
  # 64 bytes, and its catalog fetch appends the build's own version.
  @long_originator String.duplicate("synthetic-app-server-host-", 4)

  test "a turn names the catalog ETag its own client's catalog fetch received, for every agent",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_catalog_representation_agents",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = catalog_setup(upstream)
    port = start_public_endpoint!()

    verbatim_etag =
      conn |> recycle() |> auth(setup) |> get("/backend-api/codex/models") |> get_resp_header("etag") |> hd()

    mismatches =
      for {client, turn_user_agent, models_user_agent, client_version, representation} <- [
            {"omp", "omp/18.2.11", "Bun/1.3.14", "0.153.0", :verbatim},
            {"curl", "curl/8.22.0", "curl/8.22.0", "0.156.0", :verbatim},
            {"codex", "codex_cli_rs/0.156.1 (Alpine Linux 3.24.1; aarch64) unknown", "codex_cli_rs/0.156.1 (Alpine Linux 3.24.1; aarch64) unknown", "0.156.1", :template_only},
            {"slash originator", "acme/agent/0.156.1 (Mac OS 26.0.0; arm64) unknown (acme/agent; 1.0.0)", "acme/agent/0.156.1 (Mac OS 26.0.0; arm64) unknown (acme/agent; 1.0.0)", "0.156.1", :template_only},
            {"long originator", "#{@long_originator}/0.156.1 (Linux 6.8.0; x86_64) unknown", "#{@long_originator}/0.156.1 (Linux 6.8.0; x86_64) unknown", "0.156.1", :template_only}
          ],
          mismatch <- agent_etag_mismatches(conn, setup, port, verbatim_etag, {client, turn_user_agent, models_user_agent, client_version, representation}) do
        mismatch
      end

    assert mismatches == []

    # oh-my-pi echoes the last x-models-etag on its next turn; the Pooler never
    # forwards a client-sent value.
    requests = FakeUpstream.requests(upstream)
    assert requests != []
    refute Enum.any?(requests, fn %{headers: headers} -> Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "x-models-etag" end) end)
  end

  defp agent_etag_mismatches(conn, setup, port, verbatim_etag, {client, turn_user_agent, models_user_agent, client_version, representation}) do
    models =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("user-agent", models_user_agent)
      |> get("/backend-api/codex/models", %{"client_version" => client_version})

    assert [catalog_etag] = get_resp_header(models, "etag")

    served =
      if catalog_etag == verbatim_etag, do: :verbatim, else: :template_only

    turn =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("user-agent", turn_user_agent)
      |> put_req_header("x-models-etag", catalog_etag)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic catalog representation agent turn"),
        "stream" => true
      })

    assert turn.status == 200

    {socket, _websocket, _ref, response_headers} =
      public_websocket_connect_with_request_headers!(
        port,
        setup,
        "",
        "/backend-api/codex/responses",
        [{"user-agent", turn_user_agent}]
      )

    upgrade_etag =
      try do
        List.keyfind(response_headers, "x-models-etag", 0)
      after
        Mint.HTTP.close(socket)
      end

    [
      served != representation && {client, :catalog_representation, served},
      get_resp_header(turn, "x-models-etag") != [catalog_etag] && {client, :http_sse_etag_differs},
      upgrade_etag != {"x-models-etag", catalog_etag} && {client, :websocket_upgrade_etag_differs}
    ]
    |> Enum.filter(& &1)
  end

  defp put_codex_user_agent(conn, version),
    do: put_user_agent(conn, "codex_cli_rs/#{version} (Linux 6.8.0; x86_64) unknown")

  defp put_user_agent(conn, nil), do: conn
  defp put_user_agent(conn, user_agent), do: put_req_header(conn, "user-agent", user_agent)

  defp catalog_etag(conn, setup, client_version) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_codex_user_agent(client_version)
    |> get("/backend-api/codex/models", %{"client_version" => client_version})
    |> get_resp_header("etag")
    |> hd()
  end

  defp catalog_setup(upstream) do
    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id =>
              source(setup.model.exposed_model_id, %{
                "base_instructions" => @template,
                "model_messages" => %{
                  "instructions_template" => @template,
                  "instructions_variables" => %{"personality_default" => "synthetic"}
                }
              })
          }
        }
      )
      |> Repo.update!()

    legacy_model =
      model_fixture(setup.pool, %{
        exposed_model_id: "gpt-catalog-legacy-instructions",
        upstream_model_id: "provider-gpt-catalog-legacy-instructions",
        display_name: "Catalog Legacy Instructions",
        metadata: %{
          "source_assignment_ids" => [setup.assignment.id],
          "source_assignment_models" => %{
            setup.assignment.id => source("gpt-catalog-legacy-instructions", %{"base_instructions" => @template})
          }
        }
      })

    setup
    |> Map.put(:model, model)
    |> Map.put(:legacy_model, legacy_model)
  end

  defp source(slug, instructions) do
    Map.merge(
      %{
        "slug" => slug,
        "display_name" => "Synthetic Catalog Representation",
        "description" => "Synthetic catalog representation source",
        "default_reasoning_level" => "high",
        "supported_reasoning_levels" => [%{"effort" => "high", "description" => "High"}],
        "shell_type" => "shell_command",
        "visibility" => "list",
        "supported_in_api" => true,
        "priority" => 1,
        "support_verbosity" => false,
        "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
        "experimental_supported_tools" => [],
        "use_responses_lite" => false
      },
      instructions
    )
  end

  defp entry!(%{"models" => models}, slug) do
    case Enum.find(models, &(&1["slug"] == slug)) do
      %{} = entry -> entry
      nil -> flunk("catalog entry #{slug} missing")
    end
  end
end
