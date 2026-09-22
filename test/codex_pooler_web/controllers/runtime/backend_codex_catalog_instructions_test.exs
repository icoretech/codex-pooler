defmodule CodexPoolerWeb.Runtime.BackendCodexCatalogInstructionsTest do
  # findings#258 rows 258-43/258-62: a Codex client whose catalog decoder
  # prefers `model_messages.instructions_template` (every build reporting
  # 0.148.0 or newer) gets entries without the mirrored `base_instructions`;
  # older, 0.147.0, absent and unparsable versions keep the entry verbatim. The
  # ETag is the digest of the served representation, and a Responses turn names
  # the representation the same client's catalog fetch selected.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Repo

  @template "Synthetic instructions template for the catalog representation test."
  @template_only_versions ["0.156.0", "0.148.0", "0.155.0"]
  @verbatim_versions ["0.147.0", "0.146.1", "not-a-version", ""]

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

    for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"],
        version <- @verbatim_versions do
      response = conn |> recycle() |> auth(setup) |> get(path, %{"client_version" => version})

      assert json_response(response, 200) == verbatim_body, "#{path} #{version}"
      assert get_resp_header(response, "etag") == [verbatim_etag], "#{path} #{version}"
    end

    template_responses =
      for path <- ["/backend-api/codex/models", "/backend-api/codex/v1/models"],
          version <- @template_only_versions do
        response = conn |> recycle() |> auth(setup) |> get(path, %{"client_version" => version})
        body = json_response(response, 200)
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

  defp catalog_etag(conn, setup, client_version) do
    conn
    |> recycle()
    |> auth(setup)
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
