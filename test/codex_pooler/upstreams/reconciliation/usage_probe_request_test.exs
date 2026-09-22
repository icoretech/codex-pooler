defmodule CodexPooler.Upstreams.Reconciliation.UsageProbeRequestTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Ecto.Adapters.SQL.Sandbox

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.UpstreamConnPoolTelemetry
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @account_id "acct_usage_header_contract"
  @probe_detection_timeout_ms 15_000

  test "usage GETs match current Codex and omit an explicit JSON Accept header" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 1,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600,
          "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 3_600, :second))
        }
      }
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {404, %{}},
           "/backend-api/codex/usage" => {200, payload}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment, access_token: access_token} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/codex/usage"}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    requests = FakeUpstream.requests(fake)

    assert Enum.map(requests, & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/codex/usage"
           ]

    Enum.each(requests, fn request ->
      headers = Map.new(request.headers)

      assert headers["authorization"] == "Bearer #{access_token}"
      assert headers["chatgpt-account-id"] == @account_id
      refute Map.has_key?(headers, "accept")
    end)
  end

  # codex-pooler#390. A throttled usage read used to fall straight through to
  # the alternative endpoint and then repeat both on the next probe, so a
  # provider asking for an hour got four requests in under a second.
  test "a valid Retry-After stops the fallback chain and the reads that would follow" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {:json_headers, 429, %{}, [{"retry-after", "3600"}]},
           "/backend-api/codex/usage" => {200, usage_payload(observed_at)}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:error, {:usage_poll_deferred, %DateTime{} = not_before}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert DateTime.diff(not_before, observed_at, :second) in 3_500..3_601

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == ["/backend-api/wham/usage"]

    # The pause is committed, so a second probe of the same identity does not
    # reach the provider at all - including the endpoint that never answered.
    assert {:error, {:usage_poll_deferred, ^not_before}} =
             UsageProbe.fetch_from_identity(
               Repo.get!(UpstreamIdentity, identity.id),
               assignment,
               DateTime.add(observed_at, 30, :second),
               []
             )

    assert length(FakeUpstream.requests(fake)) == 1
  end

  # findings#259: an anomalous interval must be noticed, once, when it is the
  # one that sets the deadline - never for an ordinary short throttle, and never
  # for an instruction merged into a longer pause that is already running.
  test "a Retry-After longer than an hour is logged once with bounded fields, a short one is not" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, short} = FakeUpstream.start_link({:path_json, %{"/backend-api/wham/usage" => {:json_headers, 429, %{}, [{"retry-after", "900"}]}}})
    {:ok, long} = FakeUpstream.start_link({:path_json, %{"/backend-api/wham/usage" => {:json_headers, 503, %{}, [{"retry-after", "259200"}]}}})

    on_exit(fn ->
      FakeUpstream.stop(short)
      FakeUpstream.stop(long)
    end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(short)}
      })

    short_log =
      capture_log(fn ->
        assert {:error, {:usage_poll_deferred, _deadline}} =
                 UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])
      end)

    refute short_log =~ "long-pause threshold"

    long_assignment = %{assignment | metadata: %{"usage_base_url" => FakeUpstream.url(long)}}

    long_log =
      capture_log(fn ->
        assert {:error, {:usage_poll_deferred, deadline}} =
                 UsageProbe.fetch_from_identity(Repo.get!(UpstreamIdentity, identity.id), long_assignment, observed_at, [])

        send(self(), {:deadline, deadline})
      end)

    assert_received {:deadline, deadline}
    assert long_log =~ "usage polling paused beyond the long-pause threshold by a provider Retry-After"
    assert long_log =~ "upstream_identity_id=#{identity.id} credential_epoch=1"
    assert long_log =~ "status=503 paused_until=#{DateTime.to_iso8601(deadline)}"
    assert long_log =~ ~r/pause_seconds=259\d{3} threshold_seconds=3600/
    refute long_log =~ FakeUpstream.url(long)
    refute long_log =~ "127.0.0.1"

    # A shorter instruction on the same host merges into the running pause and
    # sets nothing, so it says nothing either.
    identity = Repo.get!(UpstreamIdentity, identity.id)
    origin = UsagePollCooldown.origin_key(FakeUpstream.url(long))

    merged_log =
      capture_log(fn ->
        assert {:ok, ^deadline} =
                 UsagePollCooldown.record(identity.id, 1, origin, 429, DateTime.add(observed_at, 7_200, :second), observed_at)
      end)

    refute merged_log =~ "long-pause threshold"
  end

  test "a throttled read with no usable instruction keeps the existing fallback" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    for {label, header} <- [{"absent", []}, {"malformed", [{"retry-after", "later please"}]}] do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/usage" => {:json_headers, 429, %{}, header},
             "/backend-api/codex/usage" => {200, usage_payload(observed_at)}
           }}
        )

      on_exit(fn -> FakeUpstream.stop(fake) end)

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool_fixture(), %{
          chatgpt_account_id: "#{@account_id}_#{label}",
          metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
        })

      assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/codex/usage"}} =
               UsageProbe.fetch_from_identity(identity, assignment, observed_at, []),
             "expected a #{label} Retry-After to keep falling back"

      assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end
  end

  test "an unavailable upstream that says when to come back is deferred, not just halted" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {:json_headers, 503, %{}, [{"retry-after", "900"}]},
           "/backend-api/codex/usage" => {200, usage_payload(observed_at)}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: "#{@account_id}_503",
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:error, {:usage_poll_deferred, %DateTime{} = not_before}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert DateTime.diff(not_before, observed_at, :second) in 800..901

    assert {:error, {:usage_poll_deferred, ^not_before}} =
             UsageProbe.fetch_from_identity(
               Repo.get!(UpstreamIdentity, identity.id),
               assignment,
               observed_at,
               []
             )

    assert length(FakeUpstream.requests(fake)) == 1
  end

  test "a throttled reset-credit read keeps the usage result and still pauses the next probe" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload =
      observed_at
      |> usage_payload()
      |> Map.put("rate_limit_reset_credits", %{"available_count" => 1})

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/wham/rate-limit-reset-credits" => {:json_headers, 429, %{}, [{"retry-after", "1800"}]}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: "#{@account_id}_detail",
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    # The usage read succeeded, so its result stands: only the optional detail
    # read was refused.
    assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/wham/usage"}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]

    # The pause the detail read was told about covers the whole origin, so the
    # next usage probe does not go out either.
    assert {:error, {:usage_poll_deferred, %DateTime{}}} =
             UsageProbe.fetch_from_identity(
               Repo.get!(UpstreamIdentity, identity.id),
               assignment,
               DateTime.add(observed_at, 30, :second),
               []
             )

    assert length(FakeUpstream.requests(fake)) == 2
  end

  test "two usage hosts of one identity keep their own pauses" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, throttled} =
      FakeUpstream.start_link({:path_json, %{"/backend-api/wham/usage" => {:json_headers, 429, %{}, [{"retry-after", "3600"}]}}})

    {:ok, healthy} =
      FakeUpstream.start_link({:path_json, %{"/backend-api/wham/usage" => {200, usage_payload(observed_at)}}})

    on_exit(fn ->
      FakeUpstream.stop(throttled)
      FakeUpstream.stop(healthy)
    end)

    %{identity: identity, assignment: throttled_assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: "#{@account_id}_origins",
        metadata: %{"usage_base_url" => FakeUpstream.url(throttled)}
      })

    healthy_assignment = %{
      throttled_assignment
      | metadata: %{"usage_base_url" => FakeUpstream.url(healthy)}
    }

    assert {:error, {:usage_poll_deferred, %DateTime{}}} =
             UsageProbe.fetch_from_identity(identity, throttled_assignment, observed_at, [])

    # The pause belongs to the host that asked for it. The same identity
    # reading a different usage host is untouched.
    assert {:ok, %UsageProbe.Result{}} =
             UsageProbe.fetch_from_identity(
               Repo.get!(UpstreamIdentity, identity.id),
               healthy_assignment,
               observed_at,
               []
             )

    assert length(FakeUpstream.requests(throttled)) == 1
    assert length(FakeUpstream.requests(healthy)) == 1
  end

  test "an auth rejection before a throttled read keeps its result and still records the pause" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {403, %{"error" => "forbidden"}},
           "/backend-api/codex/usage" => {:json_headers, 429, %{}, [{"retry-after", "3600"}]}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: "#{@account_id}_mixed",
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    # The auth rejection is the stronger fact about this credential and keeps
    # its existing precedence in the result.
    assert {:error, {:mixed_auth_rejection, {:usage_poll_deferred, %DateTime{}}}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    assert length(FakeUpstream.requests(fake)) == 2

    # The pause was still committed, so the next probe does not retry either.
    assert {:error, {:usage_poll_deferred, %DateTime{}}} =
             UsageProbe.fetch_from_identity(
               Repo.get!(UpstreamIdentity, identity.id),
               assignment,
               DateTime.add(observed_at, 30, :second),
               []
             )

    assert length(FakeUpstream.requests(fake)) == 2
  end

  defp usage_payload(observed_at) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 1,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 3_600,
          "reset_at" => DateTime.to_unix(DateTime.add(observed_at, 3_600, :second))
        }
      }
    }
  end

  test "usage and reset-credit GETs carry the upstream connection idle bound from settings" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      "plan_type" => "plus",
      "rate_limit" => %{"allowed" => true, "limit_reached" => false},
      "rate_limit_reset_credits" => %{"available_count" => 1}
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/codex/usage" => {200, payload},
           "/backend-api/wham/rate-limit-reset-credits" => {200, %{"items" => []}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    UpstreamConnPoolTelemetry.put_idle_bound!(0)
    UpstreamConnPoolTelemetry.attach!(FakeUpstream.url(fake))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, %UsageProbe.Result{}} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    paths = fake |> FakeUpstream.requests() |> Enum.map(& &1.path)
    assert "/backend-api/wham/rate-limit-reset-credits" in paths
    assert length(paths) >= 2

    assert UpstreamConnPoolTelemetry.drain_events() ==
             List.duplicate(:conn_max_idle_time_exceeded, length(paths) - 1)
  end

  for stage <- [:before_headers, :mid_stream], earlier_success? <- [false, true] do
    test "#{stage} timeout preserves only earlier successful coverage=#{earlier_success?}" do
      assert_timeout_coverage(unquote(stage), unquote(earlier_success?))
    end
  end

  defp assert_timeout_coverage(stage, earlier_success?) do
    observed_at = DateTime.utc_now()
    release_ref = make_ref()

    response = timeout_response(stage, release_ref)

    entries =
      if earlier_success? do
        [
          usage_request("/api/codex/usage", FakeUpstream.json_response(weekly_payload())),
          usage_request("/backend-api/codex/usage", response)
        ]
      else
        [usage_request("/api/codex/usage", response)]
      end

    {fake, identity, assignment} = probe_fixture(entries)
    task = start_probe(identity, assignment, observed_at, 200)

    assert_receive {:fake_upstream_timeout_barrier, ^stage, handler, ^release_ref},
                   @probe_detection_timeout_ms

    handler_monitor = Process.monitor(handler)

    try do
      # Exercise the real Finch receive timeout while the response is held.
      # The one-second budget lets an earlier healthy request complete under load.
      result = Task.await(task, @probe_detection_timeout_ms)

      if earlier_success? do
        assert {:ok, %UsageProbe.Result{} = probe} = result
        assert probe.usage_path == "/api/codex/usage"
        assert length(probe.windows) == 1
        assert MapSet.size(probe.covered_descriptors) == 1
      else
        assert {:error, %{reason: :timeout}} = result
      end

      assert FakeUpstream.count(fake) == length(entries)
      assert :ok = FakeUpstream.verify!(fake)
      send(handler, {:fake_upstream_release_timeout, release_ref})

      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason},
                     @probe_detection_timeout_ms
    after
      send(handler, {:fake_upstream_release_timeout, release_ref})
    end
  end

  test "canceling an in-flight probe cannot dispatch a fallback or apply its late response" do
    release_ref = make_ref()

    {fake, identity, assignment} =
      probe_fixture([
        usage_request(
          "/api/codex/usage",
          {:gated_json_headers, 200, primary_payload(), self(), release_ref}
        )
      ])

    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.allow(Repo, owner, self())
        PoolReconciliation.refresh_quota_from_usage(identity, assignment, receive_timeout: 30_000)
      end)

    assert_receive {:fake_upstream_gate, :before_headers, handler, ^release_ref},
                   @probe_detection_timeout_ms

    handler_monitor = Process.monitor(handler)

    try do
      assert nil == Task.shutdown(task, :brutal_kill)
      send(handler, {:fake_upstream_release_gate, release_ref})

      assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason},
                     @probe_detection_timeout_ms

      assert FakeUpstream.count(fake) == 1
      assert :ok = FakeUpstream.verify!(fake)
      assert Windows.list_evidence(identity) == []
      assert Repo.reload!(identity).metadata["usage_probe_sequence"] == 1
      assert Repo.reload!(identity).metadata["usage_probe_applied_sequence"] == 0
    after
      send(handler, {:fake_upstream_release_gate, release_ref})
    end
  end

  for {label, first_response} <- [
        not_found: {:json, 404, %{}},
        rate_limited: {:json, 429, %{}},
        empty: {:json, 200, %{}},
        malformed: {:malformed_json, 200, "{"}
      ] do
    test "#{label} response falls back once without adding descriptor coverage" do
      {fake, identity, assignment} =
        probe_fixture([
          usage_request("/api/codex/usage", unquote(Macro.escape(first_response))),
          usage_request("/backend-api/codex/usage", FakeUpstream.json_response(primary_payload()))
        ])

      assert {:ok, %UsageProbe.Result{} = probe} =
               UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])

      assert probe.usage_path == "/backend-api/codex/usage"
      assert length(probe.windows) == 1
      assert MapSet.size(probe.covered_descriptors) == 1
      assert FakeUpstream.count(fake) == 2
      assert :ok = FakeUpstream.verify!(fake)
    end
  end

  test "server failure stops probing and does not silently retry the GET" do
    {fake, identity, assignment} =
      probe_fixture([
        usage_request("/api/codex/usage", FakeUpstream.json_response(%{}, 503))
      ])

    assert {:error, {:upstream_status, 503}} =
             UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])

    assert FakeUpstream.count(fake) == 1
    assert :ok = FakeUpstream.verify!(fake)
  end

  for {label, body} <- [array: "[]", null: "null", number: "42", string: "\"invalid\""] do
    test "#{label} reset-credit detail cannot discard a successful quota probe" do
      payload = Map.put(primary_payload(), "rate_limit_reset_credits", %{"available_count" => 1})

      invalid_detail =
        FakeUpstream.raw_response(unquote(body), headers: [{"content-type", "application/json"}])

      {fake, identity, assignment} =
        probe_fixture([
          usage_request("/api/codex/usage", FakeUpstream.json_response(payload)),
          usage_request("/backend-api/wham/rate-limit-reset-credits", invalid_detail),
          usage_request("/wham/rate-limit-reset-credits", invalid_detail)
        ])

      assert {:ok, %UsageProbe.Result{} = probe} =
               UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])

      assert length(probe.windows) == 1
      assert MapSet.size(probe.covered_descriptors) == 1
      assert probe.payload["rate_limit_reset_credits"]["available_count"] == 1
      assert FakeUpstream.count(fake) == 3
      assert :ok = FakeUpstream.verify!(fake)
    end
  end

  defp start_probe(identity, assignment, observed_at, receive_timeout) do
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    Task.Supervisor.async_nolink(supervisor, fn ->
      Sandbox.allow(Repo, owner, self())

      UsageProbe.fetch_from_identity(identity, assignment, observed_at, receive_timeout: receive_timeout)
    end)
  end

  defp probe_fixture(entries) do
    # provenance: synthetic_adversarial
    {:ok, fake} = FakeUpstream.start_link(FakeUpstream.strict_sequence(entries))
    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        chatgpt_account_id: @account_id,
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    {fake, identity, assignment}
  end

  defp usage_request(path, response),
    do: FakeUpstream.expect_request(method: "GET", path: path, respond: response)

  defp timeout_response(:before_headers, release_ref),
    do: {:timeout_before_headers, self(), release_ref}

  defp timeout_response(:mid_stream, release_ref),
    do: {:timeout_mid_stream, "{", self(), release_ref}

  defp weekly_payload, do: quota_payload(604_800)
  defp primary_payload, do: quota_payload(18_000)

  defp quota_payload(window_seconds) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => window_seconds,
          "reset_after_seconds" => 3_600,
          "reset_at" => System.system_time(:second) + 3_600
        }
      }
    }
  end
end
