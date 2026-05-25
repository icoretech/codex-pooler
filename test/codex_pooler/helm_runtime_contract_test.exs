defmodule CodexPooler.HelmRuntimeContractTest do
  use ExUnit.Case, async: true

  @chart_path "./charts/codex-pooler"
  @required_secret_env %{
    "DATABASE_URL" => "database-url",
    "SECRET_KEY_BASE" => "secret-key-base",
    "CODEX_POOLER_TOTP_ENCRYPTION_KEY" => "totp-encryption-key",
    "CODEX_POOLER_TOTP_KEY_VERSION" => "totp-key-version",
    "CODEX_POOLER_UPSTREAM_SECRET_KEY" => "upstream-secret-key",
    "CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION" => "upstream-secret-key-version"
  }

  @required_plain_env %{
    "PORT" => ~s("4000"),
    "PHX_HOST" => ~s("codex-pooler.example.com"),
    "POOL_SIZE" => ~s("10"),
    "ECTO_IPV6" => ~s("false"),
    "OBAN_JOBS_QUEUE_LIMIT" => ~s("8"),
    "OBAN_SHUTDOWN_GRACE_PERIOD_MS" => ~s("55000"),
    "LANG" => ~s("C.UTF-8"),
    "LC_ALL" => ~s("C.UTF-8")
  }

  @websocket_owner_forwarding_env "CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING"
  @valid_raw_upstream_secret_key String.duplicate("r", 32)
  @valid_base64_upstream_secret_key Base.encode64(String.duplicate("b", 32))
  @required_inline_secret_args [
    "--set-string",
    "secrets.databaseUrl=postgres://example-postgres/codex_pooler",
    "--set-string",
    "secrets.secretKeyBase=example-secret-key-base",
    "--set-string",
    "secrets.totpEncryptionKey=example-totp-key"
  ]

  @migrated_env [
    "CODEX_POOLER_FILE_MAX_SIZE_BYTES",
    "CODEX_POOLER_UPLOAD_TTL_SECONDS",
    "CODEX_POOLER_ABANDONED_UPLOAD_CLEANUP_INTERVAL_SECONDS",
    "CODEX_POOLER_BRIDGE_OWNER_LEASE_TTL_SECONDS",
    "CODEX_POOLER_BRIDGE_OWNER_LEASE_RENEWAL_SECONDS",
    "CODEX_POOLER_EXPIRED_ALIAS_TTL_SECONDS",
    "CODEX_POOLER_FIREWALL_ALLOWLIST",
    "CODEX_POOLER_TRUSTED_PROXIES",
    "CODEX_POOLER_DECOMPRESSION_ALGORITHMS",
    "CODEX_POOLER_MAX_COMPRESSED_BODY_BYTES",
    "CODEX_POOLER_MAX_DECOMPRESSED_BODY_BYTES",
    "CODEX_POOLER_MAX_DECOMPRESSION_RATIO",
    "CODEX_POOLER_DECOMPRESSION_TIMEOUT_MS",
    "CODEX_POOLER_GATEWAY_DEBUG",
    "CODEX_POOLER_SSE_KEEPALIVE_INTERVAL_MS",
    "CODEX_POOLER_MAX_TRANSCRIPTION_UPLOAD_BYTES",
    "CODEX_POOLER_CIRCUIT_FAILURE_THRESHOLD",
    "CODEX_POOLER_CIRCUIT_OPEN_SECONDS",
    "CODEX_POOLER_CIRCUIT_HALF_OPEN_PROBE_LIMIT",
    "CODEX_POOLER_CIRCUIT_SUCCESS_THRESHOLD",
    "CODEX_POOLER_METRICS_BEARER_TOKEN",
    "CODEX_POOLER_OPERATOR_LOGIN_BASE_URL",
    "CODEX_POOLER_UPSTREAM_CONNECT_TIMEOUT_MS",
    "CODEX_POOLER_UPSTREAM_POOL_TIMEOUT_MS",
    "CODEX_POOLER_UPSTREAM_RECEIVE_TIMEOUT_MS",
    "CODEX_POOLER_MODEL_CONTEXT_WINDOW_OVERRIDES",
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_USERNAME",
    "SMTP_PASSWORD",
    "SMTP_FROM",
    "SMTP_SSL",
    "SMTP_TLS",
    "SMTP_RETRIES"
  ]

  test "default chart keeps Phoenix release role env contracts aligned with runtime" do
    rendered = helm_template!()

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    worker = source_doc!(rendered, "codex-pooler/templates/oban-worker-deployment.yaml")
    scheduler = source_doc!(rendered, "codex-pooler/templates/oban-scheduler-deployment.yaml")
    migration = source_doc!(rendered, "codex-pooler/templates/migration-job.yaml")

    assert_env_value(app, "PHX_SERVER", ~s("true"))
    assert_env_value(app, "OBAN_MODE", "web")
    assert app =~ ~r/replicas: 1\b/
    assert_rolling_strategy(app, 0, 1)
    assert app =~ ~r/terminationGracePeriodSeconds: 75\b/

    assert app =~ ~r/readinessProbe:\n\s+httpGet:\n\s+path: \/readyz/
    assert app =~ ~r/livenessProbe:\n\s+httpGet:\n\s+path: \/healthz/
    assert app =~ ~r/startupProbe:\n\s+httpGet:\n\s+path: \/healthz/
    assert app =~ ~r/startupProbe:[\s\S]*timeoutSeconds: 2/
    assert app =~ "name: X-Forwarded-Proto"
    assert app =~ "value: https"
    assert_env_value(app, "CODEX_POOLER_DRAIN_MARKER_PATH", ~s("/tmp/codex-pooler-draining"))

    assert app =~
             ~s(command: ["/bin/sh", "-c", "touch \\\"$CODEX_POOLER_DRAIN_MARKER_PATH\\\"; sleep 10"])

    assert_rolling_strategy(worker, 0, 1)
    assert worker =~ ~r/terminationGracePeriodSeconds: 75\b/
    refute worker =~ "preStop"

    assert_rolling_strategy(scheduler, 0, 1)
    assert scheduler =~ ~r/terminationGracePeriodSeconds: 75\b/
    refute scheduler =~ "preStop"

    assert_env_value(worker, "OBAN_MODE", "worker")
    assert_env_value(scheduler, "OBAN_MODE", "scheduler")
    assert_env_value(migration, "OBAN_MODE", "web")

    refute_env(worker, "PHX_SERVER")
    refute_env(scheduler, "PHX_SERVER")
    refute_env(migration, "PHX_SERVER")

    assert migration =~ ~s(command: ["/bin/sh", "-lc"])
    assert migration =~ ~S|/app/bin/codex_pooler eval "CodexPooler.Release.migrate()"|

    assert migration =~
             ~S|/app/bin/codex_pooler eval "CodexPooler.Release.import_openai_pricing_from_priv()"|

    Enum.each([app, worker, scheduler, migration], fn doc ->
      Enum.each(@required_secret_env, fn {env_name, secret_key} ->
        assert_secret_env(doc, env_name, secret_key)
      end)

      Enum.each(@required_plain_env, fn {env_name, value} ->
        assert_env_value(doc, env_name, value)
      end)

      Enum.each(@migrated_env, &refute_env(doc, &1))
      refute_env(doc, @websocket_owner_forwarding_env)
    end)
  end

  test "multi-replica app render requires explicit websocket continuity acknowledgement" do
    assert {:error, output} = helm_template_result(["--set", "app.replicaCount=2"])

    assert output =~ "app.replicaCount > 1 is unsafe for backend websocket continuity"
    assert output =~ "post-smoke guard relaxation"
    assert output =~ "app.websocketContinuity.allowUnsafeMultiReplica=true"

    rendered =
      helm_template!([
        "--set",
        "app.replicaCount=2",
        "--set",
        "app.websocketContinuity.allowUnsafeMultiReplica=true"
      ])

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    assert app =~ ~r/replicas: 2\b/
    refute_env(app, @websocket_owner_forwarding_env)
  end

  test "owner forwarding renders only app env when app clustering participates" do
    rendered =
      helm_template!([
        "--set",
        "clustering.enabled=true",
        "--set",
        "app.websocketContinuity.ownerForwarding.enabled=true"
      ])

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    worker = source_doc!(rendered, "codex-pooler/templates/oban-worker-deployment.yaml")
    scheduler = source_doc!(rendered, "codex-pooler/templates/oban-scheduler-deployment.yaml")
    migration = source_doc!(rendered, "codex-pooler/templates/migration-job.yaml")

    assert_env_value(app, @websocket_owner_forwarding_env, ~s("true"))

    assert_env_value(
      app,
      "DNS_CLUSTER_QUERY",
      ~s("codex-pooler-cluster.default.svc.cluster.local")
    )

    Enum.each([worker, scheduler, migration], fn doc ->
      refute_env(doc, @websocket_owner_forwarding_env)
    end)
  end

  test "owner forwarding keeps multi-replica guard until unsafe acknowledgement" do
    owner_forwarding_args = [
      "--set",
      "app.replicaCount=2",
      "--set",
      "clustering.enabled=true",
      "--set",
      "app.websocketContinuity.ownerForwarding.enabled=true"
    ]

    assert {:error, output} = helm_template_result(owner_forwarding_args)
    assert output =~ "app.replicaCount > 1 is unsafe for backend websocket continuity"
    assert output =~ "post-smoke guard relaxation"

    rendered =
      helm_template!(
        owner_forwarding_args ++
          ["--set", "app.websocketContinuity.allowUnsafeMultiReplica=true"]
      )

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    worker = source_doc!(rendered, "codex-pooler/templates/oban-worker-deployment.yaml")
    scheduler = source_doc!(rendered, "codex-pooler/templates/oban-scheduler-deployment.yaml")
    migration = source_doc!(rendered, "codex-pooler/templates/migration-job.yaml")

    assert app =~ ~r/replicas: 2\b/
    assert_env_value(app, @websocket_owner_forwarding_env, ~s("true"))

    Enum.each([worker, scheduler, migration], fn doc ->
      refute_env(doc, @websocket_owner_forwarding_env)
    end)
  end

  test "owner forwarding requires clustering to be enabled" do
    assert {:error, output} =
             helm_template_result([
               "--set",
               "app.websocketContinuity.ownerForwarding.enabled=true"
             ])

    assert output =~
             "app.websocketContinuity.ownerForwarding.enabled requires clustering.enabled=true"
  end

  test "owner forwarding requires app clustering participation" do
    assert {:error, output} =
             helm_template_result([
               "--set",
               "clustering.enabled=true",
               "--set",
               "clustering.participants.app=false",
               "--set",
               "app.websocketContinuity.ownerForwarding.enabled=true"
             ])

    assert output =~
             "app.websocketContinuity.ownerForwarding.enabled requires clustering.participants.app=true"

    assert output =~ "worker or scheduler clustering cannot satisfy websocket owner forwarding"
  end

  test "clustering render supplies release distribution env for runtime nodes only" do
    rendered = helm_template!(["--set", "clustering.enabled=true"])

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    worker = source_doc!(rendered, "codex-pooler/templates/oban-worker-deployment.yaml")
    scheduler = source_doc!(rendered, "codex-pooler/templates/oban-scheduler-deployment.yaml")
    migration = source_doc!(rendered, "codex-pooler/templates/migration-job.yaml")

    Enum.each([app, worker, scheduler], fn doc ->
      assert_env_value(
        doc,
        "DNS_CLUSTER_QUERY",
        ~s("codex-pooler-cluster.default.svc.cluster.local")
      )

      assert doc =~ "name: POD_IP"
      assert doc =~ "fieldPath: status.podIP"

      assert_env_value(doc, "RELEASE_DISTRIBUTION", "name")

      assert_env_value(
        doc,
        "ERL_AFLAGS",
        ~s("-kernel inet_dist_listen_min 9000 inet_dist_listen_max 9000")
      )

      assert_secret_env(doc, "RELEASE_COOKIE", "release-cookie")
      assert_env_value(doc, "RELEASE_NODE", "\"codex_pooler@$(POD_IP)\"")
      assert doc =~ ~s(subdomain: codex-pooler-cluster)
    end)

    refute_env(migration, "POD_IP")
    refute_env(migration, "DNS_CLUSTER_QUERY")
    refute_env(migration, "RELEASE_DISTRIBUTION")
    refute_env(migration, "RELEASE_COOKIE")
  end

  test "chart-managed upstream secret key accepts raw and base64 32-byte values" do
    for key <- [@valid_raw_upstream_secret_key, @valid_base64_upstream_secret_key] do
      rendered = helm_template!(inline_secret_args(key))
      secret = source_doc!(rendered, "codex-pooler/templates/secret.yaml")

      assert secret =~ "upstream-secret-key:"
      refute secret =~ "CODEX_POOLER_UPSTREAM_SECRET_KEY must"
    end
  end

  test "chart-managed upstream secret key rejects malformed and wrong-length values safely" do
    invalid_cases = ["not-base64!!!!", Base.encode64("too-short")]

    for key <- invalid_cases do
      assert {:error, output} = helm_template_result(inline_secret_args(key))

      assert output =~
               "secrets.upstreamSecretKey (CODEX_POOLER_UPSTREAM_SECRET_KEY) must be 32 raw bytes or base64-encoded 32 bytes"

      refute output =~ key
    end
  end

  test "existing Secret deployments do not validate absent literal upstream secret keys" do
    rendered =
      helm_template!([
        "--set",
        "secrets.create=false",
        "--set-string",
        "secrets.existingSecret=codex-pooler-secrets",
        "--set-string",
        "secrets.upstreamSecretKey=not-base64!!!!"
      ])

    app = source_doc!(rendered, "codex-pooler/templates/app-deployment.yaml")
    assert_secret_env(app, "CODEX_POOLER_UPSTREAM_SECRET_KEY", "upstream-secret-key")
    refute rendered =~ "upstream-secret-key: not-base64"
  end

  defp helm_template!(extra_args \\ []) do
    case helm_template_result(extra_args) do
      {:ok, rendered} -> rendered
      {:error, output} -> flunk("helm template failed:\n#{output}")
    end
  end

  defp helm_template_result(extra_args) do
    args = ["template", "codex-pooler", @chart_path, "--namespace", "default"] ++ extra_args

    case System.cmd("helm", args, stderr_to_stdout: true) do
      {rendered, 0} -> {:ok, rendered}
      {output, _status} -> {:error, output}
    end
  end

  defp inline_secret_args(upstream_secret_key) do
    ["--set", "secrets.create=true"] ++
      @required_inline_secret_args ++
      ["--set-string", "secrets.upstreamSecretKey=#{upstream_secret_key}"]
  end

  defp source_doc!(rendered, source) do
    rendered
    |> String.split(~r/^---\n/m, trim: true)
    |> Enum.find(&String.contains?(&1, "# Source: #{source}"))
    |> case do
      nil -> flunk("missing rendered source #{source}")
      doc -> doc
    end
  end

  defp assert_env_value(doc, name, value) do
    assert doc =~ ~r/- name: #{Regex.escape(name)}\n\s+value: #{Regex.escape(value)}(?:\n|$)/
  end

  defp assert_rolling_strategy(doc, max_unavailable, max_surge) do
    assert doc =~
             ~r/strategy:\n\s+type: RollingUpdate\n\s+rollingUpdate:\n\s+maxUnavailable: #{max_unavailable}\n\s+maxSurge: #{max_surge}/
  end

  defp refute_env(doc, name) do
    refute doc =~ ~r/- name: #{Regex.escape(name)}\b/
  end

  defp assert_secret_env(doc, name, key) do
    assert doc =~
             ~r/- name: #{Regex.escape(name)}\n\s+valueFrom:\n\s+secretKeyRef:\n\s+name: codex-pooler-secrets\n\s+key: "?#{Regex.escape(key)}"?(?:\n|$)/
  end
end
