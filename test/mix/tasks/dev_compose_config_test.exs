defmodule CodexPooler.MixTasks.DevComposeConfigTest do
  use CodexPooler.UnixIntegrationCase,
    async: true,
    tools: ~w(docker),
    docker_compose: true

  @compose Path.expand("../../../docker-compose.dev.yml", __DIR__)
  @public_compose Path.expand("../../../docker-compose.yml", __DIR__)
  @generate_env Path.expand("../../../scripts/self-host/generate-env.sh", __DIR__)

  @tag :tmp_dir
  test "an existing public install keeps its PostgreSQL image and named volume until explicit opt-in", %{tmp_dir: tmp_dir} do
    File.cp!(@public_compose, Path.join(tmp_dir, "docker-compose.yml"))
    env_path = Path.join(tmp_dir, ".env")
    assert {_, 0} = System.cmd("sh", [@generate_env, env_path])
    old_env = env_path |> File.read!() |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "CODEX_POOLER_POSTGRES_IMAGE=")) |> Enum.join("\n")
    File.write!(env_path, old_env)

    for {choice, expected} <- [{nil, "postgres:18"}, {"postgres:19", "postgres:19"}] do
      assert {json, 0} =
               System.cmd("docker", ["compose", "-p", "sample-pooler", "config", "--format", "json", "db"],
                 cd: tmp_dir,
                 env: [{"COMPOSE_FILE", nil}, {"POSTGRES_IMAGE", "postgres:latest"}, {"CODEX_POOLER_POSTGRES_IMAGE", choice}]
               )

      config = CodexPooler.JSON.decode!(json)
      db = config["services"]["db"]
      assert db["image"] == expected
      assert [%{"source" => "codex-pooler-postgres", "target" => "/var/lib/postgresql"}] = db["volumes"]
      assert config["volumes"]["codex-pooler-postgres"]["name"] == "sample-pooler_codex-pooler-postgres"
    end
  end

  test "development PostgreSQL publishes only on loopback by default" do
    db = rendered_db([])

    assert [%{"host_ip" => "127.0.0.1", "published" => "5433", "target" => 5432, "protocol" => "tcp"}] = db["ports"]
    assert db["image"] == "postgres:18"
    assert [%{"type" => "volume", "target" => "/var/lib/postgresql"}] = db["volumes"]
  end

  test "empty bind and port overrides retain the loopback defaults" do
    db = rendered_db([{"POSTGRES_BIND_ADDRESS", ""}, {"POSTGRES_PORT", ""}])

    assert [%{"host_ip" => "127.0.0.1", "published" => "5433", "target" => 5432}] = db["ports"]
  end

  test "development PostgreSQL preserves the host port override on loopback" do
    db = rendered_db([{"POSTGRES_PORT", "55433"}])

    assert [%{"host_ip" => "127.0.0.1", "published" => "55433", "target" => 5432}] = db["ports"]
  end

  test "PostgreSQL 19 is an explicit opt-in on the same volume mount" do
    db = rendered_db([{"CODEX_POOLER_POSTGRES_IMAGE", "postgres:19"}])

    assert db["image"] == "postgres:19"
    assert [%{"type" => "volume", "target" => "/var/lib/postgresql"}] = db["volumes"]
  end

  test "an explicit bind address permits intentional remote development" do
    db = rendered_db([{"POSTGRES_BIND_ADDRESS", "0.0.0.0"}, {"POSTGRES_PORT", "55434"}])

    assert [%{"host_ip" => "0.0.0.0", "published" => "55434", "target" => 5432}] = db["ports"]
  end

  defp rendered_db(overrides) do
    env = Map.merge(%{"POSTGRES_BIND_ADDRESS" => nil, "POSTGRES_PORT" => nil, "POSTGRES_IMAGE" => "postgres:latest", "CODEX_POOLER_POSTGRES_IMAGE" => nil}, Map.new(overrides))

    {output, code} =
      System.cmd("docker", ["compose", "--env-file", "/dev/null", "-f", @compose, "config", "--format", "json"],
        env: Map.to_list(env),
        stderr_to_stdout: true
      )

    assert code == 0, output
    output |> CodexPooler.JSON.decode!() |> get_in(["services", "db"])
  end
end
