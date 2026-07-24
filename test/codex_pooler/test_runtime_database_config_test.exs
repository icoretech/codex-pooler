defmodule CodexPooler.TestRuntimeDatabaseConfigTest do
  use ExUnit.Case, async: false

  test "a positive partition id enables the bounded partitioned database configuration" do
    with_env(
      %{
        "CODEX_POOLER_TEST_RUN_NAMESPACE" => nil,
        "MIX_TEST_PARTITION" => "4"
      },
      fn ->
        config = Config.Reader.read!("config/test.exs", env: :test)
        repo_config = config[:codex_pooler][CodexPooler.Repo]
        oban_config = Oban.Config.new(config[:codex_pooler][Oban])

        assert repo_config[:database] == "codex_pooler_test4"
        assert repo_config[:pool_size] == 8
        assert oban_config.notifier == {Oban.Notifiers.PG, []}
      end
    )
  end

  test "a make test-fast run namespace produces a safe bounded database name" do
    with_env(
      %{
        "CODEX_POOLER_TEST_POSTGRES_DB" => String.duplicate("Unsafe-Database.Name-", 8),
        "CODEX_POOLER_TEST_RUN_NAMESPACE" => "0123456789abcdef",
        "MIX_TEST_PARTITION" => "4"
      },
      fn ->
        repo_config = read_repo_config()
        database = repo_config[:database]

        assert database =~
                 ~r/^codex_pooler_test_[0-9a-f]{8}_0123456789abcdef_p4$/

        assert byte_size(database) <= 63
      end
    )
  end

  test "all partitions in one invocation share the namespace and differ by numeric partition" do
    databases =
      for partition <- 1..4 do
        with_env(
          %{
            "CODEX_POOLER_TEST_RUN_NAMESPACE" => "fedcba9876543210",
            "MIX_TEST_PARTITION" => Integer.to_string(partition)
          },
          fn -> read_repo_config()[:database] end
        )
      end

    assert Enum.uniq(databases) == databases

    assert Enum.map(databases, &String.replace(&1, ~r/_p[1-4]$/, "_p")) ==
             List.duplicate(String.replace(hd(databases), ~r/_p1$/, "_p"), 4)
  end

  test "different invocation namespaces produce different database and advisory-lock identities" do
    first = partition_database("0123456789abcdef", 1)
    second = partition_database("fedcba9876543210", 1)

    refute first == second
  end

  for invalid_namespace <- ["", "short", "0123456789abcdeg", String.duplicate("a", 17)] do
    test "rejects unsafe invocation namespace #{inspect(invalid_namespace)}" do
      assert_raise RuntimeError, ~r/CODEX_POOLER_TEST_RUN_NAMESPACE/, fn ->
        partition_database(unquote(invalid_namespace), 1)
      end
    end
  end

  test "a missing partition id retains the serial database configuration" do
    assert_serial_config(nil)
  end

  test "a run namespace without a numeric partition retains the serial database configuration" do
    with_env(
      %{
        "CODEX_POOLER_TEST_RUN_NAMESPACE" => "0123456789abcdef",
        "MIX_TEST_PARTITION" => nil
      },
      fn ->
        repo_config = read_repo_config()

        assert repo_config[:database] == "codex_pooler_test"
        assert repo_config[:pool_size] == System.schedulers_online() * 2
      end
    )
  end

  for {label, value} <- [
        {"empty", ""},
        {"malformed", "abc"},
        {"zero", "0"},
        {"negative", "-1"}
      ] do
    test "a #{label} partition id safely retains the serial database configuration" do
      assert_serial_config(unquote(value))
    end
  end

  defp assert_serial_config(partition) do
    with_env(
      %{
        "CODEX_POOLER_TEST_RUN_NAMESPACE" => nil,
        "MIX_TEST_PARTITION" => partition
      },
      fn ->
        config = read_config()
        repo_config = config[:codex_pooler][CodexPooler.Repo]
        oban_config = Oban.Config.new(config[:codex_pooler][Oban])

        assert repo_config[:database] == "codex_pooler_test"
        assert repo_config[:pool_size] == System.schedulers_online() * 2
        assert oban_config.notifier == {Oban.Notifiers.Postgres, []}
      end
    )
  end

  defp partition_database(namespace, partition) do
    with_env(
      %{
        "CODEX_POOLER_TEST_RUN_NAMESPACE" => namespace,
        "MIX_TEST_PARTITION" => Integer.to_string(partition)
      },
      fn -> read_repo_config()[:database] end
    )
  end

  defp read_repo_config do
    read_config()[:codex_pooler][CodexPooler.Repo]
  end

  defp read_config do
    Config.Reader.read!("config/test.exs", env: :test)
  end

  defp with_env(values, fun) when is_map(values) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
