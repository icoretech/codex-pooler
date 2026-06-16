defmodule CodexPoolerWeb.V1.UnsupportedRoutes do
  @moduledoc false

  @routes [
    %{
      method: "POST",
      router_method: :post,
      router_path: "/images/variations",
      action: :unsupported_post,
      path_info: ["v1", "images", "variations"],
      sample_path: "/v1/images/variations"
    },
    %{
      method: "POST",
      router_method: :post,
      router_path: "/embeddings",
      action: :unsupported_post,
      path_info: ["v1", "embeddings"],
      sample_path: "/v1/embeddings"
    },
    %{
      method: "POST",
      router_method: :post,
      router_path: "/batches",
      action: :unsupported_post,
      path_info: ["v1", "batches"],
      sample_path: "/v1/batches"
    },
    %{
      method: "POST",
      router_method: :post,
      router_path: "/moderations",
      action: :unsupported_post,
      path_info: ["v1", "moderations"],
      sample_path: "/v1/moderations"
    },
    %{
      method: "POST",
      router_method: :post,
      router_path: "/fine_tuning/jobs",
      action: :unsupported_post,
      path_info: ["v1", "fine_tuning", "jobs"],
      sample_path: "/v1/fine_tuning/jobs"
    },
    %{
      method: "GET",
      router_method: :get,
      router_path: "/responses/:response_id",
      action: :unsupported_get,
      path_info: ["v1", "responses", :response_id],
      sample_path: "/v1/responses/resp_fixture"
    },
    %{
      method: "POST",
      router_method: :post,
      router_path: "/responses/:response_id/cancel",
      action: :unsupported_post,
      path_info: ["v1", "responses", :response_id, "cancel"],
      sample_path: "/v1/responses/resp_fixture/cancel"
    },
    %{
      method: "DELETE",
      router_method: :delete,
      router_path: "/responses/:response_id",
      action: :unsupported_delete,
      path_info: ["v1", "responses", :response_id],
      sample_path: "/v1/responses/resp_fixture"
    }
  ]

  @spec router_routes() :: [{atom(), String.t(), atom()}]
  def router_routes do
    Enum.map(@routes, &{&1.router_method, &1.router_path, &1.action})
  end

  @spec test_routes() :: [{atom(), String.t()}]
  def test_routes do
    Enum.map(@routes, &{&1.router_method, &1.sample_path})
  end

  @spec unsupported?(Plug.Conn.t()) :: boolean()
  def unsupported?(%Plug.Conn{method: method, path_info: path_info}) do
    Enum.any?(@routes, &matches?(&1, method, path_info))
  end

  defp matches?(%{method: method, path_info: pattern}, method, path_info) do
    same_path?(pattern, path_info)
  end

  defp matches?(_route, _method, _path_info), do: false

  defp same_path?(pattern, path_info) when length(pattern) == length(path_info) do
    pattern
    |> Enum.zip(path_info)
    |> Enum.all?(fn
      {expected, actual} when is_binary(expected) -> expected == actual
      {expected, actual} when is_atom(expected) -> is_binary(actual) and actual != ""
    end)
  end

  defp same_path?(_pattern, _path_info), do: false
end
