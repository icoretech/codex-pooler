defmodule CodexPooler.Platform.DNSClusterResolverTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Platform.DNSClusterResolver
  import ExUnit.CaptureLog

  defmodule ContractResolver do
    def basename(_node_name), do: "codex_pooler"

    def connect_node(node_name) do
      send(test_pid(), {:connect_node, node_name})
      true
    end

    def list_nodes, do: []

    def lookup(_query, resource_type) do
      send(test_pid(), {:lookup, resource_type})

      DNSClusterResolver.reject_current_pod_ip([
        {10, 42, 0, 130},
        {10, 42, 0, 131}
      ])
    end

    defp test_pid do
      :codex_pooler
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:test_pid)
    end
  end

  describe "reject_current_pod_ip/1" do
    test "matches equivalent IPv6 spellings and preserves neighboring pods" do
      current = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      neighbor = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}

      for pod_ip <- ["2001:db8::1", "2001:0DB8:0000:0000:0000:0000:0000:0001"] do
        with_pod_ip(pod_ip, fn ->
          assert DNSClusterResolver.reject_current_pod_ip([current, neighbor, current]) ==
                   [neighbor]
        end)
      end
    end

    test "empty or malformed pod addresses leave discovery unchanged" do
      records = [{192, 0, 2, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

      for pod_ip <- ["", "not-an-ip"] do
        with_pod_ip(pod_ip, fn ->
          assert DNSClusterResolver.reject_current_pod_ip(records) == records
        end)
      end
    end

    test "node naming and discovery use the distribution runtime" do
      assert DNSClusterResolver.basename(:"sample_app@192.0.2.1") == "sample_app"
      assert DNSClusterResolver.basename(:"sample_app@2001:db8::1") == "sample_app"
      refute Node.self() in DNSClusterResolver.list_nodes()

      assert DNSClusterResolver.connect_node(Node.self()) ==
               if(Node.alive?(), do: true, else: :ignored)
    end

    test "removes only the current pod IPv4 record" do
      with_pod_ip("10.42.0.130", fn ->
        assert DNSClusterResolver.reject_current_pod_ip([
                 {10, 42, 0, 130},
                 {10, 42, 0, 127}
               ]) == [{10, 42, 0, 127}]
      end)
    end

    test "preserves records when POD_IP is missing" do
      records = [{10, 42, 0, 130}]

      with_pod_ip(nil, fn ->
        assert DNSClusterResolver.reject_current_pod_ip(records) == records
      end)
    end

    test "accepts every dns_cluster 0.3 resource type" do
      for resource_type <- [:a, :aaaa, :srv] do
        assert DNSClusterResolver.lookup("invalid.example", resource_type) == []
      end
    end

    test "keeps discovery multi-node safe across A, AAAA, and SRV records" do
      previous_config = Application.get_env(:codex_pooler, ContractResolver)

      on_exit(fn ->
        if previous_config do
          Application.put_env(:codex_pooler, ContractResolver, previous_config)
        else
          Application.delete_env(:codex_pooler, ContractResolver)
        end
      end)

      Application.put_env(:codex_pooler, ContractResolver, test_pid: self())

      with_pod_ip("10.42.0.130", fn ->
        capture_log(fn ->
          assert {:ok, _pid} =
                   start_supervised(
                     {DNSCluster,
                      name: __MODULE__.Cluster,
                      query: "cluster.invalid",
                      resource_types: [:a, :aaaa, :srv],
                      interval: :timer.hours(1),
                      resolver: ContractResolver}
                   )
        end)

        for resource_type <- [:a, :aaaa, :srv] do
          assert_receive {:lookup, ^resource_type}
        end

        assert_receive {:connect_node, :"codex_pooler@10.42.0.131"}
        refute_received {:connect_node, :"codex_pooler@10.42.0.130"}
        refute_received {:connect_node, :"codex_pooler@10.42.0.131"}
      end)
    end
  end

  defp with_pod_ip(value, fun) do
    previous = System.get_env("POD_IP")

    restore = fn ->
      if previous do
        System.put_env("POD_IP", previous)
      else
        System.delete_env("POD_IP")
      end
    end

    # Also on_exit: the ExUnit timeout or a linked crash kills the test before `after` runs.
    on_exit(restore)

    if value do
      System.put_env("POD_IP", value)
    else
      System.delete_env("POD_IP")
    end

    try do
      fun.()
    after
      restore.()
    end
  end
end
