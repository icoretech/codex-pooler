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

    if value do
      System.put_env("POD_IP", value)
    else
      System.delete_env("POD_IP")
    end

    try do
      fun.()
    after
      if previous do
        System.put_env("POD_IP", previous)
      else
        System.delete_env("POD_IP")
      end
    end
  end
end
