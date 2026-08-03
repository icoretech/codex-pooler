defmodule CodexPooler.Dev.ResponsesToolCompatSmokeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Dev.ResponsesToolCompatSmoke, as: Smoke
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  import CodexPooler.AccountsFixtures

  @owner_id "11111111-1111-4111-8111-111111111111"
  @labels ~w(codex01 codex02 codex03)

  setup do
    run_id = "20260803T120000Z-#{random_hex(6)}"
    run_dir = Path.join(["tmp", "issue-241", "runtime", run_id])
    receipt_path = Path.join(["tmp", "issue-241", "receipts", "#{run_id}.json"])

    on_exit(fn ->
      File.rm_rf(run_dir)
      File.rm(receipt_path)
    end)

    %{run_id: run_id, run_dir: run_dir, receipt_path: receipt_path}
  end

  describe "parse_args/1" do
    test "accepts the exact provisioning shape" do
      assert {:ok,
              %{
                mode: :provision,
                owner_id: @owner_id,
                identity_labels: @labels,
                dry_run?: true,
                base_url: %URI{scheme: "http", host: "localhost", port: 4000}
              }} =
               Smoke.parse_args([
                 "--base-url",
                 "http://localhost:4000",
                 "--owner-id",
                 @owner_id,
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex02",
                 "--identity-label",
                 "codex03",
                 "--dry-run"
               ])
    end

    test "accepts cleanup only with the same explicit owner contract", %{run_id: run_id} do
      assert {:ok, %{mode: :cleanup, cleanup_run_id: ^run_id, owner_id: @owner_id}} =
               Smoke.parse_args(["--cleanup-run-id", run_id, "--owner-id", @owner_id])
    end

    test "accepts owner resolution only as a standalone mode" do
      assert {:ok, %{mode: :resolve_owner}} = Smoke.parse_args(["--resolve-owner-id"])

      assert {:error, "--resolve-owner-id must be used alone"} =
               Smoke.parse_args(["--resolve-owner-id", "--owner-id", @owner_id])
    end

    test "rejects non-loopback, malformed, duplicate, incomplete, and unknown input", %{
      run_id: run_id
    } do
      common = [
        "--owner-id",
        @owner_id,
        "--identity-label",
        "codex01",
        "--identity-label",
        "codex02",
        "--identity-label",
        "codex03"
      ]

      assert {:error, "base URL must be an origin-only HTTP loopback URL"} =
               Smoke.parse_args(["--base-url", "https://example.com" | common])

      assert {:error, "base URL must be an origin-only HTTP loopback URL"} =
               Smoke.parse_args(["--base-url", "http://localhost:4000/v1" | common])

      assert {:error, "owner id must be a UUID"} =
               Smoke.parse_args([
                 "--base-url",
                 "http://127.0.0.1:4000",
                 "--owner-id",
                 "wrong"
                 | Enum.drop(common, 2)
               ])

      assert {:error, "identity labels must be distinct"} =
               Smoke.parse_args([
                 "--base-url",
                 "http://127.0.0.1:4000",
                 "--owner-id",
                 @owner_id,
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex01",
                 "--identity-label",
                 "codex03"
               ])

      assert {:error, "exactly three --identity-label values are required"} =
               Smoke.parse_args(["--base-url", "http://localhost:4000" | Enum.drop(common, -2)])

      assert {:error, "cleanup accepts only --cleanup-run-id and --owner-id"} =
               Smoke.parse_args([
                 "--cleanup-run-id",
                 run_id,
                 "--owner-id",
                 @owner_id,
                 "--dry-run"
               ])

      assert {:error, "unknown or positional arguments are not allowed"} =
               Smoke.parse_args(["--unknown"])
    end
  end

  test "synthetic dry-run validates fixtures without boot, writes, or network" do
    command = provision_command()

    inspection = %{
      owners: [@owner_id],
      identities:
        Enum.with_index(@labels, 1)
        |> Enum.map(fn {label, index} ->
          %{
            id:
              "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
            label: label,
            status: "active"
          }
        end),
      other_client_application_names: []
    }

    assert {:ok,
            "dry-run passed: localhost, sole owner, three distinct active identities, no writes"} =
             Smoke.execute(command,
               inspection: inspection,
               server_check: fn _uri -> :ok end
             )
  end

  test "synthetic dry-run fails closed on owner, identity, database, and port guards" do
    command = provision_command()
    valid = valid_inspection()

    assert {:error, "owner id is not the sole active instance owner"} =
             Smoke.execute(command,
               inspection: %{valid | owners: []},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "identity labels must resolve to exactly three distinct active identities"} =
             Smoke.execute(command,
               inspection: %{valid | identities: Enum.drop(valid.identities, 1)},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "database has another client backend"} =
             Smoke.execute(command,
               inspection: %{valid | other_client_application_names: ["other-client"]},
               server_check: fn _uri -> :ok end
             )

    assert {:error, "localhost port is already occupied"} =
             Smoke.execute(command,
               inspection: valid,
               server_check: fn _uri -> {:error, "localhost port is already occupied"} end
             )
  end

  test "isolated endpoint uses the installed Bandit protocol option boundary" do
    endpoint = Smoke.isolated_endpoint_config([], URI.parse("http://localhost:4000"))
    http = Keyword.fetch!(endpoint, :http)

    assert Keyword.fetch!(http, :http_1_options) == [enabled: true]
    assert Keyword.fetch!(http, :http_2_options) == [enabled: false]
    refute Keyword.has_key?(http, :protocol_options)

    {:ok, pid} =
      Bandit.start_link(
        plug: fn conn, _opts -> Plug.Conn.send_resp(conn, 200, "ok") end,
        port: 0,
        http_1_options: [enabled: true],
        http_2_options: [enabled: false]
      )

    Process.unlink(pid)
    on_exit(fn -> Supervisor.stop(pid) end)
  end

  test "journal replacement is private, exact, and rejects symlink traversal", %{
    run_id: run_id,
    run_dir: run_dir
  } do
    journal = Smoke.new_journal(run_id, @owner_id, @labels)
    :ok = Smoke.write_journal!(run_dir, journal)

    assert {:ok, ^journal} = Smoke.read_journal(run_id)
    assert {:ok, %File.Stat{type: :directory, mode: directory_mode}} = File.lstat(run_dir)
    assert Bitwise.band(directory_mode, 0o077) == 0

    manifest = Path.join(run_dir, "manifest.json")
    assert {:ok, %File.Stat{type: :regular, mode: file_mode}} = File.lstat(manifest)
    assert Bitwise.band(file_mode, 0o077) == 0

    File.rm!(manifest)
    File.ln_s!(Path.join(run_dir, "missing"), manifest)

    assert {:error, "expected a regular file and refused a link or special file"} =
             Smoke.read_journal(run_id)
  end

  test "journal targeting is derived only from the run id", %{run_id: run_id, run_dir: run_dir} do
    journal = Smoke.new_journal(run_id, @owner_id, @labels)
    assert :ok = Smoke.validate_journal_targets(journal)
    assert Enum.all?(journal["pool_slugs"], &(&1 == String.downcase(&1)))

    tampered = %{journal | "pool_slugs" => ["unrelated-pool"]}
    :ok = Smoke.write_journal!(run_dir, tampered)

    assert {:error, "run manifest contains non-deterministic Pool targets"} =
             Smoke.read_journal(run_id)
  end

  test "new and repeatedly recovered journal Pool slugs stay canonical and readable", %{
    run_id: run_id,
    run_dir: run_dir
  } do
    owner = owner_fixture!()
    scope = Scope.for_user(owner)
    journal = Smoke.new_journal(run_id, owner.id, @labels)
    [slug | _rest] = journal["pool_slugs"]

    assert slug == String.downcase(slug)

    assert {:ok, pool} =
             Pools.create_pool(
               scope,
               %{slug: String.upcase(slug), name: "Canonical recovery", status: "active"},
               broadcast?: false
             )

    assert pool.slug == slug
    assert {:ok, recovered_once} = Smoke.recover_pools(journal)
    assert {:ok, recovered_twice} = Smoke.recover_pools(recovered_once)
    assert recovered_twice["pool_slugs"] == journal["pool_slugs"]

    assert [%{"id" => pool_id, "slug" => ^slug}] =
             Enum.filter(recovered_twice["resources"], &(&1["kind"] == "pool"))

    assert pool_id == pool.id
    :ok = Smoke.write_journal!(run_dir, recovered_twice)
    assert {:ok, ^recovered_twice} = Smoke.read_journal(run_id)
  end

  test "cleanup plan contains exact recorded ids only and has dependency order", %{run_id: run_id} do
    journal =
      Smoke.new_journal(run_id, @owner_id, @labels)
      |> Smoke.record_resource("pool", "pool-exact", %{slug: "issue-241-#{run_id}-01"})
      |> Smoke.record_resource("model", "model-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("api_key", "key-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("assignment", "assignment-exact", %{pool_id: "pool-exact"})
      |> Smoke.record_resource("serving_override", "override-exact", %{
        pool_id: "pool-exact",
        model_id: "gpt-example"
      })
      |> Smoke.record_resource("pool", "pool-exact", %{})
      |> Smoke.record_resource("unknown", "must-not-clean", %{})

    assert Enum.map(Smoke.exact_cleanup_plan(journal), &{&1["kind"], &1["id"]}) == [
             {"serving_override", "override-exact"},
             {"assignment", "assignment-exact"},
             {"api_key", "key-exact"},
             {"model", "model-exact"},
             {"pool", "pool-exact"}
           ]
  end

  test "cleanup ownership uses the persisted canonical Pool slug and rejects mismatches", %{
    run_id: run_id
  } do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])

    {:ok, pool} =
      Pools.create_pool(
        scope,
        %{slug: "Issue-241-#{run_id}-01", name: "Issue 241 ownership test", status: "active"},
        broadcast?: false
      )

    journal = Smoke.new_journal(run_id, @owner_id, @labels)
    valid = %{journal | "pool_slugs" => [pool.slug]}
    plan = [%{"kind" => "pool", "id" => pool.id, "slug" => pool.slug}]

    assert :ok = Smoke.validate_cleanup_ownership(plan, valid)

    mismatched = [%{hd(plan) | "slug" => "issue-241-mismatched"}]

    assert {:error, "journaled Pool ownership did not match its deterministic slug"} =
             Smoke.validate_cleanup_ownership(mismatched, valid)
  end

  test "catalog sync result contract accepts complete and rejects partial, skipped, and unknown shapes" do
    sync_run = %CodexPooler.Catalog.SyncRun{}
    model = %CodexPooler.Catalog.Model{}

    assert {:ok, %{sync_run: ^sync_run, models: [^model]}} =
             Smoke.accept_catalog_sync_result(
               {:ok, %{sync_run: sync_run, models: [model], partial?: false}}
             )

    assert {:error, "catalog sync was partial"} =
             Smoke.accept_catalog_sync_result({:ok, %{partial?: true}})

    assert {:error, "catalog sync was skipped"} =
             Smoke.accept_catalog_sync_result({:ok, %{skipped?: true}})

    assert {:error, "provisioning returned an unexpected shape"} =
             Smoke.accept_catalog_sync_result(
               {:ok, %{sync_run: %URI{}, models: [model], partial?: false}}
             )

    assert {:error, "provisioning returned an unexpected shape"} =
             Smoke.accept_catalog_sync_result(:unexpected)
  end

  test "candidate probe classification sanitizes binary and non-binary failures" do
    assert Smoke.classify_candidate_probe_result(:ok) == "passed_terminal_and_settlement"

    assert Smoke.classify_candidate_probe_result({:expected_denial, :lite_typed_tool_choice}) ==
             "denied_unsupported_typed_choice"

    refute Smoke.classify_candidate_probe_result({:expected_denial, :lite_typed_tool_choice}) ==
             "passed_terminal_and_settlement"

    assert Smoke.classify_candidate_probe_result(:not_tested) == "not_tested_http_failed"

    assert Smoke.classify_candidate_probe_result(
             {:error, "provider did not return the required tool call"}
           ) == "missing_forced_tool_call"

    assert Smoke.classify_candidate_probe_result({:error, :response_timeout}) ==
             "transport_failed"

    assert Smoke.classify_candidate_probe_result(:unexpected) == "probe_failed"
  end

  test "paired candidate controls independently gate each websocket on its matching HTTP" do
    parent = self()

    passing_function = fn control, transport ->
      send(parent, {:candidate_control, control, transport})
      if control == "custom", do: {:error, "custom omitted"}, else: :ok
    end

    assert Smoke.run_paired_candidate_controls(passing_function) == [
             %{control: "custom", transport: "http", result: {:error, "custom omitted"}},
             %{control: "custom", transport: "websocket", result: :not_tested},
             %{control: "function", transport: "http", result: :ok},
             %{control: "function", transport: "websocket", result: :ok}
           ]

    assert_receive {:candidate_control, "custom", "http"}
    refute_received {:candidate_control, "custom", "websocket"}
    assert_receive {:candidate_control, "function", "http"}
    assert_receive {:candidate_control, "function", "websocket"}

    failing_function = fn control, transport ->
      send(parent, {:failed_candidate_control, control, transport})
      if control == "function", do: {:error, "function omitted"}, else: :ok
    end

    assert Smoke.run_paired_candidate_controls(failing_function) == [
             %{control: "custom", transport: "http", result: :ok},
             %{control: "custom", transport: "websocket", result: :ok},
             %{control: "function", transport: "http", result: {:error, "function omitted"}},
             %{control: "function", transport: "websocket", result: :not_tested}
           ]

    assert_receive {:failed_candidate_control, "custom", "http"}
    assert_receive {:failed_candidate_control, "custom", "websocket"}
    assert_receive {:failed_candidate_control, "function", "http"}
    refute_received {:failed_candidate_control, "function", "websocket"}
  end

  test "candidate controls use an unconfounded strict function schema and Codex-shaped custom tool" do
    cases = Smoke.candidate_capability_cases("20260803T120000Z-abcdef123456")

    function_tool = cases["function"].payload["tools"] |> List.first()
    function_schema = function_tool["parameters"]

    assert function_schema["properties"]["goal"]["type"] == "object"
    assert function_tool["strict"] == true

    custom_tool = cases["custom"].payload["tools"] |> List.first()

    assert custom_tool["description"] != ""
    assert custom_tool["format"]["type"] == "grammar"
    assert custom_tool["format"]["syntax"] == "lark"
  end

  test "candidate result aggregation keeps bounded control metadata only" do
    assert Smoke.aggregate_candidate_probe_results([
             %{
               model: "gpt-example",
               profile: "lite",
               control: "function",
               transport: "http",
               status: "missing_forced_tool_call",
               raw_key: "forbidden-raw-key",
               arguments: %{"forbidden" => true}
             }
           ]) == [
             %{
               model: "gpt-example",
               profile: "lite",
               control: "function",
               transport: "http",
               status: "missing_forced_tool_call"
             }
           ]
  end

  # This provider sends `"output": []` in every terminal response.completed,
  # including turns where it demonstrably called the tool (wire-verified
  # 2026-08-03). Callers must backfill the terminal from the streamed
  # response.output_item.done events before asserting; a bare empty array is a
  # real failure, not an accepted outcome.
  test "certification requires an exact forced tool call from the backfilled terminal" do
    smoke_case = Smoke.candidate_capability_cases("20260803T120000Z-abcdef123456")["function"]

    assert {:error, "provider did not return the required tool call"} =
             Smoke.validate_terminal_output(%{"output" => []}, smoke_case)

    call = %{
      "type" => "function_call",
      "name" => smoke_case.name,
      "arguments" => Jason.encode!(%{"goal" => %{"value" => "issue241"}})
    }

    assert :ok = Smoke.validate_terminal_output(%{"output" => [call]}, smoke_case)

    assert Smoke.certification_case_status("full", smoke_case) == "passed_forced_tool_call"

    denial = Map.put(smoke_case, :result, {:expected_denial, :lite_typed_tool_choice})
    assert Smoke.certification_case_status("lite", denial) == "rejected_unsupported_typed_choice"

    assert Smoke.certification_case_status("lite", Map.put(smoke_case, :result, :ok)) ==
             "failed_unexpected_success"
  end

  test "websocket terminals are backfilled from streamed output item frames" do
    call = %{"type" => "custom_tool_call", "name" => "probe", "input" => "issue241"}

    frames = [
      %{"type" => "response.created"},
      %{"type" => "response.output_item.done", "item" => call},
      %{"type" => "response.completed", "response" => %{"output" => []}}
    ]

    assert %{"output" => [^call]} =
             Smoke.backfill_websocket_output(%{"output" => []}, frames)

    # A terminal that already carries items is authoritative and never replaced.
    existing = %{"type" => "function_call", "name" => "kept"}

    assert %{"output" => [^existing]} =
             Smoke.backfill_websocket_output(%{"output" => [existing]}, frames)

    # Nothing to backfill from leaves the empty array intact, so the assertion
    # above still reports a genuine missing call.
    assert %{"output" => []} = Smoke.backfill_websocket_output(%{"output" => []}, [])
  end

  test "Lite typed-choice lifecycle allows one sanitized rejection without attempts or ledger entries" do
    request = %CodexPooler.Accounting.Request{
      status: "rejected",
      last_error_code: "unsupported_parameter",
      request_metadata: %{"gateway_denial" => %{"param" => "tool_choice"}}
    }

    before_counts = %{requests: 3, attempts: 2, ledger_entries: 6, settlements: 2}
    after_counts = %{requests: 4, attempts: 2, ledger_entries: 6, settlements: 2}

    assert :ok =
             Smoke.validate_lite_typed_choice_lifecycle(before_counts, after_counts, request)

    assert {:error, "Lite typed tool choice was not rejected before dispatch"} =
             Smoke.validate_lite_typed_choice_lifecycle(
               before_counts,
               %{after_counts | attempts: 3},
               request
             )

    assert {:error, "Lite typed tool choice was not rejected before dispatch"} =
             Smoke.validate_lite_typed_choice_lifecycle(
               before_counts,
               %{after_counts | ledger_entries: 7},
               request
             )
  end

  test "receipt publication strips forbidden owner and secret-bearing fields", %{
    run_id: run_id,
    receipt_path: receipt_path
  } do
    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Smoke.validate_receipt(%{run_id: run_id, owner_user_id: @owner_id})

    assert ^receipt_path =
             Smoke.publish_receipt!(%{
               run_id: run_id,
               certification_status: "failed",
               cleanup_status: "completed",
               owner_user_id: @owner_id,
               raw_key: "forbidden-raw-key",
               provider_identifier: "forbidden-provider"
             })

    assert {:ok, content} = File.read(receipt_path)
    assert {:ok, receipt} = Jason.decode(content)

    assert receipt == %{
             "certification_status" => "failed",
             "cleanup_status" => "completed",
             "run_id" => run_id
           }

    refute content =~ @owner_id
    refute content =~ "forbidden-raw-key"
    refute content =~ "forbidden-provider"
  end

  test "direct Pool and assignment lifecycle does not enqueue catalog sync jobs" do
    owner = owner_fixture!()
    scope = Scope.for_user(owner)
    identity = active_identity_fixture!()
    slug = "issue-241-no-job-#{System.unique_integer([:positive])}"

    assert {:ok, pool} =
             Pools.create_pool(scope, %{slug: slug, name: "No job smoke", status: "active"},
               broadcast?: false
             )

    assert :ok =
             Upstreams.sync_pool_assignments_for_pool_edit(pool, [identity.id],
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             )

    assert [%PoolUpstreamAssignment{status: "active", upstream_identity_id: identity_id}] =
             Upstreams.list_pool_assignments(pool)

    assert identity_id == identity.id

    refute_enqueued(
      worker: CodexPooler.Jobs.CatalogSyncWorker,
      args: %{"pool_id" => pool.id}
    )

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "Elixir.CodexPooler.Jobs.CatalogSyncWorker" and
                   fragment("?->>'pool_id' = ?", job.args, ^pool.id)
             ),
             :count
           ) == 0
  end

  defp provision_command do
    %{
      mode: :provision,
      owner_id: @owner_id,
      identity_labels: @labels,
      base_url: URI.parse("http://localhost:4000"),
      dry_run?: true
    }
  end

  defp valid_inspection do
    %{
      owners: [@owner_id],
      identities:
        Enum.with_index(@labels, 1)
        |> Enum.map(fn {label, index} ->
          %{
            id:
              "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(index), 12, "0")}",
            label: label,
            status: "active"
          }
        end),
      other_client_application_names: []
    }
  end

  defp owner_fixture! do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    user =
      %User{}
      |> User.bootstrap_changeset(%{
        "email" => "issue-241-owner-#{System.unique_integer([:positive])}@example.com",
        "display_name" => "Issue 241 Owner",
        "password" => "bootstrap-pass-123"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      role: "instance_owner",
      status: "active",
      created_by_user_id: user.id,
      created_at: now
    })
    |> Repo.insert!()

    user
  end

  defp active_identity_fixture! do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = System.unique_integer([:positive])

    %UpstreamIdentity{
      chatgpt_account_id: "acct_issue241_#{unique}",
      account_label: "issue-241-identity-#{unique}",
      onboarding_method: "import",
      status: "active",
      headers_profile_version: 1,
      created_at: now,
      updated_at: now,
      metadata: %{}
    }
    |> Repo.insert!()
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
